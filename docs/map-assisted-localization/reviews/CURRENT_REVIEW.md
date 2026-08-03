# MarketScanner 当前代码审查入口

> 文档状态：**当前有效**。最后核对日期：2026-08-03。
> 外部审查输入：`MarketScanner_P7R3_Recovery_Episode_Closeout_Prompt.md`。
> 前序审查输入：`MarketScanner_P7R1_Agent_Repair_Prompts.md`（仅用于历史连续性）。
> 生产化冻结基线：`repair-v2-w2r-safety-closeout@cf1b62c949f3574e1804808537e38c8ff643549c`。
> P7R1 审查基线：`repair-v2-p7r0-independent-baseline@79c86b120fc47c28bd350e86abc9b0354d7e838d`。
> P7R2 分支基线：`repair-v2-p7r2-sam-global-alignment-fix@c3401759aadf2015873ae15e826b6a9a1f3c4ba0`。
> P7R2 全局对齐代码：`0a2a3ec50a851d52f96120a8f3d1669a7797e34e`。
> 当前实施分支：`repair-v2-p7r3-recovery-episode-closeout`。
> P7R3 Recovery episode 代码：`0e2ce5133c8fb261fc1756111a5173c71d15b380`；后续治理提交不得改变生产代码。

当前权威审查仍为 [Production Readiness Review](PRODUCTION_READINESS_REVIEW.md)。发布判定仍是 **NO-GO / NOT PRODUCTION READY**。

P7R2 的全局 `T_map_from_arkit = T_candidate_map × inverse(T_arkit)` 数学保持不变。P7R3 关闭四个代码缺口：新 Recovery episode 在首次 trigger 时 reset tracker、保留已应用 anchor 并要求 4 个 fresh observations；历史 local support 不再使 Recovery 首帧可信或压制新正确通道；预算只在 matcher 得到至少 30 个 effective points 后消耗，并同时受 40 valid attempts/30 s 限制；converged/timed-out/cancelled/manual-reset 统一清除 wide-search tracks。repeated trigger 只增加有界 trigger count，不改变 ID、deadline、attempt 或 fresh support。supportFrames 饱和为 120。

5 m/30° Recovery 总安全门、0.35 m/8° bounded step、低唯一性平行通道 fail closed、loop closure 只授权搜索、manual correction reset、corrected HUD、原始 ARKit/RTAB-Map trajectory 和自由扫描模式均未改变。候选测试 score 统一使用生产公式 `exp(-cost/0.08)`。

Windows 已执行的定向证据为 source/sidecar 15/15 PASS、PriorMap Python 20/20 PASS；Swift host 1 项因无 `xcrun` 明确延期。完整 Windows baseline 中 symlink 权限和 CMake 缺失属于环境项，详见 `P7R3_WINDOWS_HANDOFF.md`。`PYTHON MODEL PASS != SWIFT PRODUCTION CODE EXECUTED`。

状态是 **WINDOWS IMPLEMENTATION COMPLETE — MACOS/IOS VALIDATION DEFERRED**。最终治理 HEAD 的七组 exact-SHA Repair V2 Actions、独立只读审查、Xcode/Swift host、LiDAR iPhone 与 Sam 三组重扫尚未完成，因此当前不得标记 **CI VERIFIED / READY FOR HUMAN SAM RE-TEST / REAL DEVICE PASS / FIELD PASS / PRODUCTION QUALIFIED**。

历史审查见 [`history/`](history/)，只适用于各自声明的旧 SHA。
