# MarketScanner current code-review entry point

> Document status: **当前有效 / current and authoritative**. Last reconciled: 2026-08-03.
> External review input: `MarketScanner_P7R4_Recovery_Confidence_Closeout_Prompt.md`.
> Historical predecessor input: `MarketScanner_P7R1_Agent_Repair_Prompts.md`.
> Production-readiness frozen baseline: `repair-v2-w2r-safety-closeout@cf1b62c949f3574e1804808537e38c8ff643549c`.
> P7R1 review baseline: `repair-v2-p7r0-independent-baseline@79c86b120fc47c28bd350e86abc9b0354d7e838d`.
> P7R3 cloud base at task start: `repair-v2-p7r3-recovery-episode-closeout@998c175e40562fffd85fe45579a358c485a65b30`.
> Current implementation branch: `repair-v2-p7r4-recovery-confidence-closeout`.
> P7R4 production implementation: `38831fab26b66ce31f7d86e29ea600d47a19b934`; later test/governance commits must not silently modify production code.

The authoritative release judgment remains [Production Readiness Review](PRODUCTION_READINESS_REVIEW.md): **NO-GO / NOT PRODUCTION READY**.

P7R4 separates measurement acceptance, hypothesis trust, bounded correction application, Recovery convergence, confidence acceptance, and formal constraint disposition. Intermediate Recovery steps are provisional and keep the UI in `recovering`; timeout frames remain weak. A convergence frame is capped at `usable`, followed by at least three consecutive ordinary Local trusted frames before `stable`. Any rejection resets that post-Recovery counter. Only `stable` may authorize automatic tag confirmation.

The 30-second monotonic deadline is checked before and after matching. A matcher result that crosses the deadline may count as a real attempt but cannot mutate the alignment. Attempt 40 may retain a safe bounded anchor step, but its constraint remains provisional and the outcome remains `timed_out` when residual convergence was not reached. Automatic weak/lost Recovery has a centralized 20-second cooldown; reliable RTAB-Map loop closure may bypass only that cooldown and still cannot reset or duplicate an active episode.

Completion diagnostics are bound to the completed episode and kept separate from current Local hypotheses. `PriorMapScanMatchResult.searchPerformed` is the single source for valid-attempt accounting, with `PriorMapScanMatcher.minimumSearchPointCount = 30`. The production-shared update reducer joins frame disposition, monotonic expiry, attempt exhaustion, correction/constraint acceptance, Recovery action, next confidence phase, and diagnostics; limited/no-depth/nil/undersized/busy/throttled frames consume wall time but not attempts, timeout enters and remains weak through cooldown, and exact cooldown expiry permits a new automatic episode. The localizer's production anchor is exercised through competing A/B Recovery, bounded B convergence, track cleanup, and the next ordinary Local frame. The PC reader rejects any provisional disposition marked formally accepted.

Current status: **IMPLEMENTED / focused AUTOMATED TESTED**. Windows cannot establish Xcode, UIKit, ARKit, LiDAR, or real-device PASS. Exact-final-SHA CI and the independent read-only review are still required before `READY FOR HUMAN SAM RE-TEST` may be declared. Historical reviews remain under [`history/`](history/).
