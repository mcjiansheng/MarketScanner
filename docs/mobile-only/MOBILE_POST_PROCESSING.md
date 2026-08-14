# 手机后处理（Mobile Post Processing）

> 状态：**当前有效**；IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED（P1/P2/P7/P8/P12 + 性能证据）。最后核对：2026-08-15。

## 模块

`app/ios/RTABMapApp/MobilePostProcessing/`

- `SessionSnapshotTransaction.swift`：finalized session → 私有只读快照（input_snapshot/ + 不可变 source DB 副本 + input manifest + bundle SHA）；同文件内的 `PersistentTaskCoordinator` 和 `MobileTerminalStatePersistence` 负责 `task.json`、terminal intent 与重启调和。
- `SE2FactorGraphCore.swift`：Fast Path 相对 SE(2) 因子图优化（Gauss-Newton + 稀疏阻尼 CG），bounded iterations、finite checks、确定性。
- `FinalTrajectory.swift` / `ClockCorrelationRecorder.swift`：最终轨迹与 1 Hz 重采样（见 FINAL_DEVICE_TRAJECTORY.md）。
- `TagObservationResolver.swift` / `ShelfAssociationEngine.swift`：价签最终定位（见 MOBILE_TAG_FINALIZATION.md）。
- `StrictJSONLStreamReader.swift` / strict evidence parsers：64 KiB true-streaming、final newline、no blank line、strict scalar、unknown-field 和 immutable snapshot 合同；每行 caller body 在独立 autorelease pool 内执行，避免 Foundation 临时对象跨 200k 规模累积，同时由 strict document parser 保持 UTF-8、duplicate-key、nesting 和 JSON 校验。

## 扫描性能证据

原始连续会话在 `segment_0001/performance_samples.jsonl` 保存结构化手机性能时间线。正常扫描约每 5 秒采样一次，数据库保存完成后再写一条 `scan_state=finalizing` 样本。每行必须绑定同一个 tracking session，使用从 1 开始连续递增的 `sequence` 和严格递增的 `timestamp_unix`。写侧上限来自生成合同：250,000 条、256 MiB 文件、64 KiB 单行；48 小时资格规模按 0.2 Hz 为 34,560 条。

CPU 占用率定义为相邻样本的 `delta(process user+system CPU seconds) / delta(process uptime) × 100`，因此多核负载可以超过 100%，首条样本没有区间 CPU 百分比。其他字段包括进程 `phys_footprint`、进程可用内存、可用磁盘、电池与充电、thermal state、渲染 FPS、RTAB-Map update time、节点/特征/点数、数据库内存/文件和会话目录增长。不可测量值必须缺省或显式 unavailable，禁止以 0、NaN 或 Infinity 冒充。iOS 没有普通 App 可用的可靠整机 GPU 利用率公开 API，因此只记录 `gpu_metric_status=not_available_public_ios_api`，不推导 GPU 百分比。

`metadata.json` 以 `performanceSamples`、`performanceSampleIntervalSeconds`、`performanceSampleCount`、`performanceLastSequence`、`performanceLastTimestampUnix`、`performanceEvidenceComplete` 和 `performanceWriteFailureCount` 提交水位。首条写入即失败时仍创建空文件并提交 `complete=false`，以区分采集写失败和导出漏文件。性能写失败是粘性的资格降级，但性能证据是 observability，不是 localization、coordinate 或 publication authority；它不能删除有限轨迹、价签或已经安全落盘的数据库。

`SessionSnapshotTransaction` 将 metadata 声明的性能文件放入 `observabilitySidecarPairs`，执行与其他不可变输入相同的 exact bytes/SHA、single-link、no-symlink 和稳定身份绑定，但不把它加入 `declaredSidecarPairs` 的定位证据集合。历史 finalized 会话没有性能字段时继续按历史定位合同处理，同时明确为 performance evidence unavailable。

Mobile-Only Result 在快照含性能文件时输出 `phone_performance_samples.jsonl` 和 `phone_performance_summary.json`；manifest 记录 `performance_sample_count` 与 `performance_evidence_complete`，reader 对两者分别执行 strict non-negative integer 和 strict Bool 验证。质量报告的 `phone_performance` 只描述观测数据与资格状态，不提升图优化、坐标或价签发布资格。

## Fast Path 安全

bounded iterations（60）、convergence tolerance、确定性稀疏 CG、每步 finite 检查。Route A 允许 Fast reduced graph 后至多一次 Full existing-graph optimization，不执行 True sensor Deep。两条路径仍非 PASS 时，只要 native 返回至少一个有限轨迹节点，就提交 `PARTIAL_REVIEW_REQUIRED` 或 `LOCAL_FRAME_ONLY` 的不可发布 Result；质量失败是结果属性，不再等同于“没有结果”。若 Full 求解器自身返回 `nativeFailed`，但 Fast outcome 已通过完整 strict outcome/quality 合同且含有限轨迹，则回退 Fast 并记录 `full_graph_failed_fallback_to_fast`；未知 ABI、坏指针/计数、身份/path/quality JSON 绑定失败等 `invalidOutcome` 仍终止，不能用 Fast 掩盖不可信 native 边界。因子图输入为快照解析结果；处理只读快照，绝不处理原始 session 路径。

Native optimizer 的 skeleton/factor/prior 硬上限统一由生成合同固定为 4096。Swift 必须先严格解释 native disposition，再处理可选 error 字符串，因此 `RESOURCE_REQUIRED + error detail` 仍保持可恢复的资源暂停语义；未知 disposition 或未知 prior kind 都是 ABI/语义错误。C ABI v5 为 quality JSON 提供显式 bounded UTF-8 byte count，并独立携带 runtime ABI、graph/factor SHA、factor count 和 publish count。Swift 以完整 typed DTO 严格解析 quality v3：duplicate/unknown/missing field、Bool 冒充数字、错误类型或越界值均拒绝；随后把 path/disposition、prior-map/session/projection policy identity、graph/factor SHA、`solver.factor_count`、skeleton/trajectory/publish counts 与 request 和 C outcome 精确交叉核对。quality v3 明确记录 `initial_map_pose` gauge authority、普通 robust consensus prior 数和同分量长程闭环数。单一起点 x/y/yaw 只有在同一分量存在节点跨度至少 30 的 RTAB-Map 长程闭环时才具有发布授权；否则保持 `LOCAL_FRAME_ONLY`。顶层 `factor_count` 不得冒充唯一权威路径 `solver.factor_count`，RunSummary 只能从该已验证 DTO 投影，不能再以宽松 `JSONSerialization`/`NSNumber.intValue` 读取安全字段。

`AbsolutePriorEvidenceParser` 为一次处理只构建一个 `NodeIndex`（ID 索引、按 stamp 排序数组、stamp 数组和 duplicate 集合）。constraint/manual 的 top-level、pose 和 candidate 子对象均拒绝未知字段，version/Bool/Int 使用严格 scalar；floor/map/SHA/session、node timebase 恒等式和 disposition 交叉语义必须一致。格式正确、身份一致且正式 `accepted=false` 的 constraint 是正常负证据：计入 `nonAcceptedDetails`、不生成 prior、也不污染 fatal clean gate；坏 schema、身份矛盾或 accepted record 无效仍阻断。manual v2/v3 都重算最近与第二近节点，v3 声明 ID 必须就是真实无歧义最近节点，并交叉核对 ISO/Unix wall time。

记录级证据拒绝与文件/身份损坏严格分层：`manual_event_claimed_node_not_nearest` 等单条 prior 拒绝只排除该因子，写入 degradation audit，其他相对图、有效 prior、轨迹和价签继续处理；地图/楼层/会话身份串包仍终止。tag burst/observation 的单条 schema、node binding 或未消费 frame 同样降级：已有三帧位置 quorum 时保留低置信度位置，否则保留条码占位行和空地图坐标；两种情况的价签结果均为 `LOW_CONFIDENCE`，权威证据不足时可另附非阻断 `RescanTask`，但补扫建议不是处理失败，也不能删除 PriceTags 行。JSONL framing、文件超限/不可读、duplicate durable ID、identity mismatch 和不可证明的 durable watermark 仍是 fatal。

`localization_constraints.jsonl` 的产品资格规模是 48 h × 2 Hz = 345,600 条；生成合同使用 400,000 条 parser hard cap、64 KiB 单条上限和 768 MiB 文件上限。处理必须从 `captureHealth.localizationConstraintRecordCount`、`captureHealth.manualLocalizationEventCount` 和 `captureHealth.localizationRecoveryEventCount` 读取严格非负整数，并分别与 constraint/manual/recovery JSONL 的实际原始行数精确一致，不能用已解析、已接受或恢复 episode 内存计数替代持久化行水位。manual 水位只在 durable append 成功后推进；有正水位时 finalization 不得用新建空文件掩盖缺失证据。

trace compactor 对 48 h × 10 Hz transition storm 每秒只保留保守最坏 formal state，并额外保留 exact final sample。timestamp 即使是 finite，只要无法安全映射到 `Int64` 秒轴或 subtraction 会 overflow，就返回稳定 reason `compaction_axis_out_of_range`；Swift 与 PC hostile fixture 必须同类拒绝，不能在运行时 trap。

### J-04 component identity blocker

当前快照 Graph Reader 暴露 `MobileGraphNode.mapID` 和完整 `MobileGraphLink`，因此处理时可以从最终 DB 图确定每个 node 的 connected component；但是正式 `PriorMapConstraintRecord` 只记录 node-timebase timestamp，没有原子绑定的 node ID、RTAB-Map map ID 或 component identity。manual v3 虽有 `nearest_node_id`，仍没有写侧可对照的 RTAB-Map map ID；而 connected component 会随新 link 合并，不应在采集时伪造为稳定编号。因此当前代码能严格证明 floor/prior-map/session identity、nearest/delta/margin，却不能证明 prompt 所要求的“记录声明 component 与最终 DB component 一致”。该项保持 **BLOCKER / NOT CLOSED**。

最小正确迁移不是在 reader 中猜 component：constraint schema 升级并在写侧使用与 manual v3 相同的原子 node snapshot，持久化 `bound_node_id`、`bound_node_stamp`、`node_time_delta_seconds`、`node_time_snapshot_generation` 和当时真实 `rtabmap_map_id`；manual 下一 schema 版本同样增加 `rtabmap_map_id`。最终 snapshot 再通过 links 从明确 bound node 推导 component，不持久化可能随闭环合并而漂移的 component 序号。旧 schema 没有这些证据，不能追溯补证或宣称 J-04 PASS。

快照要求 strict finalized metadata v2、连续单库、store/floor/map/session identity 一致、无 live checkpoint、无非空 WAL/journal/shm、无 symlink/hardlink。复制前后对完整文件集合和 inode/size/mtime/ctime 做稳定性核对，提交后 snapshot 文件 `0444`、目录 `0555`。对刚冻结的大文件执行长时间顺序哈希时，iOS/APFS 可能只在第一次读完后暴露同一 inode 的最终 publication/chmod `ctime`。当前实现仅在 dev/inode/mode/link/size/mtime 全等、`ctime` 只向前且 descriptor/path 最终完全一致时丢弃第一次读取，并要求第二次完整打开、读取、SHA 和 stat 全部稳定；第二次继续变化、内容/mtime 变化、inode 替换、hardlink、symlink 或 writable authority 仍 fail closed。metadata 在一次 descriptor-stable 读取中同时解析和哈希，不再为 eligibility 二次打开制造额外 TOCTOU 窗口；SQLite 校验与 generation final sweep 若只观察到上述一次性 `ctime` 稳定，也必须重新完整哈希并与 committed manifest 精确相等。`scan_events.jsonl` 是 required artifact；thermal 统计只读 snapshot，逐行 `trackingSessionId` 必须与当前处理请求精确一致，坏行或混入其他 session 均阻断。当前 finalized metadata 尚无 scan-event count/last-ID 水位，因此本版可证明身份、格式和不可变快照来源，但不能声称已证明事件基数完整；新增水位需要后续写端 schema 迁移。

手机和 PC 编译器生成的 package artifact 不承诺字节完全一致，不能把手机 `priorMapSha256` 直接与 PC `package_manifest.package_sha256` 强行等同。新会话在保留 exact 手机 package SHA 的同时写 `priorMapCanonicalSourceSha256`，PC 以完整 canonical source SHA + exact prior-map/store/floor 绑定同一源地图。缺少该字段的历史手机会话只允许使用明确的 `legacy_cross_compiler_map_identity`：selected package 必须先通过正式 validator，prior-map ID/store/floor 必须精确一致，ID 的 12 位 hash 后缀必须等于 selected canonical SHA 前 12 位，会话 package SHA 必须是合法小写 SHA-256 且所有 sidecar 继续与它一致。报告同时保存手机包 SHA、PC 包 SHA、source SHA、canonical SHA 和 compatibility mode，绝不伪装为 exact package-hash match。

## 处理状态机

created → snapshotting → fast_optimizing → fast_quality_check → [deep_reprocessing →
deep_optimizing] → building_trajectory → resampling_trajectory → resolving_tags →
building_rescan_tasks → building_workbook → validating_result → committing_result → completed
（及 rescan_required / failed / cancelled / interrupted）

方括号阶段表示一次现有全图优化的兼容状态名，不代表 True sensor Deep。恢复语义是：验证 task identity、namespace-qualified root-relative durable references、commit receipt 和 exact immutable snapshot，然后从 snapshot 重新进入流水线；不是把任意 stage 的内存对象序列化后继续执行。合法状态迁移之外的跳转一律拒绝。

Result 发布与 `task.json` 完成态是一个跨两个持久目录的有序事务：隐藏 staging 冻结并独占 rename 为不可变 final Result 后，`task.json` 才从 `committing_result` 推进到 `completed`。任何异常进入通用 terminal persistence 前，pipeline 必须先按 task ID 和 checkpoint 中唯一 result ID 搜索 committed receipt；候选 Result 必须重新验证 exact file set/modes、receipt/manifest、逐文件 bytes/SHA，以及 task/snapshot/map/session/native/policy/processing-path identity。若 final rename 已可见，则显式 fsync Result 与 library parent，并完成或精确重验 `completed` checkpoint，绝不改写为 `failed`；若 completed task writer 在 rename 前失败，状态保持 `committing_result`，重启按同一 receipt 恢复为 `completed`，不得重复导出。receipt 冲突、候选损坏、checkpoint identity 冲突或同一 task 出现多个 Result 一律保留证据并 fail closed，不能当作“没有 Result”继续处理。

取消、系统中断、资源暂停、`RESCAN_SESSION` 和普通工作流失败共用 `MobileTerminalStatePersistence`。`RESCAN_SESSION` 现在只用于完全没有任何有限轨迹节点的会话（以及读取历史持久 artifact 的兼容路径）；非 PASS、没有 publish-eligible node、单条 prior/tag 证据拒绝都走普通不可变 Result 事务，并设置 `publish_permitted=false`。旧 `rescan_session_outcome.json` 仍按 strict Bool、identity、SHA、exclusive rename 和重启调和合同读取，不能被伪造或与普通 Result 冲突。

普通 Result 的质量状态为 `COMPLETE / PARTIAL_REVIEW_REQUIRED / LOCAL_FRAME_ONLY`。`quality_report.json` v3、RunSummary 和 result manifest 同时记录 `result_quality_status`、`publish_permitted`、降级数量/原因、可用/降级/带坐标/不可用行数。`final_trajectory.jsonl` 与 DevicePositions 对地图坐标和本地诊断坐标使用互斥列；`final_tags.json` 与 PriceTags 即使无法定位也保留条码和失败原因。PC Stage-3 使用相同语义：局部 burst/tag evidence 问题生成不可发布草稿；JSON/CSV 保留全部条码，GeoJSON 仅包含有限坐标子集，绝不以 `(0,0)` 代替未知位置。

通用 terminal 生产调用顺序为：先原子写入并 fsync `terminal_state_intent.json`，再原子更新 `task.json`，成功后删除 intent 并 fsync task root，然后重新抛出原业务错误。`task.json` 在 before-temp-write、after-temp-fsync、after-rename 或 parent-fsync 边界失败时，调用方收到 `DurabilityFailure`，其中同时包含业务 outcome/code/detail、失败阶段、存储错误和当前可读 task state；不得把原业务终态静默报告为已经安全持久化。重启发现 intent 时，只有 task identity、目标 terminal state 和持久化 reason 全部精确一致才允许幂等清除，只有已知非终态阶段才允许推进到 intent 目标；completed、rescan_required、不同终态、同状态不同 reason 或 task identity 冲突一律不修改 `task.json`、不删除 intent 并 fail closed，intent 未调和前不得按普通中间态恢复。

`PersistentTaskCoordinator.updateState` 的 `error: nil` 表示“不提供新错误”，不能隐式表示清除旧值；recovery reentry、fresh/recovered snapshot、normal completed 和 committed-result recovery 必须显式传 `clearError=true`。这保证 `system_interrupted` / `resource_pause` 恢复后不会得到 `state=completed` 但仍携带旧 error 的矛盾 task。

诚实边界：intent 与 `task.json` 位于同一 task 存储。如果连 intent 的首次 write/fsync/rename/parent-fsync 都无法完成，调用方仍会收到 `establish_intent` typed durability failure，但同一故障存储上不存在可被数学保证的第二份持久标记；代码不会宣称终态成功，重启后可见状态取决于底层文件系统实际保留的最后 durable generation。该情况必须保留为存储故障诊断，不得伪报为可自动恢复 PASS。

## 测试（Swift host）

- P1：小链 + 环闭合收敛，anchor 保持，漂移被拉平。
- P7：快照事务复制输入、bundle SHA 可复现、原始目录篡改不影响快照。
- P8：`task.json` 原子持久化 interrupted 状态。
- P12：completed 为终态，interrupted 可恢复。
- P1-11：cancelled / interrupted / resource_required / workflow_failed × before-write / after-temp-fsync / after-rename / parent-fsync 共 16 条真实文件系统故障路径，均验证 typed business+durability error、intent 留存、无 temp 泄漏和重启调和；另以真实文件覆盖 completed+failed intent、cancelled+failed intent、同状态不同 reason 和 task-ID 冲突四类拒绝矩阵。
- Partial Result：Fast + 一次 Full 均非 PASS 但存在有限轨迹时提交不可发布 Result；Full `nativeFailed` 回退已验证 Fast partial，Full `invalidOutcome` 继续 fail closed；graph PASS 但无 publish-eligible node 时保留 initial-pose 对齐或 local-frame 主 component，缺 covariance 也保留有限诊断坐标但 uncertainty 为空；验证 map/local 列隔离、跨 component 不插值、不完整 burst 保留条码和 rejected manual prior 不阻断。
- Legacy RESCAN：strict parser/adversarial fixture 继续覆盖 numeric Bool、reason/disposition、RESOURCE_REQUIRED 和身份/SHA；真正零有限轨迹仍使用该终态。
- RC committed Result：覆盖 Result commit 的 after-rename / after-parent-fsync，以及 `completed` task writer 的 before-temp-write / after-temp-fsync / after-rename / after-parent-fsync；验证恰好一个不可变 Result、无 failed intent、rename 前 task-write 故障保持 `committing_result` 并在重启精确完成、rename 后精确重读可完成，同时拒绝 receipt 冲突和同 task 多 Result。
- RC stale task error：`system_interrupted` 与 `resource_pause` 两种恢复路径最终均验证 `completed` 且 `error == nil`。
- RC scale：2026-08-13 最终增量源码完整 host 1/1 PASS（1250.897 s）：300,000 finalization records peak RSS 13,238,272 bytes；1,728,000 trace transition storm 保留 172,801 条且 peak RSS 59,162,624 bytes；200,000 burst frames + 200,000 observations 接受 200,000 条，peak RSS 654,753,792 bytes，低于 768 MiB host 门。以上不是 target-device performance PASS。
