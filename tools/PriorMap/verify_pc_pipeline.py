#!/usr/bin/env python3
"""End-to-end verification of the *PC* processing path.

The phone-side work in this repository has extensive field replay tooling, but
the PC path -- map package import -> rtabmap-reprocess -> prior-map localized
processing -> result artifacts -- had no equivalent check. This script drives
it against a real captured session and reports what actually happens, rather
than what the documentation claims.

It is deliberately read-only with respect to the capture: the source database
is copied, never optimised in place, and all output goes to a scratch
directory.

Usage::

    python3 tools/PriorMap/verify_pc_pipeline.py \
        --session 扫描结果/0811/SupermarketSession-20260811-103343 \
        --prior-map /path/to/mapcase03_sam \
        --output /tmp/pc-pipeline-check

Exit code is non-zero if any stage fails, so it can gate a CI job that has a
capture and a matching package available.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
# `offline_processing` imports `supermarket_2d_map` as a top-level module, so
# the 2D map tool directory has to be importable too. The Map Studio server
# sets this up for itself; a standalone script must do it explicitly.
sys.path.insert(0, str(REPO / "tools" / "Supermarket2DMap"))

from tools.PriorMap import offline_localization as localized  # noqa: E402
from tools.PriorMap.factor_graph_runner import (  # noqa: E402
    find_factor_graph_binary,
)
from tools.SupermarketMapStudio import offline_processing as pc  # noqa: E402


def _stage(name: str) -> None:
    print(f"\n--- {name} ---", flush=True)


def _read_optimized_poses(database: Path, horizontal_axes: str = "xz") -> list:
    """Read the replay poses for a reprocessed database.

    `rtabmap-reprocess` writes its optimized graph back into the copy, so the
    node poses read here are the optimized ones. Production distinguishes an
    optimized graph from a raw-VIO fallback via
    `relative_trajectory_authority`; this verification script reports the
    authority the localized stage actually selects.
    """
    return localized.load_raw_continuous_vio_poses(
        path=database, horizontal_axes=horizontal_axes
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", required=True)
    parser.add_argument("--prior-map", required=True)
    parser.add_argument("--output", default="/tmp/pc-pipeline-check")
    parser.add_argument("--json", dest="json_path")
    args = parser.parse_args()

    session = Path(args.session).resolve()
    prior_map = Path(args.prior_map).resolve()
    output = Path(args.output)
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    report: dict = {
        "session": str(session),
        "prior_map": str(prior_map),
        "stages": {},
    }
    started = time.time()

    # ---------------------------------------------------------------- stage 1
    _stage("1. locate session database")
    segments = sorted(p for p in session.glob("segment_*") if p.is_dir())
    if len(segments) != 1:
        print(f"FAIL: expected one continuous segment, found {len(segments)}")
        return 1
    source_db = segments[0] / "rtabmap_segment_0001.db"
    if not source_db.is_file():
        print(f"FAIL: missing {source_db}")
        return 1
    print(f"source database: {source_db} ({source_db.stat().st_size} bytes)")
    report["stages"]["locate"] = {"ok": True, "database": str(source_db)}

    # ---------------------------------------------------------------- stage 2
    _stage("2. validate capture database (read-only)")
    # This API signals rejection by raising, not by returning a flag.
    try:
        validation = pc.validate_capture_database(source_db)
    except pc.OfflineProcessingError as exc:
        print(f"FAIL: {exc}")
        report["stages"]["validate"] = {"ok": False, "error": str(exc)}
        return 1
    print(json.dumps(validation, ensure_ascii=False, indent=2)[:1200])
    coverage = None
    if validation.get("node_count"):
        coverage = round(
            (validation.get("optimized_pose_count") or 0)
            / validation["node_count"],
            4,
        )
    print(f"optimized pose coverage: {coverage}")
    validation["optimized_pose_coverage"] = coverage
    report["stages"]["validate"] = validation

    # ---------------------------------------------------------------- stage 3
    _stage("3. rtabmap-reprocess (adaptive)")
    optimized_db = output / "optimized.db"
    reprocess = pc.run_adaptive_reprocess(
        input_database=source_db,
        output_database=optimized_db,
        use_local_staging=True,
    )
    print(json.dumps(reprocess, ensure_ascii=False, indent=2)[:1600])
    report["stages"]["reprocess"] = reprocess
    if not optimized_db.is_file():
        print("FAIL: optimized database was not produced")
        return 1

    # ---------------------------------------------------------------- stage 4
    _stage("4. factor graph helper availability")
    helper = find_factor_graph_binary()
    print(f"helper: {helper}")
    report["stages"]["factor_graph_helper"] = str(helper) if helper else None
    if helper is None:
        print("WARN: native helper absent; processing will use the bounded fallback")

    # ---------------------------------------------------------------- stage 5
    _stage("5. localized prior-map processing")
    poses = _read_optimized_poses(optimized_db)
    print(f"optimized poses: {len(poses)}")
    if not poses:
        print("FAIL: no optimized poses")
        return 1
    result = localized.process_localized_session(
        prior_map=prior_map,
        session=session,
        optimized_poses=poses,
        source_database=source_db,
        optimized_database=optimized_db,
        output=output,
        factor_graph_binary=helper,
    )
    summary = {
        "version_id": result.get("version_id"),
        "result_quality_status": result.get("result_quality_status"),
        "publish_permitted": result.get("publish_permitted"),
        "production_publish_permitted": result.get(
            "production_publish_permitted"
        ),
        "solver": (result.get("solver") or {}).get("type"),
        "full_factor_graph": (result.get("solver") or {}).get(
            "full_factor_graph"
        ),
        "blockers": [
            item.get("code")
            for item in (result.get("publish_gate") or {}).get("blockers", [])
        ],
        "warnings_count": len(result.get("warnings") or []),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    report["stages"]["localized"] = summary

    # ---------------------------------------------------------------- stage 6
    _stage("6. result artifacts")
    artifacts = sorted(
        str(p.relative_to(output))
        for p in output.rglob("*")
        if p.is_file() and "staging" not in str(p)
    )
    # Artifacts live under `localized/versions/vNNNNNN/`, with the current
    # pointer at `localized/current.json`.
    version_dirs = sorted((output / "localized" / "versions").glob("v*"))
    expected = [
        "localized/current.json",
        "localized_price_tags.json",
        "calibrated_positions_by_node.csv",
        "calibrated_positions_1s.csv",
        "factor_graph_report.json",
        "localization_report.json",
        "optimized_map_trajectory.geojson",
    ]
    latest = version_dirs[-1] if version_dirs else None
    if latest is None:
        print("FAIL: no localized version produced")
        return 1
    present = {
        name: (output / name).exists()
        if name.startswith("localized/")
        else (latest / name).exists()
        for name in expected
    }
    missing_artifacts = [name for name, ok in present.items() if not ok]
    print(f"version: {latest.name}")
    print(json.dumps(present, indent=2))
    report["stages"]["artifacts"] = {
        "count": len(artifacts),
        "version": latest.name,
        "present": present,
        "missing": missing_artifacts,
    }
    if missing_artifacts:
        print(f"FAIL: missing artifacts {missing_artifacts}")
        return 1

    report["elapsed_seconds"] = round(time.time() - started, 1)
    if args.json_path:
        Path(args.json_path).write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"\nwrote {args.json_path}")

    print(f"\nPC pipeline completed in {report['elapsed_seconds']}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
