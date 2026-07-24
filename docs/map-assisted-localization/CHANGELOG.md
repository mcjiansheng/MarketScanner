# 地图辅助定位变更记录

> 文档状态：**当前有效**。最后核对日期：2026-07-24。

## 2026-07-24 — 阶段一

- 根据独立代码审查修正 ARKit 水平坐标/yaw 与地图/UI 约定，并增加方向金标测试。
- 校验器扩展为全 JSON/PNG 解析和跨文件一致性校验，补充损坏包负向测试。
- 道路边加入空间索引，iOS 使用附近候选并增加 in-flight 丢帧门控。
- iOS 地图缓存改为临时校验后原子替换；设备检查不再把未启动的 ARKit tracking 写成成功。
- 回放的旋转漂移现在同时影响 XY 轨迹并输出 yaw 误差。
- 明确一次扫描只绑定一个楼层；楼层内少量竖直位移忽略于二维先验定位、保留于原始三维数据；新增逐楼层预览。
- 新增 dependency-free XLSX 先验地图转换、校验和 PNG 渲染。
- 定义 version 1 地图包、统一米制 SE(2)、道路图和空间索引。
- Map Studio 新增先验地图异步导入、校验、统计和缩放预览。
- iOS 新增自由扫描/已有地图辅助扫描双模式和五步向导。
- 新增 ARKit 初始投影、道路软约束、候选/置信状态 HUD 和人工确认审计。
- 新增 localization trace、manual event 和 metadata/checkpoint 字段。
- 新增 synthetic/trajectory replay 及阶段一测试。
- 保留 `scanMode=continuous_streaming`，新增 `workflowMode`，确保旧连续单库流程兼容。
- NFC 仍保持暂停；未加入 LiDAR 自动匹配或价签扫码。
