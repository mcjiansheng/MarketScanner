# MarketScanner 核心闭环审查报告

> 报告性质：基于源码与仓库内真实处理结果的一手核查，不是文档转述。
> 核查日期：2026-08-30　分支：`fix/esl-field-capture-efficiency` @ `96def5e`
> 核查范围：地图处理 / 扫描同步校准 / 数据处理 三个环节，及"根据地图实时位置校准"的可行性判定。

---

## 一、项目定位与核心目标

本仓库是 **RTAB-Map 0.23.5** 的业务化改造，目标场景为大型超市 / 仓储卖场。真正的业务目标不是"建一张 SLAM 图"，而是：

> **把 iPhone 在现场扫出来的轨迹和价签，精确落到门店已有的货架布局图（Excel/CAD 导出的先验地图）上，产出可直接用于零售运营的坐标成果。**

生产链路：

```text
门店 Excel（货架/固定结构/道路点）→ PriorMap 包（距离场+道路图+空间索引）
  → iPhone 连续扫描（ARKit+LiDAR+IMU，单 SQLite 库，同时记录定位证据 sidecar）
  → PC 离线：rtabmap-reprocess → 相对 SE(2) 因子图 → 道路/货架自由空间约束
  → 价签坐标重投影 → 质量门 → 不可变结果版本 → 发布
```

代码规模：iOS Swift 约 31,320 行（其中 `ViewController.swift` 9,629 行、`PriorMapLocalization.swift` 2,821 行、`PriorMapScanMatcher.swift` 1,019 行）；`tools/PriorMap/` Python 约 28,091 行（其中 `offline_localization.py` 11,372 行、`corridor_route_matcher.py` 2,497 行）。测试：PriorMap 370 例、Map Studio 148 例、Qualification 32 例，**全部为主机 Python 测试，无真机/现场自动化**。

---

## 二、三环节闭环核查

### 环节 1：地图处理 —— ✅ 已完成且成熟（三环节中唯一闭合的）

| 项 | 实现 | 核查依据 |
| --- | --- | --- |
| XLSX 解析 | 零依赖（自解 ZIP/XML），无 pandas/openpyxl | `tools/PriorMap/xlsx_reader.py` 575 行 |
| 元素分角色 | `MapShelf` / `MapTable` / `MapPillar` / `MapCross` / `MapRoadPoint` / `MapTableFeature` | 真实包 `mapcase03_sam/manifest.json` |
| 几何 | 多边形 + bounds + center，top-left anchor + 旋转 | `elements.json` 实测样本 |
| 多分辨率距离场 | **0.40 / 0.20 / 0.10 m 三级，2 m 截断，RLE 编码**，逐楼层 SHA-256 | `distance_field.py:17`；iOS 端硬性校验三级必须存在（`PriorMapScanMatcher.swift:540-546`） |
| 道路图 | 节点 = `MapRoadPoint`（含 `cross_ids`），边带 `length_m` | 山姆包：350 节点 / 404 边 |
| 空间索引 | 5 m 结构/道路网格 | `spatial_index.py` |
| 坐标系 | canonical SE(2)：`+X=东` / `+Y=北` / 单位 m / yaw 逆时针 | `coordinate_system.py` |
| 包完整性 | 全文件清单 + 逐文件 SHA-256 + 跨文件关系校验，iOS/PC 双端同构 | `validate_prior_map.py`、`PriorMapPackageIntegrityCore.swift` 1,016 行 |

真实包实测（山姆 `hs.6599`）：源 1,591 元素 → active 1,590（货架 678 / 固定结构 519 / 道路点 393），2 个楼层，地图范围 96.8 m × 69.3 m，warning 2 条。

**判定：这一环是完整闭环。** 输入 Excel 到可用于匹配的距离场/道路图/多边形，链路无缺口。

**遗留问题**：2026-08-24 的 V1R6 才修复"手机侧地图包版本与 PC 侧不一致导致无法处理"（`PRIOR_MAP_SESSION_BUNDLE_V1R6`），说明这是近期仍在实际阻断的工程问题，现已通过扫描时捆绑地图包进会话解决。

---

### 环节 2：扫描同步校准 —— ⚠️ 算法已实现，但**不闭环、实测基本不生效**

#### 2.1 实际算法（`PriorMapLocalization.update()`，L876-1332）

```text
ARKit camera.transform
  → alignmentAnchor.project(arkitPose)            // 得到 rawPose（地图坐标）
  → PriorMapDepthSampler 采样 scene depth 结构点（≤600 点）
  → 动态物体时域过滤（dynamicShelfEvidenceFilter）
  → PriorMapScanMatcher 在 0.40/0.20/0.10 m 距离场上粗中细搜索
  → hypothesisTracker 维护多个长期 alignment basin（全局 T_map_from_arkit）
  → 平滑后重建 targetPose
  → 安全门 + 货架穿透审计
  → boundedStep（有界单步）→ alignmentAnchor.retainAppliedCorrection
```

门限实测值（`PriorMapLocalizationCore.swift`）：

| 门 | 值 |
| --- | --- |
| 普通单步修正判据 | 平移 ≤ **0.35 m**，yaw ≤ **8°** |
| Recovery 宽搜索判据 | 平移 ≤ **5 m**，yaw ≤ **30°** |
| 应用增益 stepGain | **0.35** |
| 单步最大平移 / yaw | **0.25 m** / **8°** |
| 匹配接受判据 | `cost ≤ 0.10`、`effectivePointCount ≥ 45`、`coverageAngle ≥ 0.35 rad`、`uniqueness ≥ 0.10`、`inlierRatio ≥ 0.20`、`residual ≤ 0.035` |
| Recovery 预算 | 40 次有效 attempt / 30 秒，连续 6 帧不trusted 触发 |

#### 2.2 断裂点 A：**校准结果不进入 SLAM，只是并行的显示坐标**

`PriorMapLocalization.swift:1109-1122` 的注释与代码是决定性的：

```swift
if decision.correctionStepApplied, let targetPose = correctionTarget {
    estimatedPose = PriorMapCorrectionSafety.boundedStep(current: rawPose, target: targetPose)
    // Move only the map/ARKit alignment anchor. ARKit world tracking
    // and the scan database are never reset.
    alignmentAnchor.retainAppliedCorrection(
        arkitPose: arkitPose, estimatedMapPose: estimatedPose)
```

全量检索 iOS 侧所有 `rtabmap?.set*/add*/post*` 调用，**不存在任何把先验地图位姿注入 RTAB-Map 的接口**（`setGPS` 是 Core Location 室外 GPS，与室内无关）。README 亦明确"不使用 AprilTag、ArUco、landmark 或外部 pose prior"。

**结论：手机上看到的"地图坐标"是一层叠加在 SLAM 之上的对齐锚点，它不修正 SLAM 图、不修正数据库位姿、不影响点云。SQLite 里存下来的仍是原始 VIO 轨迹。**

#### 2.3 断裂点 B：道路先验是 display-only

`PriorMapLocalization.swift:1163-1173`：

```swift
else if trackingState == "normal", unique, let bestRoad = topCandidates.first {
    var correction = (bestRoad.point - projected) * softGain
    ...
    reason = "road_prior_display_only"   // 明确的命名
}
```

#### 2.4 断裂点 C：标定状态硬编码为 PENDING

`app/ios/RTABMapApp/MobilePostProcessing/ShelfLocalizationEvidence.swift:15`：

```swift
static let calibrationStatus = "CALIBRATION_PENDING"
```

无分支、无条件——每一次 prior-map 扫描写入的 metadata 恒为该值（C-1/C-2/C-3 共 6 个阈值为未标定初值）。

#### 2.5 断裂点 D：实测状态分布 —— usable ≈ 0%

从仓库内 `PC处理结果/` 的 28 份真实 `localization_report.json` 提取手机端定位状态时长分布：

| 样本 | 节点 | 轨迹长 | `recovering` | `weak` | `lost` | `usable` | 弱/丢失时长 | 地图约束接受率 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| hs6599 103343 | 2284 | 845 m | 57% | 35% | 6% | **1%** | 707 s | — |
| 远端 162937 | 3663 | 481 m | 61% | 39% | 0% | **0%** | 1474 s | 0.0 |
| 远端 181158 | 1054 | 186 m | 59% | 41% | 0% | **0%** | 464 s | 1.0 |
| tianhong/2 | 943 | 292 m | 53% | 47% | 0% | **0%** | 581 s | 0.0 |
| tianhong/7 | 439 | 93 m | 61% | 39% | 0% | **0%** | 175 s | 0.0 |
| sam 084247 | 3495 | 1039 m | 56% | 43% | 1% | **0%** | 1027 s | 0.0 |
| sam 103145 | 1237 | 282 m | 65% | 32% | 2% | **0%** | 307 s | 0.0 |

**手机在 99% 以上的扫描时间里，地图定位不处于 `usable` 状态。** 系统绝大多数时间卡在 `recovering`（重定位搜索中）或 `weak`。

补充证据（`PC处理结果/0815-sam-analysis.md` 现场一手分析）：

- 原始路径落在**货架面内部**的比例：11.5% / 16.8%
- 原始路径落在实体通道内的比例：75.0% / 63.7%
- 价签观察 51 条中 **50 条使用 `shelf_plane_ray`**（二维弱证据），仅 1 条有 `scene_depth` 的 bound-node-local 点；**可发布坐标 0 条**
- 现场出现"实时坐标长时间不变"故障，根因是价签证据写入失败触发粘性门控 + 大幅地图修正被发布门拒绝

#### 2.6 断裂点 E：跨 epoch bridge fail-closed

manifest v5 的 pose-epoch transition 要求"至少两组 node-disjoint、同 component、变换一致的 native witness"才能授权跨 epoch 闭环；缺 native 多链路共识时保持 fail-closed。而 RTAB-Map 在线回环与 prior-map 的 clock epoch 分属两套体系，真机上尚未证明能稳定产生合格 witness。这是 `usable` 比例极低的主要代码层原因之一。

---

### 环节 3：数据处理 —— ⚠️ 框架完整且严谨，但**真实结果 0 通过**

#### 3.1 主流程（`offline_localization.py`）

```python
process_localized_session()            # L11234
  ├ validate_package(prior_map)
  ├ build_session_input_manifest()      # manifest v1..v5
  ├ read_finalized_session_input_snapshot()   # parse-and-hash-once，描述符稳定读
  ├ LocalizedVersionStore.begin()       # staging
  └ _render_localized_version()         # L8858，2,376 行
       ├ 加载 Admin.opt_poses / 回退 Node.pose（禁止逐节点混 gauge）
       ├ reconstruct_gauge_neutral_trace()    # 从相邻 rawPose 恢复物理运动
       ├ build_*_constraints()          # 在线结构/道路软/走廊航向/人工锚点/shelf_face
       ├ run_relative_se2_factor_graph()      # native helper
       │    └ 失败 → optimize_trajectory()    # bounded_correction_field（draft only）
       ├ corridor_route_matcher.bounded_free_space_road_hmm_v2
       ├ 价签 P_final = T_final_node × P_node   # 单次 node-local 传播
       ├ calibrated_positions_by_node.csv / _1s.csv
       ├ localized_price_tags.json/csv + deliverables manifest
       ├ review_gate（20+ 条 AND）→ publish_gate
       └ store.commit()                 # 原子指针切换
```

#### 3.2 因子图与回退链

| 层级 | 求解器 | 发布资格 |
| --- | --- | --- |
| 1 | native 完整相对 SE(2) 因子图（g2o） | 唯一可发布 |
| 2 | `bounded_correction_field_banded_v3`（O(N) 三对角） | draft / review only |
| 3 | `gauge_neutral_free_space_road_*` / `gauge_neutral_corridor_envelope_*` | 不可发布 |
| 4 | `raw_continuous_vio_diagnostic_recovery` | 诊断草稿 |

**实测：28 份真实报告中，绝大多数落在 2/3/4 层**，`publish_blockers` 首条几乎总是 `solver_not_full_relative_se2_factor_graph`。

#### 3.3 发布门（决定性）

`offline_localization.py:10704`：

```python
report["production_publish_permitted"] = bool(
    report["publish_permitted"]
    and result_scope_policy["source_production_eligible"]
    and shelf_calibration_qualified
)
```

而 `shelf_calibration_qualified = (status == "CALIBRATED")`（`_shelf_localization_calibration_gate`，L238-251），手机侧恒写 `CALIBRATION_PENDING`。

> **这是一个无条件恒假的合取项。只要扫描绑定了先验地图并写入 v5 shelf 证据，PC 的生产发布在当前代码状态下 100% 被阻断。**
> 这是刻意设置的保险丝（防止未标定阈值冒充生产资格），不是 bug——但它客观证明"端到端闭环尚未打通"。

#### 3.4 实测结果汇总

对 `PC处理结果/**/localized/versions/*/localization_report.json` 全量统计：

- 报告总数 **28**，其中节点数 ≥ 50 的有效样本 **23**
- **`publish_permitted = True` 的数量：0（0%）**
- 全部为 `PARTIAL_REVIEW_REQUIRED` 或诊断草稿

典型 blocker 分布：

```
solver_not_full_relative_se2_factor_graph   （几乎所有样本）
weak_lost_duration_above_30s                （几乎所有样本，实测 153–1474 s）
maximum_correction_above_2m / p95>1m        （最大修正 2.2 / 3.5 / 4.0 / 5.2 / 5.3 / 9.8 / 15.7 / 46.7 m）
corridor_route_distance_scale_above_5pct    （tianhong/2 的尺度偏差达 139.9）
corridor_route_obstacle_penetration/crossing_present
corridor_route_match_unavailable            （两个 sam 样本：无可行无碰撞路线假设）
rejected_constraints_present
```

**"最大修正 46.7 m"这一项尤其说明问题**：PC 端为了把轨迹拉回地图，需要施加数十米的平移修正——这意味着手机原始轨迹与先验地图之间的偏差是**十米量级**，而不是"米级漂移可被校准"的范畴。

---

## 三、"根据地图实时位置校准"可行性判定

### 3.1 判定结论

| 维度 | 判定 |
| --- | --- |
| **架构可行性** | ✅ 可行。距离场匹配 + 全局 SE(2) 对齐 + 图优化的技术路线正确，无原理性障碍 |
| **当前实现是否闭环** | ❌ **未闭环**。手机端校准不回流 SLAM（断在环节 2），PC 端发布门恒假（断在环节 3） |
| **当前是否能"实时校准"** | ❌ **不能**。手机上实时计算的是"显示用对齐坐标"，不是被校准的轨迹；且 99% 时间不处于 `usable` |
| **精度** | ⚠️ 无真值验证。现有间接指标：手机原始轨迹与地图偏差数米至 46.7 m；通道内比例 63.7–75%；价签可发布坐标 0 条 |
| **实际效果** | ❌ 28 份真实处理结果，0 份通过发布门 |

### 3.2 为什么"实时"这件事目前做不到

1. **设计上就放弃了实时注入**：项目明确拒绝外部 pose prior（防止污染 SLAM 与证据可审计性）。因此"校准"被整体推迟到 PC 离线完成。这在工程上是**合理的取舍**，但它意味着产品话术里的"实时校准"实际只是"实时显示一个估计的地图坐标"。
2. **在线匹配的召回率太低**：`usable` 0–1% 说明距离场匹配在真实超市环境（周期性平行货架、动态行人/购物车、玻璃/反光、深度稀疏）下极少给出可信解。这是算法层的核心短板。
3. **误差量级超出在线修正能力**：在线单步上限 0.25 m / 8°，而实际偏差是数米到数十米——在线修正在数学上不可能收敛到正确位置，只能靠 Recovery 宽搜索（5 m/30°）碰运气，而 Recovery 又受 40 次 / 30 秒预算限制。
4. **缺少强锚点**：当前完全依赖"人工在地图上点起点+朝向"作为唯一 gauge 来源，以及"人工重定位"（σ=3 m / 15°）。没有视觉地标、没有 AprilTag、没有可靠的跨 epoch 闭环。周期性平行货架结构在几何上天然不可区分。

### 3.3 精度评估（基于现有间接证据，非真值）

| 指标 | 实测值 | 说明 |
| --- | --- | --- |
| 手机原始轨迹落入地图通道内比例 | 63.7% – 75.0% | sam 两次现场扫描 |
| 通道外偏差 ≤ 0.5 m 比例 | 81.1% – 87.7% | 同上 |
| 轨迹落入货架面内部比例 | 11.5% – 16.8% | 物理上不可能的位置 |
| PC 施加的最大轨迹修正 | 2.2 m – 46.7 m | 7 个样本 |
| 走廊路线距离尺度偏差 | 0.019 – 139.9 | tianhong/2 严重异常 |
| 价签可发布坐标 | **0 / 90 条观察** | sam 两次 |
| 弱/丢失定位时长占比 | 32% – 47%（时长 153–1474 s） | 全样本 |

**结论：目前系统的定位精度处于"能给出大致楼层区域、不能保证通道与货架级正确"的水平，距离零售业务要求的货架级（<1 m，理想 0.3–0.5 m）仍有数量级差距。且项目自身从未做过带控制点的真值验收，任何精度数字都无真值支撑。**

---

## 四、未完成与存在缺陷的部分（分级清单）

### P0 — 决定功能能否成立

| # | 缺口 | 证据 |
| --- | --- | --- |
| P0-1 | 手机端校准结果不回流 SLAM，`usable` 时也只是显示坐标 | `PriorMapLocalization.swift:1109-1122`；无 `setPosePrior` 接口 |
| P0-2 | 在线匹配召回率极低（usable 0–1%，recovering 53–65%） | 28 份真实 `localization_report.json` |
| P0-3 | C-1/C-2/C-3 六项阈值未标定，`calibrationStatus` 硬编码 `CALIBRATION_PENDING`，导致生产发布恒假 | `ShelfLocalizationEvidence.swift:15`、`offline_localization.py:10704` |
| P0-4 | 跨 epoch bridge 长期 fail-closed，无法稳定产生合格 witness | `ARCHITECTURE.md`、`IMPLEMENTATION_STATUS.md` 2026-08-17 条目 |
| P0-5 | **从未做过带真值的现场精度验收**（控制点/闭合路线/已知货架间距） | `FIELD_TEST_PLAN.md` 已写完但"正式现场验收：未执行" |
| P0-6 | **从未在签名 LiDAR 真机上完成完整开始—结束—导出的干跑** | 全部状态文档连续标注 `NOT RUN` |

### P1 — 精度与鲁棒性

| # | 缺口 | 说明 |
| --- | --- | --- |
| P1-1 | 周期性平行货架歧义 | 距离场匹配对重复结构天然多解，实测大量 `matched_low_confidence` |
| P1-2 | 动态物体（行人/购物车）抑制未真机验证 | 已有 `dynamicShelfEvidenceFilter`，效果未知 |
| P1-3 | 高度信息未利用 | 二维先验定位忽略 ARKit 高度，货架层板高度约束未进入定位 |
| P1-4 | 初始 gauge 依赖人工点选 | 起点+朝向人工误差直接传播为整条轨迹的绝对误差 |
| P1-5 | native 因子图 helper 在多数环境不可用 | 实测大量回退到 `bounded_correction_field`（draft only） |
| P1-6 | 尺度偏差异常 | tianhong/2 尺度偏差 139.9，说明存在未被发现的数值/单位问题 |
| P1-7 | 价签测量严重依赖弱证据 | sam 现场 50/51 条为 `shelf_plane_ray`，可发布坐标 0 |
| P1-8 | 性能裕度小 | 手机 CPU 中位 112%、FPS 28、热状态长期 `fair` 并触发降级；iOS GPU 指标不可用 |

### P2 — 工程与流程

| # | 缺口 |
| --- | --- |
| P2-1 | 无真机自动化测试（全部为 Python 主机测试 550 例） |
| P2-2 | 无 CI 上的 exact-final-SHA 全矩阵 run |
| P2-3 | 现场 4 次 crash 缺 `.ips` / 符号化栈，根因未闭合 |
| P2-4 | 地图包版本不匹配（V1R6 已修，但暴露了端到端联调薄弱） |
| P2-5 | 代码结构风险：`offline_localization.py` 11,372 行、`ViewController.swift` 9,629 行 |
| P2-6 | 大量文档为历史归档，状态分散在 4 处状态文档中，认知成本高 |

---

## 五、改进目标与具体建议

### 5.1 先做一个必须的产品决断（最高优先级）

**"实时校准"必须二选一，不能继续维持模糊表述：**

- **方案 A（推荐，改动小、风险低）**：明确产品定位为 **"现场实时显示参考位置 + PC 离线精确校准"**。把 UI 与文档中的"实时校准"改为"实时参考定位"，并对手机端坐标叠加显示不确定性椭圆（当前置信度 + 最近一次成功匹配的残差）。让用户清楚知道这个位置仅供参考，最终成果以 PC 处理为准。
- **方案 B（改动大）**：真正实现实时校准——在 native 层为 RTAB-Map 增加"地图约束注入"接口，把 prior-map 匹配结果作为**软先验因子**加入在线位姿图（不是硬重置），并同步修正 map→odom。必须配套：可回退开关、约束残差审计、以及"先验污染 SLAM"的风险评估。

**不要维持现状**——现状是：代码不注入、文档说校准、用户按校准理解，三方认知不一致，这是当前最大的产品风险。

### 5.2 提升在线匹配召回率（治本）

**目标**：`usable` 状态占比从当前 0–1% 提升到 **≥ 40%**，`weak+lost` 时长占比降到 **< 20%**。

具体动作：

1. **加"拒绝原因直方图"遥测。** 在 `localization_trace` 中追加每帧匹配失败的结构化原因（点数不足 / 角覆盖不足 / cost 过高 / 唯一性不足 / 穿透 / 超门限），并在 PC 报告中聚合。当前只能看到 `usable=1%`，**无法定位是哪一个门在拒绝**——这是必须先解决的可观测性缺口，否则后续所有调参都是盲调。
2. **逐门做真机敏感度分析。** 6 个接受判据（`cost ≤ 0.10`、点数 ≥45、角覆盖 ≥0.35 rad、uniqueness ≥0.10、inlierRatio ≥0.20、residual ≤0.035）目前是拍定的初值。做法：录制 3–5 段真机 bag（ARKit 位姿 + scene depth + 时间戳），离线回放做网格搜索，看哪些门在误杀。
3. **引入强几何锚点。** 地图里已有 `MapPillar`（柱子）、`MapCross`（通道交叉口）、墙角——这些是**非周期**结构。建议为距离场额外生成一层"角点/端点显著性图"，与现有边缘距离场并行匹配，用非周期特征打破平行货架歧义。
4. **放宽在线步长上限 + 提高增益。** 当前 0.25 m/8°、gain 0.35 对"数米级偏差"完全不够。建议：在 `recovering` 状态（已有 5 m/30° 门）下把 gain 提到 0.6–0.8 并允许连续多帧快速收敛，同时保持普通状态保守。

### 5.3 完成阈值标定（解锁发布门）

**目标**：C-1/C-2/C-3 六项阈值从 `CALIBRATION_PENDING` 变为 `CALIBRATED`，使 `production_publish_permitted` 不再恒假。

具体动作：

1. **建立带真值的现场数据集**：在一家门店布设 ≥ 20 个控制点（全站仪或激光测距，精度 ≤ 2 cm），覆盖：平行通道区、通道端头、货架端头、交叉口。扫 3 次完整路线。
2. 用该数据集反解：给定真值，最优的 C-1（几何 inlier 残差 / score scale）、C-2（闭环平移/角度/inlier 比）、C-3（对向法向角/低置信 margin）各是多少。
3. 把标定产物写成 `factor_graph_quality_policy.json` 的冻结版本（该文件已存在，当前为策略载体），并在 `ShelfLocalizationPolicy` 中把 `calibrationStatus` 改为从冻结策略文件读取，而不是硬编码常量。
4. **代价评估**：这需要一个门店停业/非营业时段 + 测量人员，是纯资源问题，不是技术难题。

### 5.4 提升最终精度

| 措施 | 预期收益 | 优先级 |
| --- | --- | --- |
| 利用货架层板高度做 z 方向约束（当前完全丢弃高度） | 减少楼层内垂直漂移，改善货架关联 | 高 |
| 用 `MapCross`/`MapPillar` 非周期结构做锚点 | 破解平行通道歧义 | 高 |
| 多趟扫描联合优化（同一门店多次扫描互相约束） | 显著降低单趟累积误差 | 中 |
| 闭合路线检测（起终点重合）作为强约束 | 直接消除累积漂移 | 中 |
| 人工锚点从"点选"升级为"扫码/拍照定位" | 降低初始 gauge 误差 | 中 |
| 动态物体分割（用 ARKit 人物分割 / 光流） | 提升结构点纯度 | 中 |

### 5.5 工程可靠性

1. **固化 native 因子图 helper 的构建与分发**：当前大量回退到 bounded_correction_field，直接导致不可发布。应在 `configure_pc_macos.sh` / `configure_pc_nvidia.sh` 中强制构建，并在启动时自检、失败即明确报错而非静默回退。
2. **补真机自动化测试**：至少覆盖"签名 Release 装真机 → 完整扫描 3 分钟 → 结束 → 导出 → PC 处理 → 校验产物齐全"这条最小闭环，接进 CI。
3. **调查 tianhong/2 的 139.9 尺度偏差**：这不是精度问题，是 bug。优先修。
4. **性能**：CPU 中位 112%、长期 `fair` 热状态触发降级，已影响深度采样质量。建议把匹配频率从逐帧（0.5 s 节流）改为按需（运动量大时提高、静止时降低），并评估降低深度采样点数（600 → 300）对精度的实际影响。

### 5.6 建议的验收门槛（可量化）

在宣称"地图辅助定位可用"之前，建议至少达成：

```
✓ 真机扫描 usable 状态占比 ≥ 40%，weak+lost 时长占比 < 20%
✓ 带 20 个控制点的现场验收：轨迹点位平面中位误差 ≤ 0.5 m，P95 ≤ 1.0 m
✓ 价签坐标：可发布比例 ≥ 90%，货架关联正确率 ≥ 95%（人工抽检 100 条）
✓ native 完整 SE(2) 因子图成功率 100%（不再回退 bounded_correction_field）
✓ C-1/C-2/C-3 全部 CALIBRATED，且有 ≥ 3 次独立现场 run 支撑
✓ 同一门店 3 次独立扫描，结果轨迹差异 P95 ≤ 0.5 m（重复性）
✓ 连续 5 次完整扫描无 crash、无 required-sidecar 写入失败
```

---

## 六、总体结论

1. **地图处理环节已完整闭环**，质量高：Excel → 距离场/道路图/空间索引 → 双端同构校验，无缺口。这是项目最扎实的资产。

2. **扫描同步校准环节未闭环**。算法与工程实现完整（距离场匹配、多假设跟踪、安全门、Recovery 机制、证据持久化都写了），但：校准结果不进入 SLAM、道路先验 display-only、在线匹配在真实数据上 usable 仅 0–1%、跨 epoch bridge fail-closed。

3. **数据处理环节框架完整但结果不可用**。解析—快照—因子图—约束—价签重投影—质量门—原子发布，链路设计严谨；但 28 份真实处理报告中 **0 份通过发布门**，且因 `CALIBRATION_PENDING` 硬编码，生产发布在当前代码状态下**恒为 false**。

4. **"根据地图进行实时位置校准"目前不能实现**。架构可行，实现未到位。手机上实时产出的是"参考性显示坐标"，真正的校准全部推迟到 PC 离线，而离线结果又因标定与召回率问题全线不可发布。当前实际能力是"能给出大致区域，不能保证通道与货架级正确"，距零售业务要求的货架级精度（<1 m）有数量级差距。

5. **最优先要做的三件事**：
   - 明确产品定位（实时参考 vs 真·实时校准），消除代码/文档/用户认知的三方错位；
   - 加匹配拒绝原因遥测，把"usable=1%"定位到具体的门，结束盲调；
   - 做一次带控制点的真机现场标定，解锁 C-1/C-2/C-3，让发布门从恒假变为可判定。

6. **与项目自身状态文档的一致性**：本报告的核查结果与 `IMPLEMENTATION_STATUS.md`、`DOCUMENT_STATUS.md` 反复声明的 **NO-GO / NOT PRODUCTION READY** 完全一致。本报告的价值在于：用源码行号和仓库内 28 份真实处理结果，把这个结论从"文档声明"落到了"可验证的事实"。

---

*核查方法：源码通读（iOS Swift 关键路径 + `tools/PriorMap/` 主流程）、仓库内 `PC处理结果/` 28 份真实 `localization_report.json` 全量统计、真实 PriorMap 包结构解析、项目状态文档交叉比对。所有数值均来自仓库内实际文件，未做推测。*
