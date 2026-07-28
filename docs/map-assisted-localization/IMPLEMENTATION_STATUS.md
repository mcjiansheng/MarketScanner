# 地图辅助定位实现状态

> 文档状态：**当前有效**。最后核对日期：2026-07-28。

## 生产化总状态

当前发布判定是 **NO-GO / NOT PRODUCTION READY**。`repair-v2-w2r-safety-closeout@cf1b62c949f3574e1804808537e38c8ff643549c` 是生产化冻结基线；P0 在专用 CI job 中锁定 bounded solver 禁止发布、cleanup 确认与精确 CAS、复制后本地副本保留、required evidence 失败时 finalization fail closed 四项不变量，不修改业务算法。

后续必须按 P1 至 P8 独立推进：P1 完整相对 SE(2) 因子图、P2 可复现干净构建、P3 Map Studio 持久任务、P4 iOS finalization/保留/provider hardening、P5 真机矩阵、P6 现场验收、P7 打包与 selfcheck、P8 独立复核。RB-01 至 RB-05 任一未关闭时均不得发布生产成果。权威判定和证据边界见 [`reviews/PRODUCTION_READINESS_REVIEW.md`](reviews/PRODUCTION_READINESS_REVIEW.md)。

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
| 人工确认和审计 | 已实现 | manual v3 JSONL；native 原子 node/timebase/generation 快照；无一致 node 证据即拒绝 |
| synthetic/trajectory replay | 已实现 | 平移/旋转 drift、XY/yaw 误差、tracking loss、道路分配 |
| 旧会话和自由扫描兼容 | 已实现 | storage/workflow 分字段、PC regression |
| 完整业务首页五入口 | 部分实现 | 现有首页/菜单保留；新建扫描双模式已完成，独立“先验地图”首页入口尚未拆出 |
| 预定路线导入 | 未实现 | 可选增强项；当前只有道路图合成遍历和回放 |
| iOS 核心契约测试 | 已实现 | ARKit 前后左右/非零原点金标、模式门控、SE(2) 投影和 CameraMobile epoch node timebase 静态/PC 回归 |

## 阶段二

| 能力 | 状态 | 代码/证据 |
| --- | --- | --- |
| 线程、状态、距离场与失败策略 | 已实现 | `STAGE_2_DESIGN.md`、`PriorMapScanMatcher.swift`、in-flight gate |
| 多分辨率确定性距离场 | 已实现 | 0.40/0.20/0.10 m、2 m 截断、RLE、逐层 SHA-256、schema 负向测试 |
| 深度结构提取和扫描匹配 | 已实现 | scene depth、跨帧 voxel 证据、600 点上限、粗中细多盆地传播、全窗真实次佳 Top‑3、周期结构保守拒绝 |
| 状态和置信度滞回 | 已实现 | initializing/stable/usable/weak/lost/manualCorrection；连续可信和 stale 门限集中管理 |
| Vision QR/条形码识别 | 已实现 | 用户触发；复用 `ARFrame.capturedImage`；捕获时对齐快照与版本；四方向 ROI；QR/EAN/Code128/UPCE/PDF417 |
| 标签三维测量与结构关联 | 已实现 | 同帧 depth；楼面法向/残差/时序置信度；货架/柜台；跨结构遮挡；侧面、offset、高度和歧义门控 |
| 阶段二 sidecar 和移动 UI | 已实现 | constraint/state/tag observation JSONL、localized tags JSON、结构指标 HUD、确认 UI 和必需证据写失败的持久红色告警 |
| PC 会话检查 | 已实现 | `/api/session/inspect` 有界汇总约束、状态、观测、最终价签和 malformed 计数 |
| 阶段二回放与指标 | 已实现 | iOS 同款校正门控/gain/锚点/状态；周期结构、动态干扰、错误初始位姿、tracking 恢复、yaw/通道/跳变和 matcher p50/p95 |
| 结束并发与提交一致性 | 已实现（自动测试） | finalization 先失效 generation 并有界 drain；metadata 提交前复核实际 required evidence 文件、严格 JSONL/身份/数量/state 水位；失败写 `finalized=false`，成功提交后即为终态；checkpoint 删除失败绝不恢复写库 |
| Sidecar 故障与终端恢复 | 已实现（自动测试） | Foundation-only 可注入 writer 运行时覆盖 trace/constraint/state 部分失败、metadata 失败、checkpoint 删除失败；首个必需写失败后停止新修正/价签确认但保留原始 DB；手机/PC 清理使用 no-follow、文件身份复核、单 segment/path-component containment、失败审计；PC 要求 confirmed 与 expected evidence CAS，冲突返回 409 |
| Finalization 副作用接线 | 已实现（Foundation 集成测试） | completion 使用 `ScanFinalizationDisposition`；effect planner 覆盖恢复、正常终态、待清理终态和 ineligible recovery，只有提交前失败恢复 camera/mapping，needs-cleanup 禁止外部复制 |
| 原子可见 sidecar 写入 | 已实现（自动测试） | 同目录唯一 temp→write→synchronize→rename；write/flush/rename 故障保留旧字节；明确不承诺未经真机验证的 power-loss durability |
| 外部复制完整性 | 已实现（自动测试），provider 待真机 | 关闭句柄后复读目标，逐文件相对路径、字节数、SHA-256，并复核源目录未变化；生成 copy receipt，默认保留本地唯一副本 |

2026-07-25 综合审查整改：地图包新增全文件清单并由 iOS 做摘要/跨文件校验；货架面语义对正方形/环方向稳定，柜台支持全部边；价签改为密集 ROI 深度证据和快照时效门；拒绝候选不再预热校正门；HUD 增加有界轨迹/价签层并折叠诊断；finalization 不再在主线程等待。

## 阶段三

| 能力 | 状态 | 代码/证据 |
| --- | --- | --- |
| RTAB-Map 重处理前置和源库只读 | 已实现 | `run_localized_map` 强制 `rtabmap-reprocess`；前后 SHA‑256 一致 |
| 先验地图派生修正 | 部分实现 | `bounded_correction_field`、yaw wrap、Huber、硬门限、绝对约束残差诊断/局部平移与 yaw 形变报告；尚非相对 SE(2) 因子图 |
| 在线/道路/人工约束与拒绝审计 | 已实现 | 在线结构约束、道路区域/方向低权重软约束、accepted/rejected residual、禁用约束、人工锚点 |
| 通道切换审计 | 已实现 | 最终轨迹几何投影输出进入/离开时间、候选 margin、方向、weak/lost overlap、人工 assignment 和可能静默切换 |
| 标签离线重算和结构关联 | 已实现（保守门控） | observation→真实 node/frame time 绑定、raw 位置 SE(2) 传播、独立次候选/遮挡/侧面/边长校验；失败进入 review 或阻断 current |
| Sidecar 输入契约 | 已实现 | 每类 required/optional、format/version、严格 UTF‑8/JSON、身份/时间/业务 schema/大小/唯一 ID；legacy manual 仅审计；tag/observation 内容交叉验证；损坏 fail closed |
| 节点覆盖审计 | 已实现 | 只读查询 source/optimized SQLite Node，和导出 node ID 三方比较缺失、额外、重复、非单调 stamp 与首尾时间；metadata 仅交叉检查 |
| 导出隐私与本机恢复 | 已实现 | version 内 `session_input_manifest.json`/input identity 绑定全部输入字节；绝对路径按 identity 隔离在不导出的 `localized/local_inputs/`，重放前验证 version、身份和当前输入 hash |
| 不可变成果事务 | 已实现 | POSIX/Windows 跨进程锁内 staging→完整文件/hash 校验→`versions/vNNNNNN`→单指针提交；Windows write-through move、版本/指针 durability 故障注入；读取与已打开 fd 复核 hash；损坏状态拒绝降级 |
| 质量报告和状态机 | 部分实现 | draft/review/published/revoked 事务框架和门禁；当前 solver 硬阻断 published |
| 人工编辑重放/撤销/重做 | 已实现 | manual_edits v4 与 input identity、强制 version/revision CAS、HTTP 409、服务端 old value/UTC/ID、字段/范围/地图校验、undo/redo audit |
| PC 非专业向导 | 已实现 | 地图+会话选择、一键处理、三轨迹/价签联动画布、状态/货架筛选、问题带入、人工编辑区和 artifact |
| 确定性 E2E fixture | 已实现 | 源库不变、漂移降低、错误约束拒绝、事务/输入变更故障、双线程客户端同基准 CAS 冲突、409、发布硬门、严格 sidecar/capture-health 负例 |
| 正式现场验收 | 未执行 | 只完成 `FIELD_TEST_PLAN.md`；不能用模拟或构建替代 |

操作流程、弱/丢失定位、人工复核、备份和失败恢复见 `USER_GUIDE.md`。

## 尚未完成的发布门槛

- Map Studio 任务持久化、崩溃/重启后的安全恢复或中断判定；
- 干净环境下可重复的 PC/iOS 构建、依赖锁定和产物溯源；
- 支持 LiDAR 的真实 iPhone 上完成完整开始、弱纹理、行人干扰、扫码、结束落盘和外部复制干跑；
- 已按 2026-07-28 外部静态审查关闭 W2 B-01 与 W2R H-01 至 H-04/M-01 至 M-05；远端多平台 CI run `30342577182` 已绑定准确提交并通过，独立人工复核仍待执行；
- 正式超市场景验收；
- 实现并验证读取 RTAB‑Map 相对/闭环边的完整 SE(2) 因子图；在此之前不得创建有效 published 成果；
- 地图直接拖拽锚点等可用性增强（问题带入和核心 ID/JSON 编辑已可用）。

自动测试和模拟回放不替代以上现场与独立审查。

## 兼容说明

实施 Prompt 建议把业务模式直接写入 `scanMode`，但当前生产协议用 `scanMode=continuous_streaming` 判定单库安全处理。阶段一因此新增 `workflowMode` 承载 `free_mapping/prior_map_localized`，保留原 storage marker。这是为了满足“不破坏自由扫描和旧 PC 流程”的更高优先级约束。
