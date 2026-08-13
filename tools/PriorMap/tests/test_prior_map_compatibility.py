from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from tools.PriorMap.prior_map_compatibility import (
    PriorMapCompatibilityError,
    prepare_prior_map_for_processing,
)
from tools.PriorMap.prior_map_schema import (
    build_package_manifest,
    validate_package,
)
from tools.PriorMap.tests.test_prior_map import write_workbook
from tools.PriorMap.xlsx_to_prior_map import _spatial_index, convert_workbook


def write_json(path: Path, payload: object) -> None:
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PriorMapCompatibilityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def legacy_hidden_cross_package(self) -> Path:
        workbook = self.root / "hidden-cross.xlsx"
        rows = [
            (
                "1",
                json.dumps(
                    {
                        "shapeType": "MapShelf",
                        "x": 100,
                        "y": 100,
                        "width": 200,
                        "height": 80,
                        "visible": True,
                    }
                ),
            ),
            (
                "1",
                json.dumps(
                    {
                        "shapeType": "MapCross",
                        "points": [0, 500, 1000, 500],
                        "lineWidth": 200,
                        "code": "C-hidden",
                        "visible": False,
                    }
                ),
            ),
            *(
                (
                    "1",
                    json.dumps(
                        {
                            "shapeType": "MapRoadPoint",
                            "x": x,
                            "y": 500,
                            "width": 20,
                            "height": 20,
                            "code": node_id,
                            "crossCodes": ["C-hidden"],
                            "visible": True,
                        }
                    ),
                )
                for node_id, x in (("A", 100), ("B", 500), ("C", 900))
            ),
        ]
        write_workbook(workbook, rows)
        package = convert_workbook(workbook, self.root / "legacy-package")
        elements = json.loads((package / "elements.json").read_text())["elements"]
        current_graph = json.loads((package / "road_graph.json").read_text())
        nodes = current_graph["nodes"]
        old_graph = {
            "format": "MarketScannerRoadGraph",
            "version": 1,
            "crosses": [],
            "nodes": nodes,
            "edges": [],
            "statistics": {
                "cross_count": 0,
                "node_count": len(nodes),
                "edge_count": 0,
                "connected_component_count": len(nodes),
                "isolated_node_count": len(nodes),
                "isolated_node_ids": sorted(node["id"] for node in nodes),
            },
        }
        report = json.loads((package / "validation_report.json").read_text())
        report["warnings"] = [
            item
            for item in report["warnings"]
            if item.get("code") != "road_cross_inferred_from_points"
        ]
        report["summary"] = {
            **report["summary"],
            **old_graph["statistics"],
            "warning_count": len(report["warnings"])
            + len(report["malformed_rows"]),
        }
        manifest = json.loads((package / "manifest.json").read_text())
        manifest["warning_count"] = report["summary"]["warning_count"]
        write_json(package / "road_graph.json", old_graph)
        write_json(package / "spatial_index.json", _spatial_index(elements, old_graph))
        write_json(package / "validation_report.json", report)
        write_json(package / "manifest.json", manifest)
        write_json(package / "package_manifest.json", build_package_manifest(package))
        validation = validate_package(package)
        self.assertEqual(
            {item["code"] for item in validation["errors"]},
            {"road_graph_source_binding", "spatial_source_binding"},
        )
        return package

    def test_legacy_hidden_cross_is_rebuilt_without_modifying_source(self) -> None:
        package = self.legacy_hidden_cross_package()
        source_hashes = {
            path.name: sha256(path)
            for path in package.iterdir()
            if path.is_file()
        }
        effective, audit = prepare_prior_map_for_processing(
            package, self.root / "result"
        )
        self.assertIsNotNone(audit)
        self.assertTrue(validate_package(effective)["valid"])
        graph = json.loads((effective / "road_graph.json").read_text())
        self.assertEqual(len(graph["edges"]), 2)
        self.assertEqual(graph["statistics"]["isolated_node_count"], 0)
        self.assertEqual(
            audit["repaired_error_codes"],
            ["road_graph_source_binding", "spatial_source_binding"],
        )
        self.assertFalse(audit["source_package_modified"])
        self.assertEqual(
            source_hashes,
            {
                path.name: sha256(path)
                for path in package.iterdir()
                if path.is_file()
            },
        )

    def test_valid_package_is_used_without_copy(self) -> None:
        workbook = self.root / "valid.xlsx"
        write_workbook(
            workbook,
            [
                (
                    "1",
                    json.dumps(
                        {
                            "shapeType": "MapShelf",
                            "x": 100,
                            "y": 100,
                            "width": 200,
                            "height": 80,
                            "visible": True,
                        }
                    ),
                )
            ],
        )
        package = convert_workbook(workbook, self.root / "valid-package")
        effective, audit = prepare_prior_map_for_processing(
            package, self.root / "unused-result"
        )
        self.assertEqual(effective, package.resolve())
        self.assertIsNone(audit)
        self.assertFalse((self.root / "unused-result").exists())

    def test_unrelated_integrity_error_remains_fatal(self) -> None:
        package = self.legacy_hidden_cross_package()
        (package / "elements.json").write_text("{}\n", encoding="utf-8")
        with self.assertRaises(PriorMapCompatibilityError):
            prepare_prior_map_for_processing(package, self.root / "result")
        self.assertFalse(
            (self.root / "result" / "prior_map_compatibility").exists()
        )


if __name__ == "__main__":
    unittest.main()
