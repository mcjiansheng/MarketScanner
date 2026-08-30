#!/usr/bin/env python3
"""Diagnose why prior-map localization never reaches `usable`.

The phone records one `localization_trace.jsonl` record per evaluated frame,
including the reason the correction was accepted or rejected and the raw
quality signals behind that decision. This tool aggregates those records so
the question "which gate is rejecting us?" can be answered from field data
instead of guessed at.

A key output is the **gate-fit table**: for each threshold it reports where
that threshold sits in the observed distribution. A gate that rejects 90% of
frames is not a quality bar, it is a mismatch between the threshold and
reality -- and this tool makes that visible.

Usage::

    python3 tools/PriorMap/localization_trace_diagnostic.py \
        --root 扫描结果 --root PC处理结果/0823-tianhong

    python3 tools/PriorMap/localization_trace_diagnostic.py \
        --root 扫描结果 --json diag.json
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
from collections import Counter, defaultdict
from typing import Any, Iterable, Sequence


# Gates as implemented in PriorMapLocalization / PriorMapScanMatcher.
GATES: list[tuple[str, str, float, str]] = [
    ("structurePointCount", "geometry candidate", 45.0, ">="),
    ("structureCoverageAngleRad", "geometry candidate", 0.35, ">="),
    ("matchUniqueness", "match acceptance", 0.10, ">="),
    ("matchResidualCost", "match acceptance", 0.10, "<="),
    ("correctionTranslationM", "online safety gate", 0.35, "<="),
]

STATE_FIELD = "localizationState"

# Spatial radius used by the *offline* basin analysis. This mirrors the
# matcher's coarse-pass `translationSeparationM`, i.e. the distance at which
# two hypotheses count as independent. It is an analysis constant only: the
# production matcher was NOT changed, because a safe fix requires comparing
# coarse/medium-stage basins rather than the fine pass's local samples. See
# the "uniqueness collapse" note in the round-2 report.
BASIN_RADIUS_M = 0.35


def _read_jsonl(path: str) -> list[dict[str, Any]]:
    if not os.path.exists(path):
        return []
    records: list[dict[str, Any]] = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return records


def discover_traces(roots: Sequence[str]) -> list[str]:
    found: list[str] = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for current, dirnames, _ in os.walk(root):
            dirnames[:] = [
                d
                for d in dirnames
                if d not in {"build", ".git", "__pycache__", "Libraries"}
            ]
            candidate = os.path.join(current, "localization_trace.jsonl")
            if os.path.exists(candidate) and os.path.getsize(candidate) > 0:
                found.append(candidate)
    return sorted(set(found))


def _quantiles(values: Sequence[float]) -> dict[str, float]:
    ordered = sorted(values)
    if not ordered:
        return {}

    def at(p: float) -> float:
        return ordered[min(len(ordered) - 1, int(len(ordered) * p))]

    return {
        "min": ordered[0],
        "p25": at(0.25),
        "median": at(0.50),
        "p75": at(0.75),
        "p90": at(0.90),
        "p99": at(0.99),
        "max": ordered[-1],
    }


def _gate_fit(
    records: Sequence[dict[str, Any]], field: str, threshold: float, op: str
) -> dict[str, Any]:
    values = [
        float(r[field])
        for r in records
        if isinstance(r.get(field), (int, float)) and not isinstance(r.get(field), bool)
    ]
    # A zero correction means "no correction was attempted", which says
    # nothing about the safety gate. Only non-zero attempts are informative.
    if field == "correctionTranslationM":
        values = [v for v in values if v > 0]
    if not values:
        return {"field": field, "threshold": threshold, "samples": 0}
    passed = sum(1 for v in values if (v >= threshold if op == ">=" else v <= threshold))
    return {
        "field": field,
        "threshold": threshold,
        "operator": op,
        "samples": len(values),
        "passed": passed,
        "rejected": len(values) - passed,
        "reject_rate": round((len(values) - passed) / len(values), 4),
        "quantiles": {k: round(v, 6) for k, v in _quantiles(values).items()},
    }


def basin_uniqueness(
    candidates: Sequence[dict[str, Any]], radius: float = BASIN_RADIUS_M
) -> float | None:
    """Uniqueness computed over spatial basins rather than raw samples.

    The matcher's fine pass searches a 0.2 m radius in 0.1 m steps, so its top
    entries are neighbouring samples of one location. Scoring those against
    each other made uniqueness collapse to ~0 and mislabelled a converged
    search as ambiguous. Candidates inside ``radius`` of one another are one
    location; basins -- not samples -- are compared.

    Returns ``1.0`` for a single basin (converged), the best-vs-runner-up cost
    ratio for two or more basins, and ``None`` when there are fewer than two
    candidates (absence of evidence, not proof of uniqueness).
    """
    if len(candidates) < 2:
        return None
    points = [
        (
            float((c.get("pose") or {}).get("x_m", 0.0)),
            float((c.get("pose") or {}).get("y_m", 0.0)),
            float(c.get("cost", 1e9)),
        )
        for c in candidates
    ]
    assigned = [False] * len(points)
    basins: list[float] = []
    for seed in range(len(points)):
        if assigned[seed]:
            continue
        assigned[seed] = True
        lowest = points[seed][2]
        frontier = [seed]
        while frontier:
            current = frontier.pop()
            for other in range(len(points)):
                if assigned[other]:
                    continue
                dx = points[current][0] - points[other][0]
                dy = points[current][1] - points[other][1]
                if dx * dx + dy * dy > radius * radius:
                    continue
                assigned[other] = True
                lowest = min(lowest, points[other][2])
                frontier.append(other)
        basins.append(lowest)
    basins.sort()
    if len(basins) < 2:
        return 1.0
    best, runner_up = basins[0], basins[1]
    return max(0.0, min(1.0, (runner_up - best) / max(runner_up, 0.01)))


def _basin_comparison(records: Sequence[dict[str, Any]]) -> dict[str, Any]:
    """Quantify how many `ambiguous_structure_match` rejections were mislabelled."""
    multi = [
        r
        for r in records
        if isinstance(r.get("matchCandidates"), list)
        and len(r["matchCandidates"]) >= 2
    ]
    if not multi:
        return {"samples": 0}

    original_pass = 0
    basin_pass = 0
    single_basin = 0
    ambiguous_total = 0
    ambiguous_converted = 0
    for record in multi:
        original = record.get("matchUniqueness") or 0
        recomputed = basin_uniqueness(record["matchCandidates"])
        if recomputed is None:
            continue
        if original >= 0.10:
            original_pass += 1
        if recomputed >= 0.10:
            basin_pass += 1
        if recomputed == 1.0:
            single_basin += 1
        if record.get("constraintReason") == "ambiguous_structure_match":
            ambiguous_total += 1
            if recomputed >= 0.10:
                ambiguous_converted += 1

    return {
        "samples": len(multi),
        "basin_radius_m": BASIN_RADIUS_M,
        "original_pass_rate": round(original_pass / len(multi), 4),
        "basin_pass_rate": round(basin_pass / len(multi), 4),
        "single_basin_count": single_basin,
        "ambiguous_total": ambiguous_total,
        "ambiguous_reclassified": ambiguous_converted,
        "ambiguous_reclassified_rate": round(
            ambiguous_converted / ambiguous_total, 4
        )
        if ambiguous_total
        else None,
        "note": (
            "Offline estimate only. The production matcher still compares the "
            "fine pass's neighbouring samples, so this is what a basin-aware "
            "fix would recover -- not what the shipped build does."
        ),
    }


def analyse(roots: Sequence[str]) -> dict[str, Any]:
    traces = discover_traces(roots)
    by_session: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for path in traces:
        session = os.path.basename(os.path.dirname(os.path.dirname(path)))
        by_session[session].extend(_read_jsonl(path))

    all_records = [r for rs in by_session.values() for r in rs]
    total = len(all_records)

    reasons = Counter(str(r.get("constraintReason")) for r in all_records)
    states = Counter(str(r.get(STATE_FIELD)) for r in all_records)
    sources = Counter(str(r.get("structureSource")) for r in all_records)

    # Does a low residual actually imply a trustworthy match? Compare the
    # residual distribution for frames that had a unique winner against those
    # that had none. If the ambiguous group is *at least as good*, residual
    # cannot be used to rescue them.
    def cost_for(predicate) -> float | None:
        values = [
            float(r["matchResidualCost"])
            for r in all_records
            if isinstance(r.get("matchResidualCost"), (int, float))
            and not isinstance(r.get("matchResidualCost"), bool)
            and predicate(r)
        ]
        return round(statistics.median(values), 6) if values else None

    ambiguity = {
        "cost_median_unique": cost_for(lambda r: (r.get("matchUniqueness") or 0) > 0),
        "cost_median_ambiguous": cost_for(
            lambda r: (r.get("matchUniqueness") or 0) == 0
        ),
    }

    sessions = []
    for session, records in sorted(by_session.items()):
        if not records:
            continue
        usable = sum(1 for r in records if r.get(STATE_FIELD) == "usable")
        uniq = [
            float(r.get("matchUniqueness") or 0)
            for r in records
            if isinstance(r.get("matchUniqueness"), (int, float))
        ]
        pts = [
            float(r.get("structurePointCount") or 0)
            for r in records
            if isinstance(r.get("structurePointCount"), (int, float))
        ]
        sessions.append(
            {
                "session": session,
                "records": len(records),
                "usable": usable,
                "usable_rate": round(usable / len(records), 5),
                "uniqueness_median": round(statistics.median(uniq), 4) if uniq else None,
                "points_median": round(statistics.median(pts), 1) if pts else None,
            }
        )

    return {
        "traces": len(traces),
        "sessions": len(by_session),
        "records": total,
        "constraint_reasons": dict(reasons.most_common()),
        "localization_states": dict(states.most_common()),
        "structure_sources": dict(sources.most_common()),
        "gate_fit": [
            _gate_fit(all_records, field, threshold, op)
            for field, _label, threshold, op in GATES
        ],
        "ambiguity_vs_residual": ambiguity,
        "basin_uniqueness_analysis": _basin_comparison(all_records),
        "per_session": sessions,
    }


def _print(report: dict[str, Any]) -> None:
    total = report["records"] or 1
    print(f"\ntrace 文件 {report['traces']}，会话 {report['sessions']}，记录 {report['records']}")

    print("\n=== 定位状态分布 ===")
    for state, count in sorted(
        report["localization_states"].items(), key=lambda kv: -kv[1]
    ):
        print(f"  {state:<22}{count:>8}  {count / total * 100:>5.1f}%")

    print("\n=== 拒绝/接受原因分布 ===")
    for reason, count in list(report["constraint_reasons"].items())[:15]:
        print(f"  {reason:<52}{count:>8}  {count / total * 100:>5.1f}%")

    print("\n=== 门限拟合（关键：门限落在观测分布的哪个位置）===")
    print(f"  {'字段':<28}{'门限':>8}{'样本':>8}{'拒绝率':>9}  中位/p90")
    for gate in report["gate_fit"]:
        if not gate.get("samples"):
            continue
        q = gate.get("quantiles", {})
        print(
            f"  {gate['field']:<28}{gate['threshold']:>8.2f}{gate['samples']:>8}"
            f"{gate['reject_rate'] * 100:>8.1f}%  "
            f"{q.get('median')}/{q.get('p90')}"
        )

    amb = report["ambiguity_vs_residual"]
    print("\n=== 歧义 vs 残差（低残差是否等于可信？）===")
    print(f"  唯一性 > 0 的记录 cost 中位: {amb['cost_median_unique']}")
    print(f"  唯一性 = 0 的记录 cost 中位: {amb['cost_median_ambiguous']}")
    if (
        amb["cost_median_unique"] is not None
        and amb["cost_median_ambiguous"] is not None
        and amb["cost_median_ambiguous"] <= amb["cost_median_unique"]
    ):
        print("  => 多解记录的残差并不更差：低残差不能证明匹配正确，")
        print("     因此放宽残差门或安全门会引入错误匹配，不是有效修复。")

    basin = report.get("basin_uniqueness_analysis") or {}
    if basin.get("samples"):
        print("\n=== 盆地唯一性分析（离线估算，非生产行为）===")
        print(f"  多候选样本 {basin['samples']}，盆地半径 {basin['basin_radius_m']} m")
        print(
            f"  原唯一性通过率 {basin['original_pass_rate'] * 100:.1f}%  ->  "
            f"盆地口径 {basin['basin_pass_rate'] * 100:.1f}%"
        )
        print(
            f"  单盆地（搜索收敛）{basin['single_basin_count']} 帧"
        )
        print(
            f"  原判 ambiguous_structure_match {basin['ambiguous_total']} 帧中，"
            f"{basin['ambiguous_reclassified']} 帧"
            f"（{(basin['ambiguous_reclassified_rate'] or 0) * 100:.1f}%）"
            f"在盆地口径下不再算歧义"
        )
        print(f"  {basin['note']}")

    print("\n=== 会话级（记录数 >= 200）===")
    print(f"  {'会话':<46}{'记录':>7}{'usable':>8}{'uniq中位':>10}{'pts中位':>9}")
    for item in report["per_session"]:
        if item["records"] < 200:
            continue
        print(
            f"  {item['session'][:44]:<46}{item['records']:>7}"
            f"{item['usable']:>8}{str(item['uniqueness_median']):>10}"
            f"{str(item['points_median']):>9}"
        )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", action="append", default=[])
    parser.add_argument("--json", dest="json_path")
    args = parser.parse_args(argv)

    roots = args.root or ["扫描结果", "PC处理结果"]
    roots = [r for r in roots if os.path.isdir(r)]
    if not roots:
        print("no scan roots found", file=__import__("sys").stderr)
        return 2

    report = analyse(roots)
    _print(report)

    if args.json_path:
        with open(args.json_path, "w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)
        print(f"\nwrote {args.json_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
