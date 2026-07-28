# MarketScanner 当前代码审查入口

> 文档状态：**当前有效**。最后核对日期：2026-07-28。
> 外部审查输入：`MarketScanner_RepairV2_W2R_Production_Readiness_Code_Review_and_Final_Product_Agent_Spec_2026-07-28.md`。
> 冻结基线：`repair-v2-w2r-safety-closeout@cf1b62c949f3574e1804808537e38c8ff643549c`。
> 当前实施分支：`repair-v2-p3-persistent-mapstudio-jobs`。

当前权威审查为 [Production Readiness Review](PRODUCTION_READINESS_REVIEW.md)。

当前结论是 **NO-GO / NOT PRODUCTION READY**。P1 已实现完整相对 SE(2) 因子图；P2 本机 macOS clean build 已通过并建立 hosted clean/iOS dependency build 合同；P3 已实现持久任务、重启中断判定、取消和日志留存。真实 LiDAR iPhone、正式现场验收、P4 hardening、安装包和独立复核仍未完成。

历史审查见 [`history/`](history/)，只适用于各自声明的旧 SHA。
