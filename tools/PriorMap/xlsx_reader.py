"""Dependency-free reader for the workbook's ``Element Info`` worksheet."""

from __future__ import annotations

import json
import posixpath
import re
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator


MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
NS = {"m": MAIN_NS, "r": REL_NS}
CELL_COLUMN = re.compile(r"([A-Z]+)")


class WorkbookError(ValueError):
    pass


@dataclass(frozen=True)
class WorkbookElement:
    row: int
    floor: str
    element: dict[str, Any]


@dataclass(frozen=True)
class WorkbookReadResult:
    elements: list[WorkbookElement]
    warnings: list[dict[str, Any]]
    malformed_rows: list[dict[str, Any]]


def _shared_strings(archive: zipfile.ZipFile) -> list[str]:
    if "xl/sharedStrings.xml" not in archive.namelist():
        return []
    root = ET.fromstring(archive.read("xl/sharedStrings.xml"))
    return [
        "".join(node.text or "" for node in item.iter(f"{{{MAIN_NS}}}t"))
        for item in root
    ]


def _worksheet_path(archive: zipfile.ZipFile, requested_name: str) -> str:
    workbook = ET.fromstring(archive.read("xl/workbook.xml"))
    relationships = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
    targets = {
        item.attrib["Id"]: item.attrib["Target"]
        for item in relationships.findall(f"{{{PKG_REL_NS}}}Relationship")
    }
    for sheet in workbook.findall("m:sheets/m:sheet", NS):
        if sheet.attrib.get("name") != requested_name:
            continue
        relationship_id = sheet.attrib.get(f"{{{REL_NS}}}id")
        target = targets.get(str(relationship_id))
        if not target:
            break
        normalized = posixpath.normpath(posixpath.join("xl", target))
        if not normalized.startswith("xl/") or normalized not in archive.namelist():
            raise WorkbookError(f"Worksheet path is invalid: {target}")
        return normalized
    raise WorkbookError(f'Workbook does not contain the "{requested_name}" worksheet.')


def _column_name(reference: str) -> str:
    match = CELL_COLUMN.match(reference.upper())
    return match.group(1) if match else ""


def _cell_text(
    cell: ET.Element,
    shared_strings: list[str],
) -> str:
    kind = cell.attrib.get("t")
    if kind == "inlineStr":
        return "".join(node.text or "" for node in cell.iter(f"{{{MAIN_NS}}}t"))
    value = cell.find("m:v", NS)
    raw = "" if value is None else value.text or ""
    if kind == "s" and raw:
        try:
            return shared_strings[int(raw)]
        except (IndexError, ValueError) as exc:
            raise WorkbookError("Workbook contains an invalid shared-string reference.") from exc
    return raw


def _rows(
    archive: zipfile.ZipFile,
    worksheet_path: str,
    shared_strings: list[str],
) -> Iterator[tuple[int, dict[str, str]]]:
    root = ET.fromstring(archive.read(worksheet_path))
    for row in root.findall(".//m:sheetData/m:row", NS):
        row_index = int(row.attrib.get("r", "0") or "0")
        cells = {
            _column_name(cell.attrib.get("r", "")): _cell_text(cell, shared_strings)
            for cell in row.findall("m:c", NS)
        }
        yield row_index, cells


def read_element_info(path: Path | str) -> WorkbookReadResult:
    source = Path(path)
    if not source.is_file():
        raise WorkbookError(f"Workbook does not exist: {source}")
    if source.suffix.lower() != ".xlsx":
        raise WorkbookError("Prior-map input must be an .xlsx workbook.")

    warnings: list[dict[str, Any]] = []
    malformed_rows: list[dict[str, Any]] = []
    elements: list[WorkbookElement] = []
    try:
        with zipfile.ZipFile(source) as archive:
            if archive.testzip() is not None:
                raise WorkbookError("Workbook ZIP data is damaged.")
            shared = _shared_strings(archive)
            sheet_path = _worksheet_path(archive, "Element Info")
            rows = iter(_rows(archive, sheet_path, shared))
            try:
                header_row, headers = next(rows)
            except StopIteration as exc:
                raise WorkbookError('The "Element Info" worksheet is empty.') from exc
            normalized_headers = {
                value.strip().lower(): column for column, value in headers.items()
            }
            if "floor" not in normalized_headers or "element" not in normalized_headers:
                raise WorkbookError(
                    f'Row {header_row} must contain "floor" and "element" columns.'
                )
            floor_column = normalized_headers["floor"]
            element_column = normalized_headers["element"]
            for row_index, cells in rows:
                floor = cells.get(floor_column, "").strip()
                raw_element = cells.get(element_column, "").strip()
                if not floor and not raw_element:
                    continue
                if not floor:
                    malformed_rows.append(
                        {
                            "row": row_index,
                            "code": "missing_floor",
                            "message": "楼层为空；该行未导入。",
                        }
                    )
                    continue
                try:
                    element = json.loads(raw_element)
                except json.JSONDecodeError as exc:
                    malformed_rows.append(
                        {
                            "row": row_index,
                            "floor": floor,
                            "code": "invalid_element_json",
                            "message": f"element JSON 无法解析：{exc.msg}（第 {exc.colno} 列）。",
                        }
                    )
                    continue
                if not isinstance(element, dict):
                    malformed_rows.append(
                        {
                            "row": row_index,
                            "floor": floor,
                            "code": "element_not_object",
                            "message": "element 必须是 JSON 对象；该行未导入。",
                        }
                    )
                    continue
                elements.append(WorkbookElement(row_index, floor, element))
    except zipfile.BadZipFile as exc:
        raise WorkbookError("The workbook is not a valid XLSX ZIP file.") from exc

    if malformed_rows:
        warnings.append(
            {
                "code": "malformed_rows",
                "count": len(malformed_rows),
                "message": f"{len(malformed_rows)} 行数据损坏，已保留在验证报告中且未导入。",
            }
        )
    if not elements:
        raise WorkbookError('The "Element Info" worksheet contains no usable elements.')
    return WorkbookReadResult(elements, warnings, malformed_rows)
