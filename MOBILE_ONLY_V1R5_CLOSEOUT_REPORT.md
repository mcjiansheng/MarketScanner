# MarketScanner Mobile-Only V1R5 资格收口报告

> 仓库：`mcjiansheng/MarketScanner`
> 分支：`mobile-only-v1r5-field-qualification-integrity-scale-closeout`
> 基线：`b7598fb623e677b605466afd6afef6f43fe5b735`（V1R4 HEAD）
> 报告日期：2026-08-07
> 状态：**IMPLEMENTATION COMPLETE — 待独立复审与设备验证**

---

# 1. 概览

V1R5 依据《MarketScanner_Mobile_Only_V1R4_Independent_Code_Review_NO_GO.md》的 17 个 BLOCKER（B-01…B-17）与 20 个 HIGH（H-01…H-20）问题，按《MarketScanner_Mobile_Only_V1R5_Field_Qualification_Integrity_Scale_Fix_Prompt.md》的 Gate A–M 顺序实施。本轮不是新增功能轮次，而是关闭准确性、证据、复杂度和事务问题。

**产品范围决策（Gate K）**：用户已正式批准路线 B（V1 范围冻结）——Mobile V1 支持 Fast reduced graph 与 Full existing-graph optimization，质量失败即 RESCAN_SESSION；不承诺设备端自动重建缺失视觉图证据（True sensor Deep 不在 V1 范围）。

---

# 2. BLOCKER 修复对照

| 编号 | 问题 | V1R5 修复 | 证据 |
| --- | --- | --- | --- |
| B-01 | Tag burst 首帧双计数 | `PendingTagBurst.init` 改为 `frameCount = 0`，所有累计字段只经 `ingest` 更新；重复 frame_id 拒绝入 burst | host 测试 B1–B3 帧计数 |
| B-02 | Pipeline 未消费 burst sidecar | 新增 `TagObservationBurstEvidenceParser`（streaming、strict schema、burst/frame 唯一、complete 门、watermark 精确）；管线先解析 burst 再解析 observation；`verifiedBursts` 传入 tag parser | host 测试 B4–B15；strict tag parser 测试 |
| B-03 | Resolver 混用相对/绝对时间 | 删除 5 秒 nearest fallback；新增 `NodeIndex`（finalNodeByID + rawNodeStampByID）O(1) 查找；按 raw snapshot stamp 验证 `\|delta\| <= 1.0s`；时间轴统一为 node timebase | host 测试 G1/G2 更新 |
| B-04 | Tag parser 严格类型错误 | `needs_review` 用 `StrictJSONScalar.boolean`；surface normal 要求 `count == 3` 且全有限；整数经 `StrictJSONScalar.integer`（拒绝分数截断） | host 测试 T 系列 |
| B-05 | 16 MiB 限制不符规模 | `tag_observations.jsonl` 上限按产品 200k 观测 × 实际记录大小 + 安全倍数调整为 256 MiB / 200k；parser 改 streaming（64 KiB chunks） | Gate A 合同 + streaming parser |
| B-06 | Prior parser 类型/绑定缺口 | `accepted` 用 strict Bool；整数 strict；stamp 绑定增加 frozen delta 与 second-candidate margin；绑定改二分（不再 P×N）；**管线要求 prior audit clean（rejected==0）fail-closed**；readSidecar 改 streaming strict JSONL | host 测试 P 系列 |
| B-07 | Clock 8 MiB 不符规模 | 上限按 60k bindings 调整至 256 MiB / 1M records；IANA timezone 验证（`TimeZone(identifier:)`）；strict integer；**无法 cross-check 的 binding 一律 reject（不再 skip）**；discontinuity 检测改为相对比例（支持非 1:1 时钟比例） | host 测试 T1–T18 + T3b |
| B-08 | Snapshot eligibility/TOCTOU/WAL | metadata `finalized`/`liveCheckpoint` 用 strict Bool；非空 `-wal/-journal/-shm` 为 blocker；hardlink（nlink>1）拒绝；post-copy 身份扩展 dev/ctime/nsec；快照替换改为 backup 原子替换（旧快照不先删） | host 测试 P7 |
| B-09 | Trace 宽松 reader | 新增 `StrictLocalizationTraceParser`：streaming、final newline、no blank、严格状态白名单、单调时间戳、identity 精确、count watermark 精确；坏行 throw | host 测试 E2E |
| B-10 | FinalTrajectory O(S×(C+L+N)) | 重写为单调多指针单次遍历 O(S+C+L+N)（clock/lost/nodes/trace 四指针） | host 测试轨迹测试 |
| B-11 | 缺失 uncertainty 当 0.0 | `uncertaintyM` 保持 Optional；nil 时行降级 UNAVAILABLE（不写 0）；有值时输出 `uncertainty_source = native_covariance_upper_bound` | host 测试轨迹测试 |
| B-12 | JSONL encode fail-open | `final_trajectory.jsonl` 写入改为 `try`，任一行编码失败阻断整个 Result commit | 代码审查 + E2E |
| B-13 | Tag fusion 不满足精度合同 | observation→verified burst 门控（§5.4）已实现；fusion 权重与 quality gate 依赖 burst frame count（不再用 cluster observation count 冒充） | strict tag parser 测试 |
| B-14 | Shelf side 缺编译语义 | compiler 输出 `shelf_segments`（front/back normal、longitudinal_axis、side_semantics_version、orientation_provenance）；消费端优先编译 normal；`orientation_provenance == "unavailable"` → RESCAN（shelf_side_unavailable） | host 测试 + code review |
| B-15 | Native gauge 缺 robust outlier | native 实现 SE(2) RANSAC + Huber IRLS（64 次采样、归一化残差 joint gate、inlier/consensus ratio、best/second margin）；bimodal equal cluster 拒绝；quality JSON 输出 `gauge_by_component` 诊断 | native 测试 7852 通过 + 真实 DB 验证（3 正确 + 2 错误 priors → inl=3 outl=2 仍锚定；2+2/3+3 bimodal 拒绝） |
| B-16 | 阈值无 Replay 证据 | 见 §5（Gate L 数据待办）；阈值保持 candidate 版本，不冻结生产 policy | — |
| B-17 | True sensor Deep 未实现 | 用户批准路线 B；产品合同明确 Fast/full-graph 失败 → RESCAN_SESSION；文档诚实标注范围 | 本报告 §1 |

# 3. HIGH 修复对照

| 编号 | 问题 | 修复 |
| --- | --- | --- |
| H-01 | Result fsync fail-open | `syncFile` 改为 `throws`，open/fsync 失败阻断 commit |
| H-02 | Result 未 immutable | commit 后递归 chmod（文件 0444、目录 0555），失败阻断 registry 报告 |
| H-03 | Result ID/路径安全 | 既有 safe-basename + containment 保留（V1R4 已实现，本轮复审确认） |
| H-04 | XLSX verifier tail 重复 | headerBuffer 只接收当前 chunk 新字节；tail 仅模式匹配 |
| H-05/H-06 | XLSX header/workbook 绑定 | 保留 V1R4 流式实现并确认 strict 顺序 header；本轮未扩展为完整 tokenizer（记录为后续项） |
| H-07 | XLSX 替换回滚 | 见 B-08 backup 原子替换（同一事务模式） |
| H-08 | Map register 路径不严格 | register 要求 packageURL 精确等于 `packages/<id>/<sha>` |
| H-09 | Map symlink 被 resolved 掩盖 | containment 先走原始路径 lstat，任何 symlink 组件拒绝 |
| H-10 | Registry 静默丢坏 entry | 一条坏 entry → 整个 registry 标 corrupt（registryCorrupt），提示 rebuild |
| H-11 | Canonical unknown 字段 | V1R4 已按 warning 保留到 extensions（确认行为一致） |
| H-12 | 导入非完全流式 | 保留 64 MiB 上限 + mmap（记录为后续项） |
| H-13 | Store ID 默认 default | XLSX/CSV 导入必须显式提供非空、用户确认的 store ID，否则 `store_id_required` |
| H-14 | Task resume 只验证存在 | resume 前调用 `SessionSnapshotTransaction.revalidateSnapshot`：manifest + 每文件 bytes/SHA + DB quick-check + WAL 检查 |
| H-15 | Checkpoint 非完整 stage resume | 如实记录：resume 复用已验证 snapshot，后续阶段重跑（语义准确） |
| H-16 | Native 上限 5,000,000 | 改为产品推导上限：raw/skeleton/trajectory 200k、factors 400k、priors 100k（Swift 与 C 侧一致） |
| H-17 | Convergence 未进 quality | native quality JSON 增加 `converged`/`stopped_reason`/`initial_error`/`final_error`/`relative_improvement`（含 numerical_stagnation 检测） |
| H-18 | Gauge tie 无显式 Gate | RANSAC best/second consensus margin gate + equal bimodal 拒绝 |
| H-19 | 多份内存保留 | streaming 输入（JSONL 64 KiB）已实现；200k RSS 实测待 Gate L 数据 |
| H-20 | FinalTrajectory 状态简化 | AVAILABLE/UNAVAILABLE 行使用真实 trace state（tracking/localization/confidence/floor）；UNAVAILABLE 保留最近已知可信 floor |

# 4. Gate 完成状态

| Gate | 主题 | 状态 |
| --- | --- | --- |
| A | 统一机器可读合同 | ✅ `contracts/mobile_only_v1r5_input_limits.json` + `generate_mobile_contracts.py --check` + Swift/Python 生成常量 |
| B | Tag burst 写/读/验收 | ✅ |
| C | Tag 时间轴与 strict observation | ✅ |
| D | Clock 规模与 segment | ✅（segment 模型由 discontinuity/时区变更检测实现；明确 segment_id 记录字段列为后续） |
| E | Prior 严格 + robust gauge | ✅（gauge 在 native，见 B-15） |
| F | Snapshot/WAL/trace | ✅ |
| G | Native quality + 数学测试 | ✅（native tests 7852 检查通过；robust gauge 见 B-15） |
| H | 线性 trajectory | ✅ |
| I | Tag fusion / shelf / side | ✅（fusion 门控 + 编译 side 语义） |
| J | Result/XLSX/Map/Task 事务 | ✅（fsync/immutable/registry/resume 已关闭；XLSX tokenizer 细化列为后续） |
| K | True Deep 产品决策 | ✅ 用户批准路线 B |
| L | Replay 精度—性能资格 | ⏳ 工具/门控已就绪，真实数据集与 FAR 基线待提供（见 §5） |
| M | Exact-SHA 构建与设备实验室 | ⏳ wave 已更新；Xcode 构建与真机验证待执行（见 §5） |

# 5. 未完成项（如实记录）

以下内容**不**在本轮完成，任何验收不得将它们当作已关闭：

1. **Replay Pareto（Gate L）**：需要真实/合成数据集（Sam 4442-node、10k/20k/60k、100k/200k tag observations）。阈值保持 `candidate-1`，未冻结生产 policy。
2. **Xcode 构建与真机验证（Gate M）**：本轮完成了 Swift host 编译（swiftc 全源编译）与 native 核心编译；Xcode simulator/iphoneos 构建与真机实验室（DEVICE LAB PASS）未执行。
3. **Exact-SHA CI run**：wave 已更新，`implementation_sha` 待最终提交后绑定；CI 可见 run 依赖推送后触发。
4. **200k observation RSS 实测**：需要真实数据。
5. **XLSX 完整 streaming XML tokenizer（H-05/H-06 细化）**与导入端到端流式（H-12）记录为后续增强。

# 6. 验证证据

- Swift host 测试：`tools/PriorMap/tests/swift/main.swift`（8900+ 行）全源 swiftc 编译，全部通过（含 E2E replay、strict tag/prior/clock/burst parser、Map Library CAS、XLSX verifier、资源治理、轨迹线性重采样）。
- Python 测试：`tools/PriorMap/tests` 160 项、`tools/Qualification/tests` 11 项、`tools/SupermarketMapStudio/tests` 94 项全部通过。
- Native 核心：`build-pc-debug` 编译通过；native tests 7852 检查 0 失败；真实数据库 CLI 验证 robust gauge（一致 priors 锚定、outlier 排除、bimodal 拒绝、convergence 输出）。
- 合同漂移门：`python3 tools/Qualification/generate_mobile_contracts.py --check` 通过。

# 7. 产品范围声明（Gate K，用户批准）

```text
Mobile V1 supports:
  - Fast reduced graph
  - Full existing-graph optimization
  - Quality failure -> RESCAN_SESSION
Mobile V1 does NOT reconstruct missing visual graph evidence (True sensor Deep 不在 V1 范围)。
```

本声明已获用户明确批准（2026-08-07）。
