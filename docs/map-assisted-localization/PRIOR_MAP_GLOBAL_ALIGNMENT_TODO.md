# 先验地图全局对齐、长期回环与启动检查 TODO

> 文档状态：**当前有效**。最后核对日期：2026-08-14。

本清单记录 TianHong 两份真实会话复盘后，尚不能在当前安全合同内直接发布的增强。已完成的核心修复包括：旧 v2 包只读派生拓扑兼容、显式初始位姿 prior、闭环异常边隔离、PC 道路/结构全局候选图、长期 **alignment basin** 保留、低置信度结果保留和 exact-node 人工绝对锚点。这里必须区分 alignment basin 与 concrete shelf identity：后者的正式跨回环跟踪、相对位姿和输入身份绑定仍未完成。

2026-08-14 已完成的轨迹语义修复：道路中心线不再用于最终坐标重参数化。PC HMM 只选择 corridor identity、有限道路边、真实 junction 和可达顺序；优化手机位姿的局部横向位置、曲线、停顿和回头保留。货架几何负责结构内点/穿架段的最小连续自由空间修正，无法在不穿架条件下消除的修正梯度继续作为低置信度 blocker，而不是重新吸附道路或删除结果。该修复不等于 concrete shelf identity 已解决，也不提供现场绝对精度证明。

整体发布资格仍是 **NO-GO / NOT PRODUCTION READY**。以下任何 diagnostic 结果都不能替代 exact-final-SHA、签名真机、LiDAR、热/内存、Device Lab 或现场控制点验收。

## P1：把跨窗口结构证据升级为正式输入

- 当前 `structure_coverage_cells.json` 不属于 PC localized session input manifest v1/v2/v3/v4，也未进入 parse-and-hash-once stable snapshot。本轮 `structure_window_alignment.py` 因此强制输出 `diagnostic_only_unbound_structure_coverage_v1`、`publishable_constraint_count=0` 和 `factor_injection_allowed=false`。manifest v4 已用于绑定 `clock_correlations.jsonl`，不能再复用同一版本承载不同文件集合。
- 若要生成正式绝对因子，必须同步设计 session input manifest v5：
  - PC `SESSION_INPUT_FILE_NAMES_V5`、snapshot、localized output store 和结果恢复；
  - 手机 `SessionSnapshotTransaction` required/optional declaration、metadata watermark 和 finalization 校验；
  - 严格 coverage schema、文件/记录/栅格预算、final newline/JSON identity（若改为 JSONL）；
  - v1/v2/v3/v4 历史兼容和跨端 mutation tests；
  - 原始 DB、coverage、trace 和 prior-map package 的同一 input identity。
- 正式因子必须绑定窗口时间范围、DB node IDs、使用的 coverage cell 集、distance-field SHA 和候选序列 margin。人工复核只能添加有不确定度的绝对证据，不能覆写原始 sidecar。

## 已实现但仍为 diagnostic-only：PC 全轨迹结构—地图联合候选图

- 当前 diagnostic 模块已联合使用：已知起点/初始方向、`Admin.opt_poses` 完整轨迹、三层货架距离场、有界 PC beam、道路中心线距离（仅 corridor identity/候选评分）、相邻窗口行进切线、道路连通最短路径、优化轨迹弧长和 correction-field 梯度。道路中心线不是手机位置观测，不得作为最终 X/Y/yaw 目标。候选预算属于算法参数，不能把某一个预算下的序列唯一性写成普遍业务事实。
- 路线/道路证据全部为有上限软代价，不删除候选；独立 runner-up 要求跨窗口达到货架尺度差异，不再把 0.3 m/1° 的同路线网格邻居误报为另一条路线。
- 真实 Tianhong 复测：
  - 使用与历史对比一致的 `candidate_limit=12` 时，`181158` 最大相邻 correction 总量为 4.080 m，但单位物理行进距离的平移/航向梯度仅为 0.176 m/m 和 1.242°/m，因此应判为长距离累计 gauge 修正连续，而不是手机瞬移；该预算下 `sequence_unique=true`；
  - `162937` 的最大总修正为 2.927 m，梯度为 0.238 m/m 和 1.513°/m，连续性通过，但仍保留 `structure_window_sequence_ambiguous`，不通过调权重伪造确定货架；
  - 将候选预算增至 24 时可能暴露新的平行序列多解，因此 `181158` 的“唯一”只属于该次固定预算诊断，不能升级为具体货架身份结论。
  - 两者都仍被 `structure_coverage_not_bound_by_localized_input_manifest` 阻断，`publishable_constraint_count=0`。
- 后续 PC 工作是把同一候选图接入正式 manifest v5 和人工复核可视化，而不是再新增一套未绑定的因子生成器。
- 在引入正式因子前，至少审核 Tianhong、北京昌平 hs.6599、MapCase02 和 Kohl's 的多会话分布并冻结质量策略。当前 factor graph policy 仍是 `candidate`，不得仅依据本次两个样本改为 `frozen`。

## P1：手机后处理的资源有界版本

- 手机端应复用相同坐标、窗口、候选连续性和证据身份语义，但不能照搬 PC 三层密集搜索。
- 手机 native 已将 `metadata.initialMapPose` 作为单一显式 SE(2) gauge authority；它只有在同一分量存在节点跨度至少 30 的 RTAB-Map 长程闭环时，才可替代“三个独立绝对 prior”的发布授权。其余覆盖、残差、局部形变和求解器门不放宽；无长程闭环仍为 `LOCAL_FRAME_ONLY`。
- 建议预算：
  - 0.40 m coarse distance field 为常驻主路径；只有 coarse margin 足够且资源允许时使用 0.20 m refine；0.10 m 默认留给 PC；
  - 每窗口最多 200–400 个确定性采样点；
  - 每窗口最多 3–5 个候选；
  - 只在结构覆盖新增、多方向观察、可靠 RTAB-Map 回环或人工校准后的稀疏关键窗口运行；
  - 复用 `ProcessingResourceGovernor`，thermal serious/critical、低电量或内存不足时返回 `resourceRequired`，不发布降级结果；
  - 中间表采用流式/有界 ring buffer，不把完整 coverage/trace/候选图同时常驻内存。
- 手机 Fast existing-graph optimization 不升级为 true sensor deep reprocess；缺少足够证据时必须保留原始扫描并转 PC/人工复核。

## P1：扫描时长期货架假设与回环恢复

- 当前手机 `PriorMapHypothesisTracker` 已继续保留多排周期结构的 dormant **alignment hypotheses**，历史 support 只能排序，重新激活必须重新累计 fresh support；它仍不是具体 `shelf_segment_id` 的 identity tracker。
- 当前可靠 RTAB-Map 回环会打开有界 recovery，并把最新估计位姿附近最多 5 个 `shelf_segment_id` 写入普通 `scan_events.jsonl`。该 top-K 事件是 `diagnostic_only_not_localization_factor`：候选来自回环后的位姿邻域，不是回环绑定的局部货架结构快照，也没有 phone↔shelf SE(2)，不能改变定位或发布资格。
- 在下列事件触发有界 recovery 搜索，而不是清空候选：
  - 跨至少 50 个节点的可靠 RTAB-Map 全局/邻近回环；
  - 多方向结构覆盖显著增长；
  - 轨迹回到历史道路/货架窗口附近；
  - 人工节点校准完成。
- 扫描 UI 应提示“回看货架端头/交叉口/独特固定结构”，但不强迫反复扫描同一价签；回环目标是全局轨迹和货架 identity，不是让使用者重复扫码。
- 正式闭环必须新增 manifest v5 绑定的 loop-window 结构证据：冻结回环前后 exact node/time 范围、局部货架/地面点、地图候选、所用 distance-field SHA 和 top-K margin；在此基础上建立 concrete shelf identity tracker，输出 phone↔shelf relative SE(2) 及其不确定度，再由 fresh multi-frame support 将已确认货架作为有界校准证据。不得直接给 strict `localization_trace` v1 增字段，也不得把当前邻域 top-K 当绝对因子。
- manifest v5 必须同步手机 writer/finalization/snapshot、水位和生成合同、Swift/Python strict parser、PC immutable input identity、localized result identity、资源上限、mutation tests 和文档；任何一端缺失都只能保持 diagnostic。
- 需要现场矩阵验证蛇形长通道、环绕同形货架、遮挡后恢复、人工校准前后、无可靠回环和错误回环隔离。

## P1：道路拓扑精确来源的 schema 升级

- Tianhong 正式工作簿把 128 条 `MapCross` 全部标记 `visible=false`，但 511 个可见 `MapRoadPoint` 仍引用其 `crossCodes`。当前安全修复只从已被 v2 manifest 绑定的可见 road points 确定性恢复拓扑；隐藏道路不进入结构距离场或障碍物。
- XLSX 内仍有隐藏 MapCross 的精确几何，但现有 package v2 `elements.json` 不保存它。编译时直接使用会导致 validator 无法从包内 authority 重建 road graph，因此禁止偷偷接入。
- 后续 package schema 应增加独立 `road_topology_source.json`：
  - manifest SHA/计数/identity 绑定；
  - 明确 `topology_only=true`，禁止进入 distance field、obstacle 和 shelf evidence；
  - Swift/PC 编译器与 validator 确定性重建；
  - hidden line 与 road-point membership 冲突时 fail closed；
  - v2 包继续使用可见 road-point fallback。

## P2：启动稳定性检查，不伪装成硬件“校准”

- 不实现第三方 App 无法完成的陀螺仪/加速度计硬件 bias 校准；ARKit 已使用系统工厂和运行时标定，二次手工扣 bias 会重复校正。
- 不依赖磁力计绝对航向，也不要求用户做“8 字校准”；超市金属货架、电器和结构会让磁场方向不稳定。
- 可实现的功能应命名为“启动稳定性检查 / initial pose readiness”，并发生在创建 session/database 前：
  - 1–2 秒相对静止；
  - ARKit tracking 进入 normal；
  - 重力方向短窗方差稳定；
  - 短时角速度/姿态变化低；
  - sceneDepth 连续可用；
  - 相机内参有效，曝光/对焦不再剧烈变化；
  - 初始地面估计可用。
- 采用 soft readiness：达到条件立即进入；超时允许用户继续但 metadata/scan event 记录 degraded 原因。不得在 `startMobileOnlyScan()` 主线程 sleep，不得先创建 DB 再等待，以免产生幽灵扫描。

## 资格与可观测性

- 为结构窗口输出可视化：每窗口点集、前 N 候选、选择序列、第二序列、correction field、道路/货架 overlay 和 blocker。
- 真样本报告必须区分：raw localization trace、`Admin.opt_poses`、最终先验地图 SE(2) trajectory、人工锚点和诊断-only structure alignment。
- 现场验收至少记录：起点误差、初始方向误差、每 20 m 控制点、最大/95% 横向误差、货架 identity 正确率、回环恢复时延、人工校准后 correction 梯度、热状态、峰值 RSS、电量和处理耗时。
- 所有原始 DB 只读；诊断与优化结果写入新目录。任何 ambiguous、unbound 或 resource-degraded 结果都不得发布。
