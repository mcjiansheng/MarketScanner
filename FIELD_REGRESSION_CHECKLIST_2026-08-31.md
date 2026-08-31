# 真机回归检查清单

> 面向 2026-08-31 之后的现场回归。目标是用最短的现场时间，验证本轮（第二轮）
> 修复在真实设备与真实门店上是否成立。
> 本文只列**必须执行**的动作与**必须归档**的数据，不做推测性结论。

---

## 0. 回归前准备（本机，约 5 分钟）

```bash
cd /Users/mcjiansheng/Documents/rtabmap-master
git status --short                 # 确认工作区干净
git log --oneline -1               # 应为 cc35768 或更新
```

构建并安装（Release，clean tree）：

```bash
# 若 tracked tree 有改动，先提交；Release 构建在 dirty tree 下会失败
xcodebuild -project app/ios/RTABMapApp.xcodeproj \
  -scheme RTABMapApp-QualifiedDevice -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/MSFieldBuild -skipPackageUpdates -scmProvider system \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES clean build
```

> 注意：宿主环境禁止 SwiftPM 的 `sandbox-exec`，必须带 `-skipPackageUpdates -scmProvider system`。

---

## 1. 现场执行（每个门店至少 3 趟）

**同一门店、同一路线、同一起点/朝向配置**，连续扫 3 趟。路线建议：

- 覆盖≥3 条平行通道（验证多解是否被正确拒绝或标注）
- 至少 1 次 U-turn 或回头（验证 gauge-neutral 恢复）
- 至少 1 次穿过通道交叉口（验证道路拓扑）
- 每趟扫 5–10 个 ESL 价签（验证价签链路）

每趟结束后**立即确认**：

- [ ] 会话正常 `finalized=true`（不是 recovery package）
- [ ] `segment_0001/` 下 `localization_trace.jsonl`、`clock_correlations.jsonl` 非空
- [ ] 若扫了价签：`tag_observations.jsonl` 与 `tag_observation_bursts.jsonl` 非空

导出会话（保留原始副本，不要只留处理结果）。

---

## 2. 回归后归档（本机，约 40 分钟）

假设现场会话放在 `扫描结果/2026-09-xx-门店名/`：

```bash
# ① 价签链路：成功率 + 耗时对比
python3 tools/PriorMap/tag_capture_backtest.py \
  --root 扫描结果/2026-09-xx-门店名 --compare --json after-tag.json

# ② 定位链路：拒绝原因分布 + 门限拟合 + 盆地分析
python3 tools/PriorMap/localization_trace_diagnostic.py \
  --root 扫描结果/2026-09-xx-门店名 --json after-diag.json

# ③ PC 处理链路：端到端成功率（自动迁移旧地图包）
python3 tools/PriorMap/batch_verify_pc_pipeline.py \
  --sessions-root 扫描结果/2026-09-xx-门店名 --json after-pc.json
```

三个 JSON 全部归档，用于跨提交对比。

---

## 3. 必看的判定指标

### 3.1 价签链路（本轮修复的直接目标）

| 指标 | 修复前基线 | 期望 |
| --- | ---: | --- |
| burst 成功率 | **0%**（0/74） | 明显 >0；若仍为 0，立即停止并回报 |
| 单次采集均值耗时 | 4.00 s | 接近 1.14 s（−71.5%） |
| 失败空等累计 | 267.8 s | 接近 59.0 s（−78.0%） |

若成功率仍为 0，请回报 `after-tag.json` 中的 `gate_failures` 分布——它会直接指出是哪一道门在拒绝。

### 3.2 定位链路

| 指标 | 修复前基线 | 期望 |
| --- | ---: | --- |
| `usable` 帧占比 | **0.2%**（94 / 43,995） | 上升；若仍在 0.2% 附近，说明分级安全门未产生预期收益 |
| `matchUniqueness` 中位 | 0 | 观察是否改善（本轮未改该门） |
| `constraintReason` 分布 | `insufficient_structure_points` 44.0% | 该比例应下降 |

用 `after-diag.json` 与仓库内既有诊断结果对比。

### 3.3 PC 处理链路

| 指标 | 修复前基线 | 期望 |
| --- | ---: | --- |
| 端到端成功率 | 未跑通过 | ≥86.7%（本次 13/15） |
| 含重复时钟绑定的会话 | 0/4 | 3/4 |

---

## 4. 需要现场特别留意的现象

出现以下任一情况，请**保留现场会话并回报**，不要重扫覆盖：

1. App 崩溃或闪退 —— 本轮修复了 3 处 `Int(floor(...))` trap，需确认是否还有遗漏路径
2. 实时坐标长时间不变 —— 曾有现场报告，本轮未直接修复，需确认是否复现
3. 扫描中途提示证据写入失败 / required-sidecar 失败
4. 结束后会话为 `finalized=false` 或生成 recovery package
5. 价签扫码反复失败或长时间等待（>4 s）

---

## 5. 已知未完成项（不要误判为回归失败）

- **定位绝对精度仍未验证**：本轮所有定位数字均为离线估算。需控制点真值才能判定精度。
- **发布门仍恒为 false**：手机 `calibrationStatus` 仍硬编码 `CALIBRATION_PENDING`，
  PC `production_publish_permitted` 因此恒为 false。这是设计上的保险丝，需 C-1/C-2/C-3 现场标定才解锁。
  **回归时出现 `production_publish_permitted=false` 属预期，不是缺陷。**
- **天虹地图包**需自动迁移才能处理；`batch_verify_pc_pipeline.py` 已集成，无需手工预处理。

---

## 6. 回归结果回报格式（便于快速定位）

```
门店 / 日期 / 设备型号 / iOS 版本 / App 提交 SHA：
趟数：3
价签：burst 总数 / 成功数 / 成功率 / 均值耗时
定位：usable 帧占比 / 主要 constraintReason top3
PC   ：会话数 / 成功数 / 失败会话及原因
异常：（崩溃、坐标不变、写入失败等，若无填"无"）
归档 JSON：after-tag.json / after-diag.json / after-pc.json
```
