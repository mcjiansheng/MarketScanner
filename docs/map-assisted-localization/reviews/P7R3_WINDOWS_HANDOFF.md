# P7R3 Windows-to-macOS handoff

> Windows implementation SHA: `0e2ce5133c8fb261fc1756111a5173c71d15b380`
> Branch: `repair-v2-p7r3-recovery-episode-closeout`
> Base: `repair-v2-p7r2-sam-global-alignment-fix@c3401759aadf2015873ae15e826b6a9a1f3c4ba0`
> Local decision: **WINDOWS IMPLEMENTATION COMPLETE — MACOS/IOS VALIDATION DEFERRED**

## Completed on Windows

- Replaced `recoveryFramesRemaining/recoveryReason` with a platform-neutral Recovery controller and explicit `inactive -> active -> converged | timed_out | cancelled | manual_reset` outcomes.
- Reset tracker history only on a new episode, retained the applied map/ARKit anchor, required 4 fresh observations, saturated support at 120, and cleared wide-search tracks on every exit.
- Counted only actual matcher searches with at least 30 effective points; configured 40 valid attempts plus a 30-second wall-clock deadline. Repeated triggers preserve ID, deadline, budget, and support.
- Added optional trace diagnostics for episode identity/reason/outcome/attempts/elapsed/fresh support/trigger count.
- Added R1—R12 Swift regression scenarios and Windows source contracts; score fixtures use `exp(-cost/0.08)`.

## Windows commands and results

| Command | Result | Log |
| --- | --- | --- |
| Python compile over 30 explicitly expanded files | PASS | `artifacts/windows-baseline/python-compile-expanded.log` |
| Import `tools.PriorMap.localized_output_store` | PASS | `artifacts/windows-baseline/prior-map-import.log` |
| Import `tools.SupermarketMapStudio.server` | PASS | `artifacts/windows-baseline/map-studio-import.log` |
| `python -m unittest -v tools.PriorMap.tests.test_ios_sidecar_health_contract` | PASS, 15/15 | `artifacts/windows-p7r3/sidecar-contract.log` |
| `python -m unittest -v tools.PriorMap.tests.test_prior_map` | PASS, 20/20; 1 macOS-only skip | `artifacts/windows-p7r3/prior-map-core-tests.log` |
| `node --check tools/SupermarketMapStudio/web/app.js` | PASS | `artifacts/windows-baseline/node-check.log` |
| `git diff --check` | PASS | `artifacts/windows-baseline/git-diff-check.log` |

The full post-change rerun found 1/123 PriorMap error (plus the expected Swift-host skip), 1/11 Qualification error, and 5/94 Map Studio errors. Every error is `WinError 1314` from a negative test attempting to create a symbolic link; Developer Mode/admin policy was not changed and the tests were not weakened. An elevated normal-user shell found CMake 3.30.5 at `AppData/Local/Programs/Python/Python312/Scripts/cmake.exe`, and the three earlier CMake-dependent release-manifest errors passed there; the Codex sandbox omits that path. Ninja, MSVC on PATH, GitHub CLI, 7-Zip CLI, and winget remain unavailable. No native/CMake production code changed, so local native build was not required. Remote CI remains required.

## Deferred macOS/iOS validation

| ID | Not executed on Windows | Exact macOS action | Expected result / collect on failure |
| --- | --- | --- | --- |
| M1 | Xcode project resolution and full Swift compile | Open the workspace/project, select RTABMapApp, resolve packages, then build | No parse/type/link errors; collect build log and resolved dependency versions |
| M2 | Generic arm64 Release App link | Run the repository CI-equivalent `xcodebuild` generic iOS Release command | Unsigned arm64 App links; collect `.xcresult` and linker log |
| M3 | Swift host contract executable | Run `python3 -m unittest -v tools.PriorMap.tests.test_prior_map.IOSCoreContractTests.test_swift_workflow_state_and_se2_projection` | R1—R12 and P7R2 T/S cases pass; collect swiftc command/stdout/stderr |
| M4 | UIKit manual relocation | Build/run map click/drag/rotate confirmation during active Recovery | outcome `manual_reset`, tracks cleared, next support 1; collect console and sidecars |
| M5 | ARKit lifecycle/depth/async matcher | Exercise normal/limited/no-depth, background/foreground, and stale generation | Invalid frames consume no attempt; stale work cannot revive episode; collect trace/events |
| M6 | LiDAR iPhone Recovery | Run 5 m/30° bounded Recovery with dropped/occluded frames | Four fresh support, <=0.35 m/8° steps, converged or explicit safe timeout |
| M7 | Sanitizers | Run Thread Sanitizer and applicable Address Sanitizer targets | No race/use-after-free; collect sanitizer reports |
| M8 | Instruments | Allocations, Leaks, Time Profiler, Energy Log, thermal/memory run | No unbounded track/support growth or queue buildup; export traces |
| M9 | Sam field samples | Same-route, Recovery-specific, and occlusion routes from the P7R3 prompt | Capture full session, screen recording, DB, trace/constraints/events and PC result |
| M10 | Distribution/lifecycle | Sign/install, background/foreground, kill/relaunch, low disk, thermal serious | Safe checkpoint/finalization behavior; collect device/sysdiagnose/App logs |

These deferred items are not PASS and are not evidence of Swift runtime correctness. Remote macOS/iOS compilation reduces compile risk but does not replace local Xcode debugging or LiDAR iPhone validation.

## Required exact-SHA CI

Push the branch, identify the run whose head SHA equals the final governance HEAD, and require all seven groups: P0 invariants; Ubuntu Python/API/Web; Windows Python/contracts; Native ABI; Ubuntu clean native; Windows clean native; macOS/iOS cold-cache full build. Record run ID, job URLs, conclusions, and exact SHA here or in the final report. Do not reuse a green result from another SHA.

## Known risks

- Production Swift has not been parsed, type-checked, linked, or executed on this Windows machine.
- UIKit/ARKit/sceneDepth concurrency and cancellation behavior require Apple runtime validation.
- No LiDAR iPhone or Sam route evidence exists for P7R3.
- Full local Windows suites still depend on symlink privilege; CMake 3.30.5 is available only in the normal-user PATH observed outside the sandbox.
