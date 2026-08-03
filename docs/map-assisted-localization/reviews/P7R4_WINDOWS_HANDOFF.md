# P7R4 Windows-to-macOS handoff

> Production implementation SHA: `218f3ef69a5b68e3e317a4300ed76dd606cb531e`
> Branch: `repair-v2-p7r4-recovery-confidence-closeout`
> Cloud base: `repair-v2-p7r3-recovery-episode-closeout@998c175e40562fffd85fe45579a358c485a65b30`
> Windows decision: **IMPLEMENTED / FOCUSED AUTOMATED TESTED — DEFERRED_MACOS_EXECUTION**

## Implemented

- Split scan measurement, trusted hypothesis, bounded correction, Recovery convergence, confidence acceptance, and formal constraint disposition.
- Mark intermediate and final-attempt non-converged Recovery steps `provisional_recovery_step`; legacy `accepted` stays false.
- Keep active Recovery in `recovering`, timeout in `weak`, convergence at most `usable`, and require three ordinary Local trusted frames for `stable`; rejection resets the counter.
- Check the injected monotonic clock before and after matcher execution. A deadline-crossing result counts as a searched attempt but cannot apply a new correction; equality with the deadline is expired.
- Add a centralized 20-second automatic weak/lost cooldown. Reliable loop closure may bypass cooldown but only merges when an episode is active.
- Bind completion time, episode hypothesis, fresh support, residual, and completion-frame step state to immutable completion diagnostics. Do not flatten them into a new Local hypothesis.
- Make matcher `searchPerformed`/attempt disposition authoritative and centralize the 30-point threshold.
- Persist backward-compatible trace/constraint fields and reject contradictory provisional/accepted records in the PC reader.
- Require `stable` (not `usable`) for automatic price-tag confirmation.
- Route the real Stage One alignment through a production-shared anchor, frame-disposition attempt reducer, and completion/current-hypothesis binder so T10/T11/T12 exercise the same code as the localizer.

## Windows validation evidence

| Command | Result |
| --- | --- |
| Expanded `python -m py_compile` over PriorMap, Qualification, and Map Studio modules | PASS |
| `node --check tools/SupermarketMapStudio/web/app.js` | PASS |
| P7R4 focused iOS source contracts plus PC disposition test | PASS, 16/16 |
| Full PriorMap suite | 124 total: 122 PASS, 1 ERROR before assertion (`WinError 1314` symlink fixture), 1 SKIP (`xcrun` absent) |
| Full Qualification suite | 11 total: 10 PASS, 1 ERROR before assertion (`WinError 1314` symlink fixture), 0 SKIP |
| Full Map Studio suite outside sandbox | 94 total: 89 PASS, 5 ERROR before assertion (`WinError 1314` symlink fixtures), 0 SKIP |
| Swift host executable | `DEFERRED_MACOS_EXECUTION` (`xcrun` unavailable) |
| Post-review source contracts | PASS, 15/15 |
| Post-review Stage3 executable assertions | 54 PASS; 1 ERROR before assertion (`WinError 1314` symlink fixture) |

The first independent read-only review rejected the earlier test-only evidence because T10/T11/T12/T14 did not exercise the required integration boundaries. Production implementation `14f2b45fb23b9485e1065d1faf572de51dfae909` and test commit `e6c2959f7eae3b0b9feb81b35ce5364effbcaca1` closed those gaps. The second review then rejected missing end-to-end timeout/weak/cooldown state paths. Final production implementation `218f3ef69a5b68e3e317a4300ed76dd606cb531e` and test commit `90d0b5c48cec25d06d3cc7a48979ee2eb2b0e0e9` route T5/T6/T8/T12 through the same update reducer as `update(frame:)`. A new exact-final-SHA CI run and independent re-review are mandatory; earlier green runs cannot qualify this newer SHA.

## Required Apple/CI validation

1. Compile and execute `tools/PriorMap/tests/swift/main.swift` against the production Swift sources; all P7R2/P7R3 and P7R4 T1–T15 assertions must pass.
2. Run the unsigned generic arm64 Release link and the full cold-cache iOS build.
3. Exercise ARKit normal/limited/no-depth, background/foreground, and matcher-deadline crossing with the injected clock seam.
4. On LiDAR iPhone, verify intermediate 5 m Recovery steps never show stable or auto-confirm tags, convergence enters usable, three Local frames restore stable, and timeout/cooldown remain fail closed.
5. Preserve DB/ARKit trajectory immutability and verify the converged B anchor is retained after wide-track cleanup.
6. Run exact-final-SHA seven-group Repair V2 CI and record run/job IDs and conclusions.

None of these deferred items is PASS. Remote compilation does not replace local Xcode debugging or real-device/Sam evidence.
