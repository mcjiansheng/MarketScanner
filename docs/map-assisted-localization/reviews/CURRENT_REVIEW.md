# MarketScanner 当前代码审查入口

> 文档状态：**当前有效**。最后核对日期：2026-07-30。
> 外部审查输入：`MarketScanner_RepairV2_P7_Independent_Production_Code_Review_and_AI_Execution_Spec_2026-07-30.md`。
> 冻结基线：`repair-v2-w2r-safety-closeout@cf1b62c949f3574e1804808537e38c8ff643549c`。
> 当前实施分支：`repair-v2-p7r0-independent-baseline`。
> 当前累计代码基线：`02c44caa65456bce33109d0ce45af7dd67a6df2f`。

当前权威审查为 [Production Readiness Review](PRODUCTION_READINESS_REVIEW.md)。

当前结论仍是 **NO-GO / NOT PRODUCTION READY**。P7R0 代码关闭了真实 Field Evidence 发布绑定、raw session identity、duplicate run/link、显式 prior uncertainty、因子图数值质量门、敏感 GET session、严格 production mode、平台 app-data journal、残差审计命名和 localized tags V1 内存上限。仓库质量策略有意保持 `candidate`，生产模式/发布会失败关闭；必须由真实 P5/P6 数据分布和 P8 人工审查冻结。剩余工作均为人工/外部环境：真实 LiDAR iPhone 矩阵、办公室与超市各三次现场资格、干净 macOS/Windows 交付 smoke/签名策略和最终独立发布审计。

历史审查见 [`history/`](history/)，只适用于各自声明的旧 SHA。
