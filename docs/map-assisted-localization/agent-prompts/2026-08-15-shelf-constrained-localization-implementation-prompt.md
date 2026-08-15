# 通道/货架约束定位 P1-B → P1-E / P2 实现 Prompt

> 文档状态：**历史归档（已执行的实施输入快照）**。最后核对日期：2026-08-16。当前实现与验证结论以 `../IMPLEMENTATION_STATUS.md` 为准。
> 适用对象：能够读取仓库、修改代码、运行测试和操作 Git 的工程 Agent（Codex / Claude Code 等）。
> 原计划基线：`fix/sam-field-end-to-end-hardening` @ `6fb7ff0ea801d29b2c34d623e56f80274d8b560b`；实际实施从已合入扫描显示名称的 `9484a60f11c068336962bc44c961d00de11fbc87` 创建 `feature/shelf-evidence-contract-p1b`。
> 远端核心基线：`origin/core-mobile-v1` @ `9a93fbd0ee52944eae5aebedf59ec6a08dedc934`，不得改写。
> 开始任何阶段前先执行：`git fetch --all --prune`，核对 ahead/behind，从最新基线创建新分支。

---

## 0. 任务使命

把设计评审《AISLE_SHELF_CONSTRAINED_LOCALIZATION_DESIGN_REVIEW_2026-08-14》提出的"通道与货架物理约束连续配准"从**诊断原型**推进为**正式证据链 + 可发布实现**，同时严格遵守产品冻结规格《SHELF_LOCALIZATION_PRODUCT_SPECIFICATION_FROZEN_2026-08-15.md》（下称**冻结规格**，S-x/C-x 编号均出自该文档）。

最终产品目标（冻结）：

1. 手机扫描时实时知道自己处于哪条通道、哪个货架的哪一侧；
2. 通道身份按**最优候选提交 + 低置信标记 + 人工重定位兜底**运行（S-8），不实现阻塞式多解发布门；
3. 同一货架的**两侧观测一致性**（S-9）作为货架闭环判据，免真值；
4. 最终价签必须绑定具体货架，平面容差直径 1 m，高度不作要求（S-4/S-5/S-6）；
5. 例行资格 = 自洽性指标（冻结规格 §7），不要求逐店真值。

**必须先读的文件**（按顺序）：

```text
docs/map-assisted-localization/SHELF_LOCALIZATION_PRODUCT_SPECIFICATION_FROZEN_2026-08-15.md   # 产品合同，最高优先级
docs/map-assisted-localization/AISLE_SHELF_CONSTRAINED_LOCALIZATION_REMEDIATION_2026-08-14.md  # 已完成项与未完成项清单
docs/map-assisted-localization/AISLE_SHELF_CONSTRAINED_LOCALIZATION_DESIGN_REVIEW_2026-08-14.md（外部输入，§9/§10 为目标架构参考）
AGENTS.md                                                                                         # 仓库工作规则
docs/map-assisted-localization/IMPLEMENTATION_STATUS.md                                           # 当前实现状态
docs/map-assisted-localization/PRIOR_MAP_GLOBAL_ALIGNMENT_TODO.md                                 # 已知缺口自述
```

## 1. 现有能力盘点（不要重复实现）

| 能力 | 位置 | 状态 |
| --- | --- | --- |
| 价签 node-local v2 坐标链（P0） | `PriorMapLocalization.localizePriceTag`、`TagObservationEvidenceParser`、`TagObservationResolver`、PC `apply_bound_node_local_point` | ✅ 已关闭，禁止回退 |
| 发布不变量（P1-A） | `MobileResultPublicationInvariant`、`offline_localization.py` blocker | ✅ 已关闭，只能加严不能放松 |
| 原子 node 快照（ID/stamp/mapID/pose） | `RTABMapApp::getNodeTimeSnapshot`、`RTABMap.latestNodeBinding` → `RTABMapNodeBindingSnapshot` | ✅ 已有，P1-B 直接复用 |
| 匿名结构对齐 Top-K basin | `PriorMapHypothesisTracker`、`PriorMapScanMatcher` | ✅ 已有，P1-C 的打分底座 |
| 人工重定位（选位/重选/有界修正场传播） | `MobileScanSetupViewController`、`PriorMapPoseSelectionViewController`、`applyManualPriorMapPose` | ✅ 已有，是 S-8 的兜底，不得破坏 |
| 回环附近货架 Top-K（诊断） | `nearbyShelfIdentityCandidates` + `loop_opened_shelf_identity_candidates` 事件 | ✅ 已有，P1-E 将其升级为正式证据的起点 |
| PC 通道路由/自由空间（review-only） | `corridor_route_matcher.py` | ✅ 已有，P1-D 将其转正 |
| 手机性能证据链 | `performance_timeline.jsonl` + `tools/SupermarketMapStudio/performance_analysis.py` | ✅ 已有，P1-C 性能摸底直接用它出报告 |
| epoch 重置诊断 | tracking state `tracking_recovery_epoch_rebase`（`SupermarketScanSession.updateSensorPose`） | ✅ 已有，P1-B 的 epoch 转移事件挂钩在这里 |

## 2. 不可协商的约束（违反任何一条 = 任务失败）

1. **冻结规格优先**：S-1～S-12 冻结值不得改动；与设计评审文档冲突处以冻结规格为准。
2. **不破坏已关闭项**：P0 坐标链、P1-A 发布门、扫描启动事务、finalization/sidecar/snapshot 合同、性能证据链、连续单库约定（`continuous_streaming` / `segment_0001` / `finalized` / `live_checkpoint`）。
3. **fail-closed**：证据 framing/身份/水位/哈希损坏必须拒绝并保留诊断；宁可"不知道"，不许用模糊证据写坐标。
4. **原始数据库只读**：PC 处理永不就地修改；新输出写新目录。
5. **正常生命周期零 crash**：不允许新增 `fatalError`/`preconditionFailure`/强制解包（`init(coder:)` 样板除外）。
6. **资源有界**：所有新增 sidecar 与内存结构必须有上限；tag evidence host 峰值门 768 MiB 不得突破。
7. **分支与提交规则**：每阶段一个独立分支，名称禁用 `codex/` 前缀；白名单暂存；不提交扫描数据/数据库/本地报告；`AGENTS.md` 与 `doc/.local/` 不进 Git。
8. **文档同步**：行为变化必须同轮更新对应"当前有效"文档与 `doc/.local/DOCUMENT_STATUS.md`。
9. **待标定项纪律**：C-1/C-2/C-3 允许先用初值实现，但必须在代码中标记 `CALIBRATION_PENDING`，发布前必须回填冻结值，禁止用现场测试结果反向调参冒充先验冻结。

## 3. 关键文件索引（改动地图）

```text
手机写入端
  app/ios/RTABMapApp/ViewController.swift                     # ARFrame 主循环、tracking 状态、回环回调、scan events
  app/ios/RTABMapApp/PriorMapLocalization.swift               # 定位器、HUD、人工重选
  app/ios/RTABMapApp/PriorMapScanMatcher.swift                # 结构匹配与假设跟踪
  app/ios/RTABMapApp/PriorMapDepthSampler.swift               # 深度结构采样
  app/ios/RTABMapApp/SupermarketScanSession.swift             # 会话、sidecar 写入、metadata
  app/ios/RTABMapApp/PriorMapLocalizationCore.swift           # 共享类型/数学

手机解析/后处理
  app/ios/RTABMapApp/MobilePostProcessing/*.swift             # strict parsers、resolver、snapshot 事务
  app/ios/RTABMapApp/MobileOnlyWorkflow/MobileProcessingPipeline.swift

native
  app/android/jni/RTABMapApp.cpp/.h                           # iOS/Android 共享 native（图/component/mapId 查询入口）
  app/ios/RTABMapApp/NativeWrapper.cpp/.hpp                   # C ABI

PC
  tools/PriorMap/offline_localization.py                      # 离线编排与发布门
  tools/PriorMap/corridor_route_matcher.py                    # 通道路由（P1-D 转正对象）
  tools/PriorMap/structure_window_alignment.py                # 结构窗口（P1-E 基础）
  core/MarketScannerFactorGraph/market_scanner_factor_graph.cpp/.h   # native 因子图（P1-D 扩展）
  tools/Reprocess/prior_map_factor_graph.cpp

合同生成器（改 schema 必须同步）
  tools/Qualification/generate_mobile_contracts.py            # 证据输入上限唯一事实源（--check 防漂移）
  app/ios/RTABMapApp/GeneratedMobileEvidenceContracts.swift
  tools/PriorMap/generated_mobile_evidence_contracts.py

测试
  tools/PriorMap/tests/                                       # Swift host + Python 合同测试
  tools/SupermarketMapStudio/tests/
```

---

## 4. 阶段 P1-B：正式证据合同（第一步，无外部依赖，立即开工）

### 4.1 目标
让 epoch/component/通道假设/货架观测窗口/货架闭环成为**逐记录、可哈希、跨端同构**的正式证据，取代 `scan_events.jsonl` 诊断事件在定位决策中的隐性地位。

### 4.2 新增 sidecar（4 个 JSONL + manifest v5）

所有文件遵循仓库严格 JSONL 惯例：每行一个对象、`format` + `version` 字段、snake_case、final newline、水位单调。schema 定义如下（字段集合即合同，解析端必须拒绝未知/缺失关键字段，按各解析器现行 fault 分级处理）：

**`pose_epoch_transitions.jsonl`**
```json
{
  "format": "MarketScannerPoseEpochTransition", "version": 1,
  "tracking_session_id": "...", "sequence": 7,
  "from_epoch": 3, "to_epoch": 4,
  "before_frame_timestamp": 123.45, "after_frame_timestamp": 124.02,
  "before_node_id": 501, "after_node_id": 502,
  "transform": {"dx_m": 0.12, "dy_m": -0.03, "dyaw_rad": 0.002},
  "bridge_evidence": [
    {"type": "multi_link_consensus", "independent_node_pairs": 3, "consensus_inlier_ratio": 0.97}
  ],
  "reason": "tracking_recovery_epoch_rebase | arkit_world_rebuild | manual",
  "write_watermark": 42
}
```
挂钩点：`SupermarketScanSession.updateSensorPose` 的 `tracking_recovery_epoch_rebase` 分支与 ARKit world 重建检测；无 bridge 证据时仍要写记录，`bridge_evidence` 为空数组且 reason 如实——解析端对"跨 epoch 无 bridge"的重访证据必须拒绝（对应设计文档图 3 负样本）。

**`corridor_hypotheses.jsonl`**（按 accepted node 节拍写，复用 1–2 Hz 自适应定位节拍，**不逐帧**）
```json
{
  "format": "MarketScannerCorridorHypotheses", "version": 1,
  "node_id": 512, "node_timestamp": 178.3, "node_map_id": 0,
  "epoch": 4, "component": 1,
  "hypotheses": [
    {"corridor_id": "road-118", "score": 0.91},
    {"corridor_id": "road-121", "score": 0.38}
  ],
  "top1_top2_margin": 0.53,
  "penetration_audit": {"node_inside_shelf_count": 0, "segment_crossing_count": 0},
  "covariance": {"along_m": 2.4, "cross_m": 0.35, "yaw_rad": 0.09}
}
```

**`shelf_observation_windows.jsonl`**（P1-E 的核心输入，**必须记录 side 与法向**——冻结规格 §8 对 P1-B 的新增要求）
```json
{
  "format": "MarketScannerShelfObservationWindow", "version": 1,
  "window_id": "sow-0003",
  "node_range": [498, 522], "time_range": [171.2, 180.9],
  "epoch": 4, "component": 1,
  "side": "left | right",
  "face_normal_map": {"x": 0.01, "y": 1.0},
  "shelf_candidates": [
    {"shelf_segment_id": "shelf-12", "score": 0.93},
    {"shelf_segment_id": "shelf-14", "score": 0.41}
  ],
  "coverage_angle_rad": 1.9, "endcap_visible": false,
  "dynamic_rejection_count": 2,
  "prior_map_sha256": "...", "distance_field_sha256": "..."
}
```

**`shelf_loop_events.jsonl`**
```json
{
  "format": "MarketScannerShelfLoopEvent", "version": 1,
  "shelf_segment_id": "shelf-12",
  "window_ids": ["sow-0003", "sow-0007"], "sides": ["right", "left"],
  "loop_from_node": 522, "loop_to_node": 560,
  "rtab_loop_id": 34, "rtab_loop_residual_m": 0.18,
  "phone_shelf_se2": {"dx_m": 0.62, "dy_m": 0.04, "dyaw_rad": 0.01},
  "consistency": {"relative_pose_delta_m": 0.21, "relative_pose_delta_yaw_rad": 0.04, "inlier_ratio": 0.84},
  "accepted": true, "reason": "two_sided_consistency_confirmed | margin_insufficient | epoch_mismatch | ..."
}
```

**manifest v5**：在现行 input manifest（v4）基础上把上述 4 个文件纳入同一 hash tree 与角色清单；版本号升级必须走 `generate_mobile_contracts.py` 生成器并三端同步（Swift 常量 / Python 常量 / PC validator），`--check` 通过。

### 4.3 逐记录正式身份
- `localization_trace`、tag observation（已有 bound node）、corridor/shelf 记录的每条都必须带 `epoch` 与 `component`；
- component 判定：native 已有 `node_map_id`；跨 map_id 即不同 component，需显式 bridge 才允许相互引用；
- 旧会话兼容：v1–v4 会话按"无新证据"处理，现有处理链不得中断；manifest 版本白名单新增 5 不删除 1–4。

### 4.4 P1-B 验收（DoD）
- [ ] Swift 写入端 + Swift/Python 双端 strict parser，坏行/坏 framing/水位回退全部有 fault-injection 测试；
- [ ] 五图确定性 fixture（设计文档 §13.1）的**证据层**部分：跨 epoch 无 bridge 的重访必须被拒；同 epoch/component 重访必须被接受；
- [ ] `generate_mobile_contracts.py --check` PASS，三端常量一致；
- [ ] 长规模压力不劣化：400,000 tag evidence host 峰值仍 < 768 MiB；新增 sidecar 解析纳入压力；
- [ ] PriorMap 全量 discover、Map Studio、Qualification 全绿；unsigned generic iPhoneOS Debug/Release 构建通过。

## 5. 阶段 P1-C：手机通道/货架状态机（简化版，依赖 P1-B）

### 5.1 按 S-8 冻结的行为
- 状态机仅三态：`BOOTSTRAP → TRACKING ⇄ LOW_CONFIDENCE`；不做阻塞式多解 UI；
- 每个 accepted node：传播当前最优假设 → 候选打分（复用 `PriorMapScanMatcher` basin 分 + 通道拓扑可达性惩罚）→ 提交 top1；
- 穿架淘汰（S-7）：节点深入货架面 > 0.4 m 或相邻节点扫掠线段穿越 > 0.4 m 的候选直接丢弃；手机前伸扫价签不误杀（深度点允许越界，**只约束手机位姿点**）；
- 低置信触发（C-2，初值：top1/top2 分差 < 15%，或最近可靠回环距今行进距离 > 30 m，或 tracking 降级频次突增）：HUD 显示"定位置信度低，建议核对位置"提示条（不阻塞扫描），质量报告记录；
- 人工重定位成功后清除低置信状态（修正场收敛即恢复 TRACKING）。

### 5.2 性能要求（R-1 关闭条件）
- 打分与穿架检测复用现行 1–2 Hz 自适应节拍，不逐 ARFrame 执行；
- 用 `performance_timeline.jsonl` 证据链出真机性能报告：CPU 增量、内存增量、FPS 影响、thermal 对比；
- 超标降级顺序：候选数 24→12 → 打分频率减半 → 保留穿架检测最后降级。

### 5.3 P1-C 验收
- [ ] 五图 fixture 的行为层：图 1 首货架唯一候选确认/重复直边保持低置信；图 4 长通道横向不跳变、沿轴 covariance 如实增长；图 5 穿架红线候选被淘汰、两条合法通道提交 top1 + 低置信标记；
- [ ] 低置信提示与人工重定位恢复的 UI 合同测试；
- [ ] 真机性能报告（签名真机，人工执行）达标后才允许合入发布候选。

## 6. 阶段 P1-D：PC 混合图正式化（依赖 P1-B）

### 6.1 因子集合（按冻结规格简化后的全集）
| 因子 | 说明 |
| --- | --- |
| relative/odometry + RTAB loop | 现有，保留 |
| manual anchor（exact node，3 m / 15°，S-12） | 现有，朝向不确定度从 20° 收紧到 15° |
| free-space inequality | 点/线段侵入 > 0.4 m 硬拒；软带内鲁棒惩罚 |
| shelf face factor | 仅对 P1-E accepted 的货架窗生效：法向距离 + 相对 yaw 约束 |
| initial pose prior（1–3 m / 15°，S-2） | 现有 |
**不实现**：人体胶囊、corridor hinge、switch variable、各向异性低秩长货架约束的完整形式（沿轴 covariance 如实上报即可）。

### 6.2 转正与放行
- 删除 `offline_localization.py` 中 corridor route 成功后强制 `full_factor_graph=false / published_capable=false` 的死规则；
- 新放行条件 = 冻结规格 §7 自洽指标全过 + P1-A invariant + shelf face 残差门（法向 ≤ 0.5 m）；
- 输出保持 raw / optimized / shelf-projected 三类坐标与残差；
- 通道方向因子作用于**行进切线**，不强迫手机 yaw 等于通道方向（设计文档 §9.3 保留条款）。

### 6.3 P1-D 验收
- [ ] corridor route 成功 + 自洽指标通过的会话可产出 `publish_permitted=true`（fixture 级）；
- [ ] 自洽指标任一项失败仍 fail-closed 到 review draft；
- [ ] 图 5 fixture：两条合法通道 margin 不足时输出低置信而非强选。

## 7. 阶段 P1-E：两侧观测货架闭环（依赖 P1-B/C）

### 7.1 确认流程（冻结规格 §6.2 五条）
1. 两窗口 exact node 区间可读、同 component、epoch 一致或有正式 bridge；
2. 两侧判定：窗口法向夹角 > 120°；
3. phone↔shelf 相对 SE(2) 两窗口差异 ≤ C-1（初值：平移 0.5 m / 朝向 10°）；
4. 几何吻合 inlier 比 ≥ C-1 初值 70%；
5. 无主导动态遮挡。
通过后：写 accepted `shelf_loop_events` → 允许把对应 RTAB loop 提升为具体货架因子 → PC 回溯平滑整圈（禁止瞬移）。

### 7.2 P1-E 验收
- [ ] 冻结规格 §6.1 走廊场景的端到端 fixture：通道 N 右侧窗口 + 通道 N+1 左侧窗口 → 同一 shelf_segment_id 两侧确认；
- [ ] 负样本：同侧重访不升级；跨 epoch 无 bridge 不升级；margin 不足写 `accepted=false + reason`；
- [ ] 闭环后整圈轨迹回修：节点不删除、结构内点 0、穿架段 0（沿用现行几何审计）。

## 8. 阶段 P2：动态物体（部分保留）

- 实现：深度结构中动态体剔除（C-3 静止判定时长初值 10 s）+ 长时静态一致性审计字段；
- 不实现：`map_mismatch` 仲裁（S-1 产品保证地图准确）、开口/货架移动正式检测门；保留冲突计数诊断与低置信联动。

## 9. 测试与证据要求（每阶段通用）

1. **跨端同输入**：五图 fixture 的手机 Swift 与 PC Python/C++ 必须使用同一份不可变输入（hash 绑定）；
2. 每阶段结束必须复跑并可引用：
   ```bash
   python3 -m unittest discover -s tools/PriorMap/tests -v
   python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v
   python3 tools/Qualification/generate_mobile_contracts.py --check
   cmake -S . -B build -DBUILD_TOOLS=ON && cmake --build build --target rtabmap-reprocess --config Release -j
   # unsigned generic iPhoneOS Debug + Release 全量构建；Release 身份门要求 tracked 树干净
   ```
3. 提交说明附证据块：各套件 N/N、长规模压力峰值、构建身份 SHA 一致性；
4. 真机项（性能摸底、LiDAR、现场路线）由人工执行，Agent 必须在文档中显式列出"未执行"清单，禁止用主机结果冒充。

## 10. 禁止事项（Guardrails）

1. 禁止放松 P1-A 发布不变量或为让 fixture 通过而修改门限值（C-x 标定除外，且须走修订流程）；
2. 禁止把诊断事件（scan_events）直接当定位因子；
3. 禁止用"投影后落在货架线"反证定位精度（投影是产品合同的一部分，但验收必须用自洽指标组合）；
4. 禁止修改原始扫描数据库；禁止删除既有会话格式字段（只增不改，可选字段 + 版本号）；
5. 禁止在未冻结 C-1/C-2/C-3 的情况下宣称发布资格；
6. 禁止把 CPU 回退报告成 GPU 成功、把主机测试表述为真机通过。

## 11. 阶段顺序与分支计划

| 顺序 | 阶段 | 建议分支名 | 依赖 | 外部依赖 |
| --- | --- | --- | --- | --- |
| 1 | P1-B 证据合同 | `feature/shelf-evidence-contract-p1b` | 无 | 无（立即开工） |
| 2 | P1-C 状态机 | `feature/shelf-tracking-statemachine-p1c` | P1-B | 真机性能摸底（R-1） |
| 3 | P1-D PC 正式化 | `feature/pc-hybrid-graph-p1d` | P1-B | 无 |
| 4 | P1-E 货架闭环 | `feature/shelf-loop-factor-p1e` | P1-B + P1-C | C-1 标定 |
| 5 | P2 动态剔除 | `feature/dynamic-rejection-p2` | P1-B | C-3 标定 |

P1-C/D 可并行（不同分支）。每阶段独立提交、独立推送、独立证据块；不合并不推送 `core-mobile-v1`。

## 12. 完成定义（整个任务）

全部阶段合入且满足：
- 冻结规格 §7 自洽指标在至少一条真实会话（手机+PC 同输入）上全部产出并通过；
- C-1/C-2/C-3 完成标定并回填冻结规格修订版；
- 签名真机冷启动、短扫 Stop/finalization/export、性能报告完成（人工）；
- 文档（ARCHITECTURE/DATA_FORMATS/TEST_PLAN/IMPLEMENTATION_STATUS/DOCUMENT_STATUS）同轮更新；
- 结论允许表述为"内部一致且满足冻结容差"；在拿到控制点真值前仍**禁止**宣称绝对精度合格或 Production GO。
