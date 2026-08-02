# MarketScanner 当前代码审查入口

> 文档状态：**当前有效**。最后核对日期：2026-08-02。
> 外部审查输入：`MarketScanner_P7R2_Sam_Global_Alignment_Fix_Prompt.md`。
> 前序审查输入：`MarketScanner_P7R1_Agent_Repair_Prompts.md`（仅用于历史连续性）。
> 冻结基线：`repair-v2-w2r-safety-closeout@cf1b62c949f3574e1804808537e38c8ff643549c`。
> P7R1 审查基线：`repair-v2-p7r0-independent-baseline@79c86b120fc47c28bd350e86abc9b0354d7e838d`。
> P7R1 实施/治理历史：`b1d0089a0a0b3e32b2f2ad404c88aa21e141b420` / `b7f75ee81656a5104dcebe75720486db72f05109`。
> P7R2 基线：`repair-v2-p7r1-evidence-publication-closeout@b7f75ee81656a5104dcebe75720486db72f05109`。
> 当前实施分支：`repair-v2-p7r2-sam-global-alignment-fix`。
> P7R2 代码提交：`0a2a3ec50a851d52f96120a8f3d1669a7797e34e`；其后只允许文档和 wave 绑定提交。

当前权威审查为 [Production Readiness Review](PRODUCTION_READINESS_REVIEW.md)。

当前结论仍是 **NO-GO / NOT PRODUCTION READY**。P7R2 已在代码和自动测试层修复 Sam 后续审查发现的在线全局对齐错误：hypothesis 不再跟踪会随手机转向变化的 body-local translation，而是跟踪固定的 `T_map_from_arkit = T_candidate_map × inverse(T_arkit)`；平移使用 `t_candidate - R(theta)t_arkit`，yaw 使用最短角插值。localizer 用平滑后的全局变换重新投影当前 ARKit 位姿，再执行局部 0.35 m/8°或恢复 5 m/30°安全门和 0.35 m/8°单步限幅。可靠 RTAB-Map 闭环只授权 20 帧恢复搜索，不直接注入位姿；人工确认清空历史 hypothesis；HUD 继续只绘制 `estimatedPose`。旧的局部修正数学和未接线 temporal gate 已删除。

本地自动证据覆盖 identity、纯平移、0/90/180°、组合转动平移、±π、蛇形转弯、转弯时错误高分通道、等分平行通道保守拒绝、短时动态遮挡、4 帧恢复、5 m/30°边界、5.01 m/30.1°拒绝、人工 reset，以及 100 组确定性随机重建；重建误差门为 `1e-9`。`localization_trace` v1 增加向后兼容的可选全局对齐/track/cost/reason/耗时诊断。Sam 修复版 iPhone 真机重扫尚未执行。

状态必须分开记录：上述为 **IMPLEMENTED / AUTOMATED TESTED**。本文编写时最终治理 HEAD 尚未生成，七组 Repair V2 Actions 的 exact-SHA 结果为 **PENDING**；只有最终精确 40 位 SHA 全绿后才可标记 **CI VERIFIED / READY FOR HUMAN SAM RE-TEST**。当前没有 **HUMAN REVIEWED / REAL DEVICE PASS / FIELD PASS / PRODUCTION QUALIFIED**。仓库质量策略仍有意保持 `candidate`，必须由真实 P5/P6 数据分布和 P8 人工审查冻结。剩余真实工作仍是修复版 Sam 重扫、LiDAR iPhone 矩阵、办公室与超市各三次现场资格、干净 macOS/Windows 交付 smoke/签名策略和最终独立发布审计。

历史审查见 [`history/`](history/)，只适用于各自声明的旧 SHA。
