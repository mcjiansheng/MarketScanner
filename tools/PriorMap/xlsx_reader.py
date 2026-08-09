"""Hardened reader for the standard prior-map XLSX workbook.

The current workbook contract has two authoritative worksheets:

* ``Basic Info`` supplies map/store identity and the source canvas;
* ``Element Info`` supplies every source element.

``Shelf Info`` is a legacy redundant projection.  Its presence and row
count are audited, but its values never enter geometry or business hashes.
"""

from __future__ import annotations

import math
import posixpath
import re
import unicodedata
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterator

from .strict_json import StrictJSONError, json_nesting_depth, load_strict_json_bytes


MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
NS = {"m": MAIN_NS, "r": REL_NS}
CELL_REFERENCE = re.compile(r"^([A-Z]+)([1-9][0-9]*)$", re.IGNORECASE)

MAXIMUM_SOURCE_BYTES = 64 * 1024 * 1024
MAXIMUM_ZIP_ENTRIES = 4096
MAXIMUM_ZIP_ENTRY_BYTES = 64 * 1024 * 1024
MAXIMUM_ZIP_TOTAL_BYTES = 256 * 1024 * 1024
MAXIMUM_ZIP_RATIO = 200
MAXIMUM_WORKBOOK_SHEETS = 4096
MAXIMUM_WORKBOOK_RELATIONSHIPS = 4096
MAXIMUM_WORKSHEET_ROWS = 500_000
MAXIMUM_WORKSHEET_COLUMNS = 16_384
MAXIMUM_SHARED_STRINGS = 1_000_000
MAXIMUM_CELL_BYTES = 1 * 1024 * 1024
MAXIMUM_JSON_NESTING_DEPTH = 64
MAXIMUM_ELEMENTS = 100_000


class WorkbookError(ValueError):
    pass


@dataclass(frozen=True)
class WorkbookElement:
    row: int
    floor: str
    element: dict[str, Any]


@dataclass(frozen=True)
class BasicMapInfo:
    map_name: str
    width_cm: float
    height_cm: float
    store_code: str
    source_scale: float | None
    network_audit: dict[str, str] = field(default_factory=dict)

    def canonical_payload(self) -> dict[str, Any]:
        return {
            "map_name": self.map_name,
            "store_code": self.store_code,
            "width_cm": self.width_cm,
            "height_cm": self.height_cm,
            "scale": self.source_scale,
        }


@dataclass(frozen=True)
class LegacyShelfInfoAudit:
    present: bool = False
    row_count: int = 0


@dataclass(frozen=True)
class WorkbookReadResult:
    elements: list[WorkbookElement]
    warnings: list[dict[str, Any]]
    malformed_rows: list[dict[str, Any]]
    basic_info: BasicMapInfo | None = None
    legacy_shelf_info: LegacyShelfInfoAudit = LegacyShelfInfoAudit()


def _read_member(archive: zipfile.ZipFile, name: str) -> bytes:
    try:
        return archive.read(name)
    except (KeyError, OSError, RuntimeError, zipfile.BadZipFile) as exc:
        raise WorkbookError(f"Workbook part is unreadable: {name}") from exc


def _xml_root(archive: zipfile.ZipFile, name: str) -> ET.Element:
    data = _read_member(archive, name)
    if b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise WorkbookError(f"Workbook XML declarations are not supported: {name}")
    try:
        return ET.fromstring(data)
    except ET.ParseError as exc:
        raise WorkbookError(f"Workbook XML is invalid: {name}: {exc}") from exc


def _validate_archive(source: Path, archive: zipfile.ZipFile) -> None:
    if source.stat().st_size > MAXIMUM_SOURCE_BYTES:
        raise WorkbookError("Workbook exceeds the 64 MiB source limit.")
    entries = archive.infolist()
    if len(entries) > MAXIMUM_ZIP_ENTRIES:
        raise WorkbookError("Workbook contains too many ZIP entries.")
    seen: set[str] = set()
    total = 0
    for info in entries:
        name = info.filename
        path_name = name[:-1] if info.is_dir() and name.endswith("/") else name
        path_parts = path_name.split("/")
        canonical_name = unicodedata.normalize("NFC", name)
        if canonical_name in seen:
            raise WorkbookError(f"Workbook contains a duplicate ZIP entry: {name}")
        seen.add(canonical_name)
        if (
            not name
            or name.startswith(("/", "\\"))
            or "\\" in name
            or not path_name
            or any(part in {"", ".", ".."} for part in path_parts)
        ):
            raise WorkbookError(f"Workbook contains an unsafe ZIP entry: {name}")
        if info.flag_bits & (0x0001 | 0x0040):
            raise WorkbookError(f"Encrypted workbook entries are unsupported: {name}")
        if info.file_size > MAXIMUM_ZIP_ENTRY_BYTES:
            raise WorkbookError(f"Workbook ZIP entry exceeds the size limit: {name}")
        total += info.file_size
        if total > MAXIMUM_ZIP_TOTAL_BYTES:
            raise WorkbookError("Workbook uncompressed data exceeds the 256 MiB limit.")
        if info.file_size > 0:
            if info.compress_size <= 0 or info.file_size > info.compress_size * MAXIMUM_ZIP_RATIO:
                raise WorkbookError(f"Workbook ZIP entry exceeds the compression ratio limit: {name}")


def _shared_strings(archive: zipfile.ZipFile) -> list[str]:
    if "xl/sharedStrings.xml" not in archive.namelist():
        return []
    root = _xml_root(archive, "xl/sharedStrings.xml")
    if root.tag != f"{{{MAIN_NS}}}sst":
        raise WorkbookError("Workbook sharedStrings root/namespace is invalid.")
    result: list[str] = []
    for item in root.findall(f"{{{MAIN_NS}}}si"):
        text = "".join(node.text or "" for node in item.iter(f"{{{MAIN_NS}}}t"))
        if len(text.encode("utf-8")) > MAXIMUM_CELL_BYTES:
            raise WorkbookError("Workbook shared string exceeds the 1 MiB cell limit.")
        result.append(text)
        if len(result) > MAXIMUM_SHARED_STRINGS:
            raise WorkbookError("Workbook contains too many shared strings.")
    return result


def _worksheet_authorities(archive: zipfile.ZipFile) -> dict[str, str]:
    workbook = _xml_root(archive, "xl/workbook.xml")
    relationships = _xml_root(archive, "xl/_rels/workbook.xml.rels")
    if workbook.tag != f"{{{MAIN_NS}}}workbook":
        raise WorkbookError("Workbook root/namespace is invalid.")
    if relationships.tag != f"{{{PKG_REL_NS}}}Relationships":
        raise WorkbookError("Workbook relationships root/namespace is invalid.")
    relationship_items = relationships.findall(
        f"{{{PKG_REL_NS}}}Relationship"
    )
    if len(relationship_items) > MAXIMUM_WORKBOOK_RELATIONSHIPS:
        raise WorkbookError("Workbook contains too many Relationship records.")
    records: dict[str, tuple[str, str]] = {}
    for item in relationship_items:
        identifier = item.attrib.get("Id", "")
        relationship_type = item.attrib.get("Type", "")
        target = item.attrib.get("Target", "")
        if (
            not identifier
            or identifier in records
            or not relationship_type
            or not target
            or item.attrib.get("TargetMode") not in {None, "Internal"}
        ):
            raise WorkbookError("Workbook relationships contain a missing or duplicate ID.")
        records[identifier] = relationship_type, target

    authorities: dict[str, str] = {}
    seen_relationship_ids: set[str] = set()
    seen_paths: set[str] = set()
    sheet_containers = workbook.findall(f"{{{MAIN_NS}}}sheets")
    if len(sheet_containers) != 1:
        raise WorkbookError("Workbook must contain exactly one authoritative sheets node.")
    sheet_items = sheet_containers[0].findall(f"{{{MAIN_NS}}}sheet")
    if len(sheet_items) > MAXIMUM_WORKBOOK_SHEETS:
        raise WorkbookError("Workbook contains too many sheet records.")
    archive_names = set(archive.namelist())
    for sheet in sheet_items:
        name = sheet.attrib.get("name", "")
        relationship_id = sheet.attrib.get(f"{{{REL_NS}}}id", "")
        if (
            not name
            or name in authorities
            or not relationship_id
            or relationship_id in seen_relationship_ids
            or relationship_id not in records
        ):
            raise WorkbookError(
                "Workbook sheet names/relationship IDs are missing or duplicated."
            )
        relationship_type, target = records[relationship_id]
        parts = target.split("/")
        if (
            not relationship_type.endswith("/worksheet")
            or target.startswith(("/", "\\"))
            or "\\" in target
            or ":" in target
            or any(part in {"", ".", ".."} for part in parts)
        ):
            raise WorkbookError(f"Worksheet relationship is invalid: {relationship_id}")
        candidates = [name for name in (f"xl/{target}", target) if name in archive_names]
        if len(set(candidates)) != 1:
            raise WorkbookError(f"Worksheet path is invalid or ambiguous: {target}")
        resolved = candidates[0]
        if resolved in seen_paths:
            raise WorkbookError("Multiple workbook sheets alias one worksheet authority.")
        authorities[name] = resolved
        seen_relationship_ids.add(relationship_id)
        seen_paths.add(resolved)
    return authorities


def _worksheet_path(archive: zipfile.ZipFile, requested_name: str) -> str:
    authorities = _worksheet_authorities(archive)
    try:
        return authorities[requested_name]
    except KeyError as exc:
        raise WorkbookError(
            f'Workbook does not contain the "{requested_name}" worksheet.'
        ) from exc


def _has_worksheet(archive: zipfile.ZipFile, requested_name: str) -> bool:
    return requested_name in _worksheet_authorities(archive)


def _cell_reference(reference: str) -> tuple[str, int] | None:
    match = CELL_REFERENCE.fullmatch(reference)
    if match is None:
        return None
    letters = match.group(1).upper()
    column_index = 0
    for letter in letters:
        column_index = column_index * 26 + ord(letter) - ord("A") + 1
        if column_index > MAXIMUM_WORKSHEET_COLUMNS:
            return None
    row_index = int(match.group(2))
    if row_index > MAXIMUM_WORKSHEET_ROWS:
        return None
    return letters, row_index


def _cell_text(
    cell: ET.Element,
    shared_strings: list[str],
) -> str:
    reference = cell.attrib.get("r", "")
    if cell.find("m:f", NS) is not None or cell.attrib.get("t") == "str":
        raise WorkbookError(f"Workbook formulas are not supported: {reference}")
    kind = cell.attrib.get("t")
    if kind == "inlineStr":
        result = "".join(node.text or "" for node in cell.iter(f"{{{MAIN_NS}}}t"))
    else:
        value = cell.find("m:v", NS)
        raw = "" if value is None else value.text or ""
        if kind == "s" and raw:
            stripped = raw.strip()
            if not stripped.isascii() or not stripped.isdigit():
                raise WorkbookError(
                    "Workbook contains an invalid shared-string reference."
                )
            try:
                result = shared_strings[int(stripped)]
            except (IndexError, ValueError) as exc:
                raise WorkbookError("Workbook contains an invalid shared-string reference.") from exc
        elif kind == "b":
            result = raw.strip()
            if result not in {"0", "1"}:
                raise WorkbookError("Workbook boolean cells must contain exactly 0 or 1.")
        else:
            result = raw
    if len(result.encode("utf-8")) > MAXIMUM_CELL_BYTES:
        raise WorkbookError(f"Workbook cell exceeds the 1 MiB limit: {reference}")
    return result


def _rows(
    archive: zipfile.ZipFile,
    worksheet_path: str,
    shared_strings: list[str],
) -> Iterator[tuple[int, dict[str, str]]]:
    root = _xml_root(archive, worksheet_path)
    if root.tag != f"{{{MAIN_NS}}}worksheet":
        raise WorkbookError(f"Workbook worksheet root/namespace is invalid: {worksheet_path}")
    sheet_data = root.findall(f"{{{MAIN_NS}}}sheetData")
    if len(sheet_data) != 1:
        raise WorkbookError(
            f"Workbook worksheet must contain exactly one direct sheetData: {worksheet_path}"
        )
    rows = sheet_data[0].findall(f"{{{MAIN_NS}}}row")
    if len(rows) > MAXIMUM_WORKSHEET_ROWS:
        raise WorkbookError("Workbook worksheet exceeds the 500,000-row limit.")
    seen_row_indexes: set[int] = set()
    last_row_index = 0
    for row in rows:
        raw_row_index = row.attrib.get("r", "")
        if (
            not raw_row_index
            or not raw_row_index.isascii()
            or not raw_row_index.isdigit()
            or raw_row_index.startswith("0")
        ):
            raise WorkbookError("Workbook row reference is missing or invalid.")
        row_index = int(raw_row_index)
        if (
            row_index <= last_row_index
            or row_index > MAXIMUM_WORKSHEET_ROWS
            or row_index in seen_row_indexes
        ):
            raise WorkbookError(
                "Workbook row references must be unique and strictly increasing."
            )
        seen_row_indexes.add(row_index)
        last_row_index = row_index
        cells: dict[str, str] = {}
        for cell in row.findall("m:c", NS):
            reference = _cell_reference(cell.attrib.get("r", ""))
            if (
                reference is None
                or reference[1] != row_index
                or reference[0] in cells
            ):
                raise WorkbookError(f"Workbook row {row_index} contains duplicate/invalid cells.")
            column = reference[0]
            cells[column] = _cell_text(cell, shared_strings)
        yield row_index, cells


def _headers(row_index: int, cells: dict[str, str], sheet_name: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for column, raw in cells.items():
        name = raw.strip().replace("\ufeff", "")
        if not name:
            continue
        if name in result:
            raise WorkbookError(
                f'Row {row_index} of "{sheet_name}" contains duplicate header "{name}".'
            )
        result[name] = column
    return result


def _parse_positive_number(value: str, field_name: str) -> float:
    try:
        number = float(value)
    except ValueError as exc:
        raise WorkbookError(f'Basic Info field "{field_name}" must be numeric.') from exc
    if not math.isfinite(number) or number <= 0:
        raise WorkbookError(f'Basic Info field "{field_name}" must be finite and positive.')
    return number


def _read_basic_info(
    archive: zipfile.ZipFile,
    shared_strings: list[str],
) -> BasicMapInfo:
    rows = iter(_rows(archive, _worksheet_path(archive, "Basic Info"), shared_strings))
    try:
        header_row, header_cells = next(rows)
    except StopIteration as exc:
        raise WorkbookError('The "Basic Info" worksheet is empty.') from exc
    headers = _headers(header_row, header_cells, "Basic Info")
    required = {"map_name", "width", "height", "storeCode"}
    missing = sorted(required - set(headers))
    if missing:
        raise WorkbookError(f'Basic Info is missing required header "{missing[0]}".')
    business_rows = [
        (row_index, cells)
        for row_index, cells in rows
        if any(str(value).strip() for value in cells.values())
    ]
    if len(business_rows) != 1:
        raise WorkbookError('The "Basic Info" worksheet must contain exactly one business row.')
    row_index, cells = business_rows[0]

    def value(name: str) -> str:
        return cells.get(headers[name], "")

    map_name = value("map_name")
    store_code = value("storeCode")
    if not map_name.strip():
        raise WorkbookError(f"Basic Info row {row_index} has an empty map_name.")
    if not store_code.strip():
        raise WorkbookError(f"Basic Info row {row_index} has an empty storeCode.")
    if map_name != map_name.strip():
        raise WorkbookError(
            f"Basic Info row {row_index} map_name must not contain leading/trailing whitespace."
        )
    if store_code != store_code.strip():
        raise WorkbookError(
            f"Basic Info row {row_index} storeCode must not contain leading/trailing whitespace."
        )
    width = _parse_positive_number(value("width"), "width")
    height = _parse_positive_number(value("height"), "height")
    scale_text = value("scale") if "scale" in headers else ""
    scale = _parse_positive_number(scale_text, "scale") if scale_text.strip() else None
    network_audit = {
        name: value(name)
        for name in ("store_ip_address", "WAIServer_ip_adress")
        if name in headers and value(name) != ""
    }
    return BasicMapInfo(
        map_name=map_name,
        width_cm=width,
        height_cm=height,
        store_code=store_code,
        source_scale=scale,
        network_audit=network_audit,
    )


def _read_element_info(
    archive: zipfile.ZipFile,
    shared_strings: list[str],
) -> tuple[list[WorkbookElement], list[dict[str, Any]], list[dict[str, Any]]]:
    warnings: list[dict[str, Any]] = []
    malformed_rows: list[dict[str, Any]] = []
    elements: list[WorkbookElement] = []
    rows = iter(_rows(archive, _worksheet_path(archive, "Element Info"), shared_strings))
    try:
        header_row, header_cells = next(rows)
    except StopIteration as exc:
        raise WorkbookError('The "Element Info" worksheet is empty.') from exc
    headers = _headers(header_row, header_cells, "Element Info")
    if "floor" not in headers or "element" not in headers:
        raise WorkbookError(f'Row {header_row} must contain "floor" and "element" columns.')
    floor_column = headers["floor"]
    element_column = headers["element"]
    source_element_rows = 0
    for row_index, cells in rows:
        source_element_rows += 1
        if source_element_rows > MAXIMUM_ELEMENTS:
            raise WorkbookError("Element Info exceeds the 100,000-element limit.")
        floor = cells.get(floor_column, "").strip()
        raw_element = cells.get(element_column, "").strip()
        if not floor and not raw_element:
            continue
        if not floor:
            malformed_rows.append(
                {"row": row_index, "code": "missing_floor", "message": "楼层为空；该行未导入。"}
            )
            continue
        try:
            element = load_strict_json_bytes(
                raw_element.encode("utf-8"), name=f"Element Info row {row_index}"
            )
            if json_nesting_depth(element) > MAXIMUM_JSON_NESTING_DEPTH:
                raise StrictJSONError("element nesting depth exceeds 64")
        except StrictJSONError as exc:
            malformed_rows.append(
                {
                    "row": row_index,
                    "floor": floor,
                    "code": "invalid_element_json",
                    "message": f"element JSON 无法严格解析：{exc}",
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
    if malformed_rows:
        warnings.append(
            {
                "code": "malformed_rows",
                "count": len(malformed_rows),
                "message": (
                    f"检测到 {len(malformed_rows)} 行损坏数据；"
                    "正式 Basic Info + Element Info 转换必须失败关闭。"
                ),
            }
        )
    if not elements:
        raise WorkbookError('The "Element Info" worksheet contains no usable elements.')
    return elements, warnings, malformed_rows


def _read_shelf_info_audit(
    archive: zipfile.ZipFile,
) -> LegacyShelfInfoAudit:
    if not _has_worksheet(archive, "Shelf Info"):
        return LegacyShelfInfoAudit()
    root = _xml_root(archive, _worksheet_path(archive, "Shelf Info"))
    rows = root.findall(".//m:sheetData/m:row", NS)
    if len(rows) > MAXIMUM_WORKSHEET_ROWS:
        raise WorkbookError("Workbook worksheet exceeds the 500,000-row limit.")
    if not rows:
        return LegacyShelfInfoAudit(present=True, row_count=0)

    # Shelf Info is an audit-only legacy projection.  Count populated XML
    # rows without resolving shared strings, evaluating/rejecting formulae,
    # or interpreting any business value.  This makes formula/style/content
    # changes incapable of affecting the formal map or blocking import.
    def has_content(row: ET.Element) -> bool:
        for cell in row.findall("m:c", NS):
            formula = cell.find("m:f", NS)
            value = cell.find("m:v", NS)
            inline = cell.find("m:is", NS)
            if formula is not None:
                return True
            if value is not None and (value.text or "").strip():
                return True
            if inline is not None and any((node.text or "").strip() for node in inline.iter()):
                return True
        return False

    count = sum(1 for row in rows[1:] if has_content(row))
    return LegacyShelfInfoAudit(present=True, row_count=count)


def read_workbook(
    path: Path | str,
    *,
    allow_legacy_element_only: bool = False,
) -> WorkbookReadResult:
    source = Path(path)
    if not source.is_file():
        raise WorkbookError(f"Workbook does not exist: {source}")
    if source.suffix.lower() != ".xlsx":
        raise WorkbookError("Prior-map input must be an .xlsx workbook.")
    try:
        with zipfile.ZipFile(source) as archive:
            _validate_archive(source, archive)
            shared = _shared_strings(archive)
            has_basic = _has_worksheet(archive, "Basic Info")
            if not has_basic and not allow_legacy_element_only:
                raise WorkbookError('Workbook does not contain the required "Basic Info" worksheet.')
            basic_info = _read_basic_info(archive, shared) if has_basic else None
            elements, warnings, malformed_rows = _read_element_info(archive, shared)
            shelf_audit = _read_shelf_info_audit(archive)
    except zipfile.BadZipFile as exc:
        raise WorkbookError("The workbook is not a valid XLSX ZIP file.") from exc
    return WorkbookReadResult(
        elements=elements,
        warnings=warnings,
        malformed_rows=malformed_rows,
        basic_info=basic_info,
        legacy_shelf_info=shelf_audit,
    )


def read_element_info(path: Path | str) -> WorkbookReadResult:
    """Legacy compatibility wrapper for callers that only need elements."""

    return read_workbook(path, allow_legacy_element_only=True)
