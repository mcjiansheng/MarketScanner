from __future__ import annotations

import json
import hashlib
import math
import os
import re
import shutil
import sqlite3
import subprocess
import tempfile
import time
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from tools.PriorMap.coordinate_system import (
    source_point_to_map,
    source_rectangle_center,
    source_rectangle_polygon,
    source_rotation_to_yaw,
)
from tools.PriorMap.distance_field import build_distance_fields, decode_level
from tools.PriorMap.prior_map_schema import (
    build_package_manifest,
    canonical_safe_name,
    validate_package,
)
from tools.PriorMap.render_prior_map import render_package
from tools.PriorMap.replay_localization import replay
from tools.PriorMap.replay_stage2 import (
    Pose as Stage2Pose,
    match as stage2_match,
    replay as replay_stage2,
)
from tools.PriorMap.spatial_index import PriorMapSpatialIndex
from tools.PriorMap.stage1_localizer import Pose2D, StageOneLocalizer
from tools.PriorMap.xlsx_to_prior_map import (
    ConversionError,
    _canonical_business_sha256,
    _polyline_abscissa,
    _spatial_index,
    convert_workbook,
)
from tools.PriorMap import xlsx_reader as xlsx_reader_module
from tools.PriorMap.xlsx_reader import BasicMapInfo, WorkbookError, read_workbook


def write_workbook(
    path: Path,
    rows: list[tuple[str, str]],
    *,
    basic_info: dict[str, object] | None = None,
    shelf_rows: list[list[object]] | None = None,
    include_basic: bool = True,
) -> None:
    """Write a self-contained fixture workbook for the current contract.

    ``shelf_rows=None`` omits the legacy audit-only worksheet.  Setting
    ``include_basic=False`` is reserved for explicit legacy importer tests.
    """

    if basic_info is None:
        basic_info = {
            "map_name": "fixture",
            "width": 2000,
            "height": 1000,
            "storeCode": "s1",
            "scale": 20,
        }
    strings: list[str] = []

    def shared_index(value: object) -> int:
        strings.append(str(value))
        return len(strings) - 1

    def sheet_xml(values: list[list[object]]) -> str:
        xml_rows: list[str] = []
        for row_index, values_row in enumerate(values, start=1):
            cells: list[str] = []
            for column_index, value in enumerate(values_row, start=1):
                number = column_index
                letters = ""
                while number:
                    number, remainder = divmod(number - 1, 26)
                    letters = chr(ord("A") + remainder) + letters
                cells.append(
                    f'<c r="{letters}{row_index}" t="s"><v>{shared_index(value)}</v></c>'
                )
            xml_rows.append(f'<row r="{row_index}">{"".join(cells)}</row>')
        return (
            '<?xml version="1.0"?><worksheet '
            'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            f'<sheetData>{"".join(xml_rows)}</sheetData></worksheet>'
        )

    sheets: list[tuple[str, str]] = []
    if include_basic:
        basic_headers = list(basic_info)
        sheets.append(
            (
                "Basic Info",
                sheet_xml(
                    [basic_headers, [basic_info[name] for name in basic_headers]]
                ),
            )
        )
    if shelf_rows is not None:
        sheets.append(("Shelf Info", sheet_xml(shelf_rows)))
    sheets.append(
        (
            "Element Info",
            sheet_xml([["floor", "element"], *[[floor, element] for floor, element in rows]]),
        )
    )
    escaped_strings = "".join(
        "<si><t>"
        + value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        + "</t></si>"
        for value in strings
    )
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        overrides = "".join(
            '<Override PartName="/xl/worksheets/sheet{index}.xml" '
            'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
            .format(index=index)
            for index in range(1, len(sheets) + 1)
        )
        archive.writestr(
            "[Content_Types].xml",
            '<?xml version="1.0"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            + overrides
            +
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
            '<sheets>'
            + "".join(
                f'<sheet name="{name}" sheetId="{index}" r:id="rId{index}"/>'
                for index, (name, _xml) in enumerate(sheets, start=1)
            )
            + '</sheets></workbook>',
        )
        archive.writestr(
            "xl/_rels/workbook.xml.rels",
            '<?xml version="1.0"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            + "".join(
                '<Relationship Id="rId{index}" '
                'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
                'Target="worksheets/sheet{index}.xml"/>'.format(index=index)
                for index in range(1, len(sheets) + 1)
            )
            +
            "</Relationships>",
        )
        archive.writestr(
            "xl/sharedStrings.xml",
            f'<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="{len(strings)}" uniqueCount="{len(strings)}">{escaped_strings}</sst>',
        )
        for index, (_name, xml) in enumerate(sheets, start=1):
            archive.writestr(f"xl/worksheets/sheet{index}.xml", xml)


def rewrite_xlsx_member(
    source: Path,
    target: Path,
    member: str,
    transform: object,
) -> None:
    """Copy an XLSX fixture while deterministically rewriting one member."""

    with zipfile.ZipFile(source) as archive:
        entries = [(info, archive.read(info.filename)) for info in archive.infolist()]
    with zipfile.ZipFile(target, "w") as archive:
        for info, data in entries:
            archive.writestr(info, transform(data) if info.filename == member else data)


def _canonical_json_elements(business_elements: list) -> list[dict]:
    """Builds normalized elements for a canonical JSON fixture, matching
    the on-device normalizer (and the PC coordinate_system oracle) so the
    three-format parity holds. Geometry fields are computed with the same
    source-to-map contract used by XLSX/CSV import (top-left origin)."""
    from tools.PriorMap.coordinate_system import (
        legacy_center_pivot_rectangle_center,
        legacy_center_pivot_rectangle_polygon,
        polygon_bounds,
        source_point_to_map,
    )

    elements: list[dict] = []
    for index, (floor, value) in enumerate(business_elements):
        shape_type = value["shapeType"]
        row = index + 2
        geometry: dict | None = None
        bounds: dict | None = None
        center: list | None = None
        yaw: float | None = None
        if shape_type in {"MapShelf", "MapTable", "MapPillar", "MapTableFeature"}:
            polygon = legacy_center_pivot_rectangle_polygon(
                value["x"], value["y"], value["width"], value["height"],
                float(value.get("rotation", 0)),
            )
            geometry = {"type": "polygon", "coordinates": polygon}
            bounds = polygon_bounds(polygon).as_dict()
            center = list(legacy_center_pivot_rectangle_center(
                value["x"], value["y"], value["width"], value["height"],
            ))
            yaw = round(-float(value.get("rotation", 0)) * math.pi / 180.0, 9)
        elif shape_type == "MapCross":
            points = value["points"]
            coordinates = [
                list(source_point_to_map(float(points[i]), float(points[i + 1])))
                for i in range(0, len(points), 2)
            ]
            geometry = {"type": "line_string", "coordinates": coordinates}
            bounds = polygon_bounds(coordinates).as_dict()
        elif shape_type == "MapRoadPoint":
            point = list(source_point_to_map(value["x"], value["y"]))
            geometry = {"type": "point", "coordinates": point}
            bounds = {
                "min_x_m": point[0], "min_y_m": point[1],
                "max_x_m": point[0], "max_y_m": point[1],
                "width_m": 0.0, "height_m": 0.0,
            }
            center = point
        element: dict = {
            "id": f"f{floor}-r{row}",
            "source_row": row,
            "floor_id": str(floor),
            "shape_type": shape_type,
            "visible": value.get("visible", True),
            "locked": False,
            "code": str(value.get("code", "")),
            "cross_code": str(value.get("crossCode", "")),
            "row_flag": str(value.get("rowFlag", "")),
            "subsection": value.get("subsection"),
            "source": value,
        }
        if geometry is not None:
            element["geometry"] = geometry
        if bounds is not None:
            element["bounds"] = bounds
        if center is not None:
            element["center_m"] = center
        if yaw is not None:
            element["yaw_rad"] = yaw
        elements.append(element)
    return elements


def _write_formula_xlsx(path: Path) -> None:
    """Writes an Element Info workbook whose floor cell is a formula —
    the mobile importer must reject it with map_source_formula_not_supported."""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(
            "[Content_Types].xml",
            '<?xml version="1.0"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
            '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
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
            "xl/worksheets/sheet1.xml",
            '<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            '<sheetData>'
            '<row r="1"><c r="A1" t="inlineStr"><is><t>floor</t></is></c>'
            '<c r="B1" t="inlineStr"><is><t>element</t></is></c></row>'
            '<row r="2"><c r="A2"><f>=1+1</f><v>2</v></c>'
            '<c r="B2" t="inlineStr"><is><t>{"shapeType":"MapShelf"}</t></is></c></row>'
            "</sheetData></worksheet>",
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
    return [(floor, json.dumps(value, ensure_ascii=False)) for floor, value in values]


class CoordinateSystemTests(unittest.TestCase):
    def test_source_coordinates_and_rotation_have_one_defined_conversion(self) -> None:
        self.assertEqual(source_point_to_map(250, 300), (2.5, -3.0))
        self.assertAlmostEqual(source_rotation_to_yaw(90), -math.pi / 2)
        polygon = source_rectangle_polygon(100, 200, 300, 100, 90)
        self.assertEqual(
            {(round(point[0], 2), round(point[1], 2)) for point in polygon},
            {(1.0, -2.0), (1.0, -5.0), (0.0, -5.0), (0.0, -2.0)},
        )
        self.assertEqual(source_rectangle_center(100, 200, 300, 100, 90), (0.5, -3.5))
        self.assertIn([1.0, -2.0], polygon)

    def test_top_left_anchor_is_frozen_for_cardinal_and_arbitrary_rotations(self) -> None:
        anchor = list(source_point_to_map(4193, 390))
        for rotation in (0, 90, 180, 270, 45):
            with self.subTest(rotation=rotation):
                polygon = source_rectangle_polygon(4193, 390, 1163, 106, rotation)
                self.assertEqual(
                    polygon[0],
                    anchor,
                    "canonical P0 must remain the top-left rotation anchor",
                )
                centroid = (
                    round(sum(point[0] for point in polygon) / 4.0, 6),
                    round(sum(point[1] for point in polygon) / 4.0, 6),
                )
                center = source_rectangle_center(4193, 390, 1163, 106, rotation)
                self.assertAlmostEqual(center[0], centroid[0], places=5)
                self.assertAlmostEqual(center[1], centroid[1], places=5)


class StandardWorkbookContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.rows = [
            (
                "1",
                json.dumps(
                    {
                        "shapeType": "MapShelf",
                        "x": 100,
                        "y": 100,
                        "width": 200,
                        "height": 50,
                        "rotation": 0,
                        "code": "S1",
                        "visible": True,
                    }
                ),
            )
        ]

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_basic_info_is_authoritative_and_shelf_info_is_audit_only(self) -> None:
        workbook = self.root / "standard.xlsx"
        write_workbook(
            workbook,
            self.rows,
            basic_info={
                "map_name": "Piaseczno",
                "width": 13129,
                "height": 8770,
                "storeCode": "CAPL.2794",
                "scale": 20,
            },
            shelf_rows=[["code"], ["legacy-1"], ["legacy-2"]],
        )
        result = read_workbook(workbook)
        self.assertEqual(result.basic_info.map_name, "Piaseczno")
        self.assertEqual(result.basic_info.store_code, "CAPL.2794")
        self.assertEqual(result.basic_info.width_cm, 13129)
        self.assertEqual(result.basic_info.height_cm, 8770)
        self.assertEqual(result.basic_info.source_scale, 20)
        self.assertTrue(result.legacy_shelf_info.present)
        self.assertEqual(result.legacy_shelf_info.row_count, 2)
        with self.assertRaises(ConversionError):
            convert_workbook(workbook, self.root / "bad-store", store_id="OTHER")
        with self.assertRaises(ConversionError):
            convert_workbook(workbook, self.root / "bad-name", map_name="Other")

    def test_prior_map_id_uses_canonical_lowercase_filesystem_slug(self) -> None:
        cases = (
            ("Piaseczno", "piaseczno-"),
            ("Kohl's 1224", "kohl-s-1224-"),
            ("TianHong.02402", "tianhong.02402-"),
            ("北京昌平6599", "6599-"),
            ("İstanbul", "stanbul-"),
            ("北京A9", "a9-"),
            ("A" * 200, f"{'a' * 115}-"),
        )
        self.assertEqual(canonical_safe_name("Kelvin"), "elvin")
        for index, (map_name, expected_prefix) in enumerate(cases):
            with self.subTest(map_name=map_name):
                workbook = self.root / f"mixed-case-{index}.xlsx"
                write_workbook(
                    workbook,
                    self.rows,
                    basic_info={
                        "map_name": map_name,
                        "width": 2000,
                        "height": 1000,
                        "storeCode": f"store.{index}",
                    },
                )
                package = convert_workbook(
                    workbook, self.root / f"mixed-case-package-{index}")
                manifest = json.loads(
                    (package / "manifest.json").read_text(encoding="utf-8"))
                prior_map_id = manifest["prior_map_id"]
                self.assertTrue(prior_map_id.startswith(expected_prefix))
                self.assertRegex(prior_map_id, r"^[a-z0-9._-]+$")
                self.assertEqual(prior_map_id, prior_map_id.lower())
                self.assertLessEqual(len(prior_map_id), 128)
                self.assertTrue(validate_package(package)["valid"])

        # Pre-canonical v2 packages keep their exact uppercase bytes only for
        # explicit read-only diagnostics. Production validation/loading and
        # MobileMapLibrary authority reject them and require re-import.
        legacy_package = self.root / "mixed-case-package-0"
        legacy_manifest_path = legacy_package / "manifest.json"
        legacy_manifest = json.loads(
            legacy_manifest_path.read_text(encoding="utf-8"))
        legacy_manifest["prior_map_id"] = (
            "Piaseczno-"
            + legacy_manifest["canonical_source_sha256"][:12]
        )
        legacy_manifest_path.write_text(
            json.dumps(
                legacy_manifest,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        (legacy_package / "package_manifest.json").write_text(
            json.dumps(
                build_package_manifest(legacy_package),
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        production_validation = validate_package(legacy_package)
        self.assertFalse(production_validation["valid"])
        self.assertIn(
            "map_id",
            {error["code"] for error in production_validation["errors"]},
        )
        self.assertTrue(
            validate_package(
                legacy_package,
                allow_legacy_v2_identifier_for_diagnostics=True,
            )["valid"]
        )

    def test_mapcase02_pc_frozen_golden_when_fixture_is_present(self) -> None:
        repository = Path(__file__).resolve().parents[3]
        workbook = repository / "map/mapcase02/mapcase02.xlsx"
        if not workbook.is_file():
            self.skipTest("ignored local MapCase02 workbook fixture is unavailable")

        expected_source_sha = (
            "1ddf428fc4dd6e4e8bd33258d0cbfaab87b809c4dedd6b8baca9e167c14b5e6a"
        )
        expected_canonical_sha = (
            "5ddfac7dc439afc45abdcf800b799c05d53704895b620d161ef08a442c55b2db"
        )
        expected_package_sha = (
            "41332d093e652ec2de94f0f86b8f15107cd6f67f3b2e5ddec1c0685ab4d7d3be"
        )
        expected_preview_sha = (
            "d0c02be63dff3ab002dcf931ce7d0c5149152b78bea139fb1b0a2d86be196a18"
        )

        self.assertEqual(
            hashlib.sha256(workbook.read_bytes()).hexdigest(),
            expected_source_sha,
            "the formal MapCase02 workbook bytes drifted",
        )
        package = convert_workbook(workbook, self.root / "mapcase02-pc-golden")
        manifest = json.loads(
            (package / "manifest.json").read_text(encoding="utf-8")
        )
        package_manifest = json.loads(
            (package / "package_manifest.json").read_text(encoding="utf-8")
        )
        validation = validate_package(package)

        self.assertTrue(validation["valid"], validation["errors"])
        self.assertEqual(manifest["source_sha256"], expected_source_sha)
        self.assertEqual(
            manifest["canonical_source_sha256"], expected_canonical_sha
        )
        self.assertEqual(manifest["prior_map_id"], "piaseczno-5ddfac7dc439")
        self.assertEqual(package_manifest["package_sha256"], expected_package_sha)
        self.assertEqual(
            hashlib.sha256((package / "preview.png").read_bytes()).hexdigest(),
            expected_preview_sha,
        )
        self.assertEqual(
            (
                manifest["source_element_count"],
                manifest["active_element_count"],
                manifest["shelf_count"],
                manifest["fixed_structure_count"],
                manifest["road_element_count"],
                manifest["presentation_ignored_count"],
            ),
            (1838, 1630, 1301, 329, 0, 208),
        )

    def test_missing_basic_info_requires_explicit_legacy_mode(self) -> None:
        workbook = self.root / "legacy.xlsx"
        write_workbook(workbook, self.rows, include_basic=False)
        with self.assertRaises(WorkbookError):
            read_workbook(workbook)
        package = convert_workbook(
            workbook,
            self.root / "legacy-package",
            store_id="s1",
            allow_legacy_element_only=True,
        )
        manifest = json.loads((package / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["version"], 1)
        self.assertNotIn("source_canvas", manifest)
        self.assertNotIn("source_map_info", manifest)
        shelves = json.loads((package / "shelves.json").read_text(encoding="utf-8"))
        self.assertEqual(shelves["version"], 1)
        self.assertNotIn("shelf_segments", shelves)
        self.assertTrue(validate_package(package)["valid"])

    def test_formal_workbook_rejects_every_malformed_element_row(self) -> None:
        workbook = self.root / "malformed-formal.xlsx"
        write_workbook(workbook, [*self.rows, ("1", "{bad json")])
        parsed = read_workbook(workbook)
        self.assertEqual(len(parsed.malformed_rows), 1)
        output = self.root / "malformed-formal-output"
        with self.assertRaisesRegex(
            ConversionError,
            "reject every malformed Element Info row",
        ):
            convert_workbook(workbook, output)
        self.assertFalse(output.exists())

    def test_duplicate_official_and_hash_derived_business_identity_are_blockers(
        self,
    ) -> None:
        official = self.root / "duplicate-official.xlsx"
        write_workbook(
            official,
            [
                (
                    "1",
                    json.dumps(
                        {
                            "shapeType": "MapShelf",
                            "sourceId": "duplicate-shelf",
                            "x": 100,
                            "y": 100,
                            "width": 200,
                            "height": 50,
                            "code": "S1",
                        }
                    ),
                ),
                (
                    "1",
                    json.dumps(
                        {
                            "shapeType": "MapShelf",
                            "sourceId": "duplicate-shelf",
                            "x": 500,
                            "y": 100,
                            "width": 200,
                            "height": 50,
                            "code": "S2",
                        }
                    ),
                ),
            ],
        )
        with self.assertRaisesRegex(ConversionError, "Duplicate business element identity"):
            convert_workbook(official, self.root / "duplicate-official-output")

        hash_derived = self.root / "duplicate-hash-derived.xlsx"
        duplicate_row = json.dumps(
            {
                "shapeType": "MapShelf",
                "x": 100,
                "y": 100,
                "width": 200,
                "height": 50,
                "code": "S1",
            }
        )
        write_workbook(hash_derived, [("1", duplicate_row), ("1", duplicate_row)])
        with self.assertRaisesRegex(ConversionError, "Duplicate business element identity"):
            convert_workbook(hash_derived, self.root / "duplicate-hash-output")

    def test_optional_scale_is_metadata_only_and_duplicate_basic_header_is_rejected(
        self,
    ) -> None:
        no_scale = self.root / "no-scale.xlsx"
        scale_20 = self.root / "scale-20.xlsx"
        scale_40 = self.root / "scale-40.xlsx"
        common = {
            "map_name": "fixture",
            "width": 2000,
            "height": 1000,
            "storeCode": "s1",
        }
        write_workbook(no_scale, self.rows, basic_info=common)
        write_workbook(scale_20, self.rows, basic_info={**common, "scale": 20})
        write_workbook(scale_40, self.rows, basic_info={**common, "scale": 40})

        self.assertIsNone(read_workbook(no_scale).basic_info.source_scale)
        packages = [
            convert_workbook(no_scale, self.root / "package-no-scale"),
            convert_workbook(scale_20, self.root / "package-scale-20"),
            convert_workbook(scale_40, self.root / "package-scale-40"),
        ]
        manifests = [
            json.loads((package / "manifest.json").read_text(encoding="utf-8"))
            for package in packages
        ]
        elements = [
            json.loads((package / "elements.json").read_text(encoding="utf-8"))
            for package in packages
        ]
        self.assertIsNone(manifests[0]["source_canvas"]["source_scale"])
        self.assertEqual(elements[0]["elements"], elements[1]["elements"])
        self.assertEqual(elements[1]["elements"], elements[2]["elements"])
        self.assertEqual(manifests[0]["bounds"], manifests[1]["bounds"])
        self.assertEqual(manifests[1]["bounds"], manifests[2]["bounds"])
        self.assertNotEqual(
            manifests[1]["canonical_source_sha256"],
            manifests[2]["canonical_source_sha256"],
            "scale is identity metadata but must never alter physical geometry",
        )

        duplicate = self.root / "duplicate-basic-header.xlsx"
        rewrite_xlsx_member(
            scale_20,
            duplicate,
            "xl/sharedStrings.xml",
            lambda data: data.replace(
                b"<si><t>height</t></si>",
                b"<si><t>width</t></si>",
                1,
            ),
        )
        with self.assertRaisesRegex(WorkbookError, "duplicate header"):
            read_workbook(duplicate)

    def test_duplicate_workbook_relationship_id_is_rejected(self) -> None:
        workbook = self.root / "relationships.xlsx"
        duplicate = self.root / "relationships-duplicate.xlsx"
        write_workbook(workbook, self.rows)
        rewrite_xlsx_member(
            workbook,
            duplicate,
            "xl/_rels/workbook.xml.rels",
            lambda data: data.replace(
                b"</Relationships>",
                (
                    b'<Relationship Id="rId1" '
                    b'Type="http://schemas.openxmlformats.org/officeDocument/2006/'
                    b'relationships/worksheet" Target="worksheets/sheet9.xml"/>'
                    b"</Relationships>"
                ),
                1,
            ),
        )
        with self.assertRaisesRegex(WorkbookError, "duplicate ID"):
            read_workbook(duplicate)

    def test_row_and_cell_references_are_unique_monotonic_and_consistent(self) -> None:
        workbook = self.root / "row-reference.xlsx"
        write_workbook(workbook, self.rows)
        mutations = {
            "missing-row": lambda data: data.replace(
                b'<row r="2">', b"<row>", 1
            ),
            "duplicate-row": lambda data: data.replace(
                b'<row r="2"><c r="A2"', b'<row r="1"><c r="A1"', 1
            ).replace(b'<c r="B2"', b'<c r="B1"', 1),
            "mismatched-cell": lambda data: data.replace(
                b'<c r="A2"', b'<c r="A3"', 1
            ),
            "duplicate-cell": lambda data: data.replace(
                b'</row></sheetData>',
                b'<c r="A2"><v>0</v></c></row></sheetData>',
                1,
            ),
        }
        for label, transform in mutations.items():
            with self.subTest(label=label):
                mutated = self.root / f"{label}.xlsx"
                rewrite_xlsx_member(
                    workbook,
                    mutated,
                    "xl/worksheets/sheet2.xml",
                    transform,
                )
                with self.assertRaises(WorkbookError):
                    read_workbook(mutated)

    def test_element_limit_counts_source_business_rows(self) -> None:
        workbook = self.root / "element-limit.xlsx"
        write_workbook(workbook, [*self.rows, *self.rows])
        self.assertEqual(xlsx_reader_module.MAXIMUM_ELEMENTS, 100_000)
        with mock.patch.object(xlsx_reader_module, "MAXIMUM_ELEMENTS", 1):
            with self.assertRaisesRegex(WorkbookError, "100,000-element limit"):
                read_workbook(workbook)

    def test_shared_string_and_column_references_fail_closed(self) -> None:
        workbook = self.root / "reference-contract.xlsx"
        write_workbook(workbook, self.rows)

        negative_shared = self.root / "negative-shared.xlsx"
        rewrite_xlsx_member(
            workbook,
            negative_shared,
            "xl/worksheets/sheet2.xml",
            lambda data: re.sub(br"<v>[0-9]+</v>", b"<v>-1</v>", data, count=1),
        )
        with self.assertRaisesRegex(WorkbookError, "invalid shared-string"):
            read_workbook(negative_shared)

        oversized_column = self.root / "oversized-column.xlsx"
        rewrite_xlsx_member(
            workbook,
            oversized_column,
            "xl/worksheets/sheet2.xml",
            lambda data: data.replace(
                b'r="A1"', b'r="AAAAAAAAAAAAAAAAAAAA1"', 1
            ),
        )
        with self.assertRaisesRegex(WorkbookError, "duplicate/invalid cells"):
            read_workbook(oversized_column)

    def test_workbook_sheet_relationship_and_target_aliases_are_rejected(self) -> None:
        workbook = self.root / "sheet-authority.xlsx"
        write_workbook(workbook, self.rows)

        duplicate_relationship = self.root / "sheet-relationship-alias.xlsx"
        rewrite_xlsx_member(
            workbook,
            duplicate_relationship,
            "xl/workbook.xml",
            lambda data: data.replace(b'r:id="rId2"', b'r:id="rId1"', 1),
        )
        with self.assertRaisesRegex(WorkbookError, "relationship IDs"):
            read_workbook(duplicate_relationship)

        duplicate_target = self.root / "sheet-target-alias.xlsx"
        rewrite_xlsx_member(
            workbook,
            duplicate_target,
            "xl/_rels/workbook.xml.rels",
            lambda data: data.replace(
                b'Target="worksheets/sheet2.xml"',
                b'Target="worksheets/sheet1.xml"',
                1,
            ),
        )
        with self.assertRaisesRegex(WorkbookError, "alias one worksheet"):
            read_workbook(duplicate_target)

    def test_workbook_xml_authority_and_cell_resource_contract_fail_closed(self) -> None:
        workbook = self.root / "xml-authority.xlsx"
        write_workbook(workbook, self.rows)

        mutations = [
            (
                "external-relationship",
                "xl/_rels/workbook.xml.rels",
                lambda data: data.replace(
                    b'Target="worksheets/sheet1.xml"',
                    b'Target="worksheets/sheet1.xml" TargetMode="External"',
                    1,
                ),
            ),
            (
                "doctype",
                "xl/workbook.xml",
                lambda data: data.replace(
                    b"?>", b'?><!DOCTYPE workbook [<!ENTITY x "x">]>', 1
                ),
            ),
            (
                "foreign-sheet-data",
                "xl/worksheets/sheet2.xml",
                lambda data: data.replace(
                    b"<sheetData>",
                    b'<evil:sheetData xmlns:evil="urn:evil">',
                    1,
                ).replace(b"</sheetData>", b"</evil:sheetData>", 1),
            ),
            (
                "leading-zero-row",
                "xl/worksheets/sheet2.xml",
                lambda data: data.replace(b'<row r="2">', b'<row r="02">', 1),
            ),
            (
                "invalid-boolean-cell",
                "xl/worksheets/sheet1.xml",
                lambda data: re.sub(
                    br't="s"><v>[0-9]+</v>', b't="b"><v>2</v>', data, count=1
                ),
            ),
            (
                "oversized-shared-string",
                "xl/sharedStrings.xml",
                lambda data: data.replace(
                    b"<si><t>",
                    b"<si><t>" + b"x" * (xlsx_reader_module.MAXIMUM_CELL_BYTES + 1),
                    1,
                ),
            ),
        ]
        for label, member, transform in mutations:
            with self.subTest(label=label):
                mutated = self.root / f"{label}.xlsx"
                rewrite_xlsx_member(workbook, mutated, member, transform)
                with self.assertRaises(WorkbookError):
                    read_workbook(mutated)

    def test_workbook_metadata_limits_and_exact_xml_roots_fail_closed(self) -> None:
        workbook = self.root / "metadata-limits.xlsx"
        write_workbook(workbook, self.rows)
        self.assertEqual(xlsx_reader_module.MAXIMUM_WORKBOOK_SHEETS, 4096)
        self.assertEqual(xlsx_reader_module.MAXIMUM_WORKBOOK_RELATIONSHIPS, 4096)
        for label, limit_name in (
            ("sheet-limit", "MAXIMUM_WORKBOOK_SHEETS"),
            ("relationship-limit", "MAXIMUM_WORKBOOK_RELATIONSHIPS"),
        ):
            with self.subTest(label=label), mock.patch.object(
                xlsx_reader_module, limit_name, 1
            ):
                with self.assertRaisesRegex(WorkbookError, "too many"):
                    read_workbook(workbook)

        root_mutations = (
            (
                "wrong-workbook-root",
                "xl/workbook.xml",
                lambda data: data.replace(b"<workbook ", b"<evil ", 1).replace(
                    b"</workbook>", b"</evil>", 1
                ),
            ),
            (
                "wrong-relationships-root",
                "xl/_rels/workbook.xml.rels",
                lambda data: data.replace(
                    b"<Relationships ", b"<evil ", 1
                ).replace(b"</Relationships>", b"</evil>", 1),
            ),
            (
                "wrong-shared-strings-root",
                "xl/sharedStrings.xml",
                lambda data: data.replace(b"<sst ", b"<evil ", 1).replace(
                    b"</sst>", b"</evil>", 1
                ),
            ),
            (
                "wrong-worksheet-root",
                "xl/worksheets/sheet2.xml",
                lambda data: data.replace(
                    b"<worksheet ", b"<evil ", 1
                ).replace(b"</worksheet>", b"</evil>", 1),
            ),
            (
                "duplicate-sheet-data",
                "xl/worksheets/sheet2.xml",
                lambda data: data.replace(
                    b"</worksheet>", b"<sheetData/></worksheet>", 1
                ),
            ),
        )
        for label, member, transform in root_mutations:
            with self.subTest(label=label):
                mutated = self.root / f"{label}.xlsx"
                rewrite_xlsx_member(workbook, mutated, member, transform)
                with self.assertRaises(WorkbookError):
                    read_workbook(mutated)

    def test_basic_identity_whitespace_is_rejected_without_trimming(self) -> None:
        for field in ("map_name", "storeCode"):
            with self.subTest(field=field):
                workbook = self.root / f"whitespace-{field}.xlsx"
                basic = {
                    "map_name": "fixture",
                    "width": 2000,
                    "height": 1000,
                    "storeCode": "s1",
                }
                basic[field] = " " + str(basic[field])
                write_workbook(workbook, self.rows, basic_info=basic)
                with self.assertRaisesRegex(WorkbookError, "leading/trailing whitespace"):
                    read_workbook(workbook)

    def test_shelf_info_formula_is_counted_but_never_used_as_authority(self) -> None:
        plain = self.root / "shelf-plain.xlsx"
        formula = self.root / "shelf-formula.xlsx"
        write_workbook(
            plain,
            self.rows,
            shelf_rows=[["code"], ["legacy-business-value"]],
        )
        formula_xml = (
            '<?xml version="1.0"?><worksheet '
            'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            '<sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>code</t></is></c></row>'
            '<row r="2"><c r="A2"><f>1+1</f><v>2</v></c></row>'
            '</sheetData></worksheet>'
        ).encode("utf-8")
        rewrite_xlsx_member(
            plain,
            formula,
            "xl/worksheets/sheet2.xml",
            lambda _data: formula_xml,
        )
        plain_read = read_workbook(plain)
        formula_read = read_workbook(formula)
        self.assertEqual(plain_read.legacy_shelf_info.row_count, 1)
        self.assertEqual(formula_read.legacy_shelf_info.row_count, 1)
        plain_package = convert_workbook(plain, self.root / "plain-package")
        formula_package = convert_workbook(formula, self.root / "formula-package")
        plain_manifest = json.loads((plain_package / "manifest.json").read_text())
        formula_manifest = json.loads((formula_package / "manifest.json").read_text())
        self.assertEqual(
            plain_manifest["canonical_source_sha256"],
            formula_manifest["canonical_source_sha256"],
        )

    def test_shelf_and_presentation_mutations_do_not_change_business_identity(self) -> None:
        first = self.root / "first.xlsx"
        second = self.root / "second.xlsx"
        circle_a = (
            "1",
            json.dumps(
                {
                    "shapeType": "Circle",
                    "x": 20,
                    "y": 30,
                    "width": 10,
                    "height": 10,
                    "visible": True,
                }
            ),
        )
        circle_b = (
            "1",
            json.dumps(
                {
                    "shapeType": "Circle",
                    "x": 999,
                    "y": 888,
                    "width": 500,
                    "height": 500,
                    "visible": False,
                }
            ),
        )
        write_workbook(first, [*self.rows, circle_a], shelf_rows=[["code"], ["old"]])
        write_workbook(second, [*self.rows, circle_b], shelf_rows=[["code"], ["new"]])
        first_package = convert_workbook(first, self.root / "first-package")
        second_package = convert_workbook(second, self.root / "second-package")
        first_manifest = json.loads((first_package / "manifest.json").read_text())
        second_manifest = json.loads((second_package / "manifest.json").read_text())
        self.assertNotEqual(first_manifest["source_sha256"], second_manifest["source_sha256"])
        self.assertEqual(
            first_manifest["canonical_source_sha256"],
            second_manifest["canonical_source_sha256"],
        )
        self.assertEqual(first_manifest["prior_map_id"], second_manifest["prior_map_id"])
        self.assertEqual(first_manifest["presentation_ignored_count"], 1)
        self.assertEqual(second_manifest["presentation_ignored_count"], 1)

    def test_active_geometry_one_centimetre_outside_canvas_is_rejected(self) -> None:
        workbook = self.root / "outside.xlsx"
        rows = [
            (
                "1",
                json.dumps(
                    {
                        "shapeType": "MapShelf",
                        "x": 1999,
                        "y": 100,
                        "width": 2,
                        "height": 10,
                        "visible": True,
                    }
                ),
            )
        ]
        write_workbook(workbook, rows)
        with self.assertRaisesRegex(ConversionError, "outside"):
            convert_workbook(workbook, self.root / "outside-package")

    def test_renderer_ignores_null_presentation_geometry(self) -> None:
        workbook = self.root / "render.xlsx"
        write_workbook(workbook, self.rows)
        package = convert_workbook(workbook, self.root / "render-package")
        elements_path = package / "elements.json"
        payload = json.loads(elements_path.read_text(encoding="utf-8"))
        payload["elements"].append(
            {
                "id": "presentation",
                "floor_id": "1",
                "shape_type": "Circle",
                "role": "presentation_only",
                "visible": True,
                "geometry": None,
            }
        )
        elements_path.write_text(json.dumps(payload), encoding="utf-8")
        output = render_package(package, self.root / "rendered.png")
        self.assertTrue(output.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))


class IOSCoreContractTests(unittest.TestCase):
    def test_esl_capture_uses_arkit_frames_without_pausing_scan(self) -> None:
        repository = Path(__file__).resolve().parents[3]
        app = repository / "app/ios/RTABMapApp"
        scanner = (app / "PriceTagVisionScanner.swift").read_text(encoding="utf-8")
        ui = (app / "PriceTagCaptureUI.swift").read_text(encoding="utf-8")
        capture_core = (app / "PriceTagCaptureCore.swift").read_text(
            encoding="utf-8"
        )
        scan_session = (app / "SupermarketScanSession.swift").read_text(
            encoding="utf-8"
        )
        view_controller = (app / "ViewController.swift").read_text(encoding="utf-8")
        flow_start = view_controller.index("private func startPriceTagCapture()")
        flow_end = view_controller.index(
            "@objc private func confirmPriorMapPosition()", flow_start
        )
        barcode_flow = view_controller[flow_start:flow_end]
        capture_sources = "\n".join((scanner, ui, barcode_flow))

        self.assertIn("cvPixelBuffer: frame.capturedImage", scanner)
        self.assertIn("request.regionOfInterest = regionOfInterest", scanner)
        self.assertIn("PriceTagVisionRequestTokenGate", scanner)
        self.assertIn("PriceTagVisionWorkerExecutor", scanner)
        self.assertIn("maximumWorkers: 2", scanner)
        self.assertIn("workerExecutor.quarantine", scanner)
        self.assertIn("requestTokens.beginRequest", scanner)
        self.assertIn("requestTokens.completeRequest", scanner)
        self.assertIn("priceTagVisionScanner.restart", barcode_flow)
        self.assertIn("maximumVisionRequestDuration", capture_core)
        self.assertIn("case requestTimedOut", capture_core)
        self.assertIn("PriceTagCapturePreviewView: MTKView", ui)
        self.assertIn("claimConfirmationCommit", capture_core)
        self.assertIn("confirmationCommitInFlight", capture_core)
        self.assertIn("PriceTagConfirmationIdentityValidator.matches", scan_session)
        self.assertIn("authority: PriceTagConfirmationCommitAuthority", scan_session)
        self.assertIn("appendScanEventIfSessionActive", scan_session)
        self.assertIn("appendScanEventIfSessionActive", barcode_flow)
        self.assertIn("matchesPriorMapAuthority", barcode_flow)
        self.assertIn("!scanSession.isFinalizingScan", view_controller)
        self.assertIn("allowDuringFinalization: false", view_controller)
        active_directory = re.search(
            r"private func activeLocalizationDirectory\([\s\S]*?\n    \}",
            scan_session,
        )
        self.assertIsNotNone(active_directory)
        self.assertNotIn(
            "!isFinalizingScan",
            active_directory.group(0),
            "an already-admitted writer must not be rejected behind the lock",
        )
        self.assertNotIn(
            "capturePriorMapGeneration == self.priorMapGeneration",
            barcode_flow,
            "background ESL callbacks must not race the main-thread map generation",
        )
        self.assertNotIn(
            "priceTagCapturePriorMapGeneration",
            barcode_flow,
            "prior-map authority must live behind the capture coordinator lock",
        )
        for prohibited in (
            "AVCaptureSession(",
            "session.pause(",
            "rtabmap?.stopCamera(",
            "stopMapping(",
            ".resetTracking",
        ):
            self.assertNotIn(
                prohibited,
                capture_sources,
                f"ESL capture must not own or pause the production scan: {prohibited}",
            )

    def test_graph_reader_bridge_rejects_malformed_blobs(self) -> None:
        xcrun = shutil.which("xcrun")
        if xcrun is None:
            self.skipTest("xcrun is unavailable outside the macOS build environment")
        repository = Path(__file__).resolve().parents[3]
        test_source = Path(__file__).with_name("graph_reader_bridge_tests.mm")
        implementation = (
            repository / "app/ios/RTABMapApp/MSRTABMapGraphReaderBridge.mm"
        )
        include_directory = repository / "app/ios/RTABMapApp"
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "graph-reader-bridge-tests"
            compile_result = subprocess.run(
                [
                    xcrun,
                    "clang++",
                    "-std=c++17",
                    "-x",
                    "objective-c++",
                    str(test_source),
                    str(implementation),
                    f"-I{include_directory}",
                    "-lsqlite3",
                    "-o",
                    str(executable),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            run_result = subprocess.run(
                [str(executable)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(run_result.returncode, 0, run_result.stderr)
            self.assertIn("graph reader bridge tests passed", run_result.stdout)

        swift_reader = (
            repository
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileGraphReader.swift"
        ).read_text(encoding="utf-8")
        self.assertRegex(
            swift_reader,
            r"static func projectToSE2\([\s\S]*?\) throws -> SE2Transform",
        )
        self.assertNotIn("return SE2Transform.identity", swift_reader)
        for required_token in (
            "node pointer/count mismatch",
            "link pointer/count mismatch",
            "node id must be positive and unique",
            "link endpoint missing from node inventory",
            "projection policy version mismatch",
        ):
            self.assertIn(required_token, swift_reader)

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
            # V1R5 Gate A: auto-generated evidence input-limit contracts.
            repository
            / "app/ios/RTABMapApp/GeneratedMobileEvidenceContracts.swift",
            repository
            / "app/ios/RTABMapApp/StrictJSONKeyUniquenessValidator.swift",
            repository / "app/ios/RTABMapApp/StrictJSONDocumentParser.swift",
            repository / "app/ios/RTABMapApp/PriorMapPackageSnapshotCore.swift",
            repository / "app/ios/RTABMapApp/PriorMapScanMatcher.swift",
            repository / "app/ios/RTABMapApp/PriceTagLocalizationCore.swift",
            repository / "app/ios/RTABMapApp/PriceTagCaptureCore.swift",
            repository / "app/ios/RTABMapApp/SupermarketScanSession.swift",
            repository
            / "app/ios/RTABMapApp/PriorMapPackageIntegrityCore.swift",
            # Mobile-Only V1: map-source import pipeline (pure logic; the
            # UIKit document picker lives in the app target only).
            repository
            / "app/ios/RTABMapApp/MobileMapImport/MapSourceImportError.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/CanonicalPriorMapSource.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/CanonicalJSONEncoder.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/SourceGeometry.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/ElementNormalizer.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/RFC4180CSVReader.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/CSVMapSourceImporter.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/XLSXZipReader.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/XLSXWorkbookReader.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/XLSXWorksheetReader.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/XLSXMapSourceImporter.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/JSONMapSourceImporter.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/MapSourceImportReport.swift",
            repository
            / "app/ios/RTABMapApp/MobileMapImport/MapSourceImportCoordinator.swift",
            # Mobile-Only V1: prior-map compiler (pure logic + CoreGraphics
            # preview rendering, available on the macOS host).
            repository
            / "app/ios/RTABMapApp/MobilePriorMapCompiler/MobileDistanceFieldBuilder.swift",
            repository
            / "app/ios/RTABMapApp/MobilePriorMapCompiler/MobileRoadGraphBuilder.swift",
            repository
            / "app/ios/RTABMapApp/MobilePriorMapCompiler/MobilePackageManifestBuilder.swift",
            repository
            / "app/ios/RTABMapApp/MobilePriorMapCompiler/MobilePreviewRenderer.swift",
            repository
            / "app/ios/RTABMapApp/MobilePriorMapCompiler/MobilePriorMapCompiler.swift",
            # Mobile-Only V1: clock correlation, final trajectory and the
            # four-sheet XLSX workbook (all host-testable pure logic).
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/ClockCorrelationRecorder.swift",
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/FinalTrajectory.swift",
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/SE2Transform.swift",
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/TagObservationResolver.swift",
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/ShelfAssociationEngine.swift",
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/SE2FactorGraphCore.swift",
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/ImmutableDirectoryPublication.swift",
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/SessionSnapshotTransaction.swift",
            # Mobile-Only V1R4: strict absolute prior-map evidence parser
            # (§6.1): real write-side schema, identity fail-closed,
            # node-timebase binding, uniqueness-derived sigma, audit codes.
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/AbsolutePriorEvidenceParser.swift",
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/TagObservationEvidenceParser.swift",
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/StrictClockEvidenceParser.swift",
            # Mobile-Only V1R5: shared strict JSONL framing, the verified
            # tag-burst parser (§5.3) and the strict trace parser (§9.6).
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/StrictJSONLStreamReader.swift",
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/TagObservationBurstEvidenceParser.swift",
            repository
            / "app/ios/RTABMapApp/MobilePostProcessing/StrictLocalizationTraceParser.swift",
            repository
            / "app/ios/RTABMapApp/MobileResults/MobileWorksheets.swift",
            repository
            / "app/ios/RTABMapApp/MobileResults/MobileResultExporter.swift",
            repository
            / "app/ios/RTABMapApp/MobileResults/XLSXWorkbookWriter.swift",
            repository
            / "app/ios/RTABMapApp/MobileResults/XLSXWorkbookVerifier.swift",
            # Mobile-Only V1R1: workflow state machine, durable map/task/
            # result stores and the end-to-end processing pipeline (all
            # Foundation-only; the UIKit coordinator/UI live in the app
            # target and are validated by the Xcode build instead).
            repository
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileOnlyWorkflowState.swift",
            repository
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileOnlyWorkflowError.swift",
            repository
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileMapLibrary.swift",
            repository
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileProcessingTaskStore.swift",
            repository
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileResultLibrary.swift",
            repository
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileNativeGraphTypes.swift",
            repository
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileBuildIdentity.swift",
            repository
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/ProcessingResourceGovernor.swift",
            repository
            / "app/ios/RTABMapApp/MobileOnlyWorkflow/MobileProcessingPipeline.swift",
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
            esl_capture_result = subprocess.run(
                [str(executable), "--esl-capture-focused"],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                esl_capture_result.returncode,
                0,
                esl_capture_result.stderr,
            )
            self.assertIn(
                "ESL barcode capture focused tests passed",
                esl_capture_result.stdout,
            )
            esl_finalization_result = subprocess.run(
                [str(executable), "--esl-finalization-focused"],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                esl_finalization_result.returncode,
                0,
                esl_finalization_result.stderr,
            )
            self.assertIn(
                "ESL finalization binding focused tests passed",
                esl_finalization_result.stdout,
            )
            absolute_prior_contract_result = subprocess.run(
                [str(executable), "--absolute-prior-contract", "run"],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                absolute_prior_contract_result.returncode,
                0,
                absolute_prior_contract_result.stderr,
            )
            self.assertIn(
                "Absolute prior/native targeted contract tests passed",
                absolute_prior_contract_result.stdout,
            )
            mapcase02_workbook = repository / "map/mapcase02/mapcase02.xlsx"
            if mapcase02_workbook.is_file():
                mapcase02_output = Path(temporary) / "mapcase02-swift-golden"
                mapcase02_command = [
                    str(executable),
                    "--mapcase02-suite",
                    str(mapcase02_workbook),
                    str(mapcase02_output),
                    (
                        "5ddfac7dc439afc45abdcf800b799c05d53704895b620d161"
                        "ef08a442c55b2db"
                    ),
                    (
                        "8d3564ce68aadb087a2820a02b4747d15ea1f4d22b14e877"
                        "6f913d33775b1b84"
                    ),
                ]
                legacy_workbook = repository / "map/mapcase01/mapcase01.xlsx"
                if legacy_workbook.is_file():
                    mapcase02_command.append(str(legacy_workbook))
                mapcase02_result = subprocess.run(
                    mapcase02_command,
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    mapcase02_result.returncode,
                    0,
                    mapcase02_result.stderr,
                )
                self.assertIn(
                    "MapCase02 suite passed",
                    mapcase02_result.stdout,
                )
                cross_end_validation = validate_package(mapcase02_output)
                self.assertTrue(
                    cross_end_validation["valid"],
                    "Python production validator rejected the Swift package: "
                    + repr(cross_end_validation["errors"]),
                )
            else:
                print(
                    "MapCase02 Swift golden explicitly skipped: ignored local "
                    "workbook fixture is unavailable"
                )

            legacy_v1_workbook = Path(temporary) / "legacy-v1.xlsx"
            write_workbook(
                legacy_v1_workbook,
                fixture_rows(),
                include_basic=False,
            )
            legacy_v1_package = convert_workbook(
                legacy_v1_workbook,
                Path(temporary) / "legacy-v1-package",
                map_name="legacy-v1",
                store_id="legacy-store",
                allow_legacy_element_only=True,
            )
            self.assertTrue(validate_package(legacy_v1_package)["valid"])
            legacy_v1_integrity_root = Path(temporary) / "legacy-v1-integrity"
            legacy_v1_integrity_root.mkdir()
            shutil.copytree(
                legacy_v1_package,
                legacy_v1_integrity_root / "baseline.pass",
            )

            def add_legacy_v1_mutation(
                name: str, mutate: object
            ) -> None:
                destination = legacy_v1_integrity_root / f"{name}.fail"
                shutil.copytree(legacy_v1_package, destination)
                manifest_path = destination / "manifest.json"
                payload = json.loads(manifest_path.read_text(encoding="utf-8"))
                mutate(payload)
                manifest_path.write_text(
                    json.dumps(
                        payload,
                        ensure_ascii=False,
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                (destination / "package_manifest.json").write_text(
                    json.dumps(
                        build_package_manifest(destination),
                        ensure_ascii=False,
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )

            statistics_key = next(
                iter(
                    json.loads(
                        (legacy_v1_package / "manifest.json").read_text(
                            encoding="utf-8"
                        )
                    )["element_statistics"]
                )
            )
            add_legacy_v1_mutation(
                "statistics-integral-float",
                lambda value: value["element_statistics"].__setitem__(
                    statistics_key,
                    float(value["element_statistics"][statistics_key]),
                ),
            )
            add_legacy_v1_mutation(
                "visible-integral-float",
                lambda value: value.__setitem__(
                    "visible_element_count",
                    float(value["visible_element_count"]),
                ),
            )
            add_legacy_v1_mutation(
                "hidden-boolean",
                lambda value: value.__setitem__(
                    "hidden_element_count", False
                ),
            )
            legacy_v1_result = subprocess.run(
                [
                    str(executable),
                    "--integrity-suite",
                    str(legacy_v1_integrity_root),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                legacy_v1_result.returncode,
                0,
                legacy_v1_result.stderr,
            )
            self.assertIn(
                "Integrity suite passed", legacy_v1_result.stdout
            )
            run_result = subprocess.run(
                [str(executable)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(run_result.returncode, 0, run_result.stderr)
            self.assertIn("Swift tests passed", run_result.stdout)

            def make_snapshot_crash_session(session: Path) -> None:
                session.mkdir(parents=True)
                prior_map_sha = "a" * 64
                metadata = {
                    "format": "MarketScannerFinalizedSessionMetadata",
                    "version": 1,
                    "formatVersion": 2,
                    "finalized": True,
                    "finalizedAtUnix": 1_700_000_100.0,
                    "scanMode": "continuous_streaming",
                    "workflowMode": "prior_map_localized",
                    "trackingSessionId": "P7-SESSION",
                    "storeId": "STORE-P7",
                    "floorId": "FLOOR-P7",
                    "priorMapId": "MAP-P7",
                    "priorMapSha256": prior_map_sha,
                    "processingEligibility": {
                        "status": "eligible",
                        "blockers": [],
                    },
                    "captureHealth": {
                        "localizationRequiredWriteFailureCount": 0,
                        "localizationTraceRecordCount": 1,
                        "localizationConstraintRecordCount": 1,
                        "manualLocalizationEventCount": 0,
                        "localizationStateEventCount": 1,
                        "localizationEvidenceComplete": True,
                        "localizationRecoveryEventCount": 1,
                        "localizationLastRecoveryEpisodeId": 1,
                        "localizationLastRecoveryFinishedAtUptime": 42.0,
                        "localizationRecoveryEvidenceComplete": True,
                    },
                    "localizationTrace": "localization_trace.jsonl",
                    "manualLocalizationEvents":
                        "manual_localization_events.jsonl",
                    "localizationConstraints":
                        "localization_constraints.jsonl",
                    "localizationEvents": "localization_events.jsonl",
                    "localizationRecoveryEvents":
                        "localization_recovery_events.jsonl",
                    "tagObservations": "tag_observations.jsonl",
                    "localizedPriceTags": "localized_price_tags.json",
                    "clockCorrelationCount": 2,
                    "clockNodeBindingCount": 2,
                    "clockLastMonotonic": 41.0,
                    "clockLastUTC": 1_700_000_041.0,
                    "clockEvidenceComplete": True,
                    "tagObservationBurstCount": 0,
                    "tagObservationBurstComplete": True,
                }
                (session / "metadata.json").write_text(
                    json.dumps(
                        metadata,
                        ensure_ascii=False,
                        sort_keys=True,
                        separators=(",", ":"),
                    )
                )
                sidecars = {
                    "localization_trace.jsonl": b"trace\n",
                    "localization_constraints.jsonl": b"constraints\n",
                    "manual_localization_events.jsonl": b"manual\n",
                    "tag_observations.jsonl": b"obs\n",
                    "localization_events.jsonl": b"events\n",
                    "localization_recovery_events.jsonl": b"recovery\n",
                    "localized_price_tags.json": b"[]",
                    "clock_correlations.jsonl": b"clock\n",
                    "tag_observation_bursts.jsonl": b"",
                }
                for name, payload in sidecars.items():
                    (session / name).write_bytes(payload)
                scan_event = {
                    "format": "SupermarketScanEvent",
                    "version": 1,
                    "timestamp": "2023-11-14T22:13:20.000Z",
                    "timestampUnix": 1_700_000_000.0,
                    "level": "info",
                    "event": "scan_started",
                    "message": "fixture scan started",
                    "trackingSessionId": "P7-SESSION",
                    "fields": {},
                }
                (session / "scan_events.jsonl").write_text(
                    json.dumps(
                        scan_event,
                        ensure_ascii=False,
                        sort_keys=True,
                        separators=(",", ":"),
                    )
                    + "\n"
                )
                database = sqlite3.connect(session / "source.db")
                try:
                    database.executescript(
                        """
                        CREATE TABLE Node (
                            id INTEGER PRIMARY KEY,
                            map_id INTEGER,
                            weight INTEGER,
                            stamp REAL,
                            pose BLOB
                        );
                        CREATE TABLE Link (
                            from_id INTEGER,
                            to_id INTEGER,
                            type INTEGER,
                            transform BLOB,
                            information_matrix BLOB
                        );
                        """
                    )
                    database.commit()
                finally:
                    database.close()

            snapshot_crash_cases = (
                ("after_intent_temp", 90),
                ("after_intent_rename", 91),
                ("old_thaw", 92),
                ("old_rename", 101),
                ("old_freeze", 102),
                ("new_rename", 93),
                ("new_freeze", 94),
                ("after_install", 95),
                ("reference_temp", 100),
                ("reference_rename", 96),
                ("reference_swap_postrename", 106),
                ("reference_durable", 97),
                ("cleanup_root", 98),
                ("cleanup_child", 104),
                ("rollback_after_authority", 99),
                ("intent_remove_postrename", 113),
            )
            snapshot_fixture_root = Path(temporary) / "snapshot-crash-fixture"
            snapshot_session = snapshot_fixture_root / "session"
            snapshot_baseline_task = snapshot_fixture_root / "task"
            make_snapshot_crash_session(snapshot_session)
            snapshot_baseline_task.mkdir(parents=True)
            baseline = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(snapshot_baseline_task),
                    "baseline",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                baseline.returncode,
                0,
                baseline.stderr + baseline.stdout,
            )
            for phase, expected_exit in snapshot_crash_cases:
                case_root = Path(temporary) / f"snapshot-crash-{phase}"
                task_root = case_root / "task"
                case_root.mkdir(parents=True)
                shutil.copytree(snapshot_baseline_task, task_root)
                crashed = subprocess.run(
                    [
                        str(executable),
                        "--snapshot-publication-crash-worker",
                        str(snapshot_session),
                        str(task_root),
                        phase,
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    crashed.returncode,
                    expected_exit,
                    crashed.stderr + crashed.stdout,
                )
                recovered = subprocess.run(
                    [
                        str(executable),
                        "--snapshot-publication-crash-worker",
                        str(snapshot_session),
                        str(task_root),
                        "recover",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    recovered.returncode,
                    0,
                    recovered.stderr + recovered.stdout,
                )
                self.assertIn("snapshot recover passed", recovered.stdout)
                self.assertEqual(
                    (task_root / "input_snapshot").stat().st_mode & 0o777,
                    0o555,
                )
                self.assertEqual(
                    (task_root / "input_manifest.json").stat().st_mode & 0o777,
                    0o444,
                )
                self.assertFalse((task_root / "input_snapshot.backup").exists())
                self.assertFalse((task_root / "input_snapshot.staging").exists())
                self.assertFalse(
                    (task_root / "input_snapshot.transaction.json").exists()
                )
                self.assertFalse(
                    list(task_root.glob("input_snapshot.transaction.tmp-*"))
                )
                self.assertFalse(list(task_root.glob(".input_manifest.*.tmp")))

            double_crash_root = Path(temporary) / "snapshot-reference-temp-double-crash"
            double_crash_task = double_crash_root / "task"
            double_crash_root.mkdir(parents=True)
            shutil.copytree(snapshot_baseline_task, double_crash_task)
            double_crash_first = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(double_crash_task),
                    "reference_temp",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                double_crash_first.returncode,
                100,
                double_crash_first.stderr + double_crash_first.stdout,
            )
            self.assertTrue(list(double_crash_task.glob(".input_manifest.*.tmp")))
            double_crash_second = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(double_crash_task),
                    "recovery_core_postintent_crash",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                double_crash_second.returncode,
                114,
                double_crash_second.stderr + double_crash_second.stdout,
            )
            self.assertFalse(list(double_crash_task.glob(".input_manifest.*.tmp")))
            self.assertFalse(
                (double_crash_task / "input_snapshot.transaction.json").exists()
            )
            double_crash_recovered = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(double_crash_task),
                    "recover",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                double_crash_recovered.returncode,
                0,
                double_crash_recovered.stderr + double_crash_recovered.stdout,
            )

            first_generation_root = Path(temporary) / "snapshot-first-generation-temp"
            first_generation_task = first_generation_root / "task"
            first_generation_task.mkdir(parents=True)
            first_generation_crash = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(first_generation_task),
                    "reference_temp",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                first_generation_crash.returncode,
                100,
                first_generation_crash.stderr + first_generation_crash.stdout,
            )
            first_generation_recovery = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(first_generation_task),
                    "recovery_core_postintent_crash",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                first_generation_recovery.returncode,
                114,
                first_generation_recovery.stderr + first_generation_recovery.stdout,
            )
            self.assertFalse(
                list(first_generation_task.glob(".input_manifest.*.tmp"))
            )
            self.assertFalse(
                (first_generation_task / "input_snapshot.transaction.json").exists()
            )
            first_generation_final_recovery = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(first_generation_task),
                    "recover",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                first_generation_final_recovery.returncode,
                0,
                first_generation_final_recovery.stderr
                + first_generation_final_recovery.stdout,
            )

            first_clear_crash_root = (
                Path(temporary) / "snapshot-first-clear-postrename"
            )
            first_clear_crash_task = first_clear_crash_root / "task"
            first_clear_crash_task.mkdir(parents=True)
            first_clear_crash = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(first_clear_crash_task),
                    "first_clear_postrename",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                first_clear_crash.returncode,
                112,
                first_clear_crash.stderr + first_clear_crash.stdout,
            )
            self.assertTrue(
                list(first_clear_crash_task.glob(".input_manifest.remove-*"))
            )
            first_clear_crash_recovery = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(first_clear_crash_task),
                    "recover",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                first_clear_crash_recovery.returncode,
                0,
                first_clear_crash_recovery.stderr
                + first_clear_crash_recovery.stdout,
            )
            self.assertFalse(
                list(first_clear_crash_task.glob(".input_manifest.remove-*"))
            )

            for conflict_phase, seed_prior in (
                ("reference_replace", True),
                ("reference_appear", False),
            ):
                conflict_root = Path(temporary) / f"snapshot-{conflict_phase}"
                conflict_task = conflict_root / "task"
                conflict_root.mkdir(parents=True)
                if seed_prior:
                    shutil.copytree(snapshot_baseline_task, conflict_task)
                else:
                    conflict_task.mkdir()
                conflict = subprocess.run(
                    [
                        str(executable),
                        "--snapshot-publication-crash-worker",
                        str(snapshot_session),
                        str(conflict_task),
                        conflict_phase,
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    conflict.returncode,
                    39,
                    conflict.stderr + conflict.stdout,
                )
                authority = conflict_task / "input_manifest.json"
                self.assertEqual(authority.read_text(), '{"unrelated":true}\n')
                self.assertEqual(authority.stat().st_mode & 0o777, 0o444)
                self.assertTrue(
                    (conflict_task / "input_snapshot.transaction.json").is_file()
                )
                if seed_prior:
                    self.assertTrue(
                        (conflict_task / "input_manifest.displaced-by-test").is_file()
                    )

            postcheck_authority_payload = '{"unrelated_postcheck":true}\n'
            for conflict_phase, seed_prior, displaced_name in (
                (
                    "reference_postcheck_replace",
                    True,
                    "input_manifest.displaced-postcheck-test",
                ),
                ("reference_postcheck_appear", False, None),
            ):
                conflict_root = Path(temporary) / f"snapshot-{conflict_phase}"
                conflict_task = conflict_root / "task"
                conflict_root.mkdir(parents=True)
                if seed_prior:
                    shutil.copytree(snapshot_baseline_task, conflict_task)
                else:
                    conflict_task.mkdir()
                conflict = subprocess.run(
                    [
                        str(executable),
                        "--snapshot-publication-crash-worker",
                        str(snapshot_session),
                        str(conflict_task),
                        conflict_phase,
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    conflict.returncode,
                    39,
                    conflict.stderr + conflict.stdout,
                )
                authority = conflict_task / "input_manifest.json"
                self.assertEqual(authority.read_text(), postcheck_authority_payload)
                self.assertEqual(authority.stat().st_mode & 0o777, 0o444)
                intent = conflict_task / "input_snapshot.transaction.json"
                self.assertTrue(intent.is_file())
                if displaced_name is not None:
                    self.assertTrue((conflict_task / displaced_name).is_file())
                self.assertFalse(list(conflict_task.glob(".input_manifest.*.tmp")))
                self.assertFalse(
                    list(conflict_task.glob(".input_manifest.conflict-*"))
                )

                recovery = subprocess.run(
                    [
                        str(executable),
                        "--snapshot-publication-crash-worker",
                        str(snapshot_session),
                        str(conflict_task),
                        "recover",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    recovery.returncode,
                    39,
                    recovery.stderr + recovery.stdout,
                )
                self.assertEqual(authority.read_text(), postcheck_authority_payload)
                self.assertTrue(intent.is_file())
                if displaced_name is not None:
                    self.assertTrue((conflict_task / displaced_name).is_file())

            swap_crash_root = (
                Path(temporary) / "snapshot-reference-swap-postrename-replace"
            )
            swap_crash_task = swap_crash_root / "task"
            swap_crash_root.mkdir(parents=True)
            shutil.copytree(snapshot_baseline_task, swap_crash_task)
            swap_crash = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(swap_crash_task),
                    "reference_swap_postrename_replace",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                swap_crash.returncode,
                107,
                swap_crash.stderr + swap_crash.stdout,
            )
            swap_temporaries = list(
                swap_crash_task.glob(".input_manifest.*.tmp")
            )
            self.assertEqual(len(swap_temporaries), 1)
            self.assertEqual(
                swap_temporaries[0].read_text(), postcheck_authority_payload
            )
            self.assertTrue(
                (swap_crash_task / "input_snapshot.transaction.json").is_file()
            )
            self.assertTrue(
                (
                    swap_crash_task
                    / "input_manifest.displaced-postcheck-test"
                ).is_file()
            )
            swap_crash_recovery = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(swap_crash_task),
                    "recover",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                swap_crash_recovery.returncode,
                39,
                swap_crash_recovery.stderr + swap_crash_recovery.stdout,
            )
            self.assertEqual(
                swap_temporaries[0].read_text(), postcheck_authority_payload
            )
            self.assertTrue(
                (swap_crash_task / "input_snapshot.transaction.json").is_file()
            )

            clear_root = Path(temporary) / "snapshot-first-clear-postcheck-appear"
            clear_task = clear_root / "task"
            clear_root.mkdir(parents=True)
            clear_task.mkdir()
            clear_conflict = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(clear_task),
                    "first_clear_postcheck_appear",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                clear_conflict.returncode,
                39,
                clear_conflict.stderr + clear_conflict.stdout,
            )
            clear_authority = clear_task / "input_manifest.json"
            clear_displaced = (
                clear_task / "input_manifest.displaced-clear-postcheck-test"
            )
            clear_intent = clear_task / "input_snapshot.transaction.json"
            self.assertEqual(
                clear_authority.read_text(), postcheck_authority_payload
            )
            self.assertEqual(clear_authority.stat().st_mode & 0o777, 0o444)
            self.assertTrue(clear_displaced.is_file())
            self.assertTrue(clear_intent.is_file())
            self.assertFalse(list(clear_task.glob(".input_manifest.*.tmp")))
            self.assertFalse(list(clear_task.glob(".input_manifest.conflict-*")))

            clear_recovery = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(clear_task),
                    "recover",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                clear_recovery.returncode,
                39,
                clear_recovery.stderr + clear_recovery.stdout,
            )
            self.assertEqual(
                clear_authority.read_text(), postcheck_authority_payload
            )
            self.assertTrue(clear_displaced.is_file())
            self.assertTrue(clear_intent.is_file())

            clear_crash_root = (
                Path(temporary) / "snapshot-first-clear-postrename-crash-appear"
            )
            clear_crash_task = clear_crash_root / "task"
            clear_crash_task.mkdir(parents=True)
            clear_crash = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(clear_crash_task),
                    "first_clear_postrename_crash_appear",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                clear_crash.returncode,
                108,
                clear_crash.stderr + clear_crash.stdout,
            )
            clear_crash_tombstones = list(
                clear_crash_task.glob(".input_manifest.remove-*")
            )
            self.assertEqual(len(clear_crash_tombstones), 1)
            self.assertEqual(
                clear_crash_tombstones[0].read_text(),
                postcheck_authority_payload,
            )
            clear_crash_recovery = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(clear_crash_task),
                    "recover",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                clear_crash_recovery.returncode,
                39,
                clear_crash_recovery.stderr + clear_crash_recovery.stdout,
            )
            clear_crash_authority = clear_crash_task / "input_manifest.json"
            self.assertEqual(
                clear_crash_authority.read_text(), postcheck_authority_payload
            )
            self.assertFalse(
                list(clear_crash_task.glob(".input_manifest.remove-*"))
            )
            self.assertTrue(
                (
                    clear_crash_task
                    / "input_manifest.displaced-clear-postcheck-test"
                ).is_file()
            )
            self.assertTrue(
                (clear_crash_task / "input_snapshot.transaction.json").is_file()
            )

            intent_replace_root = (
                Path(temporary) / "snapshot-intent-removal-replacement"
            )
            intent_replace_task = intent_replace_root / "task"
            intent_replace_root.mkdir(parents=True)
            shutil.copytree(snapshot_baseline_task, intent_replace_task)
            intent_replace = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(intent_replace_task),
                    "intent_removal_replace",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                intent_replace.returncode,
                105,
                intent_replace.stderr + intent_replace.stdout,
            )
            self.assertIn(
                "snapshot intent-removal replacement injected",
                intent_replace.stdout,
            )
            unrelated_intent_payload = '{"unrelated_intent":true}\n'
            intent_authority = (
                intent_replace_task / "input_snapshot.transaction.json"
            )
            displaced_intent = (
                intent_replace_task
                / "input_snapshot.transaction.displaced-postcheck-test"
            )
            self.assertEqual(
                intent_authority.read_text(), unrelated_intent_payload
            )
            self.assertEqual(intent_authority.stat().st_mode & 0o777, 0o444)
            self.assertTrue(displaced_intent.is_file())
            self.assertFalse(
                list(intent_replace_task.glob("input_snapshot.transaction.remove-*"))
            )
            self.assertFalse(
                list(
                    intent_replace_task.glob(
                        "input_snapshot.transaction.conflict-*"
                    )
                )
            )

            intent_recovery = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(intent_replace_task),
                    "recover",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                intent_recovery.returncode,
                39,
                intent_recovery.stderr + intent_recovery.stdout,
            )
            self.assertEqual(
                intent_authority.read_text(), unrelated_intent_payload
            )
            self.assertTrue(displaced_intent.is_file())

            intent_crash_root = (
                Path(temporary) / "snapshot-intent-removal-postrename-replacement"
            )
            intent_crash_task = intent_crash_root / "task"
            intent_crash_root.mkdir(parents=True)
            shutil.copytree(snapshot_baseline_task, intent_crash_task)
            intent_crash = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(intent_crash_task),
                    "intent_removal_postrename_crash_replace",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                intent_crash.returncode,
                109,
                intent_crash.stderr + intent_crash.stdout,
            )
            intent_crash_tombstones = list(
                intent_crash_task.glob("input_snapshot.transaction.remove-*")
            )
            self.assertEqual(len(intent_crash_tombstones), 1)
            self.assertEqual(
                intent_crash_tombstones[0].read_text(),
                unrelated_intent_payload,
            )
            intent_crash_recovery = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(intent_crash_task),
                    "recover",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                intent_crash_recovery.returncode,
                39,
                intent_crash_recovery.stderr + intent_crash_recovery.stdout,
            )
            self.assertEqual(
                (
                    intent_crash_task
                    / "input_snapshot.transaction.json"
                ).read_text(),
                unrelated_intent_payload,
            )
            self.assertFalse(
                list(intent_crash_task.glob("input_snapshot.transaction.remove-*"))
            )
            self.assertTrue(
                (
                    intent_crash_task
                    / "input_snapshot.transaction.displaced-postcheck-test"
                ).is_file()
            )

            unbound_cases = (
                (
                    "transaction_unbound_temp_replace",
                    110,
                    "input_snapshot.transaction.conflict-*",
                    b"unrelated-unbound-intent\n",
                    "input_snapshot.transaction.unbound-displaced-test",
                ),
                (
                    "task_unbound_temp_replace",
                    111,
                    ".input_manifest.conflict-*",
                    b"unrelated-unbound-task-reference\n",
                    "input_manifest.unbound-displaced-test",
                ),
            )
            for (
                unbound_phase,
                unbound_exit,
                conflict_pattern,
                conflict_payload,
                displaced_basename,
            ) in unbound_cases:
                unbound_root = Path(temporary) / f"snapshot-{unbound_phase}"
                unbound_task = unbound_root / "task"
                unbound_root.mkdir(parents=True)
                shutil.copytree(snapshot_baseline_task, unbound_task)
                unbound_crash = subprocess.run(
                    [
                        str(executable),
                        "--snapshot-publication-crash-worker",
                        str(snapshot_session),
                        str(unbound_task),
                        unbound_phase,
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    unbound_crash.returncode,
                    unbound_exit,
                    unbound_crash.stderr + unbound_crash.stdout,
                )
                unbound_recovery = subprocess.run(
                    [
                        str(executable),
                        "--snapshot-publication-crash-worker",
                        str(snapshot_session),
                        str(unbound_task),
                        "recover",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    unbound_recovery.returncode,
                    39,
                    unbound_recovery.stderr + unbound_recovery.stdout,
                )
                conflicts = list(unbound_task.glob(conflict_pattern))
                self.assertEqual(len(conflicts), 1)
                self.assertEqual(conflicts[0].read_bytes(), conflict_payload)
                self.assertTrue((unbound_task / displaced_basename).is_file())

            def prime_snapshot_authority_race_task(label: str) -> Path:
                race_root = Path(temporary) / f"snapshot-{label}"
                task_root = race_root / "task"
                task_root.mkdir(parents=True)
                primed = subprocess.run(
                    [
                        str(executable),
                        "--snapshot-publication-crash-worker",
                        str(snapshot_session),
                        str(task_root),
                        "reference_durable",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    primed.returncode,
                    97,
                    primed.stderr + primed.stdout,
                )
                self.assertTrue((task_root / "input_snapshot").is_dir())
                self.assertTrue((task_root / "input_manifest.json").is_file())
                self.assertTrue(
                    (task_root / "input_snapshot.transaction.json").is_file()
                )
                return task_root

            def immutable_snapshot_payload(
                snapshot_root: Path,
            ) -> dict[str, tuple[bytes, int]]:
                self.assertTrue(snapshot_root.is_dir())
                payload: dict[str, tuple[bytes, int]] = {}
                for entry in sorted(snapshot_root.iterdir()):
                    self.assertFalse(entry.is_symlink(), entry)
                    self.assertTrue(entry.is_file(), entry)
                    payload[entry.name] = (
                        entry.read_bytes(),
                        entry.stat().st_mode & 0o777,
                    )
                return payload

            root_race_task = prime_snapshot_authority_race_task(
                "generation-root-postopen-replace"
            )
            root_race_snapshot = root_race_task / "input_snapshot"
            original_root_stat = root_race_snapshot.stat()
            original_root_payload = immutable_snapshot_payload(
                root_race_snapshot
            )
            root_race = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(root_race_task),
                    "generation_root_postopen_replace",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                root_race.returncode,
                39,
                root_race.stderr + root_race.stdout,
            )
            displaced_root = (
                root_race_task / "input_snapshot.displaced-root-test"
            )
            self.assertTrue(root_race_snapshot.is_dir())
            self.assertTrue(displaced_root.is_dir())
            self.assertEqual(root_race_snapshot.stat().st_mode & 0o777, 0o555)
            self.assertEqual(displaced_root.stat().st_mode & 0o777, 0o555)
            self.assertEqual(
                immutable_snapshot_payload(root_race_snapshot),
                original_root_payload,
            )
            self.assertEqual(
                immutable_snapshot_payload(displaced_root),
                original_root_payload,
            )
            self.assertEqual(
                (displaced_root.stat().st_dev, displaced_root.stat().st_ino),
                (original_root_stat.st_dev, original_root_stat.st_ino),
            )
            self.assertNotEqual(
                (root_race_snapshot.stat().st_dev, root_race_snapshot.stat().st_ino),
                (displaced_root.stat().st_dev, displaced_root.stat().st_ino),
            )
            root_race_intent = (
                root_race_task / "input_snapshot.transaction.json"
            )
            self.assertTrue(root_race_intent.is_file())
            self.assertFalse(
                (
                    root_race_task
                    / "input_snapshot.prepared-root-replacement-test"
                ).exists()
            )

            root_race_recovery = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(root_race_task),
                    "recover",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                root_race_recovery.returncode,
                39,
                root_race_recovery.stderr + root_race_recovery.stdout,
            )
            self.assertTrue(root_race_intent.is_file())
            self.assertEqual(
                immutable_snapshot_payload(root_race_snapshot),
                original_root_payload,
            )
            self.assertEqual(
                immutable_snapshot_payload(displaced_root),
                original_root_payload,
            )

            artifact_races = (
                (
                    "artifact_metadata_symlink",
                    "metadata.original-symlink-test",
                ),
                (
                    "artifact_metadata_hardlink",
                    "metadata.original-hardlink-test",
                ),
                (
                    "artifact_metadata_mode_clone",
                    "metadata.original-mode-clone-test",
                ),
            )
            for artifact_phase, original_name in artifact_races:
                artifact_task = prime_snapshot_authority_race_task(
                    artifact_phase.replace("_", "-")
                )
                artifact_snapshot = artifact_task / "input_snapshot"
                metadata = artifact_snapshot / "metadata.json"
                original_metadata_bytes = metadata.read_bytes()
                original_metadata_mode = metadata.stat().st_mode & 0o777
                self.assertEqual(original_metadata_mode, 0o444)
                artifact_race = subprocess.run(
                    [
                        str(executable),
                        "--snapshot-publication-crash-worker",
                        str(snapshot_session),
                        str(artifact_task),
                        artifact_phase,
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    artifact_race.returncode,
                    39,
                    artifact_race.stderr + artifact_race.stdout,
                )
                original_metadata = artifact_snapshot / original_name
                artifact_intent = (
                    artifact_task / "input_snapshot.transaction.json"
                )
                self.assertEqual(
                    artifact_snapshot.stat().st_mode & 0o777, 0o555
                )
                self.assertTrue(artifact_intent.is_file())
                self.assertTrue(original_metadata.is_file())
                self.assertFalse(original_metadata.is_symlink())
                self.assertEqual(
                    original_metadata.read_bytes(), original_metadata_bytes
                )
                self.assertEqual(
                    original_metadata.stat().st_mode & 0o777, 0o444
                )
                if artifact_phase == "artifact_metadata_symlink":
                    self.assertTrue(metadata.is_symlink())
                    self.assertEqual(os.readlink(metadata), original_name)
                    self.assertEqual(metadata.read_bytes(), original_metadata_bytes)
                elif artifact_phase == "artifact_metadata_hardlink":
                    self.assertFalse(metadata.is_symlink())
                    self.assertTrue(os.path.samefile(metadata, original_metadata))
                    self.assertEqual(metadata.stat().st_nlink, 2)
                    self.assertEqual(metadata.stat().st_mode & 0o777, 0o444)
                else:
                    self.assertFalse(metadata.is_symlink())
                    self.assertEqual(metadata.read_bytes(), original_metadata_bytes)
                    self.assertEqual(metadata.stat().st_mode & 0o777, 0o644)
                    self.assertNotEqual(
                        (metadata.stat().st_dev, metadata.stat().st_ino),
                        (
                            original_metadata.stat().st_dev,
                            original_metadata.stat().st_ino,
                        ),
                    )

                artifact_recovery = subprocess.run(
                    [
                        str(executable),
                        "--snapshot-publication-crash-worker",
                        str(snapshot_session),
                        str(artifact_task),
                        "recover",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    artifact_recovery.returncode,
                    39,
                    artifact_recovery.stderr + artifact_recovery.stdout,
                )
                self.assertTrue(artifact_intent.is_file())
                self.assertTrue(original_metadata.is_file())
                self.assertEqual(
                    original_metadata.read_bytes(), original_metadata_bytes
                )
                if artifact_phase == "artifact_metadata_symlink":
                    self.assertTrue(metadata.is_symlink())
                    self.assertEqual(os.readlink(metadata), original_name)
                elif artifact_phase == "artifact_metadata_hardlink":
                    self.assertTrue(os.path.samefile(metadata, original_metadata))
                    self.assertEqual(metadata.stat().st_nlink, 2)
                else:
                    self.assertEqual(metadata.read_bytes(), original_metadata_bytes)
                    self.assertEqual(metadata.stat().st_mode & 0o777, 0o644)

            posthash_task = prime_snapshot_authority_race_task(
                "artifact-posthash-mutate"
            )
            posthash_snapshot = posthash_task / "input_snapshot"
            posthash_artifact = posthash_snapshot / "localization_trace.jsonl"
            posthash_before = posthash_artifact.stat()
            self.assertEqual(posthash_artifact.read_bytes(), b"trace\n")
            posthash_race = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(posthash_task),
                    "artifact_posthash_mutate",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                posthash_race.returncode,
                39,
                posthash_race.stderr + posthash_race.stdout,
            )
            posthash_after = posthash_artifact.stat()
            self.assertEqual(
                (posthash_after.st_dev, posthash_after.st_ino),
                (posthash_before.st_dev, posthash_before.st_ino),
            )
            self.assertEqual(posthash_artifact.read_bytes(), b"TRACE\n")
            self.assertEqual(posthash_after.st_mode & 0o777, 0o444)
            self.assertEqual(posthash_snapshot.stat().st_mode & 0o777, 0o555)
            self.assertTrue(
                (posthash_task / "input_snapshot.transaction.json").is_file()
            )
            posthash_recovery = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(posthash_task),
                    "recover",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                posthash_recovery.returncode,
                39,
                posthash_recovery.stderr + posthash_recovery.stdout,
            )
            self.assertEqual(posthash_artifact.read_bytes(), b"TRACE\n")

            cleanup_replace_root = Path(temporary) / "snapshot-cleanup-replacement"
            cleanup_replace_task = cleanup_replace_root / "task"
            cleanup_replace_root.mkdir(parents=True)
            shutil.copytree(snapshot_baseline_task, cleanup_replace_task)
            cleanup_replace_crash = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(cleanup_replace_task),
                    "cleanup_replace",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                cleanup_replace_crash.returncode,
                103,
                cleanup_replace_crash.stderr + cleanup_replace_crash.stdout,
            )
            replacement_backup = cleanup_replace_task / "input_snapshot.backup"
            replacement_marker = replacement_backup / "marker.txt"
            self.assertTrue(replacement_marker.is_file())
            cleanup_replace_recovery = subprocess.run(
                [
                    str(executable),
                    "--snapshot-publication-crash-worker",
                    str(snapshot_session),
                    str(cleanup_replace_task),
                    "recover",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                cleanup_replace_recovery.returncode,
                39,
                cleanup_replace_recovery.stderr
                + cleanup_replace_recovery.stdout,
            )
            self.assertTrue(replacement_marker.is_file())
            self.assertTrue(
                (cleanup_replace_task / "input_snapshot.transaction.json").is_file()
            )

            result_crash_cases = (
                ("after_intent_temp", "cleanup", 80, 0),
                ("after_intent_rename", "list", 81, 0),
                ("after_directory_rename", "committed", 82, 1),
                ("after_destination_fchmod", "read", 88, 1),
                ("after_destination_freeze", "read", 83, 1),
                ("after_exact_read", "list", 84, 1),
                ("after_parent_fsync", "cleanup", 85, 1),
            )
            committed_result_roots: list[Path] = []
            for phase, recovery_entry, expected_exit, expected_committed in (
                result_crash_cases
            ):
                results_root = Path(temporary) / f"result-crash-{phase}"
                crashed = subprocess.run(
                    [
                        str(executable),
                        "--result-publication-crash-worker",
                        str(results_root),
                        phase,
                        "unused",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    crashed.returncode,
                    expected_exit,
                    crashed.stderr + crashed.stdout,
                )
                recovered = subprocess.run(
                    [
                        str(executable),
                        "--result-publication-crash-worker",
                        str(results_root),
                        "recover",
                        recovery_entry,
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    recovered.returncode,
                    0,
                    recovered.stderr + recovered.stdout,
                )
                self.assertIn(
                    f"result recovered committed={expected_committed}",
                    recovered.stdout,
                )
                if expected_committed:
                    committed_result_roots.append(results_root)

            # A UUID-only legacy/partial temporary has no dev/inode authority.
            # Startup must fail closed and preserve it instead of treating an
            # arbitrary hidden pathname as disposable transaction state.
            partial_root = Path(temporary) / "result-partial-intent"
            partial_root.mkdir()
            partial_name = (
                ".result-publish-intent-tmp-"
                "00000000-0000-0000-0000-000000000001"
            )
            (partial_root / partial_name).write_bytes(b"{")
            partial_recovery = subprocess.run(
                [
                    str(executable),
                    "--result-publication-crash-worker",
                    str(partial_root),
                    "recover",
                    "cleanup",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                partial_recovery.returncode,
                29,
                partial_recovery.stderr + partial_recovery.stdout,
            )
            self.assertTrue((partial_root / partial_name).is_file())
            self.assertEqual((partial_root / partial_name).read_bytes(), b"{")

            # Publication helper post-freeze authority checks are executable
            # primitives, not comments: destination replacement, source-name
            # recreation and interrupted-freeze replacement must all reject
            # while preserving the injected evidence.
            for primitive_phase in (
                "primitive_publication_destination_replace",
                "primitive_publication_source_reappear",
                "primitive_interrupted_destination_replace",
            ):
                primitive_root = Path(temporary) / f"result-{primitive_phase}"
                primitive_result = subprocess.run(
                    [
                        str(executable),
                        "--result-publication-crash-worker",
                        str(primitive_root),
                        primitive_phase,
                        "unused",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    primitive_result.returncode,
                    0,
                    primitive_result.stderr + primitive_result.stdout,
                )
                self.assertIn("passed", primitive_result.stdout)

            # Unbound creation names are evidence, not cleanup authority. A
            # replacement at the creation basename must be moved to conflict
            # storage and the recovery entry must fail closed; neither inode
            # may be silently deleted.
            creation_root = Path(temporary) / "result-intent-create-replacement"
            creation_root.mkdir()
            creation_name = (
                ".result-publish-intent-create-"
                "00000000-0000-0000-0000-000000000011"
            )
            creation_path = creation_root / creation_name
            creation_original = Path(temporary) / "result-intent-create-original"
            creation_path.write_bytes(b"original-creation-evidence\n")
            creation_path.rename(creation_original)
            creation_path.write_bytes(b"replacement-creation-evidence\n")
            creation_recovery = subprocess.run(
                [
                    str(executable),
                    "--result-publication-crash-worker",
                    str(creation_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                creation_recovery.returncode,
                29,
                creation_recovery.stderr + creation_recovery.stdout,
            )
            self.assertEqual(
                creation_original.read_bytes(), b"original-creation-evidence\n"
            )
            creation_conflicts = list(
                creation_root.glob(".result-publish-intent-conflict-*")
            )
            self.assertEqual(len(creation_conflicts), 1)
            self.assertEqual(
                creation_conflicts[0].read_bytes(),
                b"replacement-creation-evidence\n",
            )

            # A correctly named identity-bound temporary does not authorize
            # deletion after its pathname is replaced with another inode.
            temp_replace_root = Path(temporary) / "result-intent-temp-replacement"
            temp_crash = subprocess.run(
                [
                    str(executable),
                    "--result-publication-crash-worker",
                    str(temp_replace_root),
                    "after_intent_temp",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(temp_crash.returncode, 80, temp_crash.stderr)
            bound_temps = list(
                temp_replace_root.glob(".result-publish-intent-tmp-*")
            )
            self.assertEqual(len(bound_temps), 1)
            bound_temp = bound_temps[0]
            temp_original = Path(temporary) / "result-intent-temp-original"
            bound_temp.rename(temp_original)
            shutil.copy2(temp_original, bound_temp)
            bound_temp.chmod(0o444)
            replacement_temp_inode = bound_temp.stat().st_ino
            self.assertNotEqual(replacement_temp_inode, temp_original.stat().st_ino)
            temp_recovery = subprocess.run(
                [
                    str(executable),
                    "--result-publication-crash-worker",
                    str(temp_replace_root),
                    "recover",
                    "cleanup",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                temp_recovery.returncode,
                29,
                temp_recovery.stderr + temp_recovery.stdout,
            )
            self.assertTrue(temp_original.is_file())
            self.assertTrue(bound_temp.is_file())
            self.assertEqual(bound_temp.stat().st_ino, replacement_temp_inode)

            # Simulate a process death after canonical intent -> removal
            # tombstone rename, then replace the tombstone. Startup must
            # quarantine the unexpected inode and return failure. It must
            # never regain the canonical authority basename on a later run.
            removal_root = Path(temporary) / "result-intent-removal-replacement"
            removal_crash = subprocess.run(
                [
                    str(executable),
                    "--result-publication-crash-worker",
                    str(removal_root),
                    "after_intent_rename",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(removal_crash.returncode, 81, removal_crash.stderr)
            canonical_intents = list(removal_root.glob(".*.publish-intent.json"))
            self.assertEqual(len(canonical_intents), 1)
            canonical_intent = canonical_intents[0]
            canonical_stat = canonical_intent.stat()
            removal_name = (
                ".result-publish-intent-remove-"
                f"{canonical_stat.st_dev}-{canonical_stat.st_ino}."
                "00000000-0000-0000-0000-000000000012"
            )
            removal_tombstone = removal_root / removal_name
            canonical_intent.rename(removal_tombstone)
            removal_original = Path(temporary) / "result-intent-removal-original"
            removal_tombstone.rename(removal_original)
            shutil.copy2(removal_original, removal_tombstone)
            removal_tombstone.chmod(0o444)
            replacement_removal_inode = removal_tombstone.stat().st_ino
            removal_recovery = subprocess.run(
                [
                    str(executable),
                    "--result-publication-crash-worker",
                    str(removal_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                removal_recovery.returncode,
                29,
                removal_recovery.stderr + removal_recovery.stdout,
            )
            self.assertTrue(removal_original.is_file())
            self.assertFalse(canonical_intent.exists())
            removal_conflicts = list(
                removal_root.glob(".result-publish-intent-conflict-*")
            )
            self.assertEqual(len(removal_conflicts), 1)
            self.assertEqual(
                removal_conflicts[0].stat().st_ino,
                replacement_removal_inode,
            )
            self.assertEqual(
                removal_conflicts[0].read_bytes(),
                removal_original.read_bytes(),
            )

            # After a durable intent but before directory publication, a
            # byte-identical staging clone is still a different authority.
            staging_replace_root = Path(temporary) / "result-staging-replacement"
            staging_crash = subprocess.run(
                [
                    str(executable),
                    "--result-publication-crash-worker",
                    str(staging_replace_root),
                    "after_intent_rename",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(staging_crash.returncode, 81, staging_crash.stderr)
            # The canonical publish-intent filename shares the hidden staging
            # basename plus `.publish-intent.json`; select the directory
            # authority explicitly instead of matching both path types.
            staging_paths = [
                path
                for path in staging_replace_root.glob(".result-staging-*")
                if path.is_dir()
            ]
            self.assertEqual(len(staging_paths), 1)
            staging_path = staging_paths[0]
            staging_original = Path(temporary) / "result-staging-original"
            staging_clone = Path(temporary) / "result-staging-clone"
            shutil.copytree(staging_path, staging_clone, copy_function=shutil.copy2)
            staging_path.rename(staging_original)
            staging_clone.rename(staging_path)
            replacement_staging_inode = staging_path.stat().st_ino
            staging_recovery = subprocess.run(
                [
                    str(executable),
                    "--result-publication-crash-worker",
                    str(staging_replace_root),
                    "recover",
                    "cleanup",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                staging_recovery.returncode,
                29,
                staging_recovery.stderr + staging_recovery.stdout,
            )
            self.assertTrue(staging_original.is_dir())
            self.assertTrue(staging_path.is_dir())
            self.assertEqual(staging_path.stat().st_ino, replacement_staging_inode)
            self.assertTrue(list(staging_replace_root.glob(".*.publish-intent.json")))

            # Result read-time binding rejects links, writable clones,
            # same-inode post-hash mutation, manifest/receipt replacement and
            # whole-root replacement during the final stability sweep.
            for verification_phase in (
                "verify_artifact_symlink",
                "verify_artifact_hardlink",
                "verify_artifact_mode_clone",
                "verify_artifact_posthash_mutate",
                "verify_manifest_postread_replace",
                "verify_receipt_postread_replace",
                "verify_result_root_final_sweep_replace",
            ):
                verification_root = (
                    Path(temporary) / f"result-{verification_phase}"
                )
                verification_result = subprocess.run(
                    [
                        str(executable),
                        "--result-publication-crash-worker",
                        str(verification_root),
                        verification_phase,
                        "unused",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                self.assertEqual(
                    verification_result.returncode,
                    0,
                    verification_result.stderr + verification_result.stdout,
                )
                self.assertIn("rejected replacement", verification_result.stdout)

            # The advisory lock prevents another process from deleting a
            # durable intent that still belongs to an active publisher.
            lock_root = Path(temporary) / "result-cross-process-lock"
            lock_attempt_marker = (
                lock_root.parent / f".{lock_root.name}.recovery-lock-attempt"
            )
            lock_acquired_marker = (
                lock_root.parent / f".{lock_root.name}.recovery-lock-acquired"
            )
            publisher_release_marker = (
                lock_root.parent / f".{lock_root.name}.release-publisher"
            )
            publisher = None
            lock_recovery = None
            try:
                publisher = subprocess.Popen(
                    [
                        str(executable),
                        "--result-publication-crash-worker",
                        str(lock_root),
                        "hold_after_intent",
                        "unused",
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                intent_pattern = ".*.publish-intent.json"
                intent_deadline = time.monotonic() + 8.0
                while (
                    time.monotonic() < intent_deadline
                    and publisher.poll() is None
                    and not list(lock_root.glob(intent_pattern))
                ):
                    time.sleep(0.01)
                self.assertTrue(
                    list(lock_root.glob(intent_pattern)),
                    "publisher did not expose durable intent",
                )

                lock_recovery = subprocess.Popen(
                    [
                        str(executable),
                        "--result-publication-crash-worker",
                        str(lock_root),
                        "recover_lock_probe",
                        "list",
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                attempt_deadline = time.monotonic() + 30.0
                while (
                    time.monotonic() < attempt_deadline
                    and lock_recovery.poll() is None
                    and not lock_attempt_marker.exists()
                ):
                    time.sleep(0.01)
                self.assertTrue(
                    lock_attempt_marker.is_file(),
                    "recovery never reached the real lockf acquisition boundary",
                )
                self.assertIsNone(publisher.poll())
                self.assertIsNone(lock_recovery.poll())
                self.assertTrue(list(lock_root.glob(intent_pattern)))
                self.assertFalse(
                    lock_acquired_marker.exists(),
                    "recovery acquired the process lock before publisher release",
                )
                self.assertFalse(
                    (lock_root / lock_attempt_marker.name).exists()
                    or (lock_root / lock_acquired_marker.name).exists(),
                    "cross-process coordination markers polluted Results root",
                )
                time.sleep(0.2)
                self.assertIsNone(lock_recovery.poll())
                self.assertFalse(lock_acquired_marker.exists())
                self.assertTrue(list(lock_root.glob(intent_pattern)))

                publisher_release_marker.write_text("release\n")
                lock_stdout, lock_stderr = lock_recovery.communicate(timeout=15)
                publisher_stdout, publisher_stderr = publisher.communicate(timeout=5)
                self.assertEqual(
                    publisher.returncode,
                    86,
                    publisher_stderr + publisher_stdout,
                )
                self.assertEqual(
                    lock_recovery.returncode,
                    0,
                    lock_stderr + lock_stdout,
                )
                self.assertTrue(
                    lock_acquired_marker.is_file(),
                    "recovery did not publish its post-lockf acquired marker",
                )
                self.assertFalse(
                    (lock_root / lock_acquired_marker.name).exists(),
                    "lock-acquired marker polluted Results root",
                )
                self.assertIn("result recovered committed=0", lock_stdout)
            finally:
                for process in (lock_recovery, publisher):
                    if process is None:
                        continue
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate()

            # Replacing an intent-bound writable final with byte-identical
            # bytes on a new inode is not authorized by the intent.
            identity_root = Path(temporary) / "result-identity-replacement"
            identity_crash = subprocess.run(
                [
                    str(executable),
                    "--result-publication-crash-worker",
                    str(identity_root),
                    "after_directory_rename",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(identity_crash.returncode, 82)
            identity_final = identity_root / "result-crash-final"
            identity_copy = Path(temporary) / "result-identity-copy"
            shutil.copytree(identity_final, identity_copy)
            shutil.rmtree(identity_final)
            identity_copy.rename(identity_final)
            identity_recovery = subprocess.run(
                [
                    str(executable),
                    "--result-publication-crash-worker",
                    str(identity_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                identity_recovery.returncode,
                29,
                identity_recovery.stderr + identity_recovery.stdout,
            )
            self.assertTrue(
                list(identity_root.glob(".*.publish-intent.json"))
            )
            self.assertEqual(identity_final.stat().st_mode & 0o777, 0o755)

            # A writable final without any durable intent is tamper evidence,
            # not a recoverable committed result. Listing isolates it.
            unbound_root = committed_result_roots[-1]
            unbound_final = unbound_root / "result-crash-final"
            unbound_final.chmod(0o755)
            unbound_recovery = subprocess.run(
                [
                    str(executable),
                    "--result-publication-crash-worker",
                    str(unbound_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                unbound_recovery.returncode,
                0,
                unbound_recovery.stderr + unbound_recovery.stdout,
            )
            self.assertIn("result recovered committed=0", unbound_recovery.stdout)
            self.assertFalse(unbound_final.exists())
            self.assertTrue((unbound_root / "quarantine").is_dir())

            # The 100k-record finalization qualification runs in its own
            # process. ru_maxrss is a lifetime high-water mark, so the
            # full suite's unrelated clock/workbook/replay allocations
            # must not contaminate this frozen 256 MiB gate.
            finalization_result = subprocess.run(
                [str(executable), "--finalization-scale"],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                finalization_result.returncode,
                0,
                finalization_result.stderr + "\n" + finalization_result.stdout,
            )
            print(finalization_result.stdout.strip())
            match = re.search(
                r"(?m)^Finalization test peak RSS bytes: (\d+)$",
                finalization_result.stdout,
            )
            self.assertIsNotNone(match, finalization_result.stdout)
            peak_rss_bytes = int(match.group(1))
            self.assertLess(
                peak_rss_bytes,
                256 * 1024 * 1024,
                f"100k-record finalization peak RSS was {peak_rss_bytes} bytes",
            )
            self.assertRegex(
                finalization_result.stdout,
                r"(?m)^Finalization test records: 300000$",
            )
            for metric in (
                "input bytes", "temporary disk bytes", "wall seconds",
                "CPU seconds",
            ):
                self.assertRegex(
                    finalization_result.stdout,
                    rf"(?m)^Finalization test {metric}: [0-9]+(?:\.[0-9]+)?$",
                )
            trace_scale_result = subprocess.run(
                [str(executable), "--trace-compaction-scale"],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                trace_scale_result.returncode,
                0,
                trace_scale_result.stderr + "\n" + trace_scale_result.stdout,
            )
            print(trace_scale_result.stdout.strip())
            trace_match = re.search(
                r"(?m)^Trace compaction peak RSS bytes: (\d+)$",
                trace_scale_result.stdout,
            )
            self.assertIsNotNone(trace_match, trace_scale_result.stdout)
            trace_peak_rss = int(trace_match.group(1))
            self.assertLess(
                trace_peak_rss,
                256 * 1024 * 1024,
                f"1.728M transition-storm compaction peak RSS was {trace_peak_rss} bytes",
            )
            self.assertRegex(
                trace_scale_result.stdout,
                r"(?m)^Trace compaction input records: 1728000$",
            )
            for metric in ("wall seconds", "CPU seconds"):
                self.assertRegex(
                    trace_scale_result.stdout,
                    rf"(?m)^Trace compaction {metric}: [0-9]+(?:\.[0-9]+)?$",
                )
            self.assertIn(
                "Trace compaction temporary disk bytes: 0",
                trace_scale_result.stdout,
            )
            tag_scale_result = subprocess.run(
                [str(executable), "--tag-evidence-scale"],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                tag_scale_result.returncode,
                0,
                tag_scale_result.stderr + "\n" + tag_scale_result.stdout,
            )
            print(tag_scale_result.stdout.strip())
            tag_match = re.search(
                r"(?m)^Tag evidence peak RSS bytes: (\d+)$",
                tag_scale_result.stdout,
            )
            self.assertIsNotNone(tag_match, tag_scale_result.stdout)
            tag_peak_rss = int(tag_match.group(1))
            self.assertLess(
                tag_peak_rss,
                768 * 1024 * 1024,
                f"200k burst/observation evidence peak RSS was {tag_peak_rss} bytes",
            )
            self.assertRegex(
                tag_scale_result.stdout,
                r"(?m)^Tag evidence input records: 400000$",
            )
            for metric in (
                "input bytes", "temporary disk bytes", "wall seconds",
                "CPU seconds",
            ):
                self.assertRegex(
                    tag_scale_result.stdout,
                    rf"(?m)^Tag evidence {metric}: [0-9]+(?:\.[0-9]+)?$",
                )
            # V1R4 §14.2: the Map Library generation-CAS scenario runs as
            # its own process (same pattern as --xlsx-scale) so the default
            # host mode stays inside the frozen peak-RSS gate.
            cas_result = subprocess.run(
                [str(executable), "--map-library-cas", str(temporary)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(cas_result.returncode, 0, cas_result.stderr)
            self.assertIn("map library CAS passed", cas_result.stdout)

            # RC-HIGH: exercise the map-quarantine transaction with real
            # process death, not a caught Swift error. Each worker exits at a
            # different durable rename/fsync boundary; a fresh process then
            # enters through list/map/rebuild and must reconcile the same tree.
            prior_map_id = "crash-recovery-map"
            package_sha = "c" * 64
            crash_cases = (
                ("after_source_thaw", "list", 70),
                ("after_payload", "list", 71),
                ("after_diagnostic_placement", "map", 76),
                ("after_diagnostic", "map", 72),
                ("after_publish_rename", "list", 74),
                ("after_publish_freeze", "map", 75),
                ("after_publish", "rebuild", 73),
            )
            recovered_roots: list[Path] = []
            for phase, recovery_entry, expected_exit in crash_cases:
                crash_root = Path(temporary) / f"map-quarantine-{phase}" / "Maps"
                crash_result = subprocess.run(
                    [
                        str(executable),
                        "--map-quarantine-crash-worker",
                        str(crash_root),
                        phase,
                        "unused",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    crash_result.returncode,
                    expected_exit,
                    crash_result.stderr + crash_result.stdout,
                )
                source = crash_root / "packages" / prior_map_id / package_sha
                quarantine_root = crash_root / "quarantine" / prior_map_id
                self.assertEqual(
                    source.exists(),
                    phase == "after_source_thaw",
                    phase,
                )
                if phase == "after_source_thaw":
                    self.assertEqual(source.stat().st_mode & 0o777, 0o755)
                    restore_boundary = subprocess.run(
                        [
                            str(executable),
                            "--map-quarantine-crash-worker",
                            str(crash_root),
                            "recover_after_source_restore",
                            "list",
                        ],
                        check=False,
                        capture_output=True,
                        text=True,
                    )
                    self.assertEqual(
                        restore_boundary.returncode,
                        77,
                        restore_boundary.stderr + restore_boundary.stdout,
                    )
                    self.assertEqual(source.stat().st_mode & 0o777, 0o555)
                    self.assertEqual(
                        len(list(quarantine_root.glob(".*.diagnostic.tmp"))),
                        1,
                    )
                self.assertTrue(quarantine_root.is_dir(), phase)

                recovery_result = subprocess.run(
                    [
                        str(executable),
                        "--map-quarantine-crash-worker",
                        str(crash_root),
                        "recover",
                        recovery_entry,
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    recovery_result.returncode,
                    0,
                    recovery_result.stderr + recovery_result.stdout,
                )
                self.assertIn("recovered listed=0 registry=0", recovery_result.stdout)
                entries = sorted(quarantine_root.iterdir())
                hidden = [item for item in entries if item.name.startswith(".")]
                finals = [item for item in entries if not item.name.startswith(".")]
                self.assertFalse(hidden, f"{phase}: {hidden}")
                self.assertEqual(len(finals), 1, f"{phase}: {entries}")
                self.assertTrue(
                    source.exists() ^ finals[0].is_dir(),
                    f"{phase}: source/final outcome must be exclusive",
                )
                diagnostic = finals[0] / "quarantine_diagnostic.json"
                self.assertTrue(diagnostic.is_file())
                self.assertEqual(diagnostic.stat().st_mode & 0o777, 0o444)
                self.assertEqual(finals[0].stat().st_mode & 0o777, 0o555)
                registry = json.loads((crash_root / "registry.json").read_text())
                self.assertEqual(registry["map_count"], 0)
                self.assertFalse(
                    any(".pending" in item.get("package_directory", "")
                        for item in registry["maps"])
                )
                recovered_roots.append(crash_root)

            def rewrite_quarantine_diagnostic_as_legacy_v2(
                diagnostic: Path,
            ) -> bytes:
                payload = json.loads(diagnostic.read_text())
                payload["version"] = 2
                payload.pop("payload_device")
                payload.pop("payload_inode")
                canonical = json.dumps(
                    payload,
                    ensure_ascii=False,
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode()
                diagnostic.chmod(0o644)
                diagnostic.write_bytes(canonical)
                diagnostic.chmod(0o444)
                return canonical

            # Legacy v2 has no dev/inode authority and is compatible only as
            # an already-published immutable final. It must never complete a
            # hidden pending transaction, whether the diagnostic is still at
            # `.diagnostic.tmp` or has already been embedded in the payload.
            v2_temporary_root = (
                Path(temporary) / "map-quarantine-v2-pending-temporary" / "Maps"
            )
            v2_temporary_crash = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(v2_temporary_root),
                    "after_payload",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(v2_temporary_crash.returncode, 71)
            v2_temporary_quarantine = (
                v2_temporary_root / "quarantine" / prior_map_id
            )
            v2_temporary_pending = next(
                v2_temporary_quarantine.glob(".*.pending")
            )
            v2_temporary_diagnostic = next(
                v2_temporary_quarantine.glob(".*.diagnostic.tmp")
            )
            v2_temporary_bytes = rewrite_quarantine_diagnostic_as_legacy_v2(
                v2_temporary_diagnostic
            )
            v2_temporary_recovery = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(v2_temporary_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                v2_temporary_recovery.returncode,
                19,
                v2_temporary_recovery.stderr + v2_temporary_recovery.stdout,
            )
            self.assertTrue(v2_temporary_pending.is_dir())
            self.assertEqual(
                v2_temporary_diagnostic.read_bytes(), v2_temporary_bytes
            )
            self.assertFalse(
                (
                    v2_temporary_root
                    / "packages"
                    / prior_map_id
                    / package_sha
                ).exists()
            )

            v2_embedded_root = (
                Path(temporary) / "map-quarantine-v2-pending-embedded" / "Maps"
            )
            v2_embedded_crash = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(v2_embedded_root),
                    "after_diagnostic_placement",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(v2_embedded_crash.returncode, 76)
            v2_embedded_quarantine = (
                v2_embedded_root / "quarantine" / prior_map_id
            )
            v2_embedded_pending = next(v2_embedded_quarantine.glob(".*.pending"))
            v2_embedded_diagnostic = (
                v2_embedded_pending / "quarantine_diagnostic.json"
            )
            v2_embedded_bytes = rewrite_quarantine_diagnostic_as_legacy_v2(
                v2_embedded_diagnostic
            )
            v2_embedded_recovery = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(v2_embedded_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                v2_embedded_recovery.returncode,
                19,
                v2_embedded_recovery.stderr + v2_embedded_recovery.stdout,
            )
            self.assertTrue(v2_embedded_pending.is_dir())
            self.assertEqual(
                v2_embedded_diagnostic.read_bytes(), v2_embedded_bytes
            )

            # A byte-identical clone at the pending pathname is still a new
            # directory authority. The v3 diagnostic binds the original inode
            # and recovery must preserve both copies instead of publishing the
            # clone or deleting either one.
            pending_clone_root = (
                Path(temporary) / "map-quarantine-pending-clone" / "Maps"
            )
            pending_clone_crash = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(pending_clone_root),
                    "after_payload",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(pending_clone_crash.returncode, 71)
            pending_clone_quarantine = (
                pending_clone_root / "quarantine" / prior_map_id
            )
            pending_clone = next(pending_clone_quarantine.glob(".*.pending"))
            pending_original = Path(temporary) / "pending-clone-original"
            pending_replacement = Path(temporary) / "pending-clone-replacement"
            shutil.copytree(
                pending_clone, pending_replacement, copy_function=shutil.copy2
            )
            pending_clone.rename(pending_original)
            pending_replacement.rename(pending_clone)
            replacement_pending_inode = pending_clone.stat().st_ino
            self.assertNotEqual(
                replacement_pending_inode, pending_original.stat().st_ino
            )
            pending_clone_recovery = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(pending_clone_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                pending_clone_recovery.returncode,
                19,
                pending_clone_recovery.stderr + pending_clone_recovery.stdout,
            )
            self.assertTrue(pending_original.is_dir())
            self.assertTrue(pending_clone.is_dir())
            self.assertEqual(pending_clone.stat().st_ino, replacement_pending_inode)
            self.assertTrue(
                (
                    pending_clone
                    / "quarantine_diagnostic.json"
                ).is_file(),
                "recovery may durably embed the diagnostic before the v3 "
                "payload-inode mismatch is detected",
            )

            # The large payload keeps verification inside its streaming hash
            # long enough for deterministic delayed replacement. The worker
            # succeeds only when production rejects the replacement and both
            # the opened original evidence and replacement pathname survive.
            delayed_recovery_cases = (
                (
                    "recover_replace_pending_after_open",
                    "pending-root-open-original",
                ),
                (
                    "recover_replace_embedded_after_read",
                    "embedded-diagnostic-original",
                ),
            )
            for delayed_phase, displaced_name in delayed_recovery_cases:
                delayed_root = (
                    Path(temporary) / f"map-quarantine-{delayed_phase}" / "Maps"
                )
                delayed_crash = subprocess.run(
                    [
                        str(executable),
                        "--map-quarantine-crash-worker",
                        str(delayed_root),
                        "after_diagnostic_large",
                        "unused",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
                self.assertEqual(
                    delayed_crash.returncode,
                    89,
                    delayed_crash.stderr + delayed_crash.stdout,
                )
                delayed_result = subprocess.run(
                    [
                        str(executable),
                        "--map-quarantine-crash-worker",
                        str(delayed_root),
                        delayed_phase,
                        "list",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
                self.assertEqual(
                    delayed_result.returncode,
                    0,
                    delayed_result.stderr + delayed_result.stdout,
                )
                self.assertIn("rejected replacement", delayed_result.stdout)
                self.assertTrue(
                    (delayed_root.parent / displaced_name).exists(),
                    delayed_phase,
                )
                delayed_pending = next(
                    (delayed_root / "quarantine" / prior_map_id).glob(
                        ".*.pending"
                    )
                )
                self.assertTrue(delayed_pending.is_dir())

            # Replacing either the already-open Maps root pathname or the
            # acquired `.map-library.lock` pathname is detected at the next
            # production validation. The durable diagnostic remains, and the
            # old/new authorities both survive for audit.
            for binding_phase, displaced_name in (
                ("replace_map_root_after_open", "map-root-open-displaced"),
                ("replace_map_lock_after_acquire", "map-lock-open-displaced"),
            ):
                binding_root = (
                    Path(temporary) / f"map-quarantine-{binding_phase}" / "Maps"
                )
                binding_result = subprocess.run(
                    [
                        str(executable),
                        "--map-quarantine-crash-worker",
                        str(binding_root),
                        binding_phase,
                        "unused",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    binding_result.returncode,
                    19,
                    binding_result.stderr + binding_result.stdout,
                )
                self.assertTrue(binding_root.exists())
                displaced_binding = binding_root.parent / displaced_name
                self.assertTrue(displaced_binding.exists())
                if binding_phase == "replace_map_root_after_open":
                    self.assertNotEqual(
                        binding_root.stat().st_ino,
                        displaced_binding.stat().st_ino,
                    )
                else:
                    canonical_lock = binding_root / ".map-library.lock"
                    displaced_lock = binding_root.parent / displaced_name
                    self.assertTrue(canonical_lock.is_file())
                    self.assertNotEqual(
                        canonical_lock.stat().st_ino,
                        displaced_lock.stat().st_ino,
                    )
                    quarantine_binding_root = (
                        binding_root / "quarantine" / prior_map_id
                    )
                    # Lock validation can fail either before the diagnostic
                    # is detached or after its identity-bound removal rename.
                    # Both names are durable recovery evidence; neither is a
                    # successful cleanup state.
                    diagnostic_evidence = list(
                        quarantine_binding_root.glob(".*.diagnostic.tmp")
                    ) + list(
                        quarantine_binding_root.glob(".*.diagnostic.removing")
                    )
                    self.assertEqual(len(diagnostic_evidence), 1)

            # If rollback finds both canonical temporary and removal
            # tombstone names, RENAME_EXCL semantics must fail closed and
            # retain both diagnostic copies.
            eexist_root = (
                Path(temporary) / "map-quarantine-rollback-eexist" / "Maps"
            )
            eexist_crash = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(eexist_root),
                    "after_source_thaw",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(eexist_crash.returncode, 70)
            eexist_quarantine = eexist_root / "quarantine" / prior_map_id
            eexist_temporary = next(eexist_quarantine.glob(".*.diagnostic.tmp"))
            eexist_removal = eexist_quarantine / (
                eexist_temporary.name.removesuffix(".diagnostic.tmp")
                + ".diagnostic.removing"
            )
            shutil.copy2(eexist_temporary, eexist_removal)
            eexist_removal.chmod(0o444)
            eexist_recovery = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(eexist_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                eexist_recovery.returncode,
                19,
                eexist_recovery.stderr + eexist_recovery.stdout,
            )
            self.assertTrue(eexist_temporary.is_file())
            self.assertTrue(eexist_removal.is_file())

            # Real process death after `.diagnostic.tmp` ->
            # `.diagnostic.removing` exercises restart from the durable
            # tombstone name without Swift unwinding or caught-error cleanup.
            tombstone_root = (
                Path(temporary) / "map-quarantine-tombstone-restart" / "Maps"
            )
            tombstone_crash = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(tombstone_root),
                    "after_source_thaw",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(tombstone_crash.returncode, 70)
            tombstone_boundary = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(tombstone_root),
                    "recover_after_tombstone_rename",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                tombstone_boundary.returncode,
                78,
                tombstone_boundary.stderr + tombstone_boundary.stdout,
            )
            tombstone_quarantine = tombstone_root / "quarantine" / prior_map_id
            self.assertEqual(
                len(list(tombstone_quarantine.glob(".*.diagnostic.removing"))),
                1,
            )
            self.assertFalse(
                list(tombstone_quarantine.glob(".*.diagnostic.tmp"))
            )
            tombstone_restart = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(tombstone_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                tombstone_restart.returncode,
                0,
                tombstone_restart.stderr + tombstone_restart.stdout,
            )
            self.assertFalse(
                list(tombstone_quarantine.glob(".*.diagnostic.removing"))
            )

            # Once the tombstone is durable, replacing the source pathname
            # with a byte-identical clone must not grant cleanup authority.
            tombstone_replace_root = (
                Path(temporary) / "map-quarantine-tombstone-source-replace" / "Maps"
            )
            tombstone_replace_crash = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(tombstone_replace_root),
                    "after_source_thaw",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(tombstone_replace_crash.returncode, 70)
            tombstone_replace_boundary = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(tombstone_replace_root),
                    "recover_replace_source_after_tombstone",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                tombstone_replace_boundary.returncode,
                79,
                tombstone_replace_boundary.stderr
                + tombstone_replace_boundary.stdout,
            )
            tombstone_replace_quarantine = (
                tombstone_replace_root / "quarantine" / prior_map_id
            )
            tombstone_replace_intent = next(
                tombstone_replace_quarantine.glob(".*.diagnostic.removing")
            )
            tombstone_replace_source = (
                tombstone_replace_root
                / "packages"
                / prior_map_id
                / package_sha
            )
            tombstone_replace_original = (
                tombstone_replace_source.parent
                / f"tombstone-original-{package_sha}"
            )
            self.assertTrue(tombstone_replace_source.is_dir())
            self.assertTrue(tombstone_replace_original.is_dir())
            self.assertNotEqual(
                tombstone_replace_source.stat().st_ino,
                tombstone_replace_original.stat().st_ino,
            )
            tombstone_replace_restart = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(tombstone_replace_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                tombstone_replace_restart.returncode,
                19,
                tombstone_replace_restart.stderr
                + tombstone_replace_restart.stdout,
            )
            self.assertTrue(tombstone_replace_intent.is_file())
            self.assertTrue(tombstone_replace_source.is_dir())
            self.assertTrue(tombstone_replace_original.is_dir())

            # The opposite restart image is unlink visible but its parent
            # fsync not yet reached. A fresh rebuild must safely re-quarantine
            # the restored source and leave no hidden diagnostic residue.
            unlink_window_root = (
                Path(temporary) / "map-quarantine-unlink-window" / "Maps"
            )
            unlink_window_crash = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(unlink_window_root),
                    "after_source_thaw",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(unlink_window_crash.returncode, 70)
            unlink_boundary = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(unlink_window_root),
                    "recover_after_tombstone_unlink_before_fsync",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                unlink_boundary.returncode,
                80,
                unlink_boundary.stderr + unlink_boundary.stdout,
            )
            unlink_quarantine = unlink_window_root / "quarantine" / prior_map_id
            self.assertFalse(list(unlink_quarantine.glob(".*.diagnostic.tmp")))
            self.assertFalse(
                list(unlink_quarantine.glob(".*.diagnostic.removing"))
            )
            unlink_restart = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(unlink_window_root),
                    "recover",
                    "rebuild",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                unlink_restart.returncode,
                0,
                unlink_restart.stderr + unlink_restart.stdout,
            )
            unlink_entries = list(unlink_quarantine.iterdir())
            self.assertFalse(
                [item for item in unlink_entries if item.name.startswith(".")]
            )
            self.assertEqual(
                len(
                    [
                        item
                        for item in unlink_entries
                        if not item.name.startswith(".")
                    ]
                ),
                1,
            )

            # Durable transaction UUID spellings are canonical lowercase
            # hyphenated UUIDs. Foundation's permissive UUID parser must not
            # alias uppercase or non-hyphenated hidden names to writer output.
            for uuid_variant in ("uppercase", "nonhyphenated"):
                uuid_root = (
                    Path(temporary)
                    / f"map-quarantine-uuid-{uuid_variant}"
                    / "Maps"
                )
                uuid_crash = subprocess.run(
                    [
                        str(executable),
                        "--map-quarantine-crash-worker",
                        str(uuid_root),
                        "after_source_thaw",
                        "unused",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(uuid_crash.returncode, 70)
                uuid_quarantine = uuid_root / "quarantine" / prior_map_id
                canonical_temporary = next(
                    uuid_quarantine.glob(".*.diagnostic.tmp")
                )
                suffix = ".diagnostic.tmp"
                transaction_id = canonical_temporary.name[1 : -len(suffix)]
                uuid_text = transaction_id[65:]
                if uuid_variant == "uppercase":
                    mutated_uuid = uuid_text.upper()
                else:
                    mutated_uuid = uuid_text.replace("-", "")
                mutated_transaction_id = (
                    transaction_id[:65] + mutated_uuid
                )
                mutated_temporary = uuid_quarantine / (
                    f".{mutated_transaction_id}{suffix}"
                )
                canonical_temporary.rename(mutated_temporary)
                uuid_recovery = subprocess.run(
                    [
                        str(executable),
                        "--map-quarantine-crash-worker",
                        str(uuid_root),
                        "recover",
                        "list",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    uuid_recovery.returncode,
                    19,
                    uuid_recovery.stderr + uuid_recovery.stdout,
                )
                self.assertTrue(mutated_temporary.is_file())

            # A v3 durable diagnostic authorizes recovery of one exact
            # payload inode, not merely any directory with the same bytes.
            # Replace the pre-rename source with a byte-identical new inode
            # and prove startup preserves the intent and fails closed.
            replacement_root = (
                Path(temporary) / "map-quarantine-source-replacement" / "Maps"
            )
            replacement_crash = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(replacement_root),
                    "after_source_thaw",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(replacement_crash.returncode, 70)
            replacement_source = (
                replacement_root / "packages" / prior_map_id / package_sha
            )
            replacement_copy = Path(temporary) / "replacement-package-copy"
            shutil.copytree(replacement_source, replacement_copy)
            shutil.rmtree(replacement_source)
            replacement_copy.rename(replacement_source)
            replacement_recovery = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(replacement_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                replacement_recovery.returncode,
                19,
                replacement_recovery.stderr + replacement_recovery.stdout,
            )
            self.assertTrue(replacement_source.is_dir())
            replacement_quarantine = (
                replacement_root / "quarantine" / prior_map_id
            )
            self.assertEqual(
                len(list(replacement_quarantine.glob(".*.diagnostic.tmp"))),
                1,
            )

            # Replace the source after recovery has hashed and restored the
            # exact diagnostic-bound inode to 0555, but before it removes the
            # durable intent. The final path check must detect the new inode,
            # preserve the intent and avoid chmodding the replacement.
            in_recovery_root = (
                Path(temporary) / "map-quarantine-recovery-replacement" / "Maps"
            )
            in_recovery_crash = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(in_recovery_root),
                    "after_source_thaw",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(in_recovery_crash.returncode, 70)
            in_recovery_result = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(in_recovery_root),
                    "recover_replace_after_mode_restore",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                in_recovery_result.returncode,
                19,
                in_recovery_result.stderr + in_recovery_result.stdout,
            )
            in_recovery_source = (
                in_recovery_root / "packages" / prior_map_id / package_sha
            )
            in_recovery_displaced = (
                in_recovery_source.parent / f"displaced-{package_sha}"
            )
            self.assertTrue(in_recovery_source.is_dir())
            self.assertTrue(in_recovery_displaced.is_dir())
            self.assertEqual(in_recovery_source.stat().st_mode & 0o777, 0o755)
            self.assertEqual(
                in_recovery_displaced.stat().st_mode & 0o777,
                0o555,
            )
            self.assertNotEqual(
                in_recovery_source.stat().st_ino,
                in_recovery_displaced.stat().st_ino,
            )
            self.assertEqual(
                (in_recovery_source / "payload.bin").read_bytes(),
                (in_recovery_displaced / "payload.bin").read_bytes(),
            )
            in_recovery_quarantine = (
                in_recovery_root / "quarantine" / prior_map_id
            )
            self.assertEqual(
                len(list(in_recovery_quarantine.glob(".*.diagnostic.tmp"))),
                1,
            )

            def rewrite_final_diagnostic_as_legacy_v2(
                map_root: Path, *, writable_root: bool
            ) -> Path:
                quarantine = map_root / "quarantine" / prior_map_id
                final = next(
                    item for item in quarantine.iterdir()
                    if not item.name.startswith(".")
                )
                diagnostic = final / "quarantine_diagnostic.json"
                payload = json.loads(diagnostic.read_text())
                payload["version"] = 2
                payload.pop("payload_device")
                payload.pop("payload_inode")
                final.chmod(0o755)
                diagnostic.chmod(0o644)
                diagnostic.write_text(
                    json.dumps(
                        payload,
                        ensure_ascii=False,
                        sort_keys=True,
                        separators=(",", ":"),
                    )
                )
                diagnostic.chmod(0o444)
                final.chmod(0o755 if writable_root else 0o555)
                return final

            # Legacy v2 diagnostics remain readable only for their historical
            # fully frozen 0555 final state. They cannot authorize recovery of
            # a writable 0755 final because v2 has no durable inode binding.
            legacy_immutable_root = recovered_roots[1]
            legacy_immutable_final = rewrite_final_diagnostic_as_legacy_v2(
                legacy_immutable_root, writable_root=False
            )
            legacy_immutable_recovery = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(legacy_immutable_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                legacy_immutable_recovery.returncode,
                0,
                legacy_immutable_recovery.stderr
                + legacy_immutable_recovery.stdout,
            )
            self.assertEqual(legacy_immutable_final.stat().st_mode & 0o777, 0o555)

            legacy_writable_root = recovered_roots[2]
            legacy_writable_final = rewrite_final_diagnostic_as_legacy_v2(
                legacy_writable_root, writable_root=True
            )
            legacy_writable_recovery = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(legacy_writable_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                legacy_writable_recovery.returncode,
                19,
                legacy_writable_recovery.stderr
                + legacy_writable_recovery.stdout,
            )
            self.assertEqual(legacy_writable_final.stat().st_mode & 0o777, 0o755)

            # A quarantine transaction must reject symlinked destination
            # roots before it writes a diagnostic or renames the package.
            for symlink_level in ("base", "map"):
                symlink_root = (
                    Path(temporary)
                    / f"map-quarantine-symlink-{symlink_level}"
                    / "Maps"
                )
                symlink_root.mkdir(parents=True)
                external = Path(temporary) / f"quarantine-external-{symlink_level}"
                external.mkdir()
                if symlink_level == "base":
                    (symlink_root / "quarantine").symlink_to(
                        external, target_is_directory=True
                    )
                else:
                    (symlink_root / "quarantine").mkdir()
                    (symlink_root / "quarantine" / prior_map_id).symlink_to(
                        external, target_is_directory=True
                    )
                symlink_result = subprocess.run(
                    [
                        str(executable),
                        "--map-quarantine-crash-worker",
                        str(symlink_root),
                        "after_payload",
                        "unused",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    symlink_result.returncode,
                    19,
                    symlink_result.stderr + symlink_result.stdout,
                )
                self.assertEqual(
                    list(external.iterdir()),
                    [],
                    f"{symlink_level}: quarantine must not follow destination symlink",
                )

            # A recovered published quarantine and a recreated production
            # source are conflicting copies. Recovery must preserve both and
            # fail closed instead of guessing which bytes should win.
            conflict_root = recovered_roots[1]
            conflict_source = (
                conflict_root / "packages" / prior_map_id / package_sha
            )
            conflict_source.mkdir(parents=True)
            (conflict_source / "recreated.bin").write_bytes(b"recreated\n")
            conflict_final = next(
                item
                for item in (conflict_root / "quarantine" / prior_map_id).iterdir()
                if not item.name.startswith(".")
            )
            conflict_result = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(conflict_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(conflict_result.returncode, 19)
            self.assertTrue(conflict_source.is_dir())
            self.assertTrue(conflict_final.is_dir())

            # Strict recovery is fail-closed. A non-0444 diagnostic and an
            # unknown transaction name are not repaired by guessing, while
            # the already-published payload remains present and auditable.
            strict_root = Path(temporary) / "map-quarantine-strict" / "Maps"
            strict_crash = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(strict_root),
                    "after_diagnostic",
                    "unused",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(strict_crash.returncode, 72, strict_crash.stderr)
            strict_quarantine = strict_root / "quarantine" / prior_map_id
            pending = next(strict_quarantine.glob(".*.pending"))
            pending_diagnostic = pending / "quarantine_diagnostic.json"
            pending_diagnostic.chmod(0o644)
            strict_recovery = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(strict_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(strict_recovery.returncode, 19)
            self.assertTrue(pending.is_dir())
            self.assertFalse(
                (strict_root / "packages" / prior_map_id / package_sha).exists()
            )
            pending_diagnostic.chmod(0o444)
            pending_payload = pending / "payload.bin"
            pending.chmod(0o755)
            pending_payload.chmod(0o644)
            pending_payload.write_bytes(b"tampered-after-crash\n")
            pending_payload.chmod(0o444)
            pending.chmod(0o555)
            hash_recovery = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(strict_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(hash_recovery.returncode, 19)
            self.assertTrue(pending.is_dir())
            pending.chmod(0o755)
            pending_payload.chmod(0o644)
            pending_payload.write_bytes(b"crash-window-payload\n")
            pending_payload.chmod(0o444)
            pending.chmod(0o555)
            strict_retry = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(strict_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                strict_retry.returncode,
                0,
                strict_retry.stderr + strict_retry.stdout,
            )

            published_root = recovered_roots[0]
            published_quarantine = published_root / "quarantine" / prior_map_id
            unknown = published_quarantine / ".unknown.pending"
            unknown.mkdir()
            unknown_result = subprocess.run(
                [
                    str(executable),
                    "--map-quarantine-crash-worker",
                    str(published_root),
                    "recover",
                    "list",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(unknown_result.returncode, 19)
            self.assertEqual(
                len([p for p in published_quarantine.iterdir()
                     if not p.name.startswith(".")]),
                1,
            )
            unknown.rmdir()
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
            package = convert_workbook(
                workbook, Path(temporary) / "package", store_id="s1"
            )
            valid_result = subprocess.run(
                [str(executable), str(package)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(valid_result.returncode, 0, valid_result.stderr)

            expected_segments = Path(temporary) / "python-shelf-segments.json"
            expected_segments.write_text(
                json.dumps(
                    json.loads(
                        (package / "shelves.json").read_text(encoding="utf-8")
                    )["shelf_segments"],
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                ),
                encoding="utf-8",
            )
            shelf_parity = subprocess.run(
                [
                    str(executable),
                    "--shelf-segment-parity",
                    str(workbook),
                    str(expected_segments),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                shelf_parity.returncode,
                0,
                shelf_parity.stderr + "\n" + shelf_parity.stdout,
            )

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

            # Rebind the package manifest after semantic shelves mutations so
            # the Swift validator must reject the version/segment contract,
            # rather than merely observing a stale artifact hash.
            formal_shelves_v1 = suite_root / "formal-shelves-v1.fail"
            shutil.copytree(package, formal_shelves_v1)
            formal_shelves_payload = json.loads(
                (formal_shelves_v1 / "shelves.json").read_text(encoding="utf-8")
            )
            formal_shelves_payload["version"] = 1
            formal_shelves_payload.pop("shelf_segments")
            (formal_shelves_v1 / "shelves.json").write_text(
                json.dumps(
                    formal_shelves_payload,
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            (formal_shelves_v1 / "package_manifest.json").write_text(
                json.dumps(
                    build_package_manifest(formal_shelves_v1),
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )

            invalid_shelf_axis = suite_root / "invalid-shelf-axis.fail"
            shutil.copytree(package, invalid_shelf_axis)
            invalid_shelf_payload = json.loads(
                (invalid_shelf_axis / "shelves.json").read_text(encoding="utf-8")
            )
            invalid_shelf_payload["shelf_segments"][0]["longitudinal_axis"] = [
                0.5,
                0.0,
            ]
            (invalid_shelf_axis / "shelves.json").write_text(
                json.dumps(
                    invalid_shelf_payload,
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            (invalid_shelf_axis / "package_manifest.json").write_text(
                json.dumps(
                    build_package_manifest(invalid_shelf_axis),
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
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

            # Mobile-Only V1: three-format canonical parity and XLSX
            # safety policy (I1-I14) run inside ONE --import-suite
            # invocation. The fixtures below are generated here so the
            # Swift harness only performs import logic.
            import_suite_root = Path(temporary) / "import-suite"
            import_suite_root.mkdir()

            business_elements = [
                (1, {"shapeType": "MapShelf", "x": 100, "y": 200,
                     "width": 300, "height": 100, "code": "S1", "visible": True}),
                (1, {"shapeType": "MapCross", "points": [0, 500, 1000, 500],
                     "lineWidth": 200, "code": "C1", "visible": True}),
                (2, {"shapeType": "MapRoadPoint", "x": 100, "y": 500,
                     "width": 20, "height": 20, "code": 1,
                     "crossCodes": ["C1"], "visible": True}),
            ]

            # sample.xlsx (self-contained minimal XLSX writer).
            write_workbook(
                import_suite_root / "sample.xlsx",
                [
                    (str(floor), json.dumps(value, ensure_ascii=False))
                    for floor, value in business_elements
                ],
                include_basic=False,
            )

            # sample.csv
            (import_suite_root / "sample.csv").write_text(
                "floor,element\n"
                + "\n".join(
                    f"{floor},\"{json.dumps(value, ensure_ascii=False).replace(chr(34), chr(34) * 2)}\""
                    for floor, value in business_elements
                )
                + "\n",
                encoding="utf-8",
            )

            # sample.json (MarketScannerPriorMapSource v1) with normalized
            # elements matching the on-device XLSX/CSV importer output.
            sample_json = {
                "format": "MarketScannerPriorMapSource",
                "version": 1,
                "storeId": "s1",
                "mapName": "sample",
                "source": {
                    "originalFormat": "json",
                    "originalFilename": "sample.json",
                    "sourceFileSha256": "unused",
                    "canonicalSourceSha256": "",
                },
                "coordinateContract": {
                    "unit": "centimetre",
                    "origin": "top_left",
                    "x_axis": "right",
                    "y_axis": "down",
                    "rotation_direction": "clockwise_degrees",
                },
                "elements": _canonical_json_elements(business_elements),
                "warnings": [],
            }
            (import_suite_root / "sample.json").write_text(
                json.dumps(sample_json, ensure_ascii=False, sort_keys=True),
                encoding="utf-8",
            )

            # sample-v2.json (canonical v2 snake_case): the canonical
            # payload of the same business map. Its document identity and
            # contract must win over the wizard parameters and its digest
            # must be byte-identical to the XLSX/CSV import.
            sample_v2 = {
                "format": "MarketScannerPriorMapSource",
                "version": 2,
                "store_id": "s1",
                "map_name": "sample",
                "coordinate_contract": {
                    "unit": "centimetre",
                    "origin": "top_left",
                    "x_axis": "right",
                    "y_axis": "down",
                    "rotation_direction": "clockwise_degrees",
                },
                "elements": _canonical_json_elements(business_elements),
                "warnings": [],
            }
            (import_suite_root / "sample-v2.json").write_text(
                json.dumps(sample_v2, ensure_ascii=False, sort_keys=True),
                encoding="utf-8",
            )

            # I5: formula cells in the business columns are rejected.
            _write_formula_xlsx(import_suite_root / "formula.xlsx")

            # I6: ZIP path traversal entry is rejected.
            with zipfile.ZipFile(
                import_suite_root / "traversal.xlsx", "w"
            ) as archive:
                archive.writestr("../evil.xml", "<x/>")
                archive.writestr("[Content_Types].xml", "<Types/>")

            # I7: ZIP bomb — a deflated entry whose ratio exceeds 200:1.
            with zipfile.ZipFile(
                import_suite_root / "bomb.xlsx", "w", zipfile.ZIP_DEFLATED
            ) as archive:
                archive.writestr("xl/workbook.xml", b"\x00" * (10 * 1024 * 1024))
                archive.writestr("xl/sharedStrings.xml", b"")

            # I14: multi-floor JSON.
            multi_floor = dict(sample_json)
            multi_floor["elements"] = sample_json["elements"] + _canonical_json_elements(
                [(3, {"shapeType": "MapTable", "x": 50, "y": 50,
                      "width": 100, "height": 100, "visible": True})]
            )
            (import_suite_root / "multi-floor.json").write_text(
                json.dumps(multi_floor, ensure_ascii=False, sort_keys=True),
                encoding="utf-8",
            )

            import_result = subprocess.run(
                [str(executable), "--import-suite", str(import_suite_root)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                import_result.returncode,
                0,
                import_result.stderr + "\n" + import_result.stdout,
            )

            # T12/X6: a 100k-row DevicePositions workbook exports in its
            # own process (kept out of the default-mode peak-RSS gate).
            scale_root = Path(temporary) / "xlsx-scale"
            scale_root.mkdir()
            scale_result = subprocess.run(
                [str(executable), "--xlsx-scale", str(scale_root)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                scale_result.returncode,
                0,
                scale_result.stderr + "\n" + scale_result.stdout,
            )
            scale_bytes = (scale_root / "result-100k.xlsx").stat().st_size
            self.assertGreater(scale_bytes, 0)

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

    def test_distance_and_spatial_grid_resource_budgets_fail_closed(self) -> None:
        oversized_floor = [
            {
                "id": "1",
                "bounds": {
                    "min_x_m": 0.0,
                    "min_y_m": 0.0,
                    "max_x_m": 3_000.0,
                    "max_y_m": 1.0,
                },
            }
        ]
        with self.assertRaisesRegex(ValueError, "resource budget"):
            build_distance_fields([], oversized_floor)

        per_floor = {
            "min_x_m": 0.0,
            "min_y_m": 0.0,
            "max_x_m": 100.0,
            "max_y_m": 100.0,
        }
        with self.assertRaisesRegex(ValueError, "total grid cell budget"):
            build_distance_fields(
                [],
                [
                    {"id": str(index), "bounds": per_floor}
                    for index in range(12)
                ],
            )

        oversized_structure = {
            "id": "huge",
            "floor_id": "1",
            "shape_type": "MapShelf",
            "role": "shelf",
            "visible": True,
            "bounds": {
                "min_x_m": 0.0,
                "min_y_m": 0.0,
                "max_x_m": 40_000_000.0,
                "max_y_m": 0.0,
            },
        }
        with self.assertRaisesRegex(ConversionError, "budget"):
            _spatial_index([oversized_structure], {"nodes": [], "edges": []})

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

    def test_conversion_emits_only_active_elements_and_audits_ignored_rows(self) -> None:
        package = convert_workbook(
            self.workbook, self.root / "package", store_id="s1"
        )
        manifest = json.loads((package / "manifest.json").read_text())
        elements = json.loads((package / "elements.json").read_text())["elements"]
        report = json.loads(
            (package / "validation_report.json").read_text(encoding="utf-8")
        )
        self.assertEqual(manifest["version"], 2)
        self.assertEqual(manifest["source_element_count"], 8)
        self.assertEqual(manifest["element_count"], 6)
        self.assertEqual(manifest["active_element_count"], 6)
        self.assertEqual(manifest["hidden_element_count"], 1)
        self.assertEqual(manifest["unsupported_ignored_count"], 1)
        self.assertEqual([floor["id"] for floor in manifest["floors"]], ["1"])
        shelf = next(item for item in elements if item["code"] == "S1")
        self.assertEqual(shelf["cross_code"], "7")
        self.assertEqual(shelf["row_flag"], "R1")
        self.assertEqual(shelf["subsection"], 2)
        self.assertFalse(any(item["shape_type"] == "FutureShape" for item in elements))
        self.assertFalse(any(item["visible"] is False for item in elements))
        self.assertEqual(report["summary"]["malformed_row_count"], 0)
        warning_codes = {item["code"] for item in report["warnings"]}
        self.assertIn("unknown_shape_type", warning_codes)
        self.assertIn("hidden_element", warning_codes)
        self.assertIn("missing_cross", warning_codes)
        self.assertTrue(validate_package(package)["valid"])
        self.assertTrue((package / "preview.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n"))

        shelves = json.loads((package / "shelves.json").read_text(encoding="utf-8"))
        self.assertEqual(shelves["version"], 2)
        self.assertEqual(len(shelves["shelves"]), 1)
        self.assertEqual(len(shelves["shelf_segments"]), 1)
        segment = shelves["shelf_segments"][0]
        self.assertEqual(segment["shelf_segment_id"], shelves["shelves"][0]["id"])
        self.assertEqual(segment["shelf_code"], "S1")
        self.assertEqual(segment["floor_id"], "1")
        self.assertEqual(segment["side_semantics_version"], 1)
        self.assertEqual(segment["orientation_provenance"], "element_yaw")
        self.assertAlmostEqual(math.hypot(*segment["longitudinal_axis"]), 1.0)
        self.assertAlmostEqual(
            segment["front_normal"][0] + segment["back_normal"][0],
            0.0,
        )
        self.assertAlmostEqual(
            segment["front_normal"][1] + segment["back_normal"][1],
            0.0,
        )

    def test_package_integrity_ignores_macos_filesystem_metadata(self) -> None:
        package = convert_workbook(
            self.workbook, self.root / "package", store_id="s1"
        )
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
        package = convert_workbook(
            self.workbook, self.root / "package", store_id="s1"
        )
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
        package = convert_workbook(
            self.workbook, self.root / "package", store_id="s1"
        )
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
        package = convert_workbook(
            self.workbook, self.root / "package", store_id="s1"
        )
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

    def test_validation_report_counts_are_strict_json_integers(self) -> None:
        package = convert_workbook(
            self.workbook, self.root / "strict-report-package", store_id="s1"
        )
        report = json.loads(
            (package / "validation_report.json").read_text(encoding="utf-8")
        )
        required_count_fields = (
            "element_count",
            "source_element_count",
            "active_element_count",
            "shelf_count",
            "fixed_structure_count",
            "road_element_count",
            "presentation_ignored_count",
            "unsupported_ignored_count",
            "hidden_element_count",
            "invalid_geometry_ignored_count",
            "malformed_row_count",
            "warning_count",
            "floor_count",
            "node_count",
            "edge_count",
        )

        def assert_rejected(field: str, replacement: object, suffix: str) -> None:
            corrupted = self.corrupted_package(
                package, f"strict-report-{field}-{suffix}"
            )
            self.rewrite_json(
                corrupted / "validation_report.json",
                lambda value: value["summary"].__setitem__(field, replacement),
            )
            (corrupted / "package_manifest.json").write_text(
                json.dumps(
                    build_package_manifest(corrupted),
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            validation = validate_package(corrupted)
            self.assertFalse(validation["valid"], (field, replacement, validation))
            self.assertIn(
                "validation_report",
                {item["code"] for item in validation["errors"]},
            )

        for field in required_count_fields:
            with self.subTest(field=field, token="integral-float"):
                assert_rejected(
                    field, float(report["summary"][field]), "integral-float"
                )
        for field, replacement in (
            ("malformed_row_count", False),
            ("floor_count", True),
        ):
            with self.subTest(field=field, token="boolean"):
                assert_rejected(field, replacement, "boolean")

        for field in ("warnings", "malformed_rows"):
            with self.subTest(field=field, token="not-array"):
                corrupted = self.corrupted_package(
                    package, f"strict-report-{field}-not-array"
                )
                self.rewrite_json(
                    corrupted / "validation_report.json",
                    lambda value, key=field: value.__setitem__(
                        key, {"invalid": True}
                    ),
                )
                (corrupted / "package_manifest.json").write_text(
                    json.dumps(
                        build_package_manifest(corrupted),
                        ensure_ascii=False,
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                validation = validate_package(corrupted)
                self.assertFalse(validation["valid"], validation)
                self.assertIn(
                    "validation_report",
                    {item["code"] for item in validation["errors"]},
                )

    def test_manifest_counts_are_strict_json_integers(self) -> None:
        package = convert_workbook(
            self.workbook, self.root / "strict-manifest-package", store_id="s1"
        )
        manifest = json.loads(
            (package / "manifest.json").read_text(encoding="utf-8")
        )
        required_count_fields = (
            "element_count",
            "active_element_count",
            "visible_element_count",
            "shelf_count",
            "fixed_structure_count",
            "road_element_count",
            "presentation_ignored_count",
            "unsupported_ignored_count",
            "hidden_element_count",
            "invalid_geometry_ignored_count",
            "source_element_count",
            "warning_count",
        )

        def assert_rejected(
            label: str, mutate: object
        ) -> None:
            corrupted = self.corrupted_package(
                package, f"strict-manifest-{label}"
            )
            self.rewrite_json(corrupted / "manifest.json", mutate)
            (corrupted / "package_manifest.json").write_text(
                json.dumps(
                    build_package_manifest(corrupted),
                    ensure_ascii=False,
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            validation = validate_package(corrupted)
            self.assertFalse(validation["valid"], (label, validation))

        for field in required_count_fields:
            with self.subTest(field=field, token="integral-float"):
                assert_rejected(
                    f"{field}-integral-float",
                    lambda value, key=field: value.__setitem__(
                        key, float(manifest[key])
                    ),
                )
        for field, replacement in (
            ("hidden_element_count", True),
            ("invalid_geometry_ignored_count", False),
        ):
            with self.subTest(field=field, token="boolean"):
                assert_rejected(
                    f"{field}-boolean",
                    lambda value, key=field, token=replacement: value.__setitem__(
                        key, token
                    ),
                )

        statistics_key = next(iter(manifest["element_statistics"]))
        with self.subTest(field="element_statistics", token="integral-float"):
            assert_rejected(
                "element-statistics-integral-float",
                lambda value: value["element_statistics"].__setitem__(
                    statistics_key,
                    float(value["element_statistics"][statistics_key]),
                ),
            )

    def test_v2_manifest_requires_strict_relation_bound_shelves_v2(self) -> None:
        package = convert_workbook(
            self.workbook, self.root / "shelves-v2-package", store_id="s1"
        )

        downgraded = self.corrupted_package(package, "formal-shelves-v1")
        shelves = json.loads((downgraded / "shelves.json").read_text(encoding="utf-8"))
        shelves["version"] = 1
        shelves.pop("shelf_segments")
        (downgraded / "shelves.json").write_text(
            json.dumps(shelves, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        (downgraded / "package_manifest.json").write_text(
            json.dumps(
                build_package_manifest(downgraded),
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        validation = validate_package(downgraded)
        self.assertFalse(validation["valid"])
        self.assertIn(
            "shelf_version_contract",
            {item["code"] for item in validation["errors"]},
        )

        mutations = {
            "unknown-field": lambda segments: segments[0].__setitem__(
                "unexpected", True
            ),
            "non-unit-axis": lambda segments: segments[0].__setitem__(
                "longitudinal_axis", [0.5, 0.0]
            ),
            "wrong-floor-binding": lambda segments: segments[0].__setitem__(
                "floor_id", "wrong-floor"
            ),
            "missing-segment": lambda segments: segments.clear(),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                corrupted = self.corrupted_package(package, f"shelf-segment-{name}")
                payload = json.loads(
                    (corrupted / "shelves.json").read_text(encoding="utf-8")
                )
                mutate(payload["shelf_segments"])
                (corrupted / "shelves.json").write_text(
                    json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
                    + "\n",
                    encoding="utf-8",
                )
                (corrupted / "package_manifest.json").write_text(
                    json.dumps(
                        build_package_manifest(corrupted),
                        ensure_ascii=False,
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                result = validate_package(corrupted)
                self.assertFalse(result["valid"], result)
                self.assertTrue(
                    {"shelf_segment_schema", "shelf_segment_relation"}
                    & {item["code"] for item in result["errors"]},
                    result,
                )

    def test_conversion_is_reproducible(self) -> None:
        first = convert_workbook(
            self.workbook, self.root / "first", store_id="s1"
        )
        second = convert_workbook(
            self.workbook, self.root / "second", store_id="s1"
        )
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
        package = convert_workbook(
            self.workbook, self.root / "package", store_id="s1"
        )
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
        package = convert_workbook(
            self.workbook, self.root / "package", store_id="s1"
        )
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
        package = convert_workbook(
            self.workbook, self.root / "package", store_id="s1"
        )
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
            tracking_loss_indices={3, 4},
        )
        self.assertEqual(recovered["samples"][3]["state"], "lost")
        self.assertEqual(recovered["samples"][4]["state"], "lost")
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
        self.package = convert_workbook(
            workbook, self.root / "package", store_id="s1"
        )

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

    def test_n1b_integral_float_version_token_rejected(self) -> None:
        package = self.copy_with("n1b-integral-float-version")
        self.rewrite_json(
            package / "package_manifest.json",
            lambda value: value["artifacts"][0].__setitem__("version", 1.0),
        )
        self.assert_invalid(
            package,
            "package_artifact_schema",
            "N1b integral floating version token",
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
            package, "active_element_contract", "N4 numeric visible field"
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
            package, "active_geometry_contract", "N5 boolean geometry coordinate"
        )

    def test_n5b_role_correct_element_with_wrong_geometry_kind_rejected(self) -> None:
        package = self.copy_with("n5b-wrong-geometry-kind")
        elements = json.loads((package / "elements.json").read_text())
        geometry = elements["elements"][0]["geometry"]
        self.assertEqual(geometry["type"], "polygon")
        geometry["type"] = "line_string"
        (package / "elements.json").write_text(
            json.dumps(elements, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        )
        self.refresh_manifest(package)
        self.assert_invalid(
            package,
            "active_geometry_contract",
            "N5b role-correct element with wrong geometry kind",
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

    def test_n6a_formal_bounds_require_six_consistent_fields(self) -> None:
        for label, mutate in (
            ("missing-width", lambda bounds: bounds.pop("width_m")),
            ("extra-field", lambda bounds: bounds.__setitem__("extra", 0.0)),
            (
                "tiny-width-drift",
                lambda bounds: bounds.__setitem__(
                    "width_m", float(bounds["width_m"]) + 5.0e-7
                ),
            ),
            (
                "mismatched-height",
                lambda bounds: bounds.__setitem__(
                    "height_m", float(bounds["height_m"]) + 1.0
                ),
            ),
        ):
            with self.subTest(label=label):
                package = self.copy_with(f"n6a-{label}")
                elements_path = package / "elements.json"
                elements_payload = json.loads(
                    elements_path.read_text(encoding="utf-8")
                )
                mutate(elements_payload["elements"][0]["bounds"])
                elements_path.write_text(
                    json.dumps(
                        elements_payload,
                        ensure_ascii=False,
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                self.refresh_manifest(package)
                self.assert_invalid(
                    package,
                    "element_bounds",
                    f"N6a formal bounds {label}",
                )

        for label, target, expected_code in (
            ("manifest-missing-width", "manifest", "map_bounds"),
            ("manifest-tiny-width-drift", "manifest_drift", "map_bounds"),
            ("floor-missing-height", "floor", "floor_bounds"),
        ):
            with self.subTest(label=label):
                package = self.copy_with(f"n6a-{label}")
                manifest_path = package / "manifest.json"
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                if target == "manifest":
                    manifest["bounds"].pop("width_m")
                elif target == "manifest_drift":
                    manifest["bounds"]["width_m"] += 5.0e-7
                else:
                    manifest["floors"][0]["bounds"].pop("height_m")
                manifest_path.write_text(
                    json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True)
                    + "\n",
                    encoding="utf-8",
                )
                self.refresh_manifest(package)
                self.assert_invalid(
                    package,
                    expected_code,
                    f"N6a formal bounds {label}",
                )

    def test_n6b_distance_field_integer_and_rle_scalars_are_strict(self) -> None:
        mutations = {
            "width-bool": lambda level: level.__setitem__("width", True),
            "width-fractional": lambda level: level.__setitem__("width", 1.5),
            "width-integral-float": lambda level: level.__setitem__("width", 1.0),
            "count-bool": lambda level: level["rows"][0].__setitem__(0, True),
            "count-integral-float": lambda level: level["rows"][0].__setitem__(0, 1.0),
            "value-bool": lambda level: level["rows"][0].__setitem__(1, False),
            "count-huge": lambda level: level["rows"][0].__setitem__(0, 10**9),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                package = self.copy_with(f"n6b-distance-{label}")
                distance_path = package / "distance_fields.json"
                distance = json.loads(distance_path.read_text(encoding="utf-8"))
                floor = next(iter(distance["floors"].values()))
                level = floor["levels"][0]
                mutate(level)
                level["data_sha256"] = hashlib.sha256(
                    json.dumps(
                        level["rows"],
                        separators=(",", ":"),
                        ensure_ascii=True,
                    ).encode("utf-8")
                ).hexdigest()
                distance_path.write_text(
                    json.dumps(distance, ensure_ascii=False, indent=2, sort_keys=True)
                    + "\n",
                    encoding="utf-8",
                )
                self.refresh_manifest(package)
                self.assert_invalid(
                    package,
                    "distance_data",
                    f"N6b distance scalar {label}",
                )

    def test_n6e_formal_center_and_yaw_scalars_are_strict(self) -> None:
        for label, field, invalid_value, expected_code in (
            ("center", "center_m", ["bad", 0.0], "element_center"),
            ("yaw", "yaw_rad", True, "element_yaw"),
        ):
            with self.subTest(label=label):
                package = self.copy_with(f"n6e-{label}")
                elements_path = package / "elements.json"
                elements_payload = json.loads(
                    elements_path.read_text(encoding="utf-8")
                )
                candidate = next(
                    item
                    for item in elements_payload["elements"]
                    if item.get("role") == "fixed_structure"
                )
                candidate[field] = invalid_value
                elements_path.write_text(
                    json.dumps(
                        elements_payload,
                        ensure_ascii=False,
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                structures_path = package / "fixed_structures.json"
                structures_payload = json.loads(
                    structures_path.read_text(encoding="utf-8")
                )
                matching = next(
                    item
                    for item in structures_payload["structures"]
                    if item["id"] == candidate["id"]
                )
                matching[field] = invalid_value
                structures_path.write_text(
                    json.dumps(
                        structures_payload,
                        ensure_ascii=False,
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                manifest_path = package / "manifest.json"
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                source_info = manifest["source_map_info"]
                basic_info = BasicMapInfo(
                    map_name=source_info["map_name"],
                    width_cm=float(source_info["width_cm"]),
                    height_cm=float(source_info["height_cm"]),
                    store_code=source_info["store_code"],
                    source_scale=source_info.get("scale"),
                )
                canonical_hash = _canonical_business_sha256(
                    basic_info, elements_payload["elements"]
                )
                manifest["canonical_source_sha256"] = canonical_hash
                base_name = canonical_safe_name(manifest["name"])
                manifest["prior_map_id"] = f"{base_name}-{canonical_hash[:12]}"
                manifest_path.write_text(
                    json.dumps(
                        manifest,
                        ensure_ascii=False,
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                self.refresh_manifest(package)
                self.assert_invalid(
                    package,
                    expected_code,
                    f"N6e formal {label} scalar",
                )

    def test_n6c_derived_artifacts_are_bound_to_authoritative_elements(self) -> None:
        spatial_package = self.copy_with("n6c-spatial-cell")
        spatial_path = spatial_package / "spatial_index.json"
        spatial = json.loads(spatial_path.read_text(encoding="utf-8"))
        floor = next(iter(spatial["floors"].values()))
        identifiers = sorted(
            {
                identifier
                for values in floor["cells"].values()
                for identifier in values
            }
        )
        floor["cells"] = {"999,999": identifiers}
        spatial_path.write_text(
            json.dumps(spatial, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.refresh_manifest(spatial_package)
        self.assert_invalid(
            spatial_package,
            "spatial_source_binding",
            "N6c spatial cells must match deterministic bounds",
        )

        distance_package = self.copy_with("n6c-distance-all-zero")
        distance_path = distance_package / "distance_fields.json"
        distance = json.loads(distance_path.read_text(encoding="utf-8"))
        for floor_value in distance["floors"].values():
            for level in floor_value["levels"]:
                level["rows"] = [[level["width"], 0] for _ in range(level["height"])]
                level["data_sha256"] = hashlib.sha256(
                    json.dumps(
                        level["rows"], separators=(",", ":"), ensure_ascii=True
                    ).encode("utf-8")
                ).hexdigest()
        distance_path.write_text(
            json.dumps(distance, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.refresh_manifest(distance_package)
        self.assert_invalid(
            distance_package,
            "distance_source_binding",
            "N6c distance field must match deterministic structures",
        )

        shelf_package = self.copy_with("n6c-shelf-shift")
        shelf_path = shelf_package / "shelves.json"
        shelves = json.loads(shelf_path.read_text(encoding="utf-8"))
        segment = shelves["shelf_segments"][0]
        segment["longitudinal_start_m"][0] += 1.0
        segment["longitudinal_end_m"][0] += 1.0
        shelf_path.write_text(
            json.dumps(shelves, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.refresh_manifest(shelf_package)
        self.assert_invalid(
            shelf_package,
            "shelf_segment_source_binding",
            "N6c shelf segment must bind source geometry/yaw",
        )

    def test_n6d_canonical_hash_and_stable_ids_are_recomputed(self) -> None:
        canonical_package = self.copy_with("n6d-canonical-claim")
        manifest_path = canonical_package / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        forged_hash = "0" * 64
        manifest["canonical_source_sha256"] = forged_hash
        base_name = canonical_safe_name(manifest["name"])
        manifest["prior_map_id"] = f"{base_name}-{forged_hash[:12]}"
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.refresh_manifest(canonical_package)
        self.assert_invalid(
            canonical_package,
            "canonical_source_binding",
            "N6d claimed canonical hash must be recomputed",
        )

        duplicate_package = self.copy_with("n6d-duplicate-stable-id")
        elements_path = duplicate_package / "elements.json"
        elements_payload = json.loads(elements_path.read_text(encoding="utf-8"))
        candidates = [
            item
            for item in elements_payload["elements"]
            if item.get("role") in {"shelf", "fixed_structure"}
        ][:2]
        self.assertEqual(len(candidates), 2)
        duplicate_source = {"id": "duplicate-official-business-id"}
        candidate_ids = {item["id"] for item in candidates}
        for item in elements_payload["elements"]:
            if item["id"] in candidate_ids:
                item["source"] = duplicate_source
        elements_path.write_text(
            json.dumps(elements_payload, ensure_ascii=False, indent=2, sort_keys=True)
            + "\n",
            encoding="utf-8",
        )
        for filename, key in (
            ("shelves.json", "shelves"),
            ("fixed_structures.json", "structures"),
        ):
            path = duplicate_package / filename
            payload = json.loads(path.read_text(encoding="utf-8"))
            for item in payload[key]:
                if item["id"] in candidate_ids:
                    item["source"] = duplicate_source
            path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
                + "\n",
                encoding="utf-8",
            )
        manifest_path = duplicate_package / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        source_info = manifest["source_map_info"]
        basic_info = BasicMapInfo(
            map_name=source_info["map_name"],
            width_cm=float(source_info["width_cm"]),
            height_cm=float(source_info["height_cm"]),
            store_code=source_info["store_code"],
            source_scale=source_info.get("scale"),
        )
        canonical_hash = _canonical_business_sha256(
            basic_info, elements_payload["elements"]
        )
        manifest["canonical_source_sha256"] = canonical_hash
        base_name = canonical_safe_name(manifest["name"])
        manifest["prior_map_id"] = f"{base_name}-{canonical_hash[:12]}"
        manifest_path.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.refresh_manifest(duplicate_package)
        self.assert_invalid(
            duplicate_package,
            "duplicate_stable_element_id",
            "N6d duplicate stable business identities must fail closed",
        )

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
