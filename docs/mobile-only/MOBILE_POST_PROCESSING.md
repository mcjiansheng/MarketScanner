# 手机后处理（Mobile Post Processing）

> 状态：**当前有效**；IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED（P1/P2/P7/P8/P12）。最后核对：2026-08-07。

## 模块

`app/ios/RTABMapApp/MobilePostProcessing/`

- `SessionSnapshotTransaction.swift`：finalized session → 私有只读快照（input_snapshot/ + 不可变 source DB 副本 + input manifest + bundle SHA）；同文件内的 `PersistentTaskCoordinator` 和 `MobileTerminalStatePersistence` 负责 `task.json`、terminal intent 与重启调和。
- `SE2FactorGraphCore.swift`：Fast Path 相对 SE(2) 因子图优化（Gauss-Newton + 稀疏阻尼 CG），bounded iterations、finite checks、确定性。
- `FinalTrajectory.swift` / `ClockCorrelationRecorder.swift`：最终轨迹与 1 Hz 重采样（见 FINAL_DEVICE_TRAJECTORY.md）。
- `TagObservationResolver.swift` / `ShelfAssociationEngine.swift`：价签最终定位（见 MOBILE_TAG_FINALIZATION.md）。
- `StrictJSONLStreamReader.swift` / strict evidence parsers：64 KiB true-streaming、final newline、no blank line、strict scalar、unknown-field 和 immutable snapshot 合同；每行 caller body 在独立 autorelease pool 内执行，避免 Foundation 临时对象跨 200k 规模累积，同时由 strict document parser 保持 UTF-8、duplicate-key、nesting 和 JSON 校验。

## Fast Path 安全

bounded iterations（60）、convergence tolerance、确定性稀疏 CG、每步 finite 检查、solver 失败抛错不发布。Route A 允许 Fast reduced graph 后至多一次 Full existing-graph optimization；仍失败即 `RESCAN_SESSION`，不执行 True sensor Deep。因子图输入为快照解析结果；处理只读快照，绝不处理原始 session 路径。

Native optimizer 的 skeleton/factor/prior 硬上限统一由生成合同固定为 4096。Swift 必须先严格解释 native disposition，再处理可选 error 字符串，因此 `RESOURCE_REQUIRED + error detail` 仍保持可恢复的资源暂停语义；未知 disposition 是 ABI 错误。C ABI v4 为 quality JSON 提供显式 bounded UTF-8 byte count，并独立携带 runtime ABI、graph/factor SHA、factor count 和 publish count。Swift 以完整 typed DTO 严格解析 quality v2：duplicate/unknown/missing field、Bool 冒充数字、错误类型或越界值均拒绝；随后把 path/disposition、prior-map/session/projection policy identity、graph/factor SHA、`solver.factor_count`、skeleton/trajectory/publish counts 与 request 和 C outcome 精确交叉核对。顶层 `factor_count` 不得冒充唯一权威路径 `solver.factor_count`，RunSummary 只能从该已验证 DTO 投影，不能再以宽松 `JSONSerialization`/`NSNumber.intValue` 读取安全字段。

`AbsolutePriorEvidenceParser` 为一次处理只构建一个 `NodeIndex`（ID 索引、按 stamp 排序数组、stamp 数组和 duplicate 集合）。constraint/manual 的 top-level、pose 和 candidate 子对象均拒绝未知字段，version/Bool/Int 使用严格 scalar；floor/map/SHA/session、node timebase 恒等式和 disposition 交叉语义必须一致。格式正确、身份一致且正式 `accepted=false` 的 constraint 是正常负证据：计入 `nonAcceptedDetails`、不生成 prior、也不污染 fatal clean gate；坏 schema、身份矛盾或 accepted record 无效仍阻断。manual v2/v3 都重算最近与第二近节点，v3 声明 ID 必须就是真实无歧义最近节点，并交叉核对 ISO/Unix wall time。

`localization_constraints.jsonl` 的产品资格规模是 48 h × 2 Hz = 345,600 条；生成合同使用 400,000 条 parser hard cap、64 KiB 单条上限和 768 MiB 文件上限。处理必须从 `captureHealth.localizationConstraintRecordCount`、`captureHealth.manualLocalizationEventCount` 和 `captureHealth.localizationRecoveryEventCount` 读取严格非负整数，并分别与 constraint/manual/recovery JSONL 的实际原始行数精确一致，不能用已解析、已接受或恢复 episode 内存计数替代持久化行水位。manual 水位只在 durable append 成功后推进；有正水位时 finalization 不得用新建空文件掩盖缺失证据。

trace compactor 对 48 h × 10 Hz transition storm 每秒只保留保守最坏 formal state，并额外保留 exact final sample。timestamp 即使是 finite，只要无法安全映射到 `Int64` 秒轴或 subtraction 会 overflow，就返回稳定 reason `compaction_axis_out_of_range`；Swift 与 PC hostile fixture 必须同类拒绝，不能在运行时 trap。

### J-04 component identity blocker

当前快照 Graph Reader 暴露 `MobileGraphNode.mapID` 和完整 `MobileGraphLink`，因此处理时可以从最终 DB 图确定每个 node 的 connected component；但是正式 `PriorMapConstraintRecord` 只记录 node-timebase timestamp，没有原子绑定的 node ID、RTAB-Map map ID 或 component identity。manual v3 虽有 `nearest_node_id`，仍没有写侧可对照的 RTAB-Map map ID；而 connected component 会随新 link 合并，不应在采集时伪造为稳定编号。因此当前代码能严格证明 floor/prior-map/session identity、nearest/delta/margin，却不能证明 prompt 所要求的“记录声明 component 与最终 DB component 一致”。该项保持 **BLOCKER / NOT CLOSED**。

最小正确迁移不是在 reader 中猜 component：constraint schema 升级并在写侧使用与 manual v3 相同的原子 node snapshot，持久化 `bound_node_id`、`bound_node_stamp`、`node_time_delta_seconds`、`node_time_snapshot_generation` 和当时真实 `rtabmap_map_id`；manual 下一 schema 版本同样增加 `rtabmap_map_id`。最终 snapshot 再通过 links 从明确 bound node 推导 component，不持久化可能随闭环合并而漂移的 component 序号。旧 schema 没有这些证据，不能追溯补证或宣称 J-04 PASS。

快照要求 strict finalized metadata v2、连续单库、store/floor/map/session identity 一致、无 live checkpoint、无非空 WAL/journal/shm、无 symlink/hardlink。复制前后对完整文件集合和 inode/size/mtime/ctime 做稳定性核对，提交后 snapshot 文件 `0444`、目录 `0555`。`scan_events.jsonl` 是 required artifact；thermal 统计只读 snapshot，逐行 `trackingSessionId` 必须与当前处理请求精确一致，坏行或混入其他 session 均阻断。当前 finalized metadata 尚无 scan-event count/last-ID 水位，因此本版可证明身份、格式和不可变快照来源，但不能声称已证明事件基数完整；新增水位需要后续写端 schema 迁移。

## 处理状态机

created → snapshotting → fast_optimizing → fast_quality_check → [deep_reprocessing →
deep_optimizing] → building_trajectory → resampling_trajectory → resolving_tags →
building_rescan_tasks → building_workbook → validating_result → committing_result → completed
（及 rescan_required / failed / cancelled / interrupted）

方括号阶段表示一次现有全图优化的兼容状态名，不代表 True sensor Deep。恢复语义是：验证 task identity、namespace-qualified root-relative durable references、commit receipt 和 exact immutable snapshot，然后从 snapshot 重新进入流水线；不是把任意 stage 的内存对象序列化后继续执行。合法状态迁移之外的跳转一律拒绝。

Result 发布与 `task.json` 完成态是一个跨两个持久目录的有序事务：隐藏 staging 冻结并独占 rename 为不可变 final Result 后，`task.json` 才从 `committing_result` 推进到 `completed`。任何异常进入通用 terminal persistence 前，pipeline 必须先按 task ID 和 checkpoint 中唯一 result ID 搜索 committed receipt；候选 Result 必须重新验证 exact file set/modes、receipt/manifest、逐文件 bytes/SHA，以及 task/snapshot/map/session/native/policy/processing-path identity。若 final rename 已可见，则显式 fsync Result 与 library parent，并完成或精确重验 `completed` checkpoint，绝不改写为 `failed`；若 completed task writer 在 rename 前失败，状态保持 `committing_result`，重启按同一 receipt 恢复为 `completed`，不得重复导出。receipt 冲突、候选损坏、checkpoint identity 冲突或同一 task 出现多个 Result 一律保留证据并 fail closed，不能当作“没有 Result”继续处理。

取消、系统中断、资源暂停、`RESCAN_SESSION` 和普通工作流失败共用 `MobileTerminalStatePersistence`。Route A 的 Fast 与至多一次 Full 仍不通过，或最终没有任何 publish-eligible trajectory node 时，先在 task root 写入专用 `rescan_session_outcome.json`：exclusive temp write → file fsync → read-only mode → `RENAME_EXCL` → task-root fsync；artifact 严格绑定 task/session/store/floor/prior-map/input-bundle/processing-path/disposition，并明确 `publish_permitted=false`、`result_published=false`。两个字段必须是 JSON Bool；`no_publish_eligible_trajectory` 只配 graph PASS，`graph_quality_failed` 只配 `RECOVERABLE_FAIL` / `NON_RECOVERABLE_FAIL` / `LOCAL_FRAME_ONLY`，`RESOURCE_REQUIRED` 不得伪装为图质量 RESCAN。随后 checkpoint 以 task namespace + SHA-256 引用 artifact，再通过 terminal intent 把 `task.json` 提交为 `rescan_required` / `rescan_session_required`。artifact writer 和 checkpoint writer 的 before-temp、after-temp-fsync、after-rename、after-parent-fsync 边界均有故障注入；rename 已可见后先 stable no-follow 重读并补 parent fsync，只有 exact identity/outcome/reference/SHA 才接受。pre-existing artifact 与 EEXIST race winner 必须在 processing path、graph disposition、reason code 和 human message 上完全等价。该路径不创建普通 Result，不生成 PriceTags、DevicePositions 或 workbook；若同 task 已有普通 committed Result 则保留现场并 fail closed。重启若看到已 fsync artifact 而 task 仍处于旧中间态，会在任何 evidence/native 重跑前恢复 typed `workflow.rescan_session_required`，terminal task 则拒绝原地重启。

通用 terminal 生产调用顺序为：先原子写入并 fsync `terminal_state_intent.json`，再原子更新 `task.json`，成功后删除 intent 并 fsync task root，然后重新抛出原业务错误。`task.json` 在 before-temp-write、after-temp-fsync、after-rename 或 parent-fsync 边界失败时，调用方收到 `DurabilityFailure`，其中同时包含业务 outcome/code/detail、失败阶段、存储错误和当前可读 task state；不得把原业务终态静默报告为已经安全持久化。重启发现 intent 时，只有 task identity、目标 terminal state 和持久化 reason 全部精确一致才允许幂等清除，只有已知非终态阶段才允许推进到 intent 目标；completed、rescan_required、不同终态、同状态不同 reason 或 task identity 冲突一律不修改 `task.json`、不删除 intent 并 fail closed，intent 未调和前不得按普通中间态恢复。

`PersistentTaskCoordinator.updateState` 的 `error: nil` 表示“不提供新错误”，不能隐式表示清除旧值；recovery reentry、fresh/recovered snapshot、normal completed 和 committed-result recovery 必须显式传 `clearError=true`。这保证 `system_interrupted` / `resource_pause` 恢复后不会得到 `state=completed` 但仍携带旧 error 的矛盾 task。

诚实边界：intent 与 `task.json` 位于同一 task 存储。如果连 intent 的首次 write/fsync/rename/parent-fsync 都无法完成，调用方仍会收到 `establish_intent` typed durability failure，但同一故障存储上不存在可被数学保证的第二份持久标记；代码不会宣称终态成功，重启后可见状态取决于底层文件系统实际保留的最后 durable generation。该情况必须保留为存储故障诊断，不得伪报为可自动恢复 PASS。

## 测试（Swift host）

- P1：小链 + 环闭合收敛，anchor 保持，漂移被拉平。
- P7：快照事务复制输入、bundle SHA 可复现、原始目录篡改不影响快照。
- P8：`task.json` 原子持久化 interrupted 状态。
- P12：completed 为终态，interrupted 可恢复。
- P1-11：cancelled / interrupted / resource_required / workflow_failed × before-write / after-temp-fsync / after-rename / parent-fsync 共 16 条真实文件系统故障路径，均验证 typed business+durability error、intent 留存、无 temp 泄漏和重启调和；另以真实文件覆盖 completed+failed intent、cancelled+failed intent、同状态不同 reason 和 task-ID 冲突四类拒绝矩阵。
- RC RESCAN：Fast + 一次 Full 均失败，以及 graph PASS 但无 publish-eligible trajectory node，均验证专用 artifact 内容/权限/SHA checkpoint、`rescan_required` terminal state、重启不复跑 native、不发布普通 Result；artifact writer 4 边界 + checkpoint writer 4 边界 + terminal writer 4 边界均覆盖，并包含 numeric Bool、reason/disposition、RESOURCE_REQUIRED、EEXIST exact-equivalence 和普通 Result 共存的 adversarial fixture。
- RC committed Result：覆盖 Result commit 的 after-rename / after-parent-fsync，以及 `completed` task writer 的 before-temp-write / after-temp-fsync / after-rename / after-parent-fsync；验证恰好一个不可变 Result、无 failed intent、rename 前 task-write 故障保持 `committing_result` 并在重启精确完成、rename 后精确重读可完成，同时拒绝 receipt 冲突和同 task 多 Result。
- RC stale task error：`system_interrupted` 与 `resource_pause` 两种恢复路径最终均验证 `completed` 且 `error == nil`。
- RC scale：300,000 finalization records peak RSS 12,795,904 bytes；1,728,000 trace transition storm 保留 172,801 条且 peak RSS 58,769,408 bytes；200,000 burst frames + 200,000 observations 经 parser→resolver→shelf→fusion→quality gate，peak RSS 670,662,656 bytes，低于 768 MiB host 门。以上不是 target-device performance PASS。
