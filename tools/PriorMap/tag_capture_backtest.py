#!/usr/bin/env python3
"""Field-data backtest for the ESL price-tag capture / localization chain.

This replays the *decision chain* that production code applies to a burst,
using real captured sidecars (``tag_observations.jsonl`` +
``tag_observation_bursts.jsonl``).  It is deliberately not a re-implementation
of SLAM or of Vision: it answers one question that field logs previously could
not --

    for every captured burst, exactly which gate rejected it, and how long
    the operator waited before that rejection?

Usage
-----
    # baseline (production policy)
    python3 tools/PriorMap/tag_capture_backtest.py --root 扫描结果 --root PC处理结果/0823-tianhong

    # optimised policy, side by side
    python3 tools/PriorMap/tag_capture_backtest.py --root 扫描结果 --compare

    # machine readable
    python3 tools/PriorMap/tag_capture_backtest.py --root 扫描结果 --json report.json

The ``--json`` form is what CI should archive so regressions in capture
success rate are visible across commits.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
from dataclasses import dataclass, field, asdict
from typing import Any, Iterable, Sequence


# --------------------------------------------------------------------------
# Policies
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class CapturePolicy:
    """Mirror of ``PriceTagCapturePolicy`` + the gates that consume a frame."""

    name: str
    minimum_candidate_lock_frames: int
    minimum_evidence_frames: int
    target_evidence_frames: int
    maximum_capture_duration_s: float
    minimum_capture_duration_s: float
    # ROI gate: fraction of the barcode box that must sit inside the scan box.
    minimum_roi_intersection_ratio: float
    # Frame-level admission gates (applied to every observation).
    require_scene_depth: bool
    allow_weak_localization: bool
    allow_aging_alignment: bool

    @staticmethod
    def production() -> "CapturePolicy":
        """Values read out of PriceTagCaptureCore.PriceTagCapturePolicy.field."""
        return CapturePolicy(
            name="production",
            minimum_candidate_lock_frames=2,
            minimum_evidence_frames=3,
            target_evidence_frames=4,
            maximum_capture_duration_s=4.0,
            minimum_capture_duration_s=0.30,
            minimum_roi_intersection_ratio=0.80,
            require_scene_depth=True,
            allow_weak_localization=False,
            allow_aging_alignment=True,
        )

    @staticmethod
    def optimized() -> "CapturePolicy":
        """Round-2 proposal: fewer frames, earlier exit, graded ROI gate."""
        return CapturePolicy(
            name="optimized",
            minimum_candidate_lock_frames=2,
            minimum_evidence_frames=2,
            target_evidence_frames=3,
            maximum_capture_duration_s=2.5,
            minimum_capture_duration_s=0.20,
            minimum_roi_intersection_ratio=0.55,
            require_scene_depth=False,
            allow_weak_localization=True,
            allow_aging_alignment=True,
        )


# --------------------------------------------------------------------------
# Sidecar loading
# --------------------------------------------------------------------------
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


def _read_localized_tags(path: str) -> list[dict[str, Any]]:
    if not os.path.exists(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (json.JSONDecodeError, OSError):
        return []
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        for key in ("tags", "price_tags"):
            value = payload.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
    return []


# --------------------------------------------------------------------------
# Per-frame / per-burst gate replay
# --------------------------------------------------------------------------
# Rejection codes are ordered by the sequence production code applies them.
GATE_ORDER = (
    "burst_incomplete",
    "insufficient_frames",
    "frame_needs_review",
    "measurement_unavailable",
    "localization_weak",
    "alignment_stale",
    "node_binding_missing",
    "no_stable_shelf_group",
)


@dataclass
class FrameVerdict:
    frame_id: str
    accepted: bool
    rejecting_gate: str | None = None
    measurement_method: str | None = None
    depth_sample_count: int = 0
    localization_state: str | None = None
    alignment_freshness: str | None = None
    has_node_binding: bool = False


@dataclass
class BurstVerdict:
    session: str
    burst_id: str
    barcode: str
    frame_count: int
    observed_duration_s: float
    accepted_frames: int
    stable_group_possible: bool
    resolved: bool
    rejecting_gate: str | None
    simulated_duration_s: float
    frames: list[FrameVerdict] = field(default_factory=list)


def _number(value: Any, default: float = 0.0) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    return float(value)


def evaluate_frame(
    observation: dict[str, Any], policy: CapturePolicy
) -> FrameVerdict:
    """Replay the frame-level gates that decide whether evidence is admitted."""
    method = observation.get("measurement_method")
    depth_samples = int(_number(observation.get("depth_sample_count")))
    localization_state = observation.get("localization_state")
    freshness = observation.get("alignment_freshness")
    has_node_binding = observation.get("bound_node_id") is not None
    needs_review = observation.get("needs_review") is True

    verdict = FrameVerdict(
        frame_id=str(observation.get("frame_id") or observation.get("observation_id") or ""),
        accepted=True,
        measurement_method=method if isinstance(method, str) else None,
        depth_sample_count=depth_samples,
        localization_state=localization_state if isinstance(localization_state, str) else None,
        alignment_freshness=freshness if isinstance(freshness, str) else None,
        has_node_binding=has_node_binding,
    )

    def reject(gate: str) -> FrameVerdict:
        verdict.accepted = False
        verdict.rejecting_gate = gate
        return verdict

    if policy.require_scene_depth and method != "scene_depth":
        # Production resolve() needs !needsReview, which scene-depth is the
        # only path capable of clearing in practice.
        return reject("measurement_unavailable")
    if method == "unavailable" and depth_samples == 0:
        return reject("measurement_unavailable")
    if not policy.allow_weak_localization and localization_state in {
        "weak",
        "lost",
        "recovering",
    }:
        return reject("localization_weak")
    if not policy.allow_aging_alignment and freshness != "fresh":
        return reject("alignment_stale")
    if not has_node_binding:
        return reject("node_binding_missing")
    if needs_review and policy.require_scene_depth:
        # Only reachable when the depth gate passed but review is still set.
        return reject("frame_needs_review")
    return verdict


def evaluate_burst(
    session: str,
    burst: dict[str, Any],
    observations_by_id: dict[str, dict[str, Any]],
    policy: CapturePolicy,
) -> BurstVerdict:
    burst_id = str(burst.get("burst_id") or "")
    frames = burst.get("frames")
    frames = frames if isinstance(frames, list) else []

    frame_verdicts: list[FrameVerdict] = []
    for frame in frames:
        if not isinstance(frame, dict):
            continue
        observation_id = frame.get("observation_id")
        observation = observations_by_id.get(str(observation_id)) if observation_id else None
        if observation is None:
            # Fall back to frame identity when observation sidecar is partial.
            observation = {
                "frame_id": frame.get("frame_id"),
                "observation_id": observation_id,
                "measurement_method": "scene_depth"
                if _number(frame.get("depth")) > 0
                else "shelf_plane_ray",
                "depth_sample_count": int(_number(frame.get("depth"))),
                "localization_state": frame.get("tracking"),
                "alignment_freshness": None,
                "bound_node_id": frame.get("bound_node_id"),
                "needs_review": True,
            }
        frame_verdicts.append(evaluate_frame(observation, policy))

    accepted = [item for item in frame_verdicts if item.accepted]
    first_ts = _number(burst.get("first_frame_timestamp"))
    last_ts = _number(burst.get("last_frame_timestamp"))
    observed_duration = max(0.0, last_ts - first_ts)

    complete = burst.get("complete") is True
    if not complete:
        return BurstVerdict(
            session=session,
            burst_id=burst_id,
            barcode=str(burst.get("barcode") or ""),
            frame_count=len(frame_verdicts),
            observed_duration_s=observed_duration,
            accepted_frames=len(accepted),
            stable_group_possible=False,
            resolved=False,
            rejecting_gate="burst_incomplete",
            simulated_duration_s=observed_duration,
            frames=frame_verdicts,
        )

    if len(accepted) < policy.minimum_evidence_frames:
        # The capture cannot reach quorum, so it runs until the deadline fires
        # and everything collected is thrown away. This is exactly the "dead
        # wait" operators complained about: the full window is paid for a
        # discarded result.
        return BurstVerdict(
            session=session,
            burst_id=burst_id,
            barcode=str(burst.get("barcode") or ""),
            frame_count=len(frame_verdicts),
            observed_duration_s=observed_duration,
            accepted_frames=len(accepted),
            stable_group_possible=False,
            resolved=False,
            rejecting_gate="insufficient_frames",
            simulated_duration_s=policy.maximum_capture_duration_s,
            frames=frame_verdicts,
        )

    # Shelf quorum: production resolve() requires minEvidenceFrames frames that
    # share one (shelfSegmentId, side) identity AND carry needsReview == false.
    # The observation sidecar does not persist the association result, so the
    # replay derives the ceiling from the frames that cleared admission.
    quorum_ready = len(accepted) >= policy.minimum_evidence_frames
    if policy.require_scene_depth and not quorum_ready:
        return BurstVerdict(
            session=session,
            burst_id=burst_id,
            barcode=str(burst.get("barcode") or ""),
            frame_count=len(frame_verdicts),
            observed_duration_s=observed_duration,
            accepted_frames=len(accepted),
            stable_group_possible=False,
            resolved=False,
            rejecting_gate="no_stable_shelf_group",
            simulated_duration_s=observed_duration,
            frames=frame_verdicts,
        )

    # Early exit: stop as soon as the target is reached, bounded below by the
    # minimum capture duration and above by the observed cadence.
    per_frame = observed_duration / len(frame_verdicts) if frame_verdicts else 0.0
    simulated = max(
        policy.minimum_capture_duration_s,
        min(policy.maximum_capture_duration_s, per_frame * policy.target_evidence_frames),
    )
    return BurstVerdict(
        session=session,
        burst_id=burst_id,
        barcode=str(burst.get("barcode") or ""),
        frame_count=len(frame_verdicts),
        observed_duration_s=observed_duration,
        accepted_frames=len(accepted),
        stable_group_possible=True,
        resolved=True,
        rejecting_gate=None,
        simulated_duration_s=simulated,
        frames=frame_verdicts,
    )


# --------------------------------------------------------------------------
# Session discovery + aggregation
# --------------------------------------------------------------------------
def discover_sessions(roots: Sequence[str]) -> list[str]:
    sessions: list[str] = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for current, dirnames, _ in os.walk(root):
            # Skip build artefacts and vendor trees.
            dirnames[:] = [
                d
                for d in dirnames
                if d not in {"build", ".git", "__pycache__", "Libraries", "node_modules"}
            ]
            if os.path.basename(current) == "segment_0001":
                sessions.append(current)
    return sorted(set(sessions))


@dataclass
class Report:
    policy_name: str
    sessions_scanned: int
    sessions_with_tags: int
    total_bursts: int
    resolved_bursts: int
    success_rate: float
    total_committed_tags: int
    gate_failures: dict[str, int]
    frame_gate_failures: dict[str, int]
    observed_duration_total_s: float
    simulated_duration_total_s: float
    simulated_duration_mean_s: float
    simulated_duration_median_s: float
    simulated_duration_p95_s: float
    wasted_wait_s: float
    per_session: list[dict[str, Any]] = field(default_factory=list)


def run(root: str | None, roots: Sequence[str], policy: CapturePolicy) -> Report:
    session_dirs = discover_sessions(roots)
    gate_failures: dict[str, int] = {gate: 0 for gate in GATE_ORDER}
    frame_gate_failures: dict[str, int] = {gate: 0 for gate in GATE_ORDER}
    verdicts: list[BurstVerdict] = []
    sessions_with_tags = 0
    total_committed = 0
    per_session: list[dict[str, Any]] = []

    for session_dir in session_dirs:
        observations = _read_jsonl(
            os.path.join(session_dir, "tag_observations.jsonl")
        )
        bursts = _read_jsonl(
            os.path.join(session_dir, "tag_observation_bursts.jsonl")
        )
        committed = _read_localized_tags(
            os.path.join(session_dir, "localized_price_tags.json")
        )
        total_committed += len(committed)
        if not bursts and not observations:
            continue
        sessions_with_tags += 1
        by_id = {
            str(item.get("observation_id")): item
            for item in observations
            if item.get("observation_id") is not None
        }
        session_name = os.path.basename(os.path.dirname(session_dir))
        session_verdicts = [
            evaluate_burst(session_name, burst, by_id, policy) for burst in bursts
        ]
        verdicts.extend(session_verdicts)
        session_ok = sum(1 for item in session_verdicts if item.resolved)
        per_session.append(
            {
                "session": session_name,
                "bursts": len(session_verdicts),
                "resolved": session_ok,
                "committed_tags": len(committed),
                "mean_simulated_duration_s": round(
                    statistics.mean(
                        [item.simulated_duration_s for item in session_verdicts]
                    ),
                    3,
                )
                if session_verdicts
                else 0.0,
            }
        )

    for verdict in verdicts:
        if verdict.rejecting_gate:
            gate_failures[verdict.rejecting_gate] = (
                gate_failures.get(verdict.rejecting_gate, 0) + 1
            )
        for frame in verdict.frames:
            if frame.rejecting_gate:
                frame_gate_failures[frame.rejecting_gate] = (
                    frame_gate_failures.get(frame.rejecting_gate, 0) + 1
                )

    resolved = [item for item in verdicts if item.resolved]
    sim = [item.simulated_duration_s for item in verdicts]
    obs = [item.observed_duration_s for item in verdicts]
    wasted = sum(
        max(0.0, item.simulated_duration_s - item.observed_duration_s)
        for item in verdicts
        if not item.resolved
    )
    total = len(verdicts)
    return Report(
        policy_name=policy.name,
        sessions_scanned=len(session_dirs),
        sessions_with_tags=sessions_with_tags,
        total_bursts=total,
        resolved_bursts=len(resolved),
        success_rate=(len(resolved) / total) if total else 0.0,
        total_committed_tags=total_committed,
        gate_failures=gate_failures,
        frame_gate_failures=frame_gate_failures,
        observed_duration_total_s=round(sum(obs), 3),
        simulated_duration_total_s=round(sum(sim), 3),
        simulated_duration_mean_s=round(statistics.mean(sim), 3) if sim else 0.0,
        simulated_duration_median_s=round(statistics.median(sim), 3) if sim else 0.0,
        simulated_duration_p95_s=round(sorted(sim)[max(0, int(len(sim) * 0.95) - 1)], 3)
        if sim
        else 0.0,
        wasted_wait_s=round(wasted, 3),
        per_session=per_session,
    )


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def _print(report: Report) -> None:
    print(f"\n=== policy: {report.policy_name} ===")
    print(f"会话扫描 {report.sessions_scanned}，含价签 {report.sessions_with_tags}")
    print(
        f"burst 总数 {report.total_bursts}，可解析 {report.resolved_bursts}，"
        f"成功率 {report.success_rate * 100:.1f}%"
    )
    print(f"实际已提交价签（现场真实产物）: {report.total_committed_tags}")
    print(
        f"耗时：合计 {report.simulated_duration_total_s:.1f}s，"
        f"均值 {report.simulated_duration_mean_s:.2f}s，"
        f"中位 {report.simulated_duration_median_s:.2f}s，"
        f"P95 {report.simulated_duration_p95_s:.2f}s"
    )
    print(f"失败空等累计 {report.wasted_wait_s:.1f}s")
    print("burst 级拒绝原因:")
    for gate, count in sorted(
        report.gate_failures.items(), key=lambda kv: -kv[1]
    ):
        if count:
            print(f"  {gate:<28}{count:>5}")
    print("frame 级拒绝原因:")
    for gate, count in sorted(
        report.frame_gate_failures.items(), key=lambda kv: -kv[1]
    ):
        if count:
            print(f"  {gate:<28}{count:>5}")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        action="append",
        default=[],
        help="Directory tree to scan for segment_0001 sessions (repeatable).",
    )
    parser.add_argument("--compare", action="store_true", help="Run both policies.")
    parser.add_argument("--json", dest="json_path", help="Write machine-readable report.")
    parser.add_argument(
        "--min-success-rate",
        type=float,
        help="Exit non-zero if the production policy falls below this rate.",
    )
    args = parser.parse_args(argv)

    roots = args.root or ["扫描结果", "PC处理结果"]
    roots = [root for root in roots if os.path.isdir(root)]
    if not roots:
        print("no scan roots found", file=sys.stderr)
        return 2

    policies = (
        [CapturePolicy.production(), CapturePolicy.optimized()]
        if args.compare
        else [CapturePolicy.production()]
    )
    reports = [run(roots[0], roots, policy) for policy in policies]
    for report in reports:
        _print(report)

    if args.compare and len(reports) == 2:
        base, opt = reports
        print("\n=== 优化对比 ===")
        print(
            f"成功率 {base.success_rate * 100:.1f}% -> {opt.success_rate * 100:.1f}%"
            f"  (+{(opt.success_rate - base.success_rate) * 100:.1f}pt)"
        )
        print(
            f"均值耗时 {base.simulated_duration_mean_s:.2f}s -> "
            f"{opt.simulated_duration_mean_s:.2f}s"
            f"  ({(opt.simulated_duration_mean_s - base.simulated_duration_mean_s) / max(base.simulated_duration_mean_s, 1e-9) * 100:+.1f}%)"
        )
        print(
            f"合计耗时 {base.simulated_duration_total_s:.1f}s -> "
            f"{opt.simulated_duration_total_s:.1f}s"
            f"  ({(opt.simulated_duration_total_s - base.simulated_duration_total_s) / max(base.simulated_duration_total_s, 1e-9) * 100:+.1f}%)"
        )
        print(
            f"失败空等 {base.wasted_wait_s:.1f}s -> {opt.wasted_wait_s:.1f}s"
            f"  ({(opt.wasted_wait_s - base.wasted_wait_s) / max(base.wasted_wait_s, 1e-9) * 100:+.1f}%)"
        )

    if args.json_path:
        payload = [asdict(report) for report in reports]
        with open(args.json_path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
        print(f"\nwrote {args.json_path}")

    if args.min_success_rate is not None:
        production = reports[0]
        if production.success_rate < args.min_success_rate:
            print(
                f"FAIL: production success rate {production.success_rate:.3f} "
                f"< required {args.min_success_rate:.3f}",
                file=sys.stderr,
            )
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
