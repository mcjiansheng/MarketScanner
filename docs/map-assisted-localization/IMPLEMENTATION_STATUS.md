# 地图辅助定位实现状态

> 文档状态：**当前有效**。最后核对日期：2026-07-24。

## 阶段一

| 能力 | 状态 | 代码/证据 |
| --- | --- | --- |
| XLSX 六类元素解析 | 已实现 | `tools/PriorMap/xlsx_reader.py`、转换测试、用户样例实转 |
| 唯一坐标/几何模块 | 已实现 | `coordinate_system.py`、90° golden 测试 |
| 版本化地图包、SHA-256、schema | 已实现 | 全文件解析、跨文件一致性、损坏包负向测试 |
| 道路图和有界空间索引 | 已实现 | road graph + 5 m structure/road grid，大索引查询测试 |
| dependency-free PNG 预览 | 已实现 | 默认兼容图 + 每层独立预览、PNG 解码校验 |
| PC 导入、进度、统计、warning、缩放预览 | 已实现 | Map Studio API/Web 和 API 测试 |
| iOS 双模式入口 | 已实现 | 新建按钮与菜单入口；自由模式默认流程不变 |
| iOS 五步向导 | 已实现 | 地图、楼层、起点/方向、设备检查、开始 |
| iOS 道路锚点快捷起点 | 已实现 | 起点步骤可从当前楼层道路节点选择锚点 |
| prior-map 仍写连续 RTAB-Map DB | 已实现 | 复用 `newScan`/`streamingDatabaseURL` |
| T_map_from_arkit 与 2D HUD | 已实现 | `PriorMapStageOneLocalizer`/`PriorMapLiveMapView` |
| 单楼层定位边界 | 已实现 | 开始前绑定一层；无跨层切换；忽略二维高度但保留原始 3D |
| 道路软约束、歧义拒绝 | 已实现 | 2 Hz、有界道路索引、in-flight 丢帧门控、0.15 gain、0.25 m cap、Top-3 |
| 人工确认和审计 | 已实现 | manual JSONL + scan event |
| synthetic/trajectory replay | 已实现 | 平移/旋转 drift、XY/yaw 误差、tracking loss、道路分配 |
| 旧会话和自由扫描兼容 | 已实现 | storage/workflow 分字段、PC regression |
| 完整业务首页五入口 | 部分实现 | 现有首页/菜单保留；新建扫描双模式已完成，独立“先验地图”首页入口尚未拆出 |
| 预定路线导入 | 未实现 | 可选增强项；当前只有道路图合成遍历和回放 |
| iOS 核心契约测试 | 已实现 | ARKit 前后左右/非零原点金标、模式门控和 SE(2) 投影 |

## 明确未实现

- LiDAR/视觉结构自动地图匹配；
- 距离场、Top-K 跨帧假设和定位状态滞回；
- Vision 二维码/条形码；
- 价签射线、深度、货架平面和货架侧面关联；
- PC 辅助扫描轨迹/价签人工复核；
- 正式超市场景验收。

这些属于阶段二/三，UI 和文档不得表述为已完成。

## 阶段二

| 能力 | 状态 | 代码/证据 |
| --- | --- | --- |
| 线程、状态、距离场与失败策略 | 设计完成 | `STAGE_2_DESIGN.md`；实现与测试待完成 |
| 深度结构提取和扫描匹配 | 未实现 | 待实现 |
| Vision QR/条形码识别 | 未实现 | 待实现 |
| 标签三维测量与货架关联 | 未实现 | 待实现 |
| 阶段二 sidecar 和移动 UI | 未实现 | 待实现 |
| 阶段二回放与指标 | 未实现 | 待实现 |

## 兼容说明

实施 Prompt 建议把业务模式直接写入 `scanMode`，但当前生产协议用 `scanMode=continuous_streaming` 判定单库安全处理。阶段一因此新增 `workflowMode` 承载 `free_mapping/prior_map_localized`，保留原 storage marker。这是为了满足“不破坏自由扫描和旧 PC 流程”的更高优先级约束。
