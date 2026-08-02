#!/usr/bin/env python3
"""Source contract for the native publish-capable relative SE(2) helper."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "tools/Reprocess/prior_map_factor_graph.cpp"
CMAKE = ROOT / "tools/Reprocess/CMakeLists.txt"


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    cmake = CMAKE.read_text(encoding="utf-8")
    required = (
        "openConnection(options.database, false, true)",
        "getAllOdomPoses",
        "loadOptimizedPoses",
        "getAllLinks",
        "getDatabaseVersion",
        "Optimizer::create(Optimizer::kTypeG2O",
        "setSlam2d(true)",
        "setRobust(true)",
        "Relative factor graph is disconnected",
        "factor_set_sha256",
        "graph_connected",
        "fixed_root",
        "absolute_priors",
        "horizontalAxes == \"ios_prior\"",
        "keep the first deterministic orientation",
    )
    missing = [token for token in required if token not in source]
    if "prior-map-factor-graph" not in cmake:
        missing.append("CMake output rtabmap-prior-map-factor-graph")
    if missing:
        for token in missing:
            print(f"factor graph native contract missing: {token}", file=sys.stderr)
        raise SystemExit(1)
    if "openConnection(options.database, true" in source:
        print("factor graph helper opens the optimized DB writable", file=sys.stderr)
        raise SystemExit(1)
    if "Contradictory duplicate relative Link detected" in source:
        print("factor graph helper still rejects reciprocal loop observations", file=sys.stderr)
        raise SystemExit(1)
    print("factor graph native source contract passed")


if __name__ == "__main__":
    main()
