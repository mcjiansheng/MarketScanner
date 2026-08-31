#!/usr/bin/env python3
"""Batch PC-pipeline verification across every session that has a map package.

`verify_pc_pipeline.py` checks one session; this drives it over all of them and
reports a success rate, which is the number the round-2 work needs: how many
real captures can actually be carried from map package import through to
finished result artifacts.

Sessions are matched to packages by `priorMapId` in metadata.json. Each run is
independent and writes to its own scratch directory.

Usage::

    python3 tools/PriorMap/batch_verify_pc_pipeline.py \
        --sessions-root 扫描结果 \
        --packages-root ~/Library/Mobile\ Documents/com~apple~CloudDocs/Downloads \
        --output-root /tmp/pc-batch --json /tmp/pc-batch.json
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import traceback
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# macOS Spotlight can drop AppleDouble sidecars next to exported packages;
# they are not map packages and must not be scanned as one.
_SKIP_DIR_PREFIXES = (".", "_")


def _discover_packages(root: Path) -> dict[str, Path]:
    packages: dict[str, Path] = {}
    if not root.is_dir():
        return packages
    for entry in sorted(root.iterdir()):
        if not entry.is_dir() or entry.name.startswith(_SKIP_DIR_PREFIXES):
            continue
        manifest = entry / "manifest.json"
        if not manifest.is_file():
            continue
        try:
            payload = json.loads(manifest.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        identifier = payload.get("prior_map_id")
        if isinstance(identifier, str) and identifier:
            packages[identifier] = entry
    return packages


def _duplicate_bindings(clock_path: Path) -> tuple[int, int]:
    """Return (binding_count, redundant_duplicate_count) for a session."""
    if not clock_path.is_file():
        return (0, 0)
    node_ids = []
    with clock_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("record_kind") == "node_binding" and record.get(
                "node_id"
            ) is not None:
                node_ids.append(record["node_id"])
    counts: dict[int, int] = {}
    for node_id in node_ids:
        counts[node_id] = counts.get(node_id, 0) + 1
    return (len(node_ids), sum(v - 1 for v in counts.values() if v > 1))


def _pairs(sessions_root: Path, packages: dict[str, Path]) -> list[tuple[Path, Path]]:
    pairs = []
    for metadata in sorted(sessions_root.glob("**/metadata.json")):
        try:
            payload = json.loads(metadata.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        if not payload.get("finalized"):
            continue
        session = metadata.parent.parent
        database = session / "segment_0001" / "rtabmap_segment_0001.db"
        if not database.is_file():
            continue
        package = packages.get(str(payload.get("priorMapId") or ""))
        if package is None:
            continue
        pairs.append((session, package))
    return pairs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sessions-root", default="扫描结果")
    parser.add_argument(
        "--packages-root",
        default=os.path.expanduser(
            "~/Library/Mobile Documents/com~apple~CloudDocs/Downloads"
        ),
    )
    parser.add_argument("--output-root", default="/tmp/pc-batch")
    parser.add_argument("--json", dest="json_path")
    parser.add_argument(
        "--limit", type=int, help="Only process the first N sessions."
    )
    args = parser.parse_args()

    sessions_root = Path(args.sessions_root)
    packages = _discover_packages(Path(args.packages_root))
    pairs = _pairs(sessions_root, packages)
    if args.limit:
        pairs = pairs[: args.limit]

    print(f"sessions root : {sessions_root}")
    print(f"packages      : {len(packages)}")
    print(f"matched pairs : {len(pairs)}")
    print()

    output_root = Path(args.output_root)
    output_root.mkdir(parents=True, exist_ok=True)
    results = []
    started = time.time()

    for index, (session, package) in enumerate(pairs, start=1):
        name = session.name
        out = output_root / name
        clock = session / "segment_0001" / "clock_correlations.jsonl"
        binding_count, duplicate_count = _duplicate_bindings(clock)
        entry = {
            "session": name,
            "package": package.name,
            "database_mb": round(
                (session / "segment_0001" / "rtabmap_segment_0001.db").stat().st_size
                / 1048576
            ),
            "binding_count": binding_count,
            "duplicate_binding_count": duplicate_count,
        }
        print(f"[{index}/{len(pairs)}] {name} ({package.name})", flush=True)
        run_started = time.time()
        proc = subprocess.run(
            [
                sys.executable,
                str(REPO / "tools" / "PriorMap" / "verify_pc_pipeline.py"),
                "--session",
                str(session),
                "--prior-map",
                str(package),
                "--output",
                str(out),
            ],
            capture_output=True,
            text=True,
            cwd=str(REPO),
        )
        entry["exit_code"] = proc.returncode
        entry["elapsed_seconds"] = round(time.time() - run_started, 1)
        entry["ok"] = proc.returncode == 0
        if proc.returncode != 0:
            tail = (proc.stderr or proc.stdout or "").strip().splitlines()
            entry["error"] = tail[-1] if tail else "unknown"
            print(f"    FAIL ({entry['elapsed_seconds']}s): {entry['error']}", flush=True)
        else:
            print(f"    OK   ({entry['elapsed_seconds']}s)", flush=True)
        results.append(entry)

    ok_count = sum(1 for item in results if item["ok"])
    total = len(results)
    with_dups = [item for item in results if item["duplicate_binding_count"] > 0]
    with_dups_ok = sum(1 for item in with_dups if item["ok"])

    summary = {
        "total": total,
        "succeeded": ok_count,
        "failed": total - ok_count,
        "success_rate": round(ok_count / total, 4) if total else None,
        "sessions_with_duplicate_bindings": len(with_dups),
        "those_succeeded": with_dups_ok,
        "elapsed_seconds": round(time.time() - started, 1),
    }

    print()
    print("=" * 72)
    print(f"PC pipeline: {ok_count}/{total} succeeded "
          f"({(summary['success_rate'] or 0) * 100:.1f}%)")
    print(f"of which had duplicate clock bindings: {len(with_dups)} "
          f"-> {with_dups_ok} succeeded")
    print(f"total elapsed: {summary['elapsed_seconds']}s")
    print("=" * 72)

    payload = {"summary": summary, "results": results}
    if args.json_path:
        Path(args.json_path).write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"wrote {args.json_path}")

    return 0 if summary["failed"] == 0 else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:  # pragma: no cover - diagnostics only
        traceback.print_exc()
        raise SystemExit(2)
