# MarketScanner 当前代码审查入口

> 文档状态：**当前有效**。最后核对日期：2026-07-28。
> 外部审查输入：`MarketScanner_RepairV2_W2R_Production_Readiness_Code_Review_and_Final_Product_Agent_Spec_2026-07-28.md`。
> 冻结基线：`repair-v2-w2r-safety-closeout@cf1b62c949f3574e1804808537e38c8ff643549c`。
> 当前实施分支：`repair-v2-p1-relative-se2-factor-graph`。

当前权威审查为 [Production Readiness Review](PRODUCTION_READINESS_REVIEW.md)。

当前结论是 **NO-GO / NOT PRODUCTION READY**。P1 已实现完整相对 SE(2) 因子图并完成本机真实 DB 只读验证，但可复现干净构建、真实 LiDAR iPhone 验证、正式现场验收和 Map Studio 持久任务恢复尚未完成。任何自动测试、模拟回放或既有构建成功都不得替代这些发布证据。

历史审查见 [`history/`](history/)，只适用于各自声明的旧 SHA。
