# 地图辅助定位实现状态

> 文档状态：**当前有效**。最后核对日期：2026-07-28。

## 生产化总状态

当前发布判定是 **NO-GO / NOT PRODUCTION READY**。`repair-v2-w2r-safety-closeout@cf1b62c949f3574e1804808537e38c8ff643549c` 是生产化冻结基线；P0 在专用 CI job 中锁定 bounded solver 禁止发布、cleanup 确认与精确 CAS、复制后本地副本保留、required evidence 失败时 finalization fail closed 四项不变量，不修改业务算法。

P1 已实现并在真实 DB 上只读验证完整相对 SE(2) 因子图、canonical factor digest、严格 Python 二次校验和 fail-closed publish capability；设计见 [`FACTOR_GRAPH_DESIGN.md`](FACTOR_GRAPH_DESIGN.md)。P2 已加入 PC release presets、依赖 capability 门、source-bound `--version`、release/iOS dependency manifests，以及不允许依赖缺失静默 skip 的 hosted build 流程；本机 macOS 空目录构建通过，跨平台远端结果仍须单独核验，见 [`REPRODUCIBLE_BUILD.md`](REPRODUCIBLE_BUILD.md)。P3 已完成 Map Studio 持久 journal、重启中断判定、子进程取消、运行日志留存和浏览器任务重连，见 [`PERSISTENT_JOBS.md`](PERSISTENT_JOBS.md)。P4 代码和主机压力测试已完成流式 finalization、descriptor-bound 读取、schema/大小门、copy receipt 隐私和 durability hook；真机 smoke 仍归 P5，见 [`IOS_FINALIZATION_HARDENING.md`](IOS_FINALIZATION_HARDENING.md)。

P5/P6 的真实执行尚未发生；仓库已提供失败关闭的设备/现场 evidence collector，完整矩阵、真实设备身份、App/native/prior/session/package hash、冻结阈值、至少 3 次扫描与独立标签控制点缺一项即 FAIL，见 [`FIELD_TEST_PLAN.md`](FIELD_TEST_PLAN.md) 和 [`tools/Qualification/README.md`](../../tools/Qualification/README.md)。这不构成真机或现场通过证据。

P7 已实现 loopback-only server、每次启动随机且不落盘的 token、POST token/Origin 门、CSP、安全 About/恢复信息、bounded 诊断包、启动 selfcheck、macOS/Windows launcher 和 hash-bound operator archive，见 [`RELEASE_OPERATIONS.md`](RELEASE_OPERATIONS.md)。干净 Windows/macOS 安装、升级、卸载 smoke 尚未执行，不能视为平台发布验收完成。

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
| 先验地图派生修正 | 已实现（P1 本地验证） | native RTAB-Map/g2o 完整相对 SE(2) 因子图、Link transform/information、absolute priors、gauge、robust、canonical digest；bounded correction 仅为不可发布 draft fallback |
| 在线/道路/人工约束与拒绝审计 | 已实现 | 在线结构约束、道路区域/方向低权重软约束、accepted/rejected residual、禁用约束、人工锚点 |
| 通道切换审计 | 已实现 | 最终轨迹几何投影输出进入/离开时间、候选 margin、方向、weak/lost overlap、人工 assignment 和可能静默切换 |
| 标签离线重算和结构关联 | 已实现（保守门控） | observation→真实 node/frame time 绑定、raw 位置 SE(2) 传播、独立次候选/遮挡/侧面/边长校验；失败进入 review 或阻断 current |
| Sidecar 输入契约 | 已实现 | 每类 required/optional、format/version、严格 UTF‑8/JSON、身份/时间/业务 schema/大小/唯一 ID；legacy manual 仅审计；tag/observation 内容交叉验证；损坏 fail closed |
| 节点覆盖审计 | 已实现 | 只读查询 source/optimized SQLite Node，和导出 node ID 三方比较缺失、额外、重复、非单调 stamp 与首尾时间；metadata 仅交叉检查 |
| 导出隐私与本机恢复 | 已实现 | version 内 `session_input_manifest.json`/input identity 绑定全部输入字节；绝对路径按 identity 隔离在不导出的 `localized/local_inputs/`，重放前验证 version、身份和当前输入 hash |
| 不可变成果事务 | 已实现 | POSIX/Windows 跨进程锁内 staging→完整文件/hash 校验→`versions/vNNNNNN`→单指针提交；Windows write-through move、版本/指针 durability 故障注入；读取与已打开 fd 复核 hash；损坏状态拒绝降级 |
| 质量报告和状态机 | 已实现（仍受现场发布门约束） | draft/review/published/revoked 事务框架和门禁；完整相对 SE(2) helper 报告通过严格能力校验后才允许进入发布判断 |
| 人工编辑重放/撤销/重做 | 已实现 | manual_edits v4 与 input identity、强制 version/revision CAS、HTTP 409、服务端 old value/UTC/ID、字段/范围/地图校验、undo/redo audit |
| PC 非专业向导 | 已实现 | 地图+会话选择、一键处理、三轨迹/价签联动画布、状态/货架筛选、问题带入、人工编辑区和 artifact |
| 确定性 E2E fixture | 已实现 | 源库不变、漂移降低、错误约束拒绝、事务/输入变更故障、双线程客户端同基准 CAS 冲突、409、发布硬门、严格 sidecar/capture-health 负例 |
| 正式现场验收 | 未执行 | 只完成 `FIELD_TEST_PLAN.md`；不能用模拟或构建替代 |

操作流程、弱/丢失定位、人工复核、备份和失败恢复见 `USER_GUIDE.md`。

## P3 持久任务

| 能力 | 状态 | 代码/证据 |
| --- | --- | --- |
| 原子任务 journal | 已实现 | `StudioState` 的 versioned JSON、文件和目录同步、有限时间戳/路径/状态校验 |
| 浏览器刷新恢复 | 已实现 | `GET /api/jobs` 恢复最近活动或完成任务 |
| 服务重启判定 | 已实现 | 活动态 fail closed 转换为 `interrupted`，不猜测继续、不发布 staging |
| 操作者取消 | 已实现 | 持久取消意图；原生子进程 terminate→有界 wait→kill；partial 清理 |
| 原生运行日志 | 已实现 | fast/discovery 独立日志、严格文件名和任务归属下载 |
| 损坏 journal/保留策略 | 已实现 | health 报告 startup error；不按不可信路径清理；默认保留 200 个终态任务 |
| 自动回归 | 已实现 | 工作台测试目录 76 项通过，其中持久任务测试 6 项、release manifest 测试 4 项 |

## 尚未完成的发布门槛

- P2 hosted Ubuntu/iOS 构建和 Windows native clean build 的最终远端证据仍须核验；
- 支持 LiDAR 的真实 iPhone 上完成完整开始、弱纹理、行人干扰、扫码、结束落盘和外部复制干跑；
- 已按 2026-07-28 外部静态审查关闭 W2 B-01 与 W2R H-01 至 H-04/M-01 至 M-05；远端多平台 CI run `30342577182` 已绑定准确提交并通过，独立人工复核仍待执行；
- 正式超市场景验收；
- 对更多真实 DB 固化相对边 residual 工程阈值，并由 clean CI 构建 helper；P1 单样本通过不替代现场 acceptance；
- 地图直接拖拽锚点等可用性增强（问题带入和核心 ID/JSON 编辑已可用）。

自动测试和模拟回放不替代以上现场与独立审查。

## 兼容说明

实施 Prompt 建议把业务模式直接写入 `scanMode`，但当前生产协议用 `scanMode=continuous_streaming` 判定单库安全处理。阶段一因此新增 `workflowMode` 承载 `free_mapping/prior_map_localized`，保留原 storage marker。这是为了满足“不破坏自由扫描和旧 PC 流程”的更高优先级约束。
