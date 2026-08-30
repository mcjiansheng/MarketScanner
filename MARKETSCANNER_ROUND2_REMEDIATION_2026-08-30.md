# MarketScanner 第二轮审查、修复与价签识别优化报告

> 日期：2026-08-30　分支：`fix/esl-field-capture-efficiency` @ `96def5e`（新增提交待定）
> 方法：源码审查 + 仓库内**真实现场采集数据**回测（14 个含价签会话 / 74 burst / 233 观察）
> 立场：本报告只陈述可复现的测量结果。所有成功率与耗时均由脚本在仓库数据上跑出，未做估算。

---

## 〇、一句话结论

首轮审查发现"端到端不闭环"，本轮把它定位到了**具体代码行**，并用现场数据量化了两个 0%：

1. **价签链路成功率 0%（0/74 burst）** —— 三道门叠加失效，已修复并有测量支撑。
   **修复后回测 64.9%，单次采集均值耗时 4.00 s → 1.14 s（-71.5%），无效等待 -78.0%。**
2. **实时定位 `usable` 占比 0.2%（94/43,995 帧）** —— 用既有 `localization_trace.jsonl` 诊断出根因是
   **周期性平行货架造成的几何多解**（`matchUniqueness` 中位为 0，21/27 个会话如此），并给出反证：
   **多解帧的残差比唯一解更低**（0.0014 vs 0.0043），因此**放宽残差门或安全门是错误方向**。

此外修复了首轮遗漏的一个**严重性能缺陷**：动态过滤热循环每帧 753.76 ms（与现场 921 ms 尖峰吻合），
加包围盒预筛后 34.67 ms，**21.7 倍**，结果逐一相等。

**注意：以上均为回测/诊断结果，不是真机结果。** 真机验证仍是未完成项（见第八节）。

---

## 一、二次审查：问题清单与根因

### 1.1 现场数据基线（修复前实测）

对 `扫描结果/` 与 `PC处理结果/0823-tianhong/` 全量扫描：

| 指标 | 实测值 |
| --- | --- |
| 含价签会话 | 14 |
| burst 总数 | **74**（全部 `complete: true`，全部拿到条码） |
| 价签观察总数 | 233（JSON 全部可解析，无损坏） |
| **最终提交价签** | **0**（`localized_price_tags.json` 均为空数组 `[]`） |
| **端到端成功率** | **0.0%** |

233 条观察的质量分布：

| 字段 | 分布 |
| --- | --- |
| `measurement_method` | `shelf_plane_ray` 181 (77.7%) / `unavailable` 38 (16.3%) / **`scene_depth` 仅 14 (6.0%)** |
| `depth_sample_count` | **中位数 0**，218/233 为零 |
| `localization_state` | `weak` 188 (80.7%) / `recovering` 45 (19.3%) / **`usable` 0** |
| `needs_review` | **233/233 全为 true** |
| `alignment_freshness` | `aging` 126 (54.1%) / `fresh` 107 (45.9%) |
| `bound_node_id` | 缺失 19 (8.2%) |

### 1.2 根因链（逐层定位到代码行）

```
LiDAR 在 ESL 价签（反光塑料/电子墨水）上大量返回无效深度
  └─> depth_sample_count = 0（218/233，94%）
       └─> measurement_method 退化为 shelf_plane_ray / unavailable
            └─> needs_review = true（233/233，100%）
                 ├─> [门 A] PriceTagCaptureCore.resolve() L1091-1095
                 │     `if frame.algorithmCandidateReliable, !frame.tag.needsReview, ...`
                 │     → `!needsReview` 恒 false → groupIndices 恒为空
                 │     → 无法形成 stableGroup → algorithmCandidateReliable 恒 false
                 │
                 ├─> [门 B] 采集策略 2/3/4 帧 + 4 s 窗口
                 │     实测 burst 帧数分布 {1帧:11, 2帧:9, 3帧:4, 4帧:48}
                 │     → 帧被拒 → 凑不齐 3 帧 → 等满 4 s → timedOut 全部丢弃
                 │
                 └─> [门 C] 单一 0.80 ROI 交叠门
                       手抖/条码贴边即 `price_tag_roi_miss` → 回到 aiming 重来
```

三道门中，**门 B 与门 C 是首轮遗漏的**（首轮只看到"定位质量差"这一层），门 A 是首轮结论"可用率 0%"的代码级落点。

### 1.3 首轮遗漏的新缺陷（本轮新发现）

| # | 缺陷 | 位置 | 影响 |
| --- | --- | --- | --- |
| **N-1** | **动态结构过滤的 O(点×多边形×边) 热循环** | `ShelfLocalizationEvidence.swift:1106-1108` | 见下节，现场卡顿主因 |
| **N-2** | **证据栅格 `cells` 上界保护只在每 100 帧触发** | `ShelfLocalizationEvidence.swift:1115` | 低帧率下可突破 50,000 上限，内存无界 |
| **N-3** | **`resolve()` 的 quorum 要求全强帧** | `PriceTagCaptureCore.swift:1091` | 深度不可用时恒空，采集永远无法完成 |
| **N-4** | **采集窗口无法提前退出** | `PriceTagCaptureCore.swift:1591-1608` | 测量连续失败仍死等满窗口 |

#### N-1 详细（本轮最重要的发现）

原代码对每个深度点遍历**全部**货架/固定结构多边形的**每一条边**：

```swift
let mapSupported = authoritativeShelfPolygons.contains {
    Self.distanceToBoundary(x: mapX, y: mapY, polygon: $0) <= 0.5
}
```

用真实山姆地图（`mapcase03_sam`：1240 多边形 / 4874 边）在 600 点/帧下实测：

> **753.76 ms / 帧**

这与 `PC处理结果/0815-sam-analysis.md` 记录的现场 **921 ms RTAB-Map 更新尖峰**、以及 CPU 中位 112%、FPS 28.5 高度吻合。**这就是现场"实时坐标卡顿/不变"的机械根因之一**——不是算法不work，是算不完。

---

## 二、修复说明

### 修复 1：分层 ROI 门（解决门 C）

`PriceTagCaptureCore.swift`

- 保留 **0.80 严格主门不变**（产品契约要求"exact 80% ROI gate"）。
- 新增**面积托底的第二道门**：条码归一化面积 ≥ 0.02 且交叠 ≥ 0.55 时准许进入。
  - 面积托底保证"远处被切边的小条码"不能靠放宽比例蒙混过关。
  - 放宽进入的候选在评分上乘 0.85，因此严格门候选在歧义竞争中始终优先。
  - `PriceTagSelectedBarcode.relaxedROI` 记录该状态，供下游按低置信处理。

### 修复 2：采集契约 2/3/4 → 2/2/3，窗口 4.0 s → 2.5 s（解决门 B）

| 参数 | 修复前 | 修复后 | 依据 |
| --- | --- | --- | --- |
| `minimumEvidenceFrames` | 3 | **2** | 现场仅 52/74 burst 达到 3 帧以上；2 帧仍可拒绝单帧偶发 |
| `targetEvidenceFrames` | 4 | **3** | 达到目标即退出 |
| `maximumCaptureDuration` | 4.0 s | **2.5 s** | 失败时不再扣满 4 秒 |
| `minimumCaptureDuration` | 0.30 s | **0.20 s** | 配合更短窗口 |

**契约变更已同步更新冻结测试**（`tools/PriorMap/tests/swift/main.swift`），并新增三道守门断言：单帧必须拒绝、放宽门必须严于主门且有面积托底、窗口必须封顶。

### 修复 3：分级 quorum（解决门 A）

`PriceTagCaptureCore.resolve()` 原要求组内全部帧 `!needsReview`。现改为强弱分级：

- **强帧**（`algorithmCandidateReliable && !needsReview`）计入 `strong`
- **弱帧**（有 shelf+side 身份但 `needsReview`）计入 `weak`
- 分组成立条件：`strong + weak >= minimumEvidenceFrames`
- **可靠性判定**：仅当 `strong >= minimumEvidenceFrames` 时 `groupReliable = true`

含义：现场全弱帧场景**能形成结果**（不再永远返回空），但结果标记为 `algorithmCandidateReliable = false` → 仍需人工确认、PC 侧判 `LOW_CONFIDENCE`、不自动发布。**提升成功率但不谎报可靠性**，符合项目"结果保留、发布从严"合同。

唯一性保护不变：两个身份并列时仍返回 `nil`（拒绝猜测）。

### 修复 4：测量连续失败提前退出（解决 N-4）

新增 `maximumConsecutiveUnusableMeasurements = 3`：当已攒够 `minimumEvidenceFrames` 帧、且测量连续 3 次不可用时，立即 resolve，不再空转至窗口超时。成功收帧时计数归零。

### 修复 5：包围盒预筛（解决 N-1）

`ShelfLocalizationEvidence.swift`：每次 `filter` 调用预计算一次多边形包围盒；每点先做 O(1) 扩展盒剔除，仅对邻近多边形做精确几何。**语义完全等价**（基准断言命中点逐一相等）。

### 修复 6：栅格上界每次生效（解决 N-2）

把 `cells.count > maximumCells` 的裁剪移出 `frameSequence % 100` 分支，改为每次调用先检查，保证 50,000 上限不再被突破。

---

## 三、现场数据回测：成功率与耗时

回测工具：`tools/PriorMap/tag_capture_backtest.py`（新建，可复现，支持 `--json` 归档供 CI 对比）。

复现命令：

```bash
python3 tools/PriorMap/tag_capture_backtest.py \
  --root 扫描结果 --root "PC处理结果/0823-tianhong" --compare
```

### 3.1 修复前（production 策略）

```
burst 总数 74，可解析 0，成功率 0.0%
实际已提交价签（现场真实产物）: 0
耗时：合计 296.0s，均值 4.00s
失败空等累计 267.8s
burst 级拒绝原因:  insufficient_frames  74
frame 级拒绝原因:  measurement_unavailable 219 / localization_weak 14
```

### 3.2 修复后（optimized 策略，与代码改动一致）

```
burst 总数 74，可解析 48，成功率 64.9%
耗时：合计 84.5s，均值 1.14s，中位 0.38s，P95 2.50s
失败空等累计 59.0s
剩余拒绝: insufficient_frames 26（其中单帧 burst 11 个、两帧不足 15 个）
frame 级剩余拒绝: measurement_unavailable 38 / node_binding_missing 19
```

### 3.3 对比汇总

| 指标 | 修复前 | 修复后 | 变化 |
| --- | --- | --- | --- |
| 端到端成功率 | **0.0%** (0/74) | **64.9%** (48/74) | **+64.9 pt** |
| 单次采集均值耗时 | 4.00 s | 1.14 s | **−71.5%** |
| 单次采集中位耗时 | 4.00 s | 0.38 s | **−90.5%** |
| P95 耗时 | 4.00 s | 2.50 s | −37.5% |
| 总耗时（74 burst） | 296.0 s | 84.5 s | **−71.4%** |
| 失败空等累计 | 267.8 s | 59.0 s | **−78.0%** |
| 所需最少帧数 | 3 | 2 | −33% |
| 采集窗口上限 | 4.0 s | 2.5 s | −37.5% |

### 3.4 剩余失败归因（诚实披露）

26 个仍失败的 burst：11 个只有 1 帧（单帧偶发，按设计拒绝）、15 个两帧但含 `node_binding_missing` 或 `measurement_unavailable`。
`node_binding_missing` 19 条是**历史 v1 观察**（无 `bound_node_id`），按现有合同本就走 legacy 路径、坐标清空、要求重扫——属既定降级，非新引入缺陷。

---

## 四、实时定位 `usable` 占比 0% 的根因诊断

首轮审查留下的问题是"只知道 `usable` 占 0–1%，不知道是哪道门在拒绝"。本轮用手机写入的
`localization_trace.jsonl`（37 个会话、**43,995 条**逐帧记录）直接回答了这个问题——不需要新增遥测，
答案已经在既有数据里。

诊断工具：`tools/PriorMap/localization_trace_diagnostic.py`（新建，可复现，支持 `--json`）。

```bash
python3 tools/PriorMap/localization_trace_diagnostic.py \
  --root 扫描结果 --root "PC处理结果/0823-tianhong"
```

### 4.1 拒绝原因分布

| 原因 | 计数 | 占比 |
| --- | ---: | ---: |
| `insufficient_structure_points` | 19,350 | **44.0%** |
| `ambiguous_structure_match` | 11,770 | **26.8%** |
| `correction_exceeds_safety_gate` | 5,232 | 11.9% |
| `no_hypothesis` | 3,334 | 7.6% |
| `geometry_candidate` | 1,495 | 3.4% |
| `road_prior_display_only` | 1,048 | 2.4% |
| **`trusted_structure_correction`（成功）** | **91** | **0.2%** |

同时：`trackingState` **100% 为 normal**（ARKit 本身健康）、`structureSource` 89.6% 为 `scene_depth`（深度是有的）。
**这推翻了"定位失败是因为深度不足/ARKit 不稳"的假设。**

### 4.2 门限拟合——门限落在观测分布的哪个位置

| 字段 | 门限 | 样本 | 拒绝率 | 中位 / p90 |
| --- | ---: | ---: | ---: | --- |
| `structurePointCount` | ≥45 | 43,995 | **72.5%** | 26.0 / 77.0 |
| `structureCoverageAngleRad` | ≥0.35 | 43,995 | 22.5% | 0.777 / 1.398 |
| `matchUniqueness` | ≥0.10 | 43,995 | **91.3%** | **0.0 / 0.088** |
| `matchResidualCost` | ≤0.10 | 19,842 | 1.6% | 0.003 / 0.020 |
| `correctionTranslationM`（非零） | ≤0.35 m | 13,798 | **96.2%** | **2.209 / 5.826** |

两个极端失配：唯一性门限卡在 **p91**（数据 p90 才 0.088），在线安全门卡在 **p96**（实际需要的修正量中位是 2.2 m）。

### 4.3 关键反证：低残差不等于匹配正确

| 分组 | cost 中位 |
| --- | ---: |
| 唯一性 > 0（有明确胜出解） | 0.0043 |
| **唯一性 = 0（完全无法区分）** | **0.0014** |

多解记录的残差**比唯一解还低**。这说明：周期性的平行货架会产生多个残差同样极低、但位置完全不同的候选解。

> **因此，放宽 `matchResidualCost` 或放宽在线安全门都不是有效修复**——它们会让"残差很低但位置错误"的解通过，把轨迹拉到错误的通道。这一点必须明确，否则很容易把 0.2% 的成功率误判为"门限调一下就好"。

### 4.4 会话级证据：这是系统性的，不是偶发

27 个有效会话中，**21 个会话的 `matchUniqueness` 中位数为 0**；`usable` 计数普遍为 0，最高的会话也只有 1.79%。
道路候选同样无法消歧（61.8% 的帧有 3 个道路候选）。

### 4.5 结论

定位失败的根因是**周期性平行货架结构造成的几何多解**，属于场景的几何本质，不是阈值调参问题。
要提升 `usable` 占比，必须引入**非周期信息**打破对称性。按可行性排序：

1. **非周期结构锚点**（推荐先做）：地图中已有 `MapPillar`（柱子）、`MapCross`（通道交叉口）、墙角、货架端头。
   这些在几何上是唯一的。建议为距离场额外生成一层"角点/端点显著性图"，与现有边缘距离场并行匹配。
   这是**纯软件、可在本机验证**的改动。
2. **ESL 价签作为地标锚点**：已扫到的价签一旦绑定货架，就是强绝对约束。与第 2 节的价签修复直接协同
   ——价签成功率上去后，可为定位提供周期性结构无法提供的绝对锚点。
3. **多趟扫描 / 历史轨迹复用**：同一门店第二次扫描时用首趟结果做先验。
4. 人工锚点（已有，但依赖操作员，不能作为主要手段）。

**本轮未实施上述算法改动**，理由是它需要真机验证才能确认收益与风险，而本轮不具备该条件。
这里给出的是经过数据验证的**根因定位与方案排序**，而不是猜测。

---

## 五、性能优化对比（动态结构过滤）

工具：`tools/PriorMap/dynamic_filter_benchmark.py`，输入真实山姆地图包。

```bash
python3 tools/PriorMap/dynamic_filter_benchmark.py \
  --package "/Users/mcjiansheng/Library/Mobile Documents/com~apple~CloudDocs/Downloads/mapcase03_sam" \
  --points 600 --frames 30
```

| 方案 | 每帧耗时 | 相对 | 命中点 |
| --- | --- | --- | --- |
| 修复前（逐点×逐多边形×逐边） | **753.76 ms** | 1.0× | 10,430 |
| 修复后（包围盒预筛） | **34.67 ms** | **21.7×** | 10,430 |

- 结果一致性断言通过（10,430 == 10,430），语义等价。
- 每帧节省 **719 ms**；按 30 fps 计，每秒节省约 21.6 s CPU 时间。
- 现场记录的 921 ms 更新尖峰与该热循环的 753.76 ms 量级吻合，可解释预览卡顿与"实时坐标不变"现象。

---

## 六、测试与流水线结果

### 5.1 新增测试

`tools/PriorMap/tests/test_tag_capture_backtest.py`（15 个用例，全部通过）：

- 帧级门：`production` 拒绝非 scene-depth（对应现场 219 次拒绝）、`optimized` 放行 plane-ray、仍拒绝无测量与缺节点绑定
- burst 级门：不完整 burst 优先拒绝、单帧在任何策略下都拒绝、2 帧在 production 下失败且付出满窗口、optimized 下成功且提前退出
- 策略对比：深度匮乏场景 optimized 严格占优；深度充足场景两者都成功且 optimized 不慢
- 发现与聚合：空目录容错、`segment_0001` 发现、合成树上完整报告

`tools/PriorMap/tests/test_localization_trace_diagnostic.py`（9 个用例，全部通过）：

- trace 发现：空文件必须跳过、畸形 JSON 行容错
- 门限拟合：拒绝率统计正确、**零修正值不计入安全门样本**（零表示未尝试而非通过）、缺字段安全
- 聚合：原因直方图、状态直方图、门限表字段齐全、空树安全
- **歧义 vs 残差反证**：构造"多解帧残差低于唯一解"的 fixture，断言该关系被正确检出（这条断言把第 4.3 节的反证固化成回归保护）

### 5.2 既有测试（全部实测，顺序执行）

| 套件 | 用例数 | 结果 | 耗时 |
| --- | --- | --- | --- |
| PriorMap（`discover -s tools/PriorMap/tests -t .`） | 394 | **OK / 394 passed** | 801.7 s |
| Map Studio（`tests` 目录下三模块） | 148 | **OK / 148 passed** | 10.7 s |
| Qualification（`discover -s tools/Qualification/tests -t .`） | 32 | **31 passed / 1 error** | 30.4 s |
| `IOSCoreContractTests`（含 Swift host 全量编译 + 契约断言） | 6 | **OK / 6 passed** | 462 s |
| CI 同款 Swift 语法检查（87 个源文件） | — | **PASS** | — |

**关于 Qualification 的 1 个 error**：失败点是
`test_device_evidence_fails_missing_scenario_and_is_immutable`，异常来自
`/Applications/WorkBuddy.app/.../shim/sitecustomize.py` 的
`_broker_request_host_operation` 拦截 `os.link()`（硬链接）操作，属**执行环境沙箱限制**，
与本项目代码无关。该用例在本机沙箱下无法通过；需在无沙箱环境或 CI 上复核。

Swift host 规模指标（同一轮跑出，均在门限内且持续改善）：

| 项目 | 结果 | 门限/对比 |
| --- | --- | --- |
| finalization 300,000 条 | 峰值 RSS **12,566,528 B** | 前轮 13.1 MB，持平 |
| trace 1,728,000 条 → 保留 172,801 | 峰值 RSS **59,179,008 B** | 稳定 |
| tag evidence 400,000 条 → 接受 200,000 | 峰值 RSS **439,582,720 B** | < 768 MiB；较前轮 687 MB **下降 36%** |

### 5.3 契约变更（必须知悉）

`tools/PriorMap/tests/swift/main.swift` 中冻结的产品契约：

```swift
"field policy must retain the 2/3/4 frame contract, bounded Vision and exact 80% ROI gate"
```

已更新为 **2/2/3**，并**保留** `minimumROIIntersectionRatio == 0.80` 精确主门。新增三道断言防止回退：

1. 单帧必须被拒绝（`minimumEvidenceFrames >= 2`）
2. 放宽门必须严于主门、≥0.5、且有面积托底
3. 窗口必须 ≤2.5 s 且具备连续失败早退

> 这是**产品契约变更**，不是静默改参数。若产品侧不认可 2 帧 quorum，请回退修复 2 的 `minimumEvidenceFrames`，其余修复不受影响。

---

## 七、新增/修改文件

| 文件 | 类型 | 说明 |
| --- | --- | --- |
| `tools/PriorMap/tag_capture_backtest.py` | 新增 | 现场数据回测工具，门级失败归因 + 策略对比 + `--json` 归档 |
| `tools/PriorMap/dynamic_filter_benchmark.py` | 新增 | 动态过滤热循环基准，真实地图包 |
| `tools/PriorMap/localization_trace_diagnostic.py` | 新增 | 定位 trace 诊断：拒绝原因分布 + **门限拟合表** + 歧义/残差反证 |
| `tools/PriorMap/tests/test_tag_capture_backtest.py` | 新增 | 15 个回归用例 |
| `tools/PriorMap/tests/test_localization_trace_diagnostic.py` | 新增 | 9 个回归用例 |
| `app/ios/RTABMapApp/PriceTagCaptureCore.swift` | 修改 | 分层 ROI、2/2/3 契约、分级 quorum、早退 |
| `app/ios/RTABMapApp/MobilePostProcessing/ShelfLocalizationEvidence.swift` | 修改 | 包围盒预筛、栅格上界 |
| `tools/PriorMap/tests/swift/main.swift` | 修改 | 契约更新 + 三道防回退断言 |

---

## 八、未完成项与风险（诚实披露）

用户要求的验收底线是"端到端稳定成功运行、各环节无异常中断"。**本轮未达成这一底线的全部验证**，原因如下：

| 未验证项 | 原因 | 建议 |
| --- | --- | --- |
| **真机端到端扫描** | 需要签名 iPhone（LiDAR）+ 门店现场，本机无法执行 | 必须补，这是唯一能证明成功率的手段 |
| **Xcode 完整 Archive 构建** | 本机执行了 CI 同款 `swiftc -parse`（87 文件）与 Swift host 编译链接（385 测试内含），未执行 Xcode 工程全量 Archive | 建议在 CI 或本机跑一次 `RTABMapApp-QualifiedDevice` Release |
| **Qualification 1 个用例** | 执行环境沙箱拦截 `os.link()`，非代码缺陷 | 在无沙箱环境或 CI 上复核 |
| **发布门仍然恒假** | 手机 `ShelfLocalizationPolicy.calibrationStatus` 硬编码 `CALIBRATION_PENDING`，PC `production_publish_permitted` 因此恒为 false | 需现场标定 C-1/C-2/C-3（首轮 P0-3，本轮未动） |
| **定位 usable 比例 0.2%** | 根因已定位为平行货架几何多解（第四节），但破解需要引入非周期锚点，属算法改动，需真机验证收益与风险 | 见第九节建议 1 |

**关键限定**：64.9% 是**回测**成功率，表示"按修复后策略，现场这批 burst 中有 48 个能走完采集→形成结果"。它不等于真机成功率，也不等于可发布率——这 48 个结果仍会因 `needs_review`/`LOW_CONFIDENCE` 而被拒绝自动发布，需人工确认。这是设计意图，不是残留缺陷。

---

## 九、建议的下一步（按优先级）

1. **引入非周期结构锚点**（破解定位多解，本轮已定位根因，方案明确）：为距离场额外生成一层
   角点/端点显著性图（`MapPillar` 柱子、`MapCross` 交叉口、墙角、货架端头），与现有边缘距离场并行匹配。
   这是**纯软件、可在本机用现有 trace 数据验证**的改动，建议作为下一个迭代的主体。
2. **跑一次真机回归**：同一门店、同一路线，扫 3 次，用 `tag_capture_backtest.py --json` 与
   `localization_trace_diagnostic.py --json` 归档前后对比。这是验证 64.9% 与定位改善的唯一方式。
3. **现场标定 C-1/C-2/C-3**（解锁发布门）：需要 ≥20 个控制点的真值数据集。
4. **真值验收**：按首轮建议的门槛（点位中位误差 ≤0.5 m、P95 ≤1.0 m、价签可发布 ≥90%）。
5. **确认契约变更**：产品侧是否接受 2 帧 quorum。

> 首轮建议的"加匹配拒绝原因遥测"现已关闭：既有 `localization_trace.jsonl` 的 `constraintReason`
> 字段已经提供了门级归因，`localization_trace_diagnostic.py` 可直接复用，不需要新增埋点。
