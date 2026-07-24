# 地图辅助定位变更记录

> 文档状态：**当前有效**。最后核对日期：2026-07-24。

## 2026-07-24 — 阶段一

- 新增 dependency-free XLSX 先验地图转换、校验和 PNG 渲染。
- 定义 version 1 地图包、统一米制 SE(2)、道路图和空间索引。
- Map Studio 新增先验地图异步导入、校验、统计和缩放预览。
- iOS 新增自由扫描/已有地图辅助扫描双模式和五步向导。
- 新增 ARKit 初始投影、道路软约束、候选/置信状态 HUD 和人工确认审计。
- 新增 localization trace、manual event 和 metadata/checkpoint 字段。
- 新增 synthetic/trajectory replay 及阶段一测试。
- 保留 `scanMode=continuous_streaming`，新增 `workflowMode`，确保旧连续单库流程兼容。
- NFC 仍保持暂停；未加入 LiDAR 自动匹配或价签扫码。
