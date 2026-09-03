# C-1 / C-2 判定窗口设计（现场交互、显示与判定逻辑）

> 文档状态：**当前有效**。最后核对日期：2026-09-03。
> 上游依据：`SHELF_LOCALIZATION_PRODUCT_SPECIFICATION_FROZEN_2026-08-15.md`（S-8、C-1/C-2 关闭方式）、
> `IMPLEMENTATION_STATUS.md` 2026-09-03 条目。本文冻结交互与逻辑设计；
> ViewController HUD 接线与真机验证在下一个分支执行，不属于本文范围。

## 1. 现状盘点（判定逻辑已存在的部分）

| 能力 | 位置 | 状态 |
| --- | --- | --- |
| C-2 低置信触发逻辑 | `ShelfTrackingStateMachine.update()`（`ShelfLocalizationEvidence.swift`）：`top1_top2_margin_below_calibration_pending_threshold`、`reliable_loop_distance_exceeded`、`structure_basin_support_insufficient`、`topology_reachability_failed`、`tracking_degradation_frequency_high` | 已实现，阈值 `CALIBRATION_PENDING` |
| C-2 状态输出 | `ShelfTrackingDecision.state` ∈ {bootstrap, tracking, lowConfidence}，`low_confidence_reasons` 已持久化进 `corridor_hypotheses.jsonl` | 已实现 |
| C-1 两侧一致性自动判定 | `ShelfLoopVerifier.accepts(...)`（手机侧实时执行）：同 `shelf_segment_id`、异侧、同 component、epoch 或有 bridge、候选 margin ≥ 阈值、两窗口 inlier 比 ≥ 阈值、对向法向夹角 > 阈值、phone↔shelf SE(2) 一致、非动态证据主导 | 已实现，结果写 `shelf_loop_events.jsonl`（accepted/reason） |
| 人工纠偏事件 | `manual_localization_events.jsonl`（manual v3，最近节点/第二候选/时间交叉核对） | 已实现 |

**结论：判定逻辑本身不需要重写；缺的是现场可见的“判定窗口”（显示 + 交互 + 标签回收）。**

## 2. C-2 现场判定窗口（低置信提示）

性质：**现场判定**——必须在扫描进行中提示，事后提示无意义。

### 2.1 触发条件（复用现有状态机，不新增逻辑）

状态机输出 `state == .lowConfidence` 即触发，原因是下列任一：

1. 第一/第二候选分差 < `calibrationPendingLowConfidenceMargin`（C-2a，初值 15%）；
2. 距上次可靠回环行进距离 > `calibrationPendingReliableLoopDistanceM`（C-2b，初值 30 m）；
3. 结构盆地支持不足 / 拓扑不可达 / tracking 降级频发（辅助原因，随主因一并显示）。

### 2.2 显示设计（HUD）

复用 `statusLabel` 体系，新增一个不遮挡取景的顶部横幅区：

- **常态（tracking）**：不显示，或仅显示一行小字当前通道身份（如 `通道 C3`），避免干扰；
- **低置信横幅**：黄色底、一行主文案 + 一个按钮：
  - 主文案按主因映射：
    - margin 不足 → `位置不确定：相邻通道难以区分`；
    - 回环距离超限 → `较长时间未闭环，建议核对位置`；
    - 结构/拓扑原因 → `结构证据不足，建议核对位置`；
  - 按钮：`核对位置` → 进入现有人工重定位选择器（可缩放/平移/旋转 + 数值微调）；
  - 副文案可显示候选数与前二名分差（如 `候选 3 · 分差 8%`），帮助现场人员判断；
- **人工纠正收敛后**：横幅立即消失（状态机已在 `manualRelocalizationConverged` 时清空原因）。

### 2.3 防抖与抑制（现场可用性的关键）

- 进入 `lowConfidence` 后横幅常驻，但**同一主因不重复弹出动画/声音**；
- 主因切换时更新文案（不重新动画）；
- 每次状态进入/离开/主因切换写一条 `scan_events.jsonl` 诊断事件（复用现有可选事件通道，坏行可隔离）。

### 2.4 标签回收（C-2 标定的数据来源，零新增合同）

- 用户点了 `核对位置` 并成功收敛 → 既有 `manual_localization_events.jsonl` 事件自动构成一个 **“提示前系统位置错误”** 标签；
- 用户无视横幅扫完全程且事后复核轨迹无误 → 构成 **“提示为误报”** 标签（由 PC 复核环节标注，见 §4）；
- 标定输入 = `corridor_hypotheses.jsonl`（当时分差/距离）× 上述标签；标定产物 = 冻结的 C-2a/C-2b 数值，回填 `ShelfLocalizationPolicy` 并把 `calibrationStatus` 从 `CALIBRATION_PENDING` 升级。

## 3. C-1 现场判定窗口（货架两侧闭环确认）

性质：**判定自动、显示现场、标定后期**。

### 3.1 判定逻辑（已完成，不改）

`ShelfLoopVerifier.accepts(...)` 在手机上对最新窗口与其对侧窗口实时执行八条检查（§1 表），结果与拒绝原因（`two_sided_consistency_confirmed` / `margin_insufficient` / `phone_shelf_se2_inconsistent` / …）写入 `shelf_loop_events.jsonl`。

### 3.2 现场显示设计（只做通知，不做拦截）

- `accepted == true` 时 HUD 顶部绿色短提示：`货架闭环确认：<shelf_segment_id>`，显示 3 秒自动消失；
- 连续被拒且主因为 `margin_insufficient` 时不提示（避免噪声），只在诊断事件里留痕；
- **不引入用户确认门**：两侧一致性是自动几何判定，人工确认只会拖慢扫描且不提供额外信息；人工纠偏入口统一在 C-2 横幅。

### 3.3 阈值标定（后期处理，本文只约定数据合同）

- 标定输入：历次现场会话的 `shelf_loop_events.jsonl`（accepted/reason/几何统计）+ 事后人工复核标签（该货架闭环是否真实成立，由 PC 复核台标注）；
- 方法：回放拟合（Pareto），目标函数 = 闭环召回率 ×（1 − 误闭环率），在 `relative_pose_delta / inlier_ratio / opposing_normal` 三维各取分界；
- 纪律：标定数据与验收数据分离；冻结值回填后禁止用验收结果反向调参（冻结规格既定纪律）。

## 4. 人工判定（复核标签）在什么环节产生

| 环节 | 谁 | 产生什么 | 去向 |
| --- | --- | --- | --- |
| 现场扫描中 | 扫描员 | 点 `核对位置` 并收敛 | `manual_localization_events.jsonl`（自动标签） |
| 现场扫描中 | 扫描员 | 无视横幅 | 无事件；由下一行回收 |
| PC 复核 | 复核员 | 轨迹对错逐段标注、货架闭环真伪标注 | `manual_edits.json`（既有事件日志 + CAS） |
| PC 标定 | 标定者 | 回放拟合得到冻结阈值 | 规格修订版 + `ShelfLocalizationPolicy` |

## 5. 明确不在本版范围

- ViewController 横幅控件与状态机接线的代码实现（下一分支，需真机验证文案可见性与遮挡）；
- C-1/C-2 阈值数值冻结（依赖现场标签积累，见 §2.4/§3.3）；
- 任何新的 sidecar 合同字段（本设计只消费既有四个 manifest v5 流 + manual/scan events）。
