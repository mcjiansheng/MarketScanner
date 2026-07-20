#!/usr/bin/env python3
"""Reproducible benchmark runner for Map Studio offline optimization profiles."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import offline_processing as offline

try:
    import resource
except ImportError:  # Windows does not provide the POSIX resource module.
    resource = None  # type: ignore[assignment]


def peak_child_rss_bytes() -> int:
    if resource is None:
        return 0
    value = int(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
    return value if sys.platform == "darwin" else value * 1024


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Benchmark adaptive, constraint-reuse or ORB-discovery RTAB-Map processing."
    )
    parser.add_argument("database", type=Path, help="Immutable input RTAB-Map database")
    parser.add_argument("output_dir", type=Path, help="Directory for benchmark DB/report")
    parser.add_argument("--binary", help="Explicit rtabmap-reprocess executable")
    parser.add_argument("--threads", type=int, default=offline.DEFAULT_PC_THREADS)
    parser.add_argument(
        "--profile",
        choices=("adaptive", "reuse", "discovery"),
        default="adaptive",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    database = args.database.expanduser().resolve()
    output_dir = args.output_dir.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    output_database = output_dir / f"optimized-{args.profile}-{stamp}.db"

    if args.profile == "adaptive":
        report = offline.run_adaptive_reprocess(
            database,
            output_database,
            explicit_binary=args.binary,
            thread_count=args.threads,
        )
    else:
        extra = offline.FAST_REUSE_PARAMETERS if args.profile == "reuse" else ()
        profile_name = (
            offline.FAST_REUSE_PROFILE
            if args.profile == "reuse"
            else offline.DISCOVERY_PROFILE
        )
        report = offline.run_reprocess(
            database,
            output_database,
            explicit_binary=args.binary,
            thread_count=args.threads,
            extra_parameters=extra,
            profile_name=profile_name,
        )

    report["benchmark"] = {
        "profile_requested": args.profile,
        "threads_requested": args.threads,
        "peak_child_rss_bytes": peak_child_rss_bytes(),
        "measured_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    report_path = output_database.with_suffix(".benchmark.json")
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    summary = {
        "database": str(database),
        "output_database": str(output_database),
        "report": str(report_path),
        "elapsed_seconds": report.get("elapsed_seconds"),
        "profile": report.get("execution", {}).get("profile"),
        "selected_pass": report.get("adaptive", {}).get("selected_pass"),
        "node_time_ms": report.get("runtime", {}).get("node_time_ms"),
        "final_optimization": report.get("runtime", {}).get("final_optimization"),
        "quality": report.get("error_optimization", {}).get("status"),
        "peak_child_rss_bytes": report["benchmark"]["peak_child_rss_bytes"],
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
