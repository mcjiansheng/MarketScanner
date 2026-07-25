# 地图辅助定位实现状态

> 文档状态：**当前有效**。最后核对日期：2026-07-25。

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

## 阶段二

| 能力 | 状态 | 代码/证据 |
| --- | --- | --- |
| 线程、状态、距离场与失败策略 | 已实现 | `STAGE_2_DESIGN.md`、`PriorMapScanMatcher.swift`、in-flight gate |
| 多分辨率确定性距离场 | 已实现 | 0.40/0.20/0.10 m、2 m 截断、RLE、逐层 SHA-256、schema 负向测试 |
| 深度结构提取和扫描匹配 | 已实现 | scene depth、跨帧 voxel 证据、600 点上限、粗中细多盆地传播、全窗真实次佳 Top‑3、周期结构保守拒绝 |
| 状态和置信度滞回 | 已实现 | initializing/stable/usable/weak/lost/manualCorrection；连续可信和 stale 门限集中管理 |
| Vision QR/条形码识别 | 已实现 | 用户触发；复用 `ARFrame.capturedImage`；捕获时对齐快照与版本；四方向 ROI；QR/EAN/Code128/UPCE/PDF417 |
| 标签三维测量与结构关联 | 已实现 | 同帧 depth；楼面法向/残差/时序置信度；货架/柜台；跨结构遮挡；侧面、offset、高度和歧义门控 |
| 阶段二 sidecar 和移动 UI | 已实现 | constraint/state/tag observation JSONL、localized tags JSON、结构指标 HUD 和确认 UI |
| PC 会话检查 | 已实现 | `/api/session/inspect` 有界汇总约束、状态、观测、最终价签和 malformed 计数 |
| 阶段二回放与指标 | 已实现 | iOS 同款校正门控/gain/锚点/状态；周期结构、动态干扰、错误初始位姿、tracking 恢复、yaw/通道/跳变和 matcher p50/p95 |
| 结束并发一致性 | 已实现 | finalization 先失效 generation 并有界 drain；sidecar 写入校验 tracking session 和 finalizing，禁止隐式新会话 |

2026-07-25 综合审查整改：地图包新增全文件清单并由 iOS 做摘要/跨文件校验；货架面语义对正方形/环方向稳定，柜台支持全部边；价签改为密集 ROI 深度证据和快照时效门；拒绝候选不再预热校正门；HUD 增加有界轨迹/价签层并折叠诊断；finalization 不再在主线程等待。

## 阶段三

| 能力 | 状态 | 代码/证据 |
| --- | --- | --- |
| RTAB-Map 重处理前置和源库只读 | 已实现 | `run_localized_map` 强制 `rtabmap-reprocess`；前后 SHA‑256 一致 |
| 先验地图 SE(2) 派生优化 | 已实现 | robust banded correction IRLS、yaw wrap、gauge、Huber、硬门限；明确非通用因子图 |
| 在线/道路/人工约束与拒绝审计 | 已实现 | 在线结构约束、道路区域/方向低权重软约束、accepted/rejected residual、禁用约束、人工锚点 |
| 标签离线重算和结构关联 | 已实现 | online/final 差值、稳定面 ID、JSON/CSV/GeoJSON/shelf index |
| 质量报告和发布门 | 已实现 | `localization_report.json`、`review_items.json`、`automatic_publish_allowed` |
| 人工编辑重放/撤销/重做 | 已实现 | hash 绑定 `manual_edits.json`、events/cursor、Map Studio API/UI |
| PC 非专业向导 | 已实现 | 地图+会话选择、一键处理、三轨迹/价签联动画布、状态/货架筛选、问题带入、人工编辑区和 artifact |
| 确定性 E2E fixture | 已实现 | 源库不变、漂移降低、错误约束拒绝、重现性、编辑分支测试 |
| 正式现场验收 | 未执行 | 只完成 `FIELD_TEST_PLAN.md`；不能用模拟或构建替代 |

操作流程、弱/丢失定位、人工复核、备份和失败恢复见 `USER_GUIDE.md`。

## 尚未完成的发布门槛

- 支持 LiDAR 的真实 iPhone 上完成完整开始、弱纹理、行人干扰、扫码、结束落盘和外部复制干跑；
- 由独立审查者复审本轮阶段一/二整改和阶段三实现；
- 正式超市场景验收；
- 地图直接拖拽锚点等可用性增强（问题带入和核心 ID/JSON 编辑已可用）。

自动测试和模拟回放不替代以上现场与独立审查。

## 兼容说明

实施 Prompt 建议把业务模式直接写入 `scanMode`，但当前生产协议用 `scanMode=continuous_streaming` 判定单库安全处理。阶段一因此新增 `workflowMode` 承载 `free_mapping/prior_map_localized`，保留原 storage marker。这是为了满足“不破坏自由扫描和旧 PC 流程”的更高优先级约束。
