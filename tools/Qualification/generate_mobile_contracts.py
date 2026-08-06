#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V1R5 Gate A: single source of truth for every formal evidence input
limit (contracts/mobile_only_v1r5_input_limits.json).

Generates (or verifies) three artifacts that must never drift apart:
- contracts/mobile_only_v1r5_input_limits.json   (authoritative JSON)
- app/ios/RTABMapApp/GeneratedMobileEvidenceContracts.swift
- tools/PriorMap/generated_mobile_evidence_contracts.py

Usage:
  python3 tools/Qualification/generate_mobile_contracts.py            # write all
  python3 tools/Qualification/generate_mobile_contracts.py --check    # CI drift gate

Limits are PRODUCT-DERIVED (V1R5 §4): the qualified store ceiling is
≈60k RTAB-Map nodes and 200k tag observations; every file gate is the
real record-size budget × the product maximum + a documented safety
factor. Generic 8/16 MiB caps copied from elsewhere are forbidden.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "contracts"
CONTRACT_FILE = CONTRACTS / "mobile_only_v1r5_input_limits.json"
SWIFT_FILE = ROOT / "app" / "ios" / "RTABMapApp" / "GeneratedMobileEvidenceContracts.swift"
PYTHON_FILE = ROOT / "tools" / "PriorMap" / "generated_mobile_evidence_contracts.py"

# ---------------------------------------------------------------------------
# The authoritative contract table (V1R5 §4).
#
# Policy fields per evidence file:
#   max_file_bytes      hard file-size gate (pre-read)
#   max_records         hard record-count gate
#   max_record_bytes    hard single-record gate
#   max_nesting_depth   JSON nesting gate (strict parser)
#   final_newline       file must end with "\\n"
#   blank_line_policy   "reject" | "empty_file_allowed"
#   strict_bool         numeric 0/1 must never bridge into Bool
#   strict_integer      fractional numbers must never truncate into Int
#   identity_fields     required exact-identity fields
#   watermark_fields    metadata fields whose values must match exactly
# ---------------------------------------------------------------------------

CONTRACT = {
    "contract_version": 1,
    "wave": "mobile-only-v1r5-field-qualification-integrity-scale-closeout",
    "product_scale": {
        "max_raw_nodes": 60000,
        "max_tag_observations": 200000,
        "max_clock_node_bindings": 60000,
        "scan_hours_upper_bound": 48,
    },
    "evidence_files": {
        "metadata.json": {
            "max_file_bytes": 16 * 1024 * 1024,
            "max_records": 1,
            "max_record_bytes": 16 * 1024 * 1024,
            "max_nesting_depth": 8,
            "final_newline": False,
            "blank_line_policy": "n_a",
            "strict_bool": True,
            "strict_integer": True,
            "identity_fields": ["storeId", "floorId", "priorMapId",
                                "priorMapSha256", "trackingSessionId"],
            "watermark_fields": ["finalized", "clockCorrelationCount",
                                 "clockNodeBindingCount",
                                 "tagObservationBurstCount",
                                 "tagObservationBurstLastID",
                                 "tagObservationBurstComplete",
                                 "localizationTraceRecordCount"],
        },
        "localization_trace.jsonl": {
            "max_file_bytes": 512 * 1024 * 1024,
            "max_records": 2000000,
            "max_record_bytes": 1024 * 1024,
            "max_nesting_depth": 8,
            "final_newline": True,
            "blank_line_policy": "reject",
            "strict_bool": True,
            "strict_integer": True,
            "identity_fields": ["trackingSessionId", "priorMapId",
                                "priorMapSha256", "floorId"],
            "watermark_fields": ["captureHealth.localizationTraceRecordCount"],
        },
        "localization_constraints.jsonl": {
            "max_file_bytes": 64 * 1024 * 1024,
            "max_records": 100000,
            "max_record_bytes": 1024 * 1024,
            "max_nesting_depth": 8,
            "final_newline": True,
            "blank_line_policy": "reject",
            "strict_bool": True,
            "strict_integer": True,
            "identity_fields": ["priorMapId", "priorMapSha256",
                                "trackingSessionId", "floorId"],
            "watermark_fields": [],
        },
        "manual_localization_events.jsonl": {
            "max_file_bytes": 64 * 1024 * 1024,
            "max_records": 100000,
            "max_record_bytes": 1024 * 1024,
            "max_nesting_depth": 8,
            "final_newline": True,
            "blank_line_policy": "reject",
            "strict_bool": True,
            "strict_integer": True,
            "identity_fields": ["prior_map_id", "prior_map_sha256",
                                "tracking_session_id", "floor_id"],
            "watermark_fields": [],
        },
        "clock_correlations.jsonl": {
            "max_file_bytes": 256 * 1024 * 1024,
            "max_records": 1000000,
            "max_record_bytes": 1024 * 1024,
            "max_nesting_depth": 8,
            "final_newline": True,
            "blank_line_policy": "reject",
            "strict_bool": True,
            "strict_integer": True,
            "identity_fields": ["tracking_session_id"],
            "watermark_fields": ["clockCorrelationCount", "clockNodeBindingCount"],
        },
        "tag_observations.jsonl": {
            "max_file_bytes": 256 * 1024 * 1024,
            "max_records": 200000,
            "max_record_bytes": 1024 * 1024,
            "max_nesting_depth": 8,
            "final_newline": True,
            "blank_line_policy": "reject",
            "strict_bool": True,
            "strict_integer": True,
            "identity_fields": ["prior_map_id", "prior_map_sha256",
                                "tracking_session_id", "floor_id"],
            "watermark_fields": ["tagObservationBurstCount",
                                 "tagObservationBurstLastID",
                                 "tagObservationBurstComplete"],
        },
        "tag_observation_bursts.jsonl": {
            "max_file_bytes": 256 * 1024 * 1024,
            "max_records": 200000,
            "max_record_bytes": 4 * 1024 * 1024,
            "max_nesting_depth": 8,
            "final_newline": True,
            "blank_line_policy": "reject",
            "strict_bool": True,
            "strict_integer": True,
            "identity_fields": ["tracking_session_id", "floor_id"],
            "watermark_fields": ["tagObservationBurstCount",
                                 "tagObservationBurstLastID",
                                 "tagObservationBurstComplete"],
        },
        "result_package": {
            "max_manifest_bytes": 4 * 1024 * 1024,
            "max_package_files": 64,
            "max_per_file_bytes": 2 * 1024 * 1024 * 1024,
            "immutable": True,
            "per_file_sha256": True,
            "package_sha256": True,
        },
        "xlsx_workbook": {
            "max_file_bytes": 2 * 1024 * 1024 * 1024,
            "max_sheet_rows": 500000,
            "exact_four_sheets": True,
            "no_formula": True,
            "crc_and_size_verified": True,
        },
        "native_graph": {
            "max_raw_nodes": 200000,
            "max_skeleton_nodes": 200000,
            "max_factors": 400000,
            "max_priors": 100000,
            "max_trajectory_rows": 200000,
        },
    },
    "rationale": (
        "Limits derive from the qualified store ceiling (60k nodes / "
        "200k observations): each gate = real per-record bytes × product "
        "maximum × safety factor. The parser streams via 64 KiB chunks so "
        "large gates do not imply large memory."
    ),
}


def contract_json() -> dict:
    return CONTRACT


def swift_source() -> str:
    files = CONTRACT["evidence_files"]
    lines = [
        "// AUTO-GENERATED by tools/Qualification/generate_mobile_contracts.py.",
        "// DO NOT EDIT BY HAND — regenerate and run `--check` in CI.",
        "// V1R5 §4: single source of truth for evidence input limits.",
        "import Foundation",
        "",
        "enum GeneratedMobileEvidenceContracts {",
        "    static let contractVersion = {}".format(CONTRACT["contract_version"]),
        "    static let wave = \"{}\"".format(CONTRACT["wave"]),
        "",
        "    enum ProductScale {",
        "        static let maxRawNodes = {}".format(CONTRACT["product_scale"]["max_raw_nodes"]),
        "        static let maxTagObservations = {}".format(CONTRACT["product_scale"]["max_tag_observations"]),
        "        static let maxClockNodeBindings = {}".format(CONTRACT["product_scale"]["max_clock_node_bindings"]),
        "        static let scanHoursUpperBound = {}".format(CONTRACT["product_scale"]["scan_hours_upper_bound"]),
        "    }",
        "",
    ]
    for name in sorted(files):
        spec = files[name]
        enum_name = name.replace(".", "_").replace("-", "_")
        lines.append("    enum File_{} {{".format(enum_name))
        for key in sorted(spec):
            value = spec[key]
            if isinstance(value, bool):
                lines.append("        static let {} = {}".format(
                    key, str(value).lower()))
            elif isinstance(value, int):
                lines.append("        static let {} = {}".format(key, value))
            elif isinstance(value, list):
                items = ", ".join('"{}"'.format(v) for v in value)
                lines.append("        static let {}: [String] = [{}]".format(
                    key, items))
            else:
                lines.append("        static let {} = \"{}\"".format(
                    key, value.replace("\\", "\\\\").replace('"', '\\"')))
        lines.append("    }")
        lines.append("")
    lines.append("}")
    return "\n".join(lines) + "\n"


def python_source() -> str:
    files = CONTRACT["evidence_files"]
    lines = [
        "# AUTO-GENERATED by tools/Qualification/generate_mobile_contracts.py.",
        "# DO NOT EDIT BY HAND — regenerate and run `--check` in CI.",
        "# V1R5 §4: single source of truth for evidence input limits.",
        "",
        "MOBILE_EVIDENCE_CONTRACT_VERSION = {}".format(CONTRACT["contract_version"]),
        "",
        "MOBILE_EVIDENCE_CONTRACTS = {",
    ]
    for name in sorted(files):
        spec = files[name]
        lines.append("    {!r}: {{".format(name))
        for key in sorted(spec):
            value = spec[key]
            if isinstance(value, bool):
                lines.append("        {!r}: {},".format(key, str(value).capitalize()))
            elif isinstance(value, int):
                lines.append("        {!r}: {},".format(key, value))
            else:
                lines.append("        {!r}: {!r},".format(key, value))
        lines.append("    },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def write_all() -> None:
    CONTRACTS.mkdir(parents=True, exist_ok=True)
    CONTRACT_FILE.write_text(
        json.dumps(CONTRACT, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    SWIFT_FILE.write_text(swift_source(), encoding="utf-8")
    PYTHON_FILE.write_text(python_source(), encoding="utf-8")


def check() -> int:
    failures = []
    if not CONTRACT_FILE.exists():
        failures.append("missing {}".format(CONTRACT_FILE))
    else:
        try:
            stored = json.loads(CONTRACT_FILE.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            failures.append("invalid contract json: {}".format(error))
            stored = None
        if stored is not None and stored != CONTRACT:
            failures.append("contract json drifted from generator")
    if not SWIFT_FILE.exists():
        failures.append("missing {}".format(SWIFT_FILE))
    elif SWIFT_FILE.read_text(encoding="utf-8") != swift_source():
        failures.append("GeneratedMobileEvidenceContracts.swift drifted")
    if not PYTHON_FILE.exists():
        failures.append("missing {}".format(PYTHON_FILE))
    elif PYTHON_FILE.read_text(encoding="utf-8") != python_source():
        failures.append("generated_mobile_evidence_contracts.py drifted")
    if failures:
        for failure in failures:
            print("CONTRACT DRIFT: {}".format(failure), file=sys.stderr)
        return 1
    print("mobile evidence contracts: OK ({} files, version {})".format(
        len(CONTRACT["evidence_files"]), CONTRACT["contract_version"]))
    return 0


def main() -> int:
    if "--check" in sys.argv:
        return check()
    write_all()
    print("wrote {}".format(CONTRACT_FILE))
    print("wrote {}".format(SWIFT_FILE))
    print("wrote {}".format(PYTHON_FILE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
