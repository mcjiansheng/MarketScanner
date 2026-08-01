# MarketScanner 当前代码审查入口

> 文档状态：**当前有效**。最后核对日期：2026-07-30。
> 外部审查输入：`MarketScanner_P7R1_Agent_Repair_Prompts.md`。
> 冻结基线：`repair-v2-w2r-safety-closeout@cf1b62c949f3574e1804808537e38c8ff643549c`。
> P7R1 审查基线：`repair-v2-p7r0-independent-baseline@79c86b120fc47c28bd350e86abc9b0354d7e838d`。
> 当前实施分支：`repair-v2-p7r1-evidence-publication-closeout`。
> P7R1 累计代码提交：`e9940996f13627fb25329eb78c921c7b3f4eadfc`；其后仅允许治理文档/wave 绑定提交。

当前权威审查为 [Production Readiness Review](PRODUCTION_READINESS_REVIEW.md)。

当前结论仍是 **NO-GO / NOT PRODUCTION READY**。P7R1 已在代码和自动测试层关闭 production publication/evidence integrity finding：development API/CLI 无条件禁止 publish；production 在调用 store 前重跑真实 selfcheck并使用 package-bound release；Device App SHA 精确绑定 release SHA；Field v3 不再接受自由 trajectory JSON，而从 exact immutable version 生成 typed evidence，并自包含 plan/release/policy、trajectory source、控制点 CSV 和 Device Evidence exact bytes供重新派生；JSON/CSV 和 package diagnostics 使用同一 descriptor 的 exact bytes 完成解析与 SHA；稳定读取在 Windows 上强制 `O_BINARY` 保留 CRLF 原始字节，分别比较 path-stat 与 handle-fstat 的读取前后身份，并在主 descriptor 保持打开时用同类 path descriptor 于读取前后完成文件身份绑定，避免跨 API 元数据表示差异造成误拒绝，同时拒绝同尺寸替换、临时替换后恢复和读取中篡改；published manifest v4 自包含 accepted Field Evidence 和 qualification manifest；About 使用真实 runtime mode。`evidenceSha256` 明确只是完整性校验，V1 依赖实际操作者 attestation 与独立 reviewer 原始包复核，不宣称具有数字签名能力。

状态必须分开记录：上述为 **IMPLEMENTED / AUTOMATED TESTED**；只有本分支最终精确 40 位 SHA 的七组 Repair V2 Actions 全绿后才是 **CI VERIFIED / READY FOR HUMAN QUALIFICATION**。当前没有 **HUMAN REVIEWED / REAL DEVICE PASS / FIELD PASS / PRODUCTION QUALIFIED**。仓库质量策略仍有意保持 `candidate`，必须由真实 P5/P6 数据分布和 P8 人工审查冻结。剩余真实工作仍是 LiDAR iPhone 矩阵、办公室与超市各三次现场资格、干净 macOS/Windows 交付 smoke/签名策略和最终独立发布审计。

历史审查见 [`history/`](history/)，只适用于各自声明的旧 SHA。
