# Mobile-Only V1R3 证据完整性、Native正确性与真机资格收口状态

> 分支：`mobile-only-v1r3-evidence-integrity-native-correctness-and-device-qualification-closeout`
> 基线：`mobile-only-v1r2-production-pipeline-and-device-readiness-closeout` HEAD `9de2908b4ea8f3169989ce37ddf25f671a511e03`
> 本文件核对日期：2026-08-06（实现 + Swift host 集成测试 + PC oracle 阶段）
> 权威代码事实：本分支当前源码；本文件与代码冲突时以已测试代码为准。

## Wave 身份

```json
{
  "wave": "mobile-only-v1r3-evidence-integrity-native-correctness-and-device-qualification-closeout",
  "branch": "mobile-only-v1r3-evidence-integrity-native-correctness-and-device-qualification-closeout",
  "base_branch": "mobile-only-v1r2-production-pipeline-and-device-readiness-closeout",
  "base_sha": "9de2908b4ea8f3169989ce37ddf25f671a511e03",
  "v1r2_head_sha": "9de2908b4ea8f3169989ce37ddf25f671a511e03",
  "implementation_sha": "6de0a4fbc65fd824e24f560fd379669c8b532d56",
  "validation_sha": "<FINAL_DOCS_GOVERNANCE_SHA>"
}
```

## 目标

关闭 V1R2 独立审查判定的 REJECTED 根因：native 图缺少 prior-map 全局
约束、snapshot 仍整库读入内存、node stamp 被无证据当 UTC、Deep 只是
全图再优化、单一大 component 不可中断、native bridge 指针生命周期风险、
information/covariance/quality 数学缺陷、tag false acceptance、result
package 与 XLSX 未端到端原子/流式。产品运行仍完全在 iPhone 内完成；
PC 仅作同源 core 的开发 oracle。

## 本轮交付（IMPLEMENTED + 已运行验证见下）

### Gate A — 扫描启动事务化（§4）

- `MobileOnlyScanStarting` 改为 `AnyObject` 协议并返回
  `MobileScanStartReceipt`（Codable/Equatable）；receipt 完整记录
  tracking/segment/database/prior-map/floor/store 身份、ARSession 与
  RTAB-Map 记录是否真正启动、sidecar writer 就绪、启动单调/UTC 时间、
  app Git SHA。
- `newScan` 改为 `@discardableResult ... -> Bool`：所有拒绝路径返回
  false（不再有静默 return 让上层误判成功）；ARSession/RTAB-Map 启动
  结果显式回传。
- 协调器 `commitScanConfiguration` 变为事务：validate → require host →
  host.start → validate receipt → persist receipt → scanning；任一步
  失败走 configuringScan → failed，绝不先进入 scanning。
- receipt 持久化到 `scan_receipts/<tracking-session>.json`，支持
  crash-after-host-start 的审计与恢复。

### Gate B — 起点方向与可通行性（§5）

- 冻结 yaw 合同：yaw=0 沿 map +X、正向逆时针；golden 方向 0°→右 /
  90°→上 / 180°→左 / -90°→下。重绘方向箭头使其在 yaw=0 指向 +X，
  消除 V1R2 箭头的 90° 偏置（不是改注释）。
- 起点 marker 使用显式 frame（非 AutoLayout），旋转变换不改变点击坐标。
- 可通行性门：起点必须在楼层边界内、不在货架/固定结构多边形内、且与
  最近障碍保持 ≥0.30 m clearance；非法点显示原因并禁用开始按钮。
- store/floor/manifest 一致性缺失阻断启动（§5.4）。

### Gate C — Prior-map 全局约束（§6）

- 新增 `MSAbsolutePriorC` 输入模型（node_id + map 帧位姿 + 3x3
  information + kind + episode_id），请求携带 prior_map_id/sha、
  tracking_session_id、projection_policy_version；不再只传 DB + tag IDs。
- 管线从 `localization_constraints.jsonl` / recovery / manual sidecar
  解析 accepted、身份一致、finite、node-bound 的证据；information 来自
  matcher uncertainty / recovery 质量 / manual 固定 policy，绝非常数。
- 无 accepted prior 时仅输出 LOCAL_FRAME_ONLY 诊断，不生成正式
  PriceTags/DevicePositions（fail closed）。
- publish component 必须被 prior 锚定；publish_ratio 进入 PASS 门。

### Gate E — P7R6D 级流式 immutable snapshot（§8）

- 资格检查（§8.1）：finalized、scanMode、trackingSessionId、
  requiredWriteFailureCount=0、无 live checkpoint、prior-map/store/floor
  身份匹配、app Git SHA 非 unknown。
- 每文件 POSIX 流式稳定复制（§8.3）：O_RDONLY|O_NOFOLLOW 源、pre fstat、
  regular-file 策略、O_CREAT|O_EXCL 目的、4 MiB 分块 + 增量 SHA-256、
  fsync、post-fstat 源身份校验、目的重开二次 SHA、chmod 只读。
- DB 只读校验（§8.5）：mode=ro&immutable=1、quick_check 恰一行 "ok"、
  Node/Link 表清单；DB 不整文件 Data。
- 动态磁盘预算（§8.6）：源字节 + 安全余量须容纳，否则 fail closed。
- 原子提交（§8.7）：staging 目录 → fsync → rename → fsync task root。
- watermark sidecar：`clock_correlations.jsonl` /
  `tag_observation_bursts.jsonl` 当 metadata watermark 声明已记录时为
  required，缺失即证据篡改。

### Gate F/G — Swift/C ABI 安全与严格 DB 读取（§9/§10）

- 所有 C 调用嵌套在 `withCString` / `withUnsafeBufferPointer` 作用域内，
  无临时桥接指针逃逸。
- outcome 全量校验（§9.2）：count 边界、指针非空、id 唯一/int 范围、
  stamp/pose finite、quality JSON 良构；未校验的原生内存一律不信任。
- 严格 BLOB 契约（§10.1）：pose/transform 恰 12 floats、information 恰
  36 doubles；短 information 零填充、长 BLOB 截断均拒绝。
- required node/link 损坏 fail closed（NON_RECOVERABLE_FAIL）；仅
  gravity/landmark 等 optional 类型隔离审计；non-monotonic stamp chain
  fail closed；void（全零）约束隔离不冒充。

### Gate H — information/factor 数学正确性（§11）

- 逆测量信息变换改为统计正确的协方差传播：Σ_w = J Σ Jᵀ 后取逆，J 为
  SE(2) 逆映射解析雅可比；修正了 d(z⁻¹).y/dyaw 的符号错误。
- 新可执行测试用中心差分在 1200 组随机 SPD 用例上验证解析式（容差
  1e-4），全部通过（§11.1）。
- SPD policy：valid / regularized_with_audit / rejected；对称化 + 特征值
  下限 + 条件数上限，绝不静默用 diag 替代。
- 聚合里程计协方差（§11.3）：Σ_total = Σ1 + Ad(T1)Σ2Ad(T1)ᵀ + …，
  与 Adjoint 公式数值一致（1e-9）。

### Gate I — 可中断 native 优化（§12）

- 分块迭代（每 5 次）在块间探测 cancel / wall-time，单一大 component
  也可中途取消；wall-time 预算耗尽 fail closed（RESOURCE_REQUIRED）。
- component 区分 global anchored / local diagnostic / tracking-lost
  fragment；只有被 prior 锚定的 publish component 可输出 AVAILABLE。

### Gate J — 真实 Deep 重处理（§13）

- 正名：当前全节点优化重命名为 `full_graph_optimization`，不再称 Deep
  reprocess；仅在 Fast RECOVERABLE_FAIL 时受控运行一次。
- 真传感器级 RTAB-Map 重处理（读 RGB/depth、特征提取、loop 候选、
  几何验证、重建 link）本轮未实现；管线在该情形 fail closed（转
  RESCAN），绝不冒用全图优化。

### Gate K — 质量门真实性（§14）

- 完整 rᵀΩr chi²（含 cross terms、pose prior 计入 chi²/DoF）。
- robust 统计改名为 `residual_threshold_ratio`（无法从 g2o 读真实
  robust weight，故不冒充 downweighted）。
- PASS 门纳入：malformed=0、coverage、prior coverage、prior/loop
  residual P95/max、chi2/DoF、correction P95/max/jump、publish ratio、
  tag-bound 节点全部恢复、identity 完整。
- quality JSON 用流式 string builder + 完整转义，绑定 policy/factor-set/
  graph-input/native-core SHA 与 projection 版本。

### Gate L — 完整轨迹业务完整性（§15/§7）

- correction field 保留 C_a/C_b 插值公式，但不跨 component/gap/map
  切换插值；每 raw node 保留 map_id/component_id/publish_eligible。
- uncertainty 不硬编码 0：无法估计时为 nil/UNAVAILABLE。
- clock 轴：优先使用扫描期记录的 clock_correlations.jsonl（扫描时区/
  offset），否则回退 stamp 轴；session end 取最后采集 stamp 而非
  finalization 墙钟（§7.5）。
- position 状态冻结为 AVAILABLE/UNAVAILABLE（原 ACCEPTED 已更正）。

### Gate Q — Result package 原子事务（§20）

- 所有产物先写 `Results/staging/<task>/<result>/`；提交时逐文件流式
  SHA、manifest 绑定 per-file SHA + input bundle SHA + native core SHA +
  processing path、fsync 文件与 staging 目录、原子 rename 入
  `Results/<result>/`、fsync parent；中途失败不可见于历史结果。
- 读取侧重验 manifest 与全部 required hash（§20.5）；损坏结果隔离并
  诊断，不静默列出。workbook SHA 用流式 `sha256File`，不整文件 Data。

### Gate D — 时钟证据（§7.1）

- 扫描期用 `ClockCorrelationRecorder` 记录 monotonic↔UTC 相关性
  （session_start / 每 30 s periodic / session_end），finalization 时
  落盘 `clock_correlations.jsonl`。

## 验证证据（本轮已跑）

- **unsigned arm64 iphoneos build：SUCCEEDED**（含本轮全部 Swift/C++
  改动的编译 + 链接，`xcodebuild -scheme RTABMapApp -configuration
  Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO`）。
- **native 可执行测试：7852 checks / 0 failures**
  （`rtabmap-market-scanner-native-tests`：SE2 恒等、逆信息解析 vs
  中心差分 1200 例、SPD policy、Adjoint 聚合协方差、reducer 必留节点、
  JSON 转义、合成图 C ABI 场景）。
- PC oracle 合成图三场景：clean+priors → PASS；wrong loops → robust
  处理；no priors → LOCAL_FRAME_ONLY。真实碎片会话 DB 保持 fail closed。
- Swift host 套件（含 Replay E2E、P7 snapshot、真实 SQLite fixture）OK。
- Qualification / SupermarketMapStudio / document-governance /
  native-symbol / factor-graph-native 契约全部通过。

## 未执行（诚实记录，禁止写 PASS）

- 真传感器级 Deep reprocess（§13.2）：本轮仅正名 + fail-closed 路由，
  未实现 RGB/depth 重处理。
- clock watermark 计数回写 metadata（`clockCorrelationCount`）：侧车已
  写入并被管线消费，但 metadata watermark 字段本轮未回写，故 snapshot
  对该侧车的强制仍依赖 watermark 存在性。
- Xcode Debug simulator clean build：本机 iOS 依赖库为 device-only
  arm64，无 simulator slice，模拟器完整链接不可行。
- Replay Pareto 与阈值冻结（§24）、exact-SHA CI（需远端）、独立人工
  reviewer、真机短路线、Sam 现场。
- tag burst 侧车（`tag_observation_bursts.jsonl`）写入与严格 burst
  parser（§16）本轮未实现；tag false-acceptance 关闭依赖既有质量门。
- floor 身份贯通（§8.1）：`Eligibility.floorID` 已建模，但生产调用点
  尚未把扫描配置的 floorId 贯通到 `Request`/`Eligibility`，故楼层门
  本轮未实际生效；storeId/floorId 在会话侧为空时仍放行（fail-open，
  待业务决策后收紧）。

## 结论

**IMPLEMENTED / UNIT TESTED（Swift host）/ PC oracle INTEGRATION
TESTED / CI VERIFIED（本地 unsigned arm64 build + native 可执行测试）**；
NOT DEVICE LAB PASS / NOT SAM FIELD PASS。真机短路线与独立审查通过前
不得声明 DEVICE LAB TESTABLE 或 READY FOR SAM FIELD TEST。
