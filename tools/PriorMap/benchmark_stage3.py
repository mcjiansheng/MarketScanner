#!/usr/bin/env python3
"""Deterministic bounded-memory benchmark for the stage-three SE(2) solver."""

from __future__ import annotations

import argparse
import json
import sys
import time
import tracemalloc
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.PriorMap.offline_localization import (
    AbsoluteConstraint,
    Pose,
    optimize_trajectory,
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nodes", type=int, default=2_000)
    parser.add_argument("--max-seconds", type=float, default=15.0)
    parser.add_argument("--max-peak-mib", type=float, default=64.0)
    args = parser.parse_args()
    if not 100 <= args.nodes <= 100_000:
        parser.error("--nodes must be between 100 and 100000")
    poses = [
        Pose(
            node_id=index + 1,
            timestamp=float(index),
            x=index * 0.05,
            y=0.20,
            yaw=0.0,
        )
        for index in range(args.nodes)
    ]
    constraints = [
        AbsoluteConstraint(
            identifier=f"benchmark-{index}",
            node_index=index,
            x=index * 0.05,
            y=0.0,
            yaw=0.0,
            weight=5.0,
            kind="online_structure",
            source={},
        )
        for index in range(0, args.nodes, 100)
    ]
    tracemalloc.start()
    started = time.perf_counter()
    optimized, accepted, rejected = optimize_trajectory(poses, constraints)
    elapsed = time.perf_counter() - started
    _, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    peak_mib = peak / (1024 * 1024)
    result = {
        "format": "MarketScannerStage3Benchmark",
        "version": 1,
        "node_count": len(optimized),
        "constraint_count": len(constraints),
        "accepted_constraint_count": len(accepted),
        "rejected_constraint_count": len(rejected),
        "elapsed_seconds": round(elapsed, 6),
        "peak_python_memory_mib": round(peak_mib, 6),
        "limits": {
            "maximum_seconds": args.max_seconds,
            "maximum_peak_memory_mib": args.max_peak_mib,
        },
        "passed": elapsed <= args.max_seconds and peak_mib <= args.max_peak_mib,
    }
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
