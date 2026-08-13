"""Read-only compatibility migration for deterministic prior-map artifacts.

Formal v2 packages are immutable inputs.  A small number of packages produced
by an older compiler contain a byte-valid authoritative element inventory but
pre-date deterministic recovery of hidden ``MapCross`` topology.  This module
copies such a package into the processing output and rebuilds only the derived
road graph, spatial index, validation summary and package manifest.

The migration is deliberately narrow: any error other than the known derived
artifact binding mismatch remains fatal.  The source package is never edited.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import uuid
from pathlib import Path
from typing import Any

from .prior_map_schema import (
    PACKAGE_MANIFEST_FILE,
    build_package_manifest,
    load_json,
    validate_package,
)
from .xlsx_to_prior_map import _road_graph, _spatial_index


COMPATIBLE_BINDING_ERRORS = frozenset(
    {
        "road_graph_source_binding",
        "spatial_source_binding",
    }
)
ROAD_WARNING_CODES = frozenset(
    {
        "duplicate_cross_id",
        "duplicate_road_point_id",
        "road_point_without_cross",
        "missing_cross",
        "road_cross_inferred_from_points",
        "zero_length_road_edge",
    }
)
MIGRATION_ALGORITHM = "deterministic_road_graph_binding_v1"


class PriorMapCompatibilityError(ValueError):
    pass


def _write_json(path: Path, payload: Any) -> None:
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _fsync_file(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _binding_error_codes(validation: dict[str, Any]) -> set[str]:
    errors = validation.get("errors")
    if not isinstance(errors, list):
        return set()
    return {
        str(item.get("code"))
        for item in errors
        if isinstance(item, dict) and isinstance(item.get("code"), str)
    }


def _require_compatible_binding_failure(
    validation: dict[str, Any],
) -> set[str]:
    codes = _binding_error_codes(validation)
    if (
        validation.get("valid") is True
        or not codes
        or not codes.issubset(COMPATIBLE_BINDING_ERRORS)
        or "road_graph_source_binding" not in codes
    ):
        raise PriorMapCompatibilityError(
            "Prior-map package is not an eligible deterministic-derived-artifact migration."
        )
    return codes


def _copy_verified_snapshot(source: Path, staging: Path) -> None:
    staging.mkdir(mode=0o700)
    for child in sorted(source.iterdir(), key=lambda item: item.name):
        if child.name == ".DS_Store":
            continue
        metadata = child.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise PriorMapCompatibilityError(
                f"Prior-map artifact is not a regular single-link file: {child.name}"
            )
        destination = staging / child.name
        shutil.copyfile(child, destination)
        os.chmod(destination, 0o600)


def rebuild_legacy_derived_artifacts(
    source: Path | str,
    destination: Path | str,
) -> dict[str, Any]:
    """Create and atomically publish a validated compatibility package.

    Returns an audit payload.  The caller should store this outside the formal
    package so mobile/package validators continue seeing the exact package
    artifact contract.
    """

    source_path = Path(source).resolve()
    destination_path = Path(destination).resolve()
    if not source_path.is_dir():
        raise PriorMapCompatibilityError(
            f"Prior-map package is not a directory: {source_path}"
        )
    if destination_path.exists():
        raise PriorMapCompatibilityError(
            f"Compatibility destination already exists: {destination_path}"
        )
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    source_validation = validate_package(source_path)
    source_error_codes = _require_compatible_binding_failure(source_validation)
    source_package_manifest = load_json(source_path / PACKAGE_MANIFEST_FILE)
    if not isinstance(source_package_manifest, dict):
        raise PriorMapCompatibilityError("Prior-map package manifest is invalid.")

    staging = destination_path.parent / (
        f".{destination_path.name}.migration-{uuid.uuid4().hex}"
    )
    try:
        _copy_verified_snapshot(source_path, staging)
        # Revalidate the copied bytes before changing anything.  This proves
        # that the migration operates on one internally hash-bound snapshot,
        # even if the original path changes after the copy.
        copied_validation = validate_package(staging)
        copied_error_codes = _require_compatible_binding_failure(
            copied_validation
        )
        copied_package_manifest = load_json(staging / PACKAGE_MANIFEST_FILE)
        if (
            copied_error_codes != source_error_codes
            or not isinstance(copied_package_manifest, dict)
            or copied_package_manifest.get("package_sha256")
            != source_package_manifest.get("package_sha256")
        ):
            raise PriorMapCompatibilityError(
                "Prior-map compatibility snapshot changed during copy."
            )

        elements_payload = load_json(staging / "elements.json")
        validation_report = load_json(staging / "validation_report.json")
        manifest = load_json(staging / "manifest.json")
        if (
            not isinstance(elements_payload, dict)
            or not isinstance(elements_payload.get("elements"), list)
            or not isinstance(validation_report, dict)
            or not isinstance(validation_report.get("summary"), dict)
            or not isinstance(validation_report.get("warnings"), list)
            or not isinstance(manifest, dict)
        ):
            raise PriorMapCompatibilityError(
                "Prior-map authoritative elements or validation report is invalid."
            )

        old_graph = load_json(staging / "road_graph.json")
        road_warnings: list[dict[str, Any]] = []
        rebuilt_graph = _road_graph(elements_payload["elements"], road_warnings)
        rebuilt_spatial = _spatial_index(
            elements_payload["elements"], rebuilt_graph
        )
        if not isinstance(old_graph, dict):
            raise PriorMapCompatibilityError("Prior-map road graph is invalid.")

        preserved_warnings = [
            item
            for item in validation_report["warnings"]
            if isinstance(item, dict)
            and str(item.get("code")) not in ROAD_WARNING_CODES
        ]
        rebuilt_warnings = [*preserved_warnings, *road_warnings]
        validation_report["warnings"] = rebuilt_warnings
        validation_report["summary"] = {
            **validation_report["summary"],
            **rebuilt_graph["statistics"],
            "warning_count": len(rebuilt_warnings)
            + len(validation_report.get("malformed_rows", [])),
        }
        manifest["warning_count"] = validation_report["summary"][
            "warning_count"
        ]

        _write_json(staging / "road_graph.json", rebuilt_graph)
        _write_json(staging / "spatial_index.json", rebuilt_spatial)
        _write_json(staging / "validation_report.json", validation_report)
        _write_json(staging / "manifest.json", manifest)
        _write_json(
            staging / PACKAGE_MANIFEST_FILE,
            build_package_manifest(staging),
        )
        migrated_validation = validate_package(staging)
        if not migrated_validation.get("valid"):
            messages = "; ".join(
                str(item.get("message"))
                for item in migrated_validation.get("errors", [])
                if isinstance(item, dict)
            )
            raise PriorMapCompatibilityError(
                "Rebuilt compatibility package failed validation: " + messages
            )

        for child in staging.iterdir():
            if child.is_file():
                _fsync_file(child)
        _fsync_directory(staging)
        staging.rename(destination_path)
        _fsync_directory(destination_path.parent)

        migrated_package_manifest = load_json(
            destination_path / PACKAGE_MANIFEST_FILE
        )
        return {
            "format": "MarketScannerPriorMapCompatibilityAudit",
            "version": 1,
            "status": "rebuilt",
            "algorithm": MIGRATION_ALGORITHM,
            "source_path": str(source_path),
            "effective_path": str(destination_path),
            "source_package_sha256": source_package_manifest.get(
                "package_sha256"
            ),
            "effective_package_sha256": migrated_package_manifest.get(
                "package_sha256"
            ),
            "canonical_source_sha256": manifest.get(
                "canonical_source_sha256"
            ),
            "prior_map_id": manifest.get("prior_map_id"),
            "repaired_error_codes": sorted(source_error_codes),
            "source_road_statistics": old_graph.get("statistics", {}),
            "effective_road_statistics": rebuilt_graph.get("statistics", {}),
            "source_package_modified": False,
            "review_required": False,
        }
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def prepare_prior_map_for_processing(
    source: Path | str,
    output_root: Path | str,
) -> tuple[Path, dict[str, Any] | None]:
    """Return a valid source package or a persistent read-only migration."""

    source_path = Path(source).resolve()
    validation = validate_package(source_path)
    if validation.get("valid") is True:
        return source_path, None
    _require_compatible_binding_failure(validation)
    destination = Path(output_root).resolve() / "prior_map_compatibility"
    audit = rebuild_legacy_derived_artifacts(source_path, destination)
    return destination, audit
