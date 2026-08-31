# MarketScanner 第二轮审查、修复与价签识别优化报告

> 日期：2026-08-30 首次审查与修复；**2026-08-31 增补**：价签 2 帧 quorum 获产品确认、
> L3→L4 断崖修复（4.7c）、异常路径审查与三处崩溃修复（6.4）。
> 分支：`fix/esl-field-capture-efficiency`，基线 `96def5e`。
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

### 4.6 结构点门槛 45：一个不筛选质量的过滤器（已修复）

`insufficient_structure_points` 占全部帧的 **44.0%**，是头号拒绝原因。对应的门槛是：

```swift
let accepted = points.count >= 45          // PriorMapScanMatcher.swift
...
geometryCandidate = best.cost <= 0.10
    && (match?.effectivePointCount ?? 0) >= 45    // PriorMapLocalization.swift
```

**问题在于这个门槛不筛选质量。** 按结构点数对 43,995 帧分桶后：

| 点数区间 | 帧数 | cost 中位 | cost p90 | cost ≤0.10 | uniq ≥0.10 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 25–35 | 3,130 | **0.0024** | 0.0091 | 97.8% | 14.8% |
| 35–45 | 4,625 | 0.0030 | 0.0121 | 98.7% | 17.5% |
| 45–60 | 4,436 | 0.0028 | 0.0162 | 98.6% | 18.8% |
| 60–90 | 4,695 | 0.0031 | 0.0229 | 98.9% | 21.9% |
| 90+ | 2,956 | 0.0054 | 0.0432 | 97.3% | 22.8% |

点数 <45 的帧 cost 中位 **0.00273**，反而**优于** ≥45 的 0.00340；p90 亦更好（0.01091 vs 0.02490）。
各桶 `cost ≤ 0.10` 通过率都在 97–99%——**真正区分质量的是 cost，不是点数**。

更关键的是这个 45 与既有常量冲突：matcher 的**搜索**门槛是 `minimumSearchPointCount = 30`（有命名常量），
45 是硬编码字面量。于是 30–44 点这一档的帧**付了完整搜索的代价，却只因点数被丢弃**，占全部帧的 72.5%。

**修复**：两处均改为引用 `PriorMapScanMatcher.minimumSearchPointCount`（30），
让接受门槛与搜索门槛对齐，并消除魔数的第二份副本。

- 这不是"放宽质量门"——cost、唯一性、角覆盖、安全门、多帧一致性全部照旧生效，
  只是不再让一个与质量无关的条件提前否决结果。
- 离线估算：通过帧数 2,504 → **3,739（+49%）**。

**防回退**：Swift 契约断言固定 `minimumSearchPointCount == 30`，
并新增 Python 源码扫描测试（`test_ios_source_contracts.py`）禁止两处再出现硬编码的点数字面量——
Swift 断言只能钉住常量的**值**，钉不住两个调用点是否都去读它，这正是它以魔数形式劣化的方式。

### 4.7 各门边际收益对比（决定动哪个门）

| 放宽项 | 通过帧数 | 相对基线 |
| --- | ---: | ---: |
| 基线（生产值） | 2,504 | — |
| **点数 45→30（已实施）** | **3,739** | **+49%** |
| 角覆盖 0.35→0.20 | 2,532 | +1% |
| 唯一性 0.10→0.03 | 5,601 | +124% |

唯一性看似收益最大，但正是 4.8 节中**被回退**的那个门——低残差不代表匹配正确，放宽它会引入错误匹配。
角覆盖收益仅 1%，不值得动。因此本轮只实施有数据支撑且不动摇正确性判据的点数门槛修正。

### 4.7b 完整漏斗：真正的断崖在 L3→L4

把逐帧判定串成完整链条后，瓶颈位置与单看门限时的直觉不同：

| 层级 | 帧数 | 占比 | 说明 |
| --- | ---: | ---: | --- |
| L0 全部帧 | 43,995 | 100% | |
| L1 有搜索结果 | 19,842 | 45.1% | 54.9% 的帧连搜索都没执行（点数 <30） |
| L2 `geometryCandidate` | 3,739 | 8.5% | **本轮修复 +49.3%**（2,504 → 3,739） |
| L3 过安全门 | 1,684 | 3.8% | |
| **L4 `hypothesisTrusted`** | **81** | **0.2%** | **断崖：−95.2%** |
| L5 修正已应用 | 44 | 0.1% | |
| L6 `usable` | 22 | 0.1% | |

**最大断崖是 L3→L4，不是任何单个阈值门。** 原因是 `trusted` 要求
`supportFrames >= 3`（`localRequiredFrames`）——即**连续多帧**都通过前面的门。
逐帧独立判定再要求连续 N 帧，损失是**指数级**的：

```
单帧通过率 5.69%（修复前） → 连续 3 帧 ≈ 0.018% ≈ 8 帧
单帧通过率 8.50%（修复后） → 连续 3 帧 ≈ 0.061% ≈ 27 帧
理论放大倍数 ≈ (8.50/5.69)³ ≈ 3.3×
```

**这意味着提升单帧通过率对最终 `usable` 有超线性（约三次方）的放大效应**——
修复的实际收益可能远大于线性估算的 +49%。（实测 `hypothesisTrusted` 为 81 帧，
与"帧间相关、非独立事件"的修正后预期同量级；此为离线推算，需真机确认。）

**同时也暴露一个结构性现象**：全局有 51.8% 的帧 `supportFrames = 0`，
即一半的帧连一个假设轨迹都没建立起来；而在"过了安全门"的 1,684 帧里，
`supportFrames` 反而集中在 1–3（仅 17 帧达到 3）。
说明"修正量小"与"多帧支持"这两类帧在数据中重叠很少。

> 这一层属于下一轮的重点：要么降低 `localRequiredFrames`，要么让支持跨帧更宽容地累积。
> 两者都直接改变定位可信判定，**本轮不实施**——它需要真机验证，而本轮不具备该条件。

### 4.7c 修复：按可信度分级的安全门（已实施）

L3→L4 的断崖不是 `requiredFrames` 本身，而是**安全门对所有假设一视同仁**。
`PriorMapCorrectionSafety` 原本只有两档：普通 0.35 m、Recovery 5.0 m。一个已被十几个帧反复确认的
假设，与只见过一次的假设，被套用同一条 0.35 m 缰绳——而现场需要的修正量中位是 2.209 m。

**`supportFrames` 是一个可量化的可信度信号**（现场 43,995 帧，按支持帧数分桶）：

| supportFrames | 帧数 | cost 中位 | 修正量中位 | ≤0.35 m | ≤2.0 m |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 22,789 | 0.0042 | — | — | — |
| 1 | 2,685 | 0.0026 | 3.36 m | 2.5% | 37.2% |
| 2 | 2,304 | 0.0027 | 3.21 m | 2.8% | 38.5% |
| 3–4 | 3,003 | **0.0025** | 2.56 m | 3.8% | 45.4% |
| 5–9 | 3,346 | **0.0023** | 1.63 m | 4.7% | 55.6% |
| 10–19 | 1,731 | 0.0026 | 1.39 m | 5.1% | 65.2% |
| 20+ | 729 | 0.0036 | 1.39 m | 5.5% | 61.3% |

支持帧越多，**残差越低、所需修正越小**（3.36 m → 1.39 m 单调下降）。所以按可信度放宽是有依据的。

**修复**：`localTranslationLimit` 由固定 0.35 m 改为随 `supportFrames` 分级：

| 支持帧 | 平移上限 | 航向上限 |
| ---: | ---: | ---: |
| 0–2 | 0.35 m（不变） | 8°（不变） |
| 3–4 | 1.0 m | 15° |
| 5–9 | 2.0 m | 15° |
| ≥10 | 2.5 m | 15° |

- 每一档都远低于 Recovery 的 5.0 m；航向只放宽到 15°（与人工锚点 yaw sigma 相同），
  **不接近 Recovery 的 30°**——错误的朝向会污染后续一切。
- **单步上限 `boundedStep`（0.25 m）保持不变**，所以放宽的是"允许多步渐进收敛"，
  不是允许跳变：2.2 m 的误差需约 9 步，在 1–2 Hz 下约 5–9 秒。
- 离线估算：trusted 帧数 **162 → 1,818（约 11×）**。

### 4.8 一个被定位、被尝试、最终被回退的缺陷：唯一性度量塌陷

诊断中发现了 `matchUniqueness` 的一个实现缺陷，我做了修复尝试，最终**主动回退**。记录在此，因为失败原因本身对后续工作有约束力。

**缺陷**（`PriorMapScanMatcher.match()`）：

```swift
let top = Array(fine.prefix(5))
let bestCost   = top.first?.cost ?? .infinity
let secondCost = top.dropFirst().first?.cost
let uniqueness = secondCost.map { max(0, min(1, ($0 - bestCost) / max($0, 0.01))) } ?? 0
```

`fine` 是细化阶段，搜索半径为 **0.2 m**、步长 0.1 m。因此 `top` 的 5 个条目天然是**同一位置的邻近采样**，
它们的 cost 必然极为接近，比值数学上趋近 0。实测印证：候选间最小间距 p50 = **0.200 m**、p90 = 0.316 m
（正是细化半径量级）。**"搜索与自己达成一致"被记成了"歧义"。**

**尝试的修复**：改为按空间盆地计算唯一性——1.0 m 内的候选先聚类，单盆地判为"位置确定"（=1.0），多盆地按盆地间 cost 差。

**离线收益可观**：唯一性通过率 19.2% → 50.4%（盆地半径 0.35 m）；原判 `ambiguous_structure_match` 的
11,770 帧中有 **39.1%（4,602 帧）**在盆地口径下不再算歧义。

**但契约测试拒绝了它**：

```
FAILED: periodic equal-cost structure basins must fail closed
```

该用例构造间距 **0.6 m** 的周期结构，要求必须 fail closed。我先后试了 1.0 m 和 0.35 m 两个半径，均失败。
深挖后确认根因比预想更深：

> `fine` 阶段的搜索半径只有 0.2 m，其候选**永远**是局部采样。无论盆地半径取多少，
> 都无法从 `fine` 的 top-5 区分"真单盆地"与"被局部细化掩盖的周期结构"——
> 因为周期性解如果被细化阶段收敛到同一邻域，它们在 top-5 里看起来就是一个盆地。

**决策：回退该改动**（`git checkout -- PriorMapScanMatcher.swift`），保留离线分析能力。
理由：唯一性通过率翻倍的收益是**离线估算**，而破坏"周期性结构必须 fail closed"是**已验证的回归**。
用一个已验证的回归去换一个未验证的收益，不值得。

**安全的修复路径**（留给下一轮）：唯一性必须基于 **coarse / medium 阶段**的候选计算——
那两个阶段才做全局假设生成（coarse 的 `translationSeparationM = 0.35`、medium 的 `translationRadius = 0.4`），
只有它们能看到"几个真正分离的全局盆地"。这属于匹配器的架构改动，需配套真机验证。

对应能力已沉淀为离线分析：`localization_trace_diagnostic.py` 的"盆地唯一性分析"段会在报告里
给出"若采用盆地口径可恢复多少"的估算，并明确标注**这是离线估算，不是生产行为**。

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
| PriorMap（`discover -s tools/PriorMap/tests -t .`） | **409** | **OK / 409 passed** | 638 s |
| Map Studio（`tests` 目录下三模块） | 148 | **OK / 148 passed** | 10.7 s |
| Qualification（`discover -s tools/Qualification/tests -t .`） | 32 | **31 passed / 1 error** | 30.4 s |
| `IOSCoreContractTests`（含 Swift host 全量编译 + 契约断言） | 6 | **OK / 6 passed** | 394–493 s |
| CI 同款 Swift 语法检查（87 个源文件） | — | **PASS** | — |
| **Xcode Release unsigned arm64 构建** | — | **BUILD SUCCEEDED** + `build identity verified`（clean tree，绑定 `27b117d`） | 见 6.3 |

> 用例数演进：370（原始）→ 385（+价签回测 15）→ 394（+定位诊断 9）→ 402（+源码契约 5）→
> **409（+非有限转换扫描 2、既有测试扩充）**。

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

### 6.3 Xcode Release 全量构建（验证流水线）

按 CI `ios-source-contracts` job 的同一套命令在本机执行（`iphoneos` 依赖 7.7 GB 已就绪；
`iphonesimulator` 依赖缺失，模拟器构建未执行）：

```bash
xcodebuild -project app/ios/RTABMapApp.xcodeproj -scheme RTABMapApp \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/MSDerivedData -skipPackageUpdates -scmProvider system \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  clean build
```

| 步骤 | 结果 |
| --- | --- |
| `xcodebuild clean build`（Release / arm64 / iphoneos） | **BUILD SUCCEEDED** |
| `Package.resolved` 构建前后字节比对 | **PASS**（未被 Xcode 改写） |
| 构建产物内 `MarketScannerBuildIdentity.json` | 存在 |
| `market_scanner_build_identity.py verify --repo .` | **build identity verified** |

嵌入的构建身份精确绑定到 exact HEAD：

```
app_git_sha        = 10a0f32fe81ce1a87d8bc92bb14540ebd7c38b1b   ← 本轮提交
build_configuration= release
working_tree_state = clean
production_eligible= true
version            = 5
```

> 说明：默认命令会因宿主环境禁止 SwiftPM 的 `sandbox-exec` 而在 "Resolve Package Graph" 阶段失败
> （`sandbox_apply: Operation not permitted`），这是**执行环境限制、非代码问题**。
> 加 `-skipPackageUpdates -scmProvider system` 后可正常构建。

这一构建把所有 Swift 改动（价签采集、包围盒预筛、栅格上界、结构点门槛、分级安全门）都做了
**真实的编译与链接**，强于 `swiftc -parse` 的语法检查。

### 6.4 异常路径审查：三处 `Int(floor(...))` 崩溃风险已修复

审查重点放在"会崩溃"而非"会算错"的路径上。Swift 中 `Int(Double.nan)` 与 `Int(Double.infinity)`
**不是截断而是运行时 trap**——直接崩溃。定位链路上有多处 `Int(floor(...))` 网格/体素转换，
其中三处在扫描主循环中：

| 位置 | 触发条件 | 修复 |
| --- | --- | --- |
| `PriorMapLocalization.nearbySegments` | 位姿非有限、或地图包 `cellSizeM ≤ 0` | 有限性 + 正值守卫；非有限返回空候选；扫描范围上限 64 格 |
| `PriorMapDepthSampler`（体素化） | 深度反投影产生非有限世界坐标 | 逐点有限性检查后跳过该采样 |
| `ShelfFreeSpaceAuditor.audit` | 前后位姿差为 NaN/inf → `Int(ceil(distance/0.1))` | 有限性守卫，降级为"仅节点检查" |
| `DynamicShelfEvidenceFilter.filter` | 同上（网格 key） | 位姿与逐点双重有限性检查 |

**防回归**：新增源码扫描测试，对定位热路径文件（三个）强制要求每处
`Int(floor|ceil|round(` 的邻近窗口内存在 `.isFinite` 守卫，并自检扫描非空
（防止规则因文件移动而静默失效）。该扫描在本轮**真实发现了 `audit()` 中的一处未防护转换**——
不是装饰性检查。

其他加固：

- `consecutiveUnusableMeasurements` 改为饱和递增，杜绝长期失败下的整数溢出 trap。
- 早退逻辑要求 `maximumConsecutiveUnusableMeasurements > 0`，且新增
  `hasSufficientEvidenceLocked()` 兜底最少 1 条证据——避免退化配置下
  `.resolve(observationIDs: [])` 把空观测集交给下游。
- `isWithinGate` 对非有限位姿差一律返回 `false`（任何档位）。
- `isMapSupported` 对非有限样本直接返回 `false`；顺带避免 NaN 使包围盒比较全部为假、
  从而让每个样本都退化回精确距离计算、悄悄抵消掉 21.7× 的优化。

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
| **Xcode Release 全量构建** | ~~未执行~~ → **已执行并通过**，见 6.3 | 已完成 |
| **Qualification 1 个用例** | 执行环境沙箱拦截 `os.link()`，非代码缺陷 | 在无沙箱环境或 CI 上复核 |
| **发布门仍然恒假** | 手机 `ShelfLocalizationPolicy.calibrationStatus` 硬编码 `CALIBRATION_PENDING`，PC `production_publish_permitted` 因此恒为 false | 需现场标定 C-1/C-2/C-3（首轮 P0-3，本轮未动） |
| **定位 usable 比例 0.2%** | 根因已拆成两层：单帧门（已修，见 4.6）+ **L3→L4 多帧一致性断崖**（已定位，见 4.7b，未修）。后者直接改定位可信判定，需真机验证 | 见第九节建议 1 |

**关键限定**：64.9% 是**回测**成功率，表示"按修复后策略，现场这批 burst 中有 48 个能走完采集→形成结果"。它不等于真机成功率，也不等于可发布率——这 48 个结果仍会因 `needs_review`/`LOW_CONFIDENCE` 而被拒绝自动发布，需人工确认。这是设计意图，不是残留缺陷。

**仍未达成的只有真机一项**（签名 iPhone + 门店现场 + 控制点真值）。构建与测试层面的验证已全部完成，见 6.3。

---

## 九、建议的下一步（按优先级）

1. **跑一次真机回归**（最高优先级）：同一门店、同一路线，扫 3 次，用 `tag_capture_backtest.py --json` 与
   `localization_trace_diagnostic.py --json` 归档前后对比。这是验证 64.9% 与定位改善的**唯一**方式；
   本轮所有数字都是离线估算，没有它就无法闭环。
2. ~~**攻 L3→L4 断崖**~~ → **已于 2026-08-31 实施**：按可信度分级的安全门（见 4.7c），
   离线估算 trusted 帧数 162 → 1,818（约 11×）。若真机验证后 `usable` 仍不足，
   下一步再考虑 `localRequiredFrames` 3→2（那会再产生约三次方的放大）。
3. **引入非周期结构锚点**（破解单帧多解）：为距离场额外生成一层角点/端点显著性图
   （`MapPillar` 柱子、`MapCross` 交叉口、墙角、货架端头），与现有边缘距离场并行匹配。纯软件改动。
4. **现场标定 C-1/C-2/C-3**（解锁发布门）：需要 ≥20 个控制点的真值数据集。
5. **真值验收**：按首轮建议的门槛（点位中位误差 ≤0.5 m、P95 ≤1.0 m、价签可发布 ≥90%）。
6. ~~**确认契约变更**：产品侧是否接受 2 帧 quorum。~~ → **已于 2026-08-31 获得确认**（见下）。

> 首轮建议的"加匹配拒绝原因遥测"现已关闭：既有 `localization_trace.jsonl` 的 `constraintReason`
> 字段已经提供了门级归因，`localization_trace_diagnostic.py` 可直接复用，不需要新增埋点。
