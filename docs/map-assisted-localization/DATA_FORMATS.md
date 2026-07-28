# 已有地图辅助扫描数据格式

> 文档状态：**当前有效**。最后核对日期：2026-07-28。

## 会话元数据

为保持既有连续单库识别不变，两个概念分字段保存：

```json
{
  "scanMode": "continuous_streaming",
  "workflowMode": "free_mapping | prior_map_localized",
  "formatVersion": 2
}
```

`scanMode` 是存储布局标记，继续使用 `continuous_streaming`；不能改成业务模式，否则旧 PC 工具会把连续数据库误判为历史分段。`workflowMode` 是地图辅助扫描业务模式。旧会话缺少它时按 `free_mapping` 兼容，并由 PC 标记 `workflow_legacy=true`。

已有地图模式还包含：

```json
{
  "priorMapId": "mapcase01-0cf6949652d4",
  "priorMapSha256": "<package_manifest.package_sha256, 64 hex>",
  "floorId": "1",
  "initialMapPose": {
    "x_m": 12.3,
    "y_m": -4.5,
    "yaw_rad": 1.57
  },
  "localizationTrace": "localization_trace.jsonl",
  "manualLocalizationEvents": "manual_localization_events.jsonl",
  "localizationConstraints": "localization_constraints.jsonl",
  "localizationEvents": "localization_events.jsonl",
  "tagObservations": "tag_observations.jsonl",
  "localizedPriceTags": "localized_price_tags.json",
  "localizedPriceTagCount": 12,
  "captureHealth": {
    "localizationRequiredWriteFailureCount": 0,
    "firstLocalizationRequiredWriteError": null,
    "localizationTraceRecordCount": 120,
    "localizationConstraintRecordCount": 120,
    "localizationStateEventCount": 4,
    "localizationEvidenceComplete": true
  },
  "processingEligibility": {"status": "eligible", "blockers": []}
}
```

`floorId` 在会话开始时固定，当前版本没有扫描中楼层切换事件。二维 `rawPose/estimatedPose` 只表达所选楼层内的 `x/y/yaw`：ARKit `+x` 对应地图 `+x`，ARKit `-z` 对应地图 `+y`，地图 yaw 0 指向 `+y` 且逆时针为正。ARKit 竖直 `y` 不写入二维定位 sidecar，但仍由原始 ARKit/RTAB-Map 三维链路保存。

实时 `live_checkpoint.json` 同步记录业务模式、地图身份、`updatedAtUnix` 和 capture health。`metadata.json` 是最终 sidecar bundle 的最后提交标记，并在最终提交时记录 `finalizedAtUnix`。metadata 写入失败属于提交前失败，可恢复录制；一旦 `finalized=true` 成功写入即进入不可逆终态。其后的 checkpoint 删除失败只能标记“已完成、待清理”，不得恢复相机或继续写数据库。手机和 PC 的显式清理都要求 finalized、同 tracking identity、两个有限 Unix 时间且 `checkpoint.updatedAtUnix <= metadata.finalizedAtUnix`，并在删除前写审计；正常 PC 优化仍无条件拒绝任何残留 checkpoint。

prior-map 会话提交 metadata 前，在 sidecar 写锁内重新读取实际文件字节。`localization_trace.jsonl`、`localization_constraints.jsonl`、`localization_events.jsonl` 必须是非符号链接的非空 regular file，严格 UTF-8、每行完整 JSON object、format/version/会话/地图/floor 身份一致，记录数必须与 capture health 一致，最后 state 必须与 `localizationLastDurableState` 水位一致。`localized_price_tags.json` 必须是合法数组且数量、身份一致；manual/tag observation 可以为空，但非空时同样必须通过格式和身份校验。任何 required 文件丢失、空、半行、损坏、链接、数量或身份不符，手机都把 metadata 降级为 `finalized=false/invalid`，写入稳定的 `evidence_bundle_*` blocker 并保留 checkpoint；不得创建空 required 文件掩盖丢失。自由扫描仍按既有完成条件结束。

## localization_trace.jsonl

固定最多 2 Hz 追加，每行一个 `MarketScannerLocalizationTrace` version 1：

```json
{
  "format": "MarketScannerLocalizationTrace",
  "version": 1,
  "timestamp": 123.4,
  "nodeTimebaseTimestamp": 1785123456.4,
  "nodeTimebaseOffsetSeconds": 1785123333.0,
  "trackingSessionId": "...",
  "priorMapSha256": "...",
  "floorId": "1",
  "trackingState": "normal",
  "localizationState": "stable",
  "confidence": 0.86,
  "rawPose": {"x_m": 1, "y_m": 2, "yaw_rad": 0.1},
  "estimatedPose": {"x_m": 1.02, "y_m": 1.98, "yaw_rad": 0.1},
  "roadCandidates": [{"edgeId": "edge-1", "distanceM": 0.2}],
  "structureSource": "smoothed_scene_depth",
  "structurePointCount": 124,
  "structureCoverageAngleRad": 1.1,
  "matchCandidates": [
    {"pose": {"x_m": 1.02, "y_m": 1.98, "yaw_rad": 0.1}, "cost": 0.02, "score": 0.78}
  ],
  "matchUniqueness": 0.31,
  "matchResidualCost": 0.02,
  "matcherElapsedMs": 18.4,
  "constraintAccepted": true,
  "constraintReason": "trusted_structure_correction"
}
```

接受和拒绝都记录原因，结构候选最多 3 个。`rawPose` 是当前 ARKit 预测投影；`estimatedPose` 才包含通过安全门控的小幅地图对齐修正。道路候选仅保留为弱先验证据。

`timestamp` 保留原始 `ARFrame.timestamp`（设备单调时钟）；RTAB‑Map 的 `CameraMobile` 在写 `Node.stamp` 前会加 `stampEpochOffset`。因此所有当前定位 sidecar 同时保存 `nodeTimebaseTimestamp = timestamp + nodeTimebaseOffsetSeconds`，PC 只用换算后的 node timebase 绑定 SQLite node，并严格复算该等式。offset 由 native camera 原子读取；尚未初始化或非有限时该记录拒绝落盘，不能直接拿原始 ARFrame 时间与 epoch node stamp 比较。

## 阶段二定位审计

- `localization_constraints.jsonl`：每个匹配周期的预测/估计、Top‑3、残差、唯一性、有效点数、角覆盖、耗时、接受标记和原因；同时保存 raw/node timebase/offset。
- `localization_events.jsonl`：状态发生变化时记录 previous/state/confidence/reason 和双时间基准。
- `tag_observations.jsonl`：每次成功 Vision 识别的原始观测，即使用户取消最终保存也保留；保存 `frame_timestamp/node_timebase_frame_timestamp/node_timebase_offset_seconds`，以及 `alignment_age_ms/alignment_version_lag/alignment_freshness` 和深度证据。地图点必须使用提交 Vision 时冻结且通过时效门的对齐快照计算。
- `localized_price_tags.json`：用户确认后的数组；包含 shelf code、row flag、cross code、货架侧面、沿货架起点距离、相对地面高度、raw/snapped 位置、定位/测量/关联三项置信度、测量方式、`needs_review` 和 `user_confirmed`。

JSONL 文件逐行独立编码和同步追加；最终价签数组用原子替换写入。必需定位追加使用 throwing `FileHandle` I/O 并返回结构化的 trace/constraint/state 成败；任一失败都是本会话不可清除的 capture-health 失败。写入前必须确认 tracking session ID 与活动会话一致且未进入 finalization，不允许日志接口自动创建新会话目录。PC 对每类文件使用正式 contract：严格 UTF‑8/JSON（禁止 NaN/Infinity）、format/version、会话/地图/floor 身份、有限且按契约单调的时间戳、业务必填字段、单行/记录上限和重复 ID 检查。`localization_trace`、constraints、state events 为必需；最终 metadata 必须明确 `localizedPriceTags` 文件名与准确计数，即使为 0 也必须存在；有最终价签时 observations 必需且不得为空。manual v3 是当前格式，v2 仅作严格兼容；legacy v1 只允许进入拒绝审计和 review blocker，不能形成锚点。

## manual_localization_events.jsonl

当前每次人工确认写 `MarketScannerManualLocalizationEvent` version 3，包含：

- 冻结且互相校验的 wall-clock ISO/Unix 时间、原始 `frame_timestamp`、`node_timebase_frame_timestamp` 和 `node_timebase_offset_seconds`；
- 必填 node ID/stamp/delta、timebase offset 和 snapshot generation；native 桥在 camera/RTAB‑Map 同一锁域取得一致快照。node 不存在、generation 无效、证据超过 1 秒或时间等式不一致时拒绝写入，绝不回退 node 0 或拼接分次 getter；
- alignment version、tracking session、prior-map hash 和 floor ID；
- 原因；
- 确认时 ARKit SE(2)；
- 用户确认的地图 SE(2)。

即使没有事件或扫码，正常 prior-map 会话也生成空 JSONL 和空最终价签数组，使 sidecar 清单稳定。

## 原始数据

上述 sidecar 不写入 SQLite，不作为外部 pose prior 注入 RTAB-Map。自动地图修正只改变先验地图 HUD 的 ARKit→地图对齐，不改写 ARKit、Node pose 或原始数据库。PC 离线处理继续复制数据库并在新输出目录优化。来源 hash 和参数分别保存在 prior-map manifest、会话 metadata 和现有 PC source manifest。

## 阶段三输出

`MapStudio-Localized-*` 在既有 2D/3D 成果和 `rtabmap_optimized/optimized.db` 之外新增事务版本区：

```text
localized/
  current.json
  published.json                 # 仅正式发布/撤销状态存在
  local_inputs/<input_identity_id>.json # 本机路径，不在 artifact/export allowlist
  versions/vNNNNNN/
    version_manifest.json
    prior_map_manifest.json      source_manifest.json
    session_input_manifest.json
    processing_manifest.json     online_localization_trace.json
    optimized_map_trajectory.geojson
    localization_constraints.json localization_report.json
    review_items.json            localized_review.json
    manual_edits.json
    localized_price_tags.json/.csv/.geojson
    shelf_tag_index.json         audit_log.jsonl
```

`localization_report.json` 包含地图/会话/数据库 hash、直接从 source/optimized SQLite `Node` 表和导出轨迹交叉计算的节点覆盖/缺失/重复/时间范围、三条轨迹长度、修正分布、仅用于诊断的绝对约束残差、局部平移/yaw 形变、weak/lost 时长、约束接受/拒绝、标签 observation coverage、review/publish blockers 和 `publish_state`。残差诊断不包含平滑项，不能表述为求解器 objective 或收敛证明。`solver.type=bounded_correction_field`、`full_factor_graph=false`、`published_capable=false` 是当前真实能力边界。

`localized_review.json` 是 Map Studio 的有界联动复核视图数据，包含先验结构、三条轨迹、价签、问题列表和明确的 `view_limits`/截断标记；它是派生展示文件，不替代各权威成果文件。

`manual_edits.json` version 4 绑定 `input_identity_id/session_input_bundle_sha256/prior_map_sha256/source_database_sha256/optimized_database_sha256/processing_parameter_sha256/tool_version/coordinate_contract_version`。事件保存服务端生成的 `event_id/created_at_utc/base_revision/old_value/new_value/actor/reason`；`audit_events` 单独记录 append/undo/redo 的旧/新 cursor。API 强制 `expected_version_id + expected_revision`，冲突返回 409；只有完整重放和版本校验成功后才推进 current。

可导出的 `source_manifest.json` 只保存会话/数据库文件名、地图 ID 和各输入 SHA‑256，不保存用户名或绝对路径。不可变 version 内的 `session_input_manifest.json` 按规范顺序绑定数据库、metadata 和全部必需 sidecar 的文件身份、大小及 SHA‑256，并生成 `input_identity_id`。人工复核重放所需的本机绝对路径按该身份单独写在 `localized/local_inputs/<input_identity_id>.json`；它不进入不可变 version、artifact allowlist 或导出包。读取时先验证 version 本身，再验证 local-input identity 和当前输入字节；不能用可变全局路径状态重放旧版本。

版本写入在 `localized/.write.lock` 的跨进程排他锁内完成父版本复核、staging 清理、版本号分配、rename 和单一指针提交。版本目录 rename 后必须先 fsync `versions/`，失败时不切指针；指针 replace 后的目录 fsync 失败会返回“durability indeterminate”，调用方必须先读取实际指针再恢复，禁止盲目重试。读取 current/published 或下载 artifact 时会重新核对 exact file set、regular-file、字节数及逐文件 SHA‑256，下载还对已打开 fd 的实际字节再次验 hash。发布创建独立 published snapshot 并只切换 `published.json`；存在 active published 时必须先撤销。正式发布还要求 store 层再次验证空 blocker、完整且可发布的相对 SE(2) 因子图，以及由服务端 actor/UTC 和当前 `localized_review.json` SHA‑256 绑定的现场验收记录；当前求解器始终不满足该门。
