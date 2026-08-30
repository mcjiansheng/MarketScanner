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
