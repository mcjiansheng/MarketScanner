# 已有地图辅助扫描数据格式

> 文档状态：**当前有效**。最后核对日期：2026-08-16。

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
  "priorMapCanonicalSourceSha256": "<manifest.canonical_source_sha256, 64 hex>",
  "storeId": "store-001",
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
  "localizationRecoveryEvents": "localization_recovery_events.jsonl",
  "tagObservations": "tag_observations.jsonl",
  "tagObservationBursts": "tag_observation_bursts.jsonl",
  "tagObservationBurstCount": 4,
  "tagObservationBurstLastID": "12345678-1234-4234-8234-123456789abc",
  "tagObservationBurstComplete": true,
  "localizedPriceTags": "localized_price_tags.json",
  "localizedPriceTagCount": 12,
  "captureHealth": {
    "localizationRequiredWriteFailureCount": 0,
    "firstLocalizationRequiredWriteError": null,
    "localizationTraceRecordCount": 120,
    "localizationConstraintRecordCount": 120,
    "localizationStateEventCount": 4,
    "localizationRecoveryEventCount": 2,
    "localizationLastRecoveryEpisodeId": 2,
    "localizationLastRecoveryFinishedAtUptime": 731.25,
    "localizationEvidenceComplete": true
  },
  "processingEligibility": {"status": "eligible", "blockers": []}
}
```

所有新完成会话（自由扫描与已有地图扫描）还声明独立性能证据：

```json
{
  "performanceSamples": "performance_samples.jsonl",
  "performanceSampleIntervalSeconds": 5.0,
  "performanceSampleCount": 1441,
  "performanceLastSequence": 1441,
  "performanceLastTimestampUnix": 1786729800.125,
  "performanceEvidenceComplete": true,
  "performanceWriteFailureCount": 0
}
```

`performanceEvidenceComplete=true` 要求至少一条样本、成功写入零失败，且 count/末序号/末时间与文件完全一致。性能证据是 observability，不是定位或坐标 authority：缺失、写失败或坏行会禁止宣称“性能资格通过”，但不会把本来有限、安全落盘的地图/轨迹删除。Mobile-Only immutable snapshot 在字段存在时必须绑定该文件的 exact bytes/hash；旧会话缺少这组字段仍可按旧定位证据合同处理。

`priorMapSha256` 是扫描时手机上 exact package artifact 的身份，仍用于全部实时 sidecar 的同会话一致性校验；Swift 与 Python 编译器生成的派生 package bytes 不承诺相同，因此它不再被解释为跨编译器通用身份。新会话同时写 `priorMapCanonicalSourceSha256`，PC 以完整 canonical source SHA 和 exact `priorMapId/storeId/floorId` 绑定同一源地图。缺失 canonical 字段的历史会话只能走显式 legacy cross-compiler compatibility：selected package 必须已通过 production validator，map/store/floor 必须精确一致，prior-map ID 的 12 位后缀必须等于 selected canonical SHA 前 12 位，手机 package SHA 必须为合法小写 SHA-256 且在 metadata/sidecar 内一致；输出报告必须标记 compatibility mode 并同时保留手机/PC/canonical/source SHA。

`floorId` 在会话开始时固定，当前版本没有扫描中楼层切换事件。二维 `rawPose/estimatedPose` 只表达所选楼层内的 `x/y/yaw`：ARKit `+x` 对应地图 `+x`，ARKit `-z` 对应地图 `+y`，地图 yaw 0 指向 `+x`（东/右）、`+π/2` 指向 `+y`（北/上），且逆时针为正。ARKit 竖直 `y` 不写入二维定位 sidecar，但仍由原始 ARKit/RTAB-Map 三维链路保存。

实时 `live_checkpoint.json` 同步记录业务模式、地图身份、`updatedAtUnix` 和 capture health。`metadata.json` 是最终 sidecar bundle 的最后提交标记，并在最终提交时记录 `finalizedAtUnix`。metadata 写入失败属于提交前失败，可恢复录制；一旦 `finalized=true` 成功写入即进入不可逆终态。其后的 checkpoint 删除失败只能标记“已完成、待清理”，不得恢复相机或继续写数据库。手机和 PC 的显式清理都要求 finalized、同 tracking identity、两个有限 Unix 时间且 `checkpoint.updatedAtUnix <= metadata.finalizedAtUnix`，并在删除前写审计；正常 PC 优化仍无条件拒绝任何残留 checkpoint。

prior-map 会话提交 metadata 前，在 sidecar 写锁内重新读取实际文件字节。`localization_trace.jsonl`、`localization_constraints.jsonl`、`localization_events.jsonl` 必须是非符号链接的非空 regular file，严格 UTF-8、每行完整 JSON object、format/version/会话/地图/floor 身份一致，记录数必须与 capture health 一致，最后 state 必须与 `localizationLastDurableState` 水位一致。`localized_price_tags.json` 必须是合法数组且数量、身份一致；manual/tag observation 与 `localization_recovery_events.jsonl`（P7R5 终态 Recovery 生命周期证据，uptime 时间戳而非 node-timebase）可以为空，但非空时同样必须通过格式和身份校验。只要存在 localized tag v2 或 burst watermark 大于 0，`tag_observation_bursts.jsonl` 就成为必需、非空且 strict JSONL 的 authority：count、last ID、complete 标记必须与 metadata 完全一致；burst sequence 必须为正并按文件顺序严格递增（允许从任意正数开始且允许跳号）；每个 burst frame 与 durable observation 必须按 `observation_id/burst_id/frame_id/payload/symbology` 双向集合相等；localized v2 tag 的 `capture_id`、exact observation set、payload 和 symbology 必须与同一个 verified complete burst 一致。任何 required 文件丢失、空、半行、损坏、链接、数量、身份或 exact binding 不符，手机都把 metadata 降级为 `finalized=false/invalid`，写入稳定的 `evidence_bundle_*` blocker 并保留 checkpoint；不得创建空 required 文件掩盖丢失。自由扫描仍按既有完成条件结束。

所有普通 localization/confirmation writer 在进入序列化 I/O 前先向 `PriceTagSessionAdmissionGate` 登记 transaction/reservation。`beginFinalization` 与 admission 在同一短锁域线性化：finalization 后的新普通 writer 被拒绝，但此前已登记 writer 即使尚在等待 writer lock 也必须完成或明确失败，finalization drain 会等待其计数归零。writer 内部不再通过再次读取 `isFinalizingScan` 否定已获得的 admission。普通 frame-driven Recovery 与 ARFrame localization 在入队和执行前都检查 generation/finalization，并使用 `allowDuringFinalization=false`；只有 terminal teardown/finalization Recovery、finalization-owned burst flush/session completion，以及 scan-stop 自有 audit 使用显式窄范围 override。

ESL audit 不是 session 创建 API。每个 capture generation 冻结 exact tracking session ID；`appendScanEventIfSessionActive` 只在 admission 后、`captureLock` 内核对该 identity、既有 root、`segmentIndex == 1` 和已存在的 `segment_0001`，从不调用隐式 `startNewSessionIfNeeded()`。因此无 active session、finalization 后的普通 audit、detach 后的旧 generation 和未知/已驱逐 generation 都 fail closed，不会创建空 successor session 或把旧事件写入新 session。

checkpoint cleanup 是显式破坏性恢复事务。iOS 与 PC 都按 path component 验证 session/唯一 `segment_0001`，拒绝 symlink；Windows 额外拒绝 junction/reparse point。metadata、checkpoint 和既有 audit 文件以 no-follow descriptor 打开，`fstat` 证明 regular file 和设备/文件身份，授权审计后重新打开并比较身份、长度和字节，再删除同一 checkpoint；删除失败追加 `finalization_checkpoint_cleanup_failed`，审计自身失败会明确记录 degraded。Map Studio inspect 返回客户端看到的 tracking identity、finalized time 及 metadata/checkpoint SHA-256；POST 必须携带严格 `confirmed=true` 和全部 expected evidence，任何变化返回 HTTP 409 `checkpoint_cleanup_conflict`。普通 inspect/reprocess 从不自动删除。

## performance_samples.jsonl

生产写侧约每 5 秒追加一条 `MarketScannerPerformanceSample` version 1，数据库保存完成后追加 `scan_state=finalizing` 的终止样本。文件最大 256 MiB、250,000 条、单条 64 KiB；48 小时资格规模按 5 秒 cadence 为 34,560 条。每行必须是 UTF-8 JSON object、无空行、以 newline 结束，`sequence` 从 1 连续递增，`timestamp_unix` 严格递增，`tracking_session_id` 在全文件内固定并与 metadata 相等，所有数字必须有限且非负。

```json
{
  "format": "MarketScannerPerformanceSample",
  "version": 1,
  "sequence": 42,
  "timestamp_unix": 1786722600.123,
  "process_uptime_seconds": 210.5,
  "tracking_session_id": "...",
  "scan_state": "mapping",
  "tracking_state": "normal",
  "node_count": 815,
  "database_memory_mb": 286,
  "database_bytes": 734003200,
  "scan_storage_bytes": 741342208,
  "process_memory_footprint_mb": 1480,
  "available_memory_mb": 670,
  "process_cpu_time_seconds": 88.4,
  "process_cpu_percent": 172.1,
  "thermal_state": "fair",
  "battery_percent": 63.0,
  "battery_charging": false,
  "available_disk_bytes": 45781234567,
  "rendering_fps": 23.8,
  "rtabmap_update_time_ms": 43.1,
  "word_count": 12000,
  "feature_count": 1300,
  "point_count": 280000,
  "polygon_count": 0,
  "online_loop_closure_count": 12,
  "reliable_loop_closure_count": 4,
  "gpu_metric_status": "not_available_public_ios_api",
  "gpu_utilization_percent": null
}
```

`process_cpu_percent` 是进程累计 user+system CPU 时间相对墙钟的区间比率，多核设备上可大于 100%，不是按单核归一后的整机 CPU。`process_memory_footprint_mb` 来自 `phys_footprint`，`available_memory_mb` 来自 iOS process-available-memory；测量不可用时相应可选字段为空/省略，不能写 0 冒充测量。普通 iOS App 无可靠公开整机 GPU utilization API，因此 GPU 百分比保持 null，并由 status 明确说明。

Map Studio 对源文件执行单链接 regular-file、前后 stat、文件/行/条数、JSON finite scalar、identity、sequence、timestamp 和 metadata 水位校验；一次流式读取同时计算 SHA-256、写原始副本与 CSV，并使用有界确定性压缩生成浏览器趋势和近似分位数。最终单设备地图包包含：

```text
performance/
  performance_manifest.json
  phone/
    phone_performance_samples.jsonl
    phone_performance_samples.csv
    phone_performance_summary.json
    diagnostics/metrickit_diagnostics_*.jsonl   # 已投递时
```

坏日志不生成可信 CSV/趋势；若源文件仍是安全大小的单链接 regular file，则 exact 原始 bytes 以 `phone_performance_samples.invalid.jsonl` 保留并记录 SHA-256，便于 PC 取证。多设备结果使用 `performance/device_01/`、`device_02/` 等独立命名空间。

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
  "mapFromArkitX": 4.2,
  "mapFromArkitY": -1.3,
  "mapFromArkitYawDeg": 18.0,
  "selectedHypothesisId": 7,
  "activeHypothesisTrackCount": 2,
  "hypothesisBestCost": 0.02,
  "hypothesisSecondCost": 0.05,
  "hypothesisReason": "trusted_local_hypothesis",
  "hypothesisTrackerElapsedMs": 0.08,
  "constraintAccepted": true,
  "constraintReason": "trusted_structure_correction"
}
```

接受和拒绝都记录原因，结构匹配保留最多 5 个独立盆地。`rawPose` 是现有对齐下的 ARKit 预测投影；`estimatedPose` 才包含通过安全门控的小幅地图对齐修正。道路候选仅保留为弱先验证据。

P7R2 的 hypothesis 统一跟踪全局 `T_map_from_arkit`，而不是手机自身坐标下的局部平移。对 ARKit 水平位姿 `A=(R_a,t_a)` 与候选地图位姿 `C=(R_c,t_c)`，记录的变换满足 `M=C×inverse(A)`：`theta=normalize(yaw_c-yaw_a)`、`t_m=t_c-R(theta)t_a`，且 `apply(M,A)` 必须重建 `C`。`mapFromArkitX/Y/YawDeg` 是所选 track 的平滑全局变换；`selectedHypothesisId` 只在本次 tracker 生命周期内稳定；active count 上限 8；best/second cost 对应当前排名前两条活动 track；reason 与 tracker elapsed 用于解释歧义和性能。无活动 hypothesis 时可选字段省略。以上是 version 1 的向后兼容附加诊断字段，不改变现有必填业务 schema；旧 reader 可忽略，最终证据校验仍要求原有身份、时间和 pose 字段。

P7R3 把宽搜索改为显式 Recovery episode。`inactive -> active -> converged | timed_out | cancelled | manual_reset`；新 episode 开始时清空 hypothesis track，但保留已应用的 `T_map_from_arkit` anchor，因此 HUD 不会因触发 Recovery 瞬移。Recovery trust 的 `hypothesisSupportFrames`/`recoveryFreshSupportFrames` 只包含本 episode 的新观测，至少 4 帧；local lifetime support 不得参与。预算为最多 40 次有效 matcher search 和 30 秒 wall clock，只有 tracking normal、observation 非空且 matcher 有至少 30 个 effective points 时才增加 attempt；throttle、busy、limited/no-depth/nil/undersized observation 不消耗 attempt。所有 outcome 都清除宽搜索 tracks；2026-08-15 冻结规格将已应用 anchor 的平移单步上限收紧为 0.25 m，角度上限仍为 8°。

`localization_trace` v1 继续用向后兼容可选字段记录 `recoveryEpisodeId/recoveryReason/recoveryOutcome/recoveryValidAttemptCount/recoveryRemainingValidAttempts/recoveryElapsedMs/recoveryFreshSupportFrames/recoveryTriggerCount`。active 记录使用 `recoveryOutcome=active`；结束该 episode 的记录使用终态字符串。数值均为有限小标量，不保存结构点；旧 reader 可忽略这些字段。

可靠 RTAB-Map 回环仍会在 `scan_events.jsonl` 写可读诊断摘要；正式 authority 已迁移到 manifest v5 的 `shelf_observation_windows.jsonl` 与 `shelf_loop_events.jsonl`。只有 exact node 区间、同 component、同 epoch 或正式 bridge、两侧法向 >120°、phone↔shelf 相对 SE(2) 差异不超过 0.5 m/10°、inlier ≥70% 且动态证据不主导时，loop 才可写 `accepted=true` 并进入 PC shelf-face 因子。C-1/C-2/C-3 数值必须随记录保留 `CALIBRATION_PENDING`，不得表述为现场冻结值。

## Manifest v5 通道/货架证据

- `pose_epoch_transitions.jsonl`：相邻 epoch、前后 exact node、有限 SE(2) 变换和可选正式 bridge evidence；跨 epoch loop 没有完整 bridge 链时不得接受。
- `corridor_hypotheses.jsonl`：exact node/map/component/epoch、bounded top-K、top1/top2 margin、点/扫掠线段穿架计数和沿轴/横轴/yaw covariance。
- `shelf_observation_windows.jsonl`：exact node/time range、component/epoch、left/right、地图法向、bounded shelf candidates、覆盖角、端头可见、动态剔除计数、prior-map 与 distance-field SHA。
- `shelf_loop_events.jsonl`：两个窗口、具体 shelf segment、RTAB loop 身份/残差、phone↔shelf SE(2)、一致性指标、接受结果/原因和标定状态。

四个文件允许 0 行但必须存在；严格 UTF-8 JSONL、无空行、末行换行、未知字段拒绝、sequence/write_watermark 从 1 连续增长。metadata 同时声明四个文件及 exact count/last-sequence、`shelfLocalizationEvidenceComplete=true` 和 `shelfLocalizationCalibrationStatus=CALIBRATION_PENDING`。manifest v5 的 trace 和 tag observation v2 必须逐记录携带 epoch/component；v1-v4 继续只读兼容但没有 formal shelf-loop authority。

PC native helper 的 `MarketScannerAbsoluteSE2Priors` 在存在 shelf-face 因子时使用 version 3：保留 v2 的 target pose、平移 sigma 和 yaw sigma，并新增平移信息矩阵 `Ixx/Ixy/Iyy`。普通先验仍写等方差矩阵；shelf-face 以货架面法向 0.5 m、沿架 3 m 初始不确定度构造各向异性矩阵，因此只强约束法向和相对 yaw，不把长货架轴向位置伪装成厘米级真值。该 3 m 沿轴值随 C-1 保持 `CALIBRATION_PENDING`；v1/v2 prior 文件继续可读。

`timestamp` 保留原始 `ARFrame.timestamp`（设备单调时钟）；RTAB‑Map 的 `CameraMobile` 在写 `Node.stamp` 前会加 `stampEpochOffset`。因此所有当前定位 sidecar 同时保存 `nodeTimebaseTimestamp = timestamp + nodeTimebaseOffsetSeconds`，PC 只用换算后的 node timebase 绑定 SQLite node，并严格复算该等式。offset 由 native camera 原子读取；尚未初始化或非有限时该记录拒绝落盘，不能直接拿原始 ARFrame 时间与 epoch node stamp 比较。

## clock_correlations.jsonl

正式 session input manifest v4 绑定 `clock_correlations.jsonl`。文件同时包含 `MarketScannerClockCorrelation` v2 和 `MarketScannerClockNodeBinding` v2：前者保存 device monotonic uptime、UTC、IANA `timezone_id`、`utc_offset_seconds` 与采样原因；后者把 exact `node_id/node_stamp/sampled_frame_timestamp/system_uptime` 绑定到同一 UTC/时区上下文。metadata 的 `clockCorrelationCount` 与 `clockNodeBindingCount` 是严格水位，必须与 durable 行数一致。

Swift 与 PC reader 统一要求 correlation uptime、correlation UTC、binding node stamp 和 binding UTC 严格递增；`sampled_frame_timestamp` 与 `node_stamp` 差值最多 2 秒，binding UTC 必须在 2 秒内吻合 correlation 插值，且 binding 的 timezone/offset 必须等于该 uptime 所属 correlation context。单个语义不一致 binding 会被排除并审计，不会抹掉其余合法时间线；少于两个合法 correlation 或 binding 时不能宣称权威时间映射，但这属于覆盖退化而不是整单失败。只要 framing、水位、身份和数据库仍完整，节点轨迹和价签继续提交，correlation 覆盖的秒级时间行全部保留，无法绑定位置的行写 `UNAVAILABLE`。历史无权威 clock evidence 时 node stamp 仅保留在 `node_timebase_timestamp`，不得伪装成 UTC。

系统时钟跳变、timezone/offset 变化以及 UTC 相对 uptime 残差超过 2 秒都会切分 `clock_segment_index`。节点级 CSV 保存每个 node 的 segment；秒级 CSV 只允许在同一 segment 内插值。跨 segment 的秒必须保留业务行，但 `x_m/y_m/yaw_*` 为空，`position_status=UNAVAILABLE`、`position_degradation_code=clock_discontinuity`。任何处理机本地时区、当前 wall clock 或跨 discontinuity 插值都不是合法回退。

## 阶段二定位审计

- `localization_constraints.jsonl`：每个匹配周期的预测/估计、Top‑3、残差、唯一性、有效点数、角覆盖、耗时、接受标记和原因；同时保存 raw/node timebase/offset。
- `localization_events.jsonl`：状态发生变化时记录 previous/state/confidence/reason 和双时间基准。
- `tag_observations.jsonl`：每个成功 Barcode Capture frame 的独立原始观测，即使用户取消最终确认也保留；保存 `observation_id/burst_id/frame_id`、`frame_timestamp/node_timebase_frame_timestamp/node_timebase_offset_seconds`，以及 `alignment_age_ms/alignment_version_lag/alignment_freshness` 和逐帧深度证据。version 2 由同一次 native atomic snapshot 冻结 `bound_node_id`、`bound_node_stamp`、`bound_node_map_id` 与 node pose，并声明 `coordinate_frame=RTABMAP_BOUND_NODE_LOCAL`、`point_in_bound_node_frame={x_m,y_m,z_m}`；`measurement_height_m` 与 node-local z 分离。只有 scene-depth 类测量允许 node-local 点，二维 `shelf_plane_ray`/`unavailable` 必须省略它。`raw_map_position` 只保留在线显示/审计，不再是最终传播权威。
- `tag_observation_bursts.jsonl`：每个完成 capture 的 `MarketScannerPriceTagBurst` version 2；包含 canonical burst/capture ID、严格递增 sequence、barcode/symbology、完整 scan/map/floor identity、3—64 个唯一 frame、node/time/depth/view/tracking/confidence 摘要和 `complete=true`。同一 observation 或 frame 不得跨 burst 复用；durable observation 中只要带有 burst/frame identity，就必须出现在该 complete burst 中，反向亦然。
- `localized_price_tags.json`：version 1 继续只读兼容旧字段。新的现场确认写 additive version 2：`capture_id/frame_observation_ids` 必须精确等于一个 verified complete burst；`algorithm_*` 保存算法货架 segment/code/side/offset/confidence，`user_confirmed_*` 保存操作员选择，`confirmation_status=USER_CONFIRMED|USER_OVERRIDDEN`、确认时间和 `confirmation_source=on_device_operator` 独立审计。用户 override 不得覆盖 `algorithm_*`，也不得写回 SLAM、trajectory、node pose、localization constraint 或 map alignment。

只有至少 3 个逐帧 `algorithmCandidateReliable=true`、`needsReview=false` 的独立 observation 共同指向同一 `shelfSegmentId + side`，UI 才能提供可靠确认。确认提交使用一次性 capture authority，并在同一 session writer 事务中重新核对 workflow、required-write health、tracking session、prior-map ID/SHA-256、floor、capture ID 和 verified burst frame set；取消先于 claim 时不写，claim 先于取消时已接受的提交继续由持久化回调收口。

手机结果 `FinalPriceTag.quality_status` 为三态：`ACCEPTED` 表示所有自动质量门通过；`LOW_CONFIDENCE` 表示 observation↔burst、tracking/map identity、exact `boundNodeID/stamp/map_id` 和 node-local 可重算位置权威完整，但 recovering/weak、深度、node uncertainty、离散度或货架关联不足以自动批准；`RESCAN_REQUIRED` 仅用于完整 burst、身份/图质量、exact node、node-local point、measurement method 或可解析位置等权威条件缺失。`LOW_CONFIDENCE` 必须保留在 PriceTags 和质量报告中。手机与 PC 均按 `P_final = T_final_node × P_node` 使用 exact node O(1) 重投影，不允许 nearest-time fallback，也不允许对已经在 prior-map frame 的 `raw_map_position` 再应用 raw-node inverse。手机 `MarketScannerFinalTags` version 2 与 PriceTags 工作表保留 online/raw、optimized、shelf-projected 三类平面坐标、法向投影残差和纵向段内标记；兼容字段 `map_x_m/map_y_m` 对可发布价签必须等于 shelf-projected。历史 observation v1 只保留条码/业务身份并产生 `legacy_tag_coordinate_frame_rescan_required`，不得输出可发布地图坐标。

手机 result manifest 的 `coordinate_contract_version=2` 同时记录 `coordinate_frame_audit_passed` 和 `legacy_tag_coordinate_frame_count`。`COMPLETE/publish_permitted=true` 仅在地图坐标权威、图质量 PASS、零 degradation、coordinate audit PASS、零 legacy、零 `LOW_CONFIDENCE`、零 unpositioned、零 unassociated、零 rescan 时成立；immutable result reader 与任务恢复重复验证。历史 coordinate contract v1 只允许作为不可发布复核工件。

durable burst 的业务库存独立于其最终置信度。`burst_id`、burst frame `frame_id`、burst/observation 两侧的 `observation_id` 都在读取原始身份后立即进入会话级全局唯一集合；即使该 burst 后续因为 summary、schema、node binding 或关联证据不足而退化，这些 ID 也不会被释放给后续 burst 复用。跨记录非空 `capture_id` 同样必须唯一。重复 durable 主键会使业务身份不可界定，因此属于少数仍可阻断的完整性错误，而不是普通低置信度。

PC 以“原始 localized tag 数量 + 未被任何 final tag `capture_id` 表示的安全 durable burst 数量”计算 `tag_source_record_count`。若一个身份、barcode、symbology 和记录边界都明确的 durable burst 没有出现在 final tag 数组中，PC 必须补出 exactly one `LOW_CONFIDENCE` 业务记录，保留 `capture_id/barcode/symbology`，位置和货架为空，并写 `durable_burst_missing_final_tag`；不得按 barcode 合并不同 burst。最终 `tag_source_record_count == tag_retained_count`，否则不可提交不可变成果。

JSONL 文件逐行独立编码和同步追加，禁止空行且最后一条记录也必须带换行；最终价签数组用同目录唯一 temp、完整写入、`synchronize()` 和原子 rename 替换。write/flush/rename 三个提交前阶段可故障注入，失败保留旧文件并清理 temp。该合同保证应用进程观察到旧文件或完整新文件，并为进程崩溃恢复提供 checkpoint；iOS 没有在此路径声明父目录 fsync/设备断电持久化保证，因此类型和文档只称“原子可见提交”，不能把它写成 power-loss durable。必需定位追加使用 throwing `FileHandle` I/O 并返回结构化的 trace/constraint/state 成败；任一 observation 已持久化但无法进入相同 burst 时立即增加 sticky required-write failure，不能只写 warning 等待最终化发现 orphan。写入前必须确认 tracking session ID 与活动会话一致且未进入 finalization，不允许日志接口自动创建新会话目录。PC 对每类文件使用正式 contract：严格 UTF‑8/JSON（禁止 NaN/Infinity 和未知 v2 tag/burst 字段）、format/version、会话/地图/floor 身份、有限且按契约单调的时间戳、业务必填字段、单行/记录上限、重复 ID 和 observation↔burst exact binding 检查。`localization_trace`、constraints、state events 为必需；最终 metadata 必须明确 `localizedPriceTags` 文件名与准确计数，即使为 0 也必须存在；有最终价签时 observations 必需且不得为空。manual v3 是当前格式，v2 仅作严格兼容；legacy v1 只允许进入拒绝审计和 review blocker，不能形成锚点。

外部复制的 `segment_0001` 必须满足复制前源清单 = 关闭句柄后目标复读清单 = 复制后源清单，每项包含 POSIX 相对路径、字节数和 SHA-256。验证成功后在目标 session 根写 `copy_verification.json`（format `MarketScannerExternalCopyVerification` version 2），只记录 session/package ID、provider display name、相对路径、清单、package content SHA-256、验证时间、`localCopyRetained=true` 和 provider durability 边界，不写绝对源/目标路径。`copy_package_manifest.json`（format `MarketScannerExternalCopyPackageManifest` version 1）把 segment 和 receipt 纳入 export-root 清单，并固定 `durabilityQualificationStatus=not_executed`。真实设备在实际 reconnect/disconnect/power-cycle 后可通过资格 hook 重散列并生成 `copy_durability_qualification.json`；普通复制不能生成该证据。默认始终保留本地会话；provider 复制完成和复读一致不能证明云盘/外接介质已承受设备断电，真机 provider 策略验收前不提供自动删除。

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
    factor_graph_report.json
    review_items.json            localized_review.json
    manual_edits.json
    calibrated_positions_by_node.csv
    calibrated_positions_1s.csv
    calibrated_deliverables_manifest.json
    localized_price_tags.json/.csv/.geojson
    shelf_tag_index.json         audit_log.jsonl
    field_evidence.json          # 仅 published/revoked v6
    qualification_manifest.json # 仅 published/revoked v6
```

`localization_report.json` 包含地图/会话/数据库 hash、直接从 source/optimized SQLite `Node` 表和导出轨迹交叉计算的节点覆盖/缺失/重复/时间范围、三条轨迹长度、修正分布、绝对约束和相对边残差、weak/lost 时长、约束接受/拒绝、标签 observation coverage、review/publish blockers 和 `publish_state`。测试诊断结果还固定记录 `diagnostic_mode`、`diagnostic_only` 和 `ignored_conflicting_source_constraint_count`；它可以推进工作用 `draft/current` 以便加载复核，但 `publish_gate` 必含 `diagnostic_mode_enabled` blocker。`factor_graph_report.json` version 1 保存 native solver/DB 版本、input identity、optimized DB SHA-256、canonical factor digest、Node/Factor inventory、gauge/连通性、objective/iterations、残差分位数、拒绝/降权诊断及最终 poses。完整报告必须通过 Python 和 version store 两层复核。

长会话成功生成道路复核草稿时，`localization_report.json` 还包含 `gauge_neutral_physical_trace` 与 `corridor_route_match`。前者记录 trace/node 数、自动/人工 alignment reset 数、输入 map-gauge 最大跳变、恢复后最大物理步长和物理里程；后者当前使用 `MarketScannerCorridorRouteMatchAudit` version 2 和 `matcher=bounded_free_space_road_hmm_v2`，记录逐节点 `edge_ids/corridor_ids`、货架内点、穿越结构线段、道路拓扑断裂、最大输出/物理步长、输出/物理里程、`ambiguity_intervals`、通道身份置信度、人工锚点残差以及分段 `distance_scale`。`geometry_preservation.method=local_geometry_preserving_corridor_envelope_v2` 必须同时声明 `centerline_snap_applied=false`、`road_geometry_role=topology_and_free_space_constraint_only` 和 `source_geometry_role=optimized_phone_pose_local_geometry`；道路有限端点范围只进入身份评分，不得成为最终坐标目标。

`geometry_preservation` 还记录 `anchor_translation_field`、`correction_field_solver`/迭代数、`point_obstacle_escape`、`point_escape_continuity_repair`、`segment_collision_repair`、`correction_spike_repair` 和 `correction_gradient_repair`。线段修复的正常路径是 shelf-driven rigid translation；`safe_escape_reference` 明确区分货架刚体平移与 exact anchor 锁定时的 topology fallback。最终修正尖刺/梯度只有在候选点、整个窗口线段均处于自由空间且局部最大步长不增加时才可替换。`mean_centerline_offset_m`/`maximum_centerline_offset_m` 只是证明轨迹未被压到中心线的审计量，不是误差目标。任一分段尺度与 1.0 偏差超过 5% 时，`distance_scale_confidence=low` 并加入 `corridor_route_distance_scale_above_5pct`；修正相邻梯度仍超过 0.5 m 时加入 `corridor_envelope_correction_gradient_above_0_5m`。这些普通质量项保留完整版本和工件，只阻止 review/publish。历史 version 1 的 `reparameterization` 继续只读解析，不能作为新结果写出。

`optimized_map_trajectory.geojson` 的 `rtabmap_optimized`、`prior_map_offline_optimized` 和可用时的 `online_localization` feature properties 均保存 `timestamps`、`node_ids` 与同长度 `yaws_rad`。`yaws_rad` 是对应地图 gauge 下的手机朝向；道路切线仅表示移动方向，不能代替手机 yaw。任何坐标、时间、node ID、yaw 长度不一致或非有限值都使校准坐标导出拒绝执行。

helper 可用且所有门通过时 `solver.type=relative_se2_factor_graph`、`full_factor_graph=true`；helper 缺失或失败时仍写报告，但回退为 `bounded_correction_field` draft，`published_capable=false`。长会话 corridor route 是 full graph 之后的正式自洽验证/修正层，不再把一次成功匹配强制改回 `full_factor_graph=false/published_capable=false`；低置信 route、结构内点、穿架段、拓扑断裂、非物理步长、>5% 尺度偏差或 >0.5 m 修正梯度仍 fail-closed。价签输出保留 `online/raw_map_position`、`optimized_map_position`、`shelf_projected_map_position`；发布坐标必须等于 shelf-projected，法向残差 ≤0.5 m 且纵向位于长边范围内。旧 version manifest v1/v2 可继续只读解析；含 factor report、但还没有不可变业务表的历史 draft/review 使用 version manifest v3。当前 draft/review 将四个核心业务表和 `calibrated_deliverables_manifest.json` 纳入 exact file/hash tree，使用 version manifest v5；正式 publication 使用 version manifest v6。

不可变 localized version 自身就是核心业务成果权威，包含：

```text
calibrated_positions_by_node.csv
calibrated_positions_1s.csv
localized_price_tags.json
localized_price_tags.csv
calibrated_deliverables_manifest.json
```

`calibrated_deliverables_manifest.json` 记录 source/exported node、source/retained tag、positioned/unpositioned/shelf-associated/unassociated tag 数量，并绑定四张表的 row count、字节数和 SHA-256。普通导出不得修改这些文件。`tools/PriorMap/export_calibrated_trajectory.py` 先按 `version_manifest.json` 验证核心 CSV，再逐字节复制到 version 外的兼容目录并额外生成复核 PNG：

```text
calibrated_trajectory_exports/
  calibrated_positions_by_node.csv
  calibrated_positions_1s.csv
  calibrated_trajectory_on_prior_map.png
  calibrated_trajectory_timestamped.png
  export_manifest.json
```

节点级与秒级 CSV 字段包括 Unix 秒、本地 ISO-8601 时间、IANA 时区、UTC offset、`clock_segment_index`、clock/position status、`x_m/y_m`、`yaw_rad/yaw_deg`、`yaw_source=optimized_phone_pose`、nearest node、道路 edge/corridor、`route_confidence`、`corridor_identity_confidence`、`distance_scale`、`distance_scale_confidence` 和人工锚点状态。时钟或位置不可用时业务行继续存在，未知坐标字段保持为空，不能写 `(0,0)`；低置信度与不可发布状态必须原样传播到导出 manifest，不能因为能生成 PNG/CSV 就提升结果资格。

`localized_review.json` 是 Map Studio 的有界联动复核视图数据，包含先验结构、三条轨迹、价签、问题列表和明确的 `view_limits`/截断标记；它是派生展示文件，不替代各权威成果文件。

`manual_edits.json` version 4 绑定 `input_identity_id/session_input_bundle_sha256/prior_map_sha256/source_database_sha256/optimized_database_sha256/processing_parameter_sha256/tool_version/coordinate_contract_version`。事件保存服务端生成的 `event_id/created_at_utc/base_revision/old_value/new_value/actor/reason`；`audit_events` 单独记录 append/undo/redo 的旧/新 cursor。API 强制 `expected_version_id + expected_revision`，冲突返回 409；只有完整重放和版本校验成功后才推进 current。

可导出的 `source_manifest.json` 只保存会话/数据库文件名、地图 ID 和各输入 SHA‑256，不保存用户名或绝对路径。不可变 version 内的 `session_input_manifest.json` 按规范顺序绑定数据库、metadata 和全部必需 sidecar 的 role、规范文件名、大小及 SHA‑256，并生成 `input_identity_id`。v1 是 legacy 输入，v2 额外绑定 Recovery sidecar，v3 再绑定 `tag_observation_bursts.jsonl`，v4 再绑定 `clock_correlations.jsonl`。共享 manifest validator 强制 version 为非 Boolean 的严格 JSON integer；v1 对应 `recovery_lifecycle_evidence_unbound_legacy`，v2/v3/v4 对应 `recovery_lifecycle_evidence_bound_v2`，并要求 processing/report 中的 manifest version 与 binding 一致。v4 已是当前正式时钟合同，未来 loop-window 货架结构证据必须使用 v5，不能复用 v4。`metadata` role 只能指向 `metadata.json`，除 `source_database` 可保留实际数据库 basename 外，其余 role 的 `file` 必须与 role 完全相同；全部文件名按 case-insensitive 规则唯一。source database 名称必须非空、不是 `.`/`..`、不含 slash/backslash/NUL、不是 POSIX/Windows absolute 或 drive-relative path、不与 canonical sidecar 冲突，并与 `source_manifest.source_database_name` 完全一致。即使攻击者重算 bundle/cross-artifact hash，role→filename 改绑仍会 fail-closed。source database 在 manifest build、snapshot 和 verified copy 三个入口都必须是稳定的 single-link regular file，且相邻非空 WAL 或 rollback journal 会拒绝输入。人工复核重放所需的本机绝对路径按该身份单独写在 `localized/local_inputs/<input_identity_id>.json`；它不进入不可变 version、artifact allowlist 或导出包。读取时先验证 version 本身，再验证 local-input identity 和当前输入字节；不能用可变全局路径状态重放旧版本。

PC 重关联不会静默覆盖操作员确认：optimized segment+side 与用户选择一致时写 `NO_CONFLICT` 并保持 approved；可靠 optimized 证据指向另一 segment/side 时写 `USER_CONFIRMATION_CONFLICT`；pose binding、raw map position 或 offline association 不可用/不可靠时统一写 `OFFLINE_ASSOCIATION_UNAVAILABLE`。后两者固定为 `REVIEW_REQUIRED`、`rescan_required=true`、`needs_review=true`、`approval_status=pending`，并保留全部 algorithm/user evidence。

版本写入在 `localized/.write.lock` 的跨进程排他锁内完成父版本复核、staging 清理、版本号分配、rename 和单一指针提交。版本目录 rename 后必须先 fsync `versions/`，失败时不切指针；指针 replace 后的目录 fsync 失败会返回“durability indeterminate”，调用方必须先读取实际指针再恢复，禁止盲目重试。读取 current/published 或下载 artifact 时会重新核对 exact file set、regular-file、字节数及逐文件 SHA‑256，下载还对已打开 fd 的实际字节再次验 hash。发布创建独立 published snapshot 并只切换 `published.json`；存在 active published 时必须先撤销。正式发布还要求 production-only server 即时 selfcheck、store 层空 blocker/完整因子图门，以及由 actor/UTC、`localized_review.json` SHA、exact Field Evidence bytes 和 candidate manifest SHA 共同绑定的现场验收记录。没有匹配的自包含现场证据时仍不能正式发布。

# P7R4 Recovery confidence fields (backward-compatible v1 additions)

`localization_trace.jsonl` keeps version 1 and adds optional/defaulted fields: `measurementAccepted`, `hypothesisTrusted`, `correctionStepApplied`, `recoveryConvergedThisUpdate`, `confidenceAccepted`, `constraintDisposition`, `postRecoveryTrustedLocalFrames`, `scanSearchPerformed`, `recoveryFinishedAtUptime`, `recoverySelectedHypothesisId`, `recoveryFinalResidualTranslationM`, `recoveryFinalResidualYawDeg`, `recoveryCorrectionStepAppliedOnCompletionFrame`, `recoveryCooldownRemainingMs`, `recoveryAutomaticTriggerSuppressed`, and `recoveryAutomaticTriggerReason`.

`localization_constraints.jsonl` keeps version 1 and adds `measurementAccepted`, `correctionStepApplied`, `confidenceAccepted`, and `disposition`. `accepted=true` means a formal high-confidence constraint only. `provisional_recovery_step` must always have `accepted=false` and `confidenceAccepted=false`; the PC reader fails closed on a contradictory record. Allowed dispositions are `rejected`, `provisional_recovery_step`, `accepted_local`, and `accepted_recovery_convergence`. All numeric diagnostics must be finite.

Mobile post-processing validates the current writer schema exactly: unknown top-level/pose/candidate fields, non-strict version/Bool/Int values, floor/map/SHA/session mismatches, node-timebase invariant failures and disposition/measurement/correction/confidence contradictions are fatal evidence. A complete identity-bound `accepted=false` record is a normal negative decision, is retained in the non-accepted audit and never creates an absolute prior; it is not itself a corrupt-record blocker. The qualified constraint scale is 48 hours × 2 Hz = 345,600 rows, with a 400,000-row parser hard cap, 64 KiB per-record cap and 768 MiB file cap. `captureHealth.localizationConstraintRecordCount`、`captureHealth.manualLocalizationEventCount` 和 `captureHealth.localizationRecoveryEventCount` 分别是 constraint/manual/recovery 的严格原始行数水位。Manual v2/v3 records reject unknown fields, cross-check ISO/Unix and node-timebase timestamps, and both enforce nearest-node plus second-candidate margin; v3's claimed node ID must equal the recomputed nearest node.

Component identity is not present in the current formal constraint schema. The final snapshot DB exposes node `map_id` and links, but `PriorMapConstraintRecord` has no atomic bound node ID/map ID; manual v3 has a nearest node ID but no RTAB-Map map ID. A connected-component number is also not stable while later loop links can merge components. Therefore current readers must not synthesize a claimed component. Closing J-04 requires a new writer schema with atomic bound node ID/stamp/delta/snapshot generation and real RTAB-Map map ID; the final component is then derived from snapshot links. Existing version-1 constraints cannot be retroactively certified as same-component evidence.

Recovery completion fields belong to the completed episode. On a completion frame the flat current-hypothesis fields are left empty rather than associating a new Local candidate with the old Recovery outcome. A just-converged frame is at most `usable`; only later ordinary Local evidence may reach `stable`, and only `stable` may authorize automatic price-tag confirmation.

# P7R5 terminal Recovery lifecycle evidence

`localization_recovery_events.jsonl` carries one `MarketScannerRecoveryLifecycleEvent` version 1 record per finished Recovery episode, including teardowns (scan stop, map unload) that never see another update frame. Fields: `format`, `version`, `tracking_session_id`, `prior_map_id`, `prior_map_sha256`, `floor_id`, `episode_id`, `reason`, `outcome` (`converged`/`timed_out`/`cancelled`/`manual_reset`), nullable `cancellation_reason` (`scan_stopped`/`map_unloaded`/`app_interrupted`/`session_generation_changed`/`operator_cancelled`), `episode_automatic`, `started_at_uptime`, `finished_at_uptime`, `elapsed_ms` (bound to `finished_at_uptime` when a completion exists, never to a later consuming frame), `valid_matcher_attempts`, `accepted_corrections`, `trigger_count`, `automatic_trigger_count`, `reliable_loop_trigger_count`, `last_trigger_reason`, `last_trigger_at_uptime`, nullable `selected_hypothesis_id`, `fresh_support_frames`, nullable `final_residual_translation_m`/`final_residual_yaw_rad`, and `completion_frame_step_applied`.

Timestamps are monotonic uptimes, not node-timebase stamps; the evidence bundle validator checks identity and format through a recovery-specific branch with non-strict timestamp ordering. Since P7R6 the sidecar is reconciled against an exact expected-count watermark: capture health carries `localizationRecoveryEventCount` plus the last persisted `localizationLastRecoveryEpisodeId`/`localizationLastRecoveryFinishedAtUptime`, the watermark advances exactly once after each confirmed durable append and never on failure, finalization validates the exact record count and the last episode/finish uptime against it, and a missing file or a rebuilt empty file while the watermark is positive is a hard blocker instead of being masked. Writing a terminal record is required evidence: any append failure increments the localization required-write failure counter and makes the session processing-ineligible (fail closed). Cancellation outcomes are reconciled with the automatic cooldown: convergence/manual reset clears it, timeouts extend it regardless of trigger source, and cancellations follow their explicit reason (`scan_stopped`/`app_interrupted` suppress automatic retry). Each episode retains a bounded trigger summary: at most eight trigger records plus automatic/reliable-loop counters and the last trigger reason/uptime.

# P7R6 recovery evidence integrity contracts

`MarketScannerRecoveryLifecycleEvent` version 2 adds `deadline_uptime`, `maximum_valid_attempts`, and the bounded `trigger_records` sequence; version 1 records remain readable. Both devices and the PC reader fail closed on the strict business schema: outcome whitelist, cancellation reasons only on `cancelled` outcomes, elapsed time bound to start/finish within one millisecond, non-negative counters with `accepted_corrections` inside the attempt budget, automatic plus reliable-loop triggers equal to the trigger count, trigger records consistent with the last-trigger summary, strictly increasing episode IDs, and non-decreasing finish uptimes. Stable reads reject symlinks, hard links, partial final lines, and files swapped or truncated during validation.

Teardown-to-disk persistence runs through the Foundation-only `RecoveryLifecyclePersistenceCoordinator` with a peek/ack protocol: terminal completions stay queued in the localizer until the durable append is confirmed, a failed append keeps the completion retryable and auditable, identical already-persisted bytes acknowledge without rewriting (idempotence strategy A), conflicting bytes or an unreadable evidence snapshot fail closed, and a stale tracking-session identity rejects the write without advancing the watermark.

The PC input manifest binds the recovery sidecar in version 2: sessions whose capture health carries `localizationRecoveryEventCount` build manifest version 2 with `localization_recovery_events.jsonl` in the canonical file set (its bytes move the bundle SHA), a missing file fails the build, and the watermark decides the version, never the mere presence of the file. Older sessions keep manifest version 1 and are explicitly marked `recovery_lifecycle_evidence_unbound_legacy`; the marker stays outside the canonical hash so historical digests remain reproducible, and the canonical identity (format, version, source database SHA, bare file names) is identical across Windows and POSIX readers. The localized report adds `recovery_summary` (terminal outcome counts and provisional completion steps) and a `recovery_gate` whose blockers also enter the review and publish gates: a `recovering` state without a terminal record, or a final `recovering` state whose last terminal outcome is not `cancelled`, blocks the session.

# P7R6A persisted recovery parser contracts

The persisted Recovery lifecycle evidence now has one strict, Foundation-only parser (`RecoveryLifecyclePersistedEvidenceParser`) shared by both consumers:

1. `localization_recovery_events.jsonl` is JSONL: every non-empty file must end with a newline; blank lines, partial tails, trailing garbage, non-object lines, unknown fields, and NaN/Infinity are all rejected. The persistence coordinator and finalization consume the same stable-read snapshot through the same parser, so a file one of them accepts is always accepted by the other.
2. Version 1 and version 2 differ by exactly three facts: `deadline_uptime`, `maximum_valid_attempts`, and `trigger_records`. Version 1 records carry them as absent and are parsed without fabricating any of them; a v1 record that contains any of the three fields is rejected as an unknown field.
3. Version 1 evidence is never rewritten or upgraded in place, and a persisted v1 record can never be merged idempotently with a pending v2 episode of the same ID (`persisted_episode_version_conflict`, fail closed).
4. Mixed v1/v2 files are legal as long as episode IDs stay strictly increasing and finish uptimes never move backwards; finalization validates the mix through the shared parser.
5. Same-episode idempotence requires an existing v2 record whose canonical re-encoded bytes equal the pending canonical bytes; any other content for the same episode ID is `persisted_episode_bytes_conflict`. Appending an episode below the existing maximum is `persisted_episode_order_conflict`.
6. Acknowledgement only happens after the complete snapshot parsed: a parse failure reports `existing_evidence_<stable_code>` with `attemptedEpisodeIds` empty (no episode was attempted), and pre-transaction failures (missing identity, unreadable snapshot) never masquerade as an attempt on the first pending episode.
7. `attemptedEpisodeIds` lists exactly the episodes the transaction entered: pending [1,2,3] with a failure on episode 2 reports attempted [1,2], persisted [1], failed 2, and keeps [2,3] queued.
8. `prior_map_sha256` must equal the expectation and be a 64-character lowercase hex digest; identities are compared strictly, never only for non-emptiness.
9. The PC reader shares the contract: it rejects a missing final newline and classifies the shared fixtures (`tools/PriorMap/tests/fixtures/recovery_lifecycle/`) into the same stable categories as the device parser (PASS, `missing_final_newline`, `blank_record`, `duplicate_episode`, `episode_order_invalid`, `finish_order_invalid`, `unknown_field`, `identity_mismatch`).

# P7R6B strict JSON and pending-queue contracts

Last reconciled: 2026-08-05. This wave closes the strict-type, duplicate-key, pending-queue and unified-limit findings of the P7R6A review.

## Strict JSON scalars

A JSON numeric `0`/`1` is **not** a boolean. Swift Foundation bridges `NSNumber` through `is Bool`/`as? Bool`, so the device previously accepted a numeric boolean that the Python PC reader (`isinstance(value, bool)`) rejected. All formal evidence schemas now read booleans through `StrictJSONScalar.boolean` (a CoreFoundation `CFBooleanGetTypeID` check) and integers/numbers through `StrictJSONScalar.integer`/`.number`:

| Contract | Field | Swift rule | Python rule |
|---|---|---|---|
| Recovery record | `episode_automatic` | `StrictJSONScalar.boolean` | `isinstance(value, bool)` |
| Recovery record | `completion_frame_step_applied` | `StrictJSONScalar.boolean` | `isinstance(value, bool)` |
| Recovery trigger record | `automatic` | `StrictJSONScalar.boolean` | `isinstance(value, bool)` |
| Constraint | `accepted` | `StrictJSONScalar.boolean` | `isinstance(value, bool)` |
| Localized price tag | `needs_review` / `user_confirmed` | `StrictJSONScalar.boolean` | `isinstance(value, bool)` |
| Prior-map element | `visible` | `StrictJSONScalar.boolean` | PC producer writes real booleans |
| Prior-map validation report | `valid` | `StrictJSONScalar.boolean` | PC producer writes real booleans |
| Prior-map manifest/report | all count/statistics fields | `StrictJSONScalar.integer` | `type(value) is int`；`bool`/integral-float 均拒绝 |

Stable categories: Swift `business_schema_invalid` / `trigger_records_invalid`; PC `recovery_business_schema_invalid` / `recovery_trigger_records_invalid`; shared fixture category `business_schema_invalid` / `trigger_records_invalid`. Genuine `true`/`false` still pass on both readers.

## Duplicate JSON object keys

Duplicate keys are ambiguous evidence and are rejected **before** `JSONSerialization`/`json.loads` can silently apply last-key-wins. The on-device scanner (`StrictJSONKeyUniquenessValidator`) is byte-level and iterative (bounded depth 32, bounded tokens, no recursion), decodes JSON escapes including surrogate pairs, and compares decoded keys per object, so `{"episode_id":1,"\u0065pisode_id":2}` is a duplicate. Python uses an `object_pairs_hook` on every formal JSON/JSONL read. Stable categories: Swift `duplicate_json_key`; coordinator `existing_evidence_duplicate_json_key`; finalization blocker `evidence_bundle_localization_recovery_events.jsonl_duplicate_json_key` (other files follow the same `duplicate_json_key` reason); PC `recovery_duplicate_json_key`; shared fixture category `duplicate_json_key`.

## Pending completion queue contract

`RecoveryLifecyclePersistenceCoordinator` never sorts the pending queue; it carries finish order. Before any snapshot read, append or acknowledgement it validates: positive unique episode IDs in strictly increasing order, finite started/finished uptimes, `finished >= started`, and non-decreasing finish uptimes. Violations report `attemptedEpisodeIds=[]`, `persistedEpisodeIds=[]`, the first offending episode, and a stable reason (`pending_episode_duplicate` / `pending_episode_order_invalid` / `pending_finish_order_invalid`) with zero appends and zero acknowledgements. Effective persisted state (records and maximum episode ID) advances inside the transaction, so the idempotence lookup never falls back to a stale pre-append snapshot and the coordinator cannot write a duplicate episode even if the source contract regresses.

## Unified Recovery evidence limits

The device parser, the finalization bundle validator, the session stable-read snapshot and the PC reader share one frozen contract (`RecoveryLifecycleEvidenceLimits` on device; `RECOVERY_MAXIMUM_*` in `offline_localization.py`):

```text
maximumFileBytes                16 MiB
maximumRecordBytes              1 MiB
maximumRecords                  100,000
maximumTriggerRecordsPerEpisode 8
maximumJSONNestingDepth         32
```

The PC reader checks the file size before reading and the record/nesting depth per line. Boundary tests cover exact-limit PASS and limit+1 FAIL for file bytes, record bytes and nesting depth. Recovery records are small; the historical 512 MiB expected-count ceiling is gone.

## Status words

IMPLEMENTED, UNIT TESTED, INTEGRATION TESTED (P-B1..P-B15 Swift host; shared Swift/PC fixtures). Exact-final-SHA CI on the P7R6B HEAD, the clean Apple build and the independent read-only review remain NOT RUN; human Sam re-test and real-device field runs are NOT RUN and must never be reported as PASS.

# P7R6C stable-input snapshot and total JSON validator contracts

Last reconciled: 2026-08-05. This wave closes the total-function, token-cap, iOS package TOCTOU, PC session-input hash/parse decoupling and strict prior-map schema findings of the P7R6B review.

## Total strict JSON validator (C1)

`StrictJSONKeyUniquenessValidator.validate(_:line:maximumNestingDepth:)` is a **total function**: for any `Data` input it returns or throws a typed `StrictJSONValidationError` and never crashes, never reads out of bounds and never force-unwraps. Two layers run before any structural decision:

1. `validateStrictUTF8`: strict RFC 3629 over the whole document — rejects overlong encodings, UTF-8-encoded UTF-16 surrogates, scalars above U+10FFFF, invalid continuation bytes and truncated 2/3/4-byte sequences.
2. The structural scan iterates the raw bytes (`data.withUnsafeBytes`, no whole-file copy) with an explicit stack, decodes `\uXXXX` escapes with high/low surrogate pairing, and compares decoded keys per object so `{"a":1,"\u0061":2}` is a duplicate. It never indexes an empty stack: after the top-level value completes, trailing bytes are left for `JSONSerialization` to reject.

Stable errors carry byte offsets: `invalidUTF8`, `invalidStringEscape`, `invalidUnicodeEscape`, `unpairedHighSurrogate`, `unpairedLowSurrogate`, `scalarOutOfRange`, `duplicateKey(line:key:)`, `nestingTooDeep`, `malformedStructure`. The deterministic fuzz (10,000 random byte arrays, length 0–4096, U10/TJ9) may only observe return-or-throw.

## Byte-derived progress bound, no token cap (C2)

The old fixed 1,000,000-token cap is gone. The scanner enforces a **progress bound derived from the byte count**:

```text
maximumIterations = data.count * 4 + 1024
```

Every legal document advances the index or performs at most one transient push per iteration, so the bound is provably above any legal input and exists only to detect scanner bugs. `StrictJSONDocumentLimits.maximumBytes`/`maximumNestingDepth` drive the strict document parser; the whole-array tag file (16 MiB, 50,000 tags) is scanned and parsed without copying the `Data` (extra memory is `O(depth + key set)`, not `O(file size)`). The largest legal catalog that fits below 16 MiB finalizes cleanly; a 16 MiB + 1 byte file fails the frozen size limit; duplicate keys and numeric booleans are still detected in the last tag.

## Prior-map package immutable snapshot (C3)

A prior-map package is read exactly once into `PriorMapPackageSnapshot`; integrity validation, format checks, model decoding and previews all consume that same snapshot. Per artifact the descriptor-bound read (`SafeSessionPath.readRegularFile`: no-follow, regular file, `st_nlink == 1`, size bounded, pre/post identity) returns bytes that are simultaneously hashed and (for JSON) strictly parsed, so the returned package SHA can never describe bytes the loader never parsed.

```text
package_manifest.json <= 2 MiB
individual JSON       <= 64 MiB
preview image         <= 64 MiB
total package         <= 512 MiB
artifact count        <= 128
```

Directory identity is captured before and after the reads; symlinked/hard-linked artifacts, truncation, file-set changes, preview swaps, same-size self-consistent replacements and duplicate keys in the manifest/elements/validation report all fail closed.

## PC finalized-session input snapshot (C4)

`read_finalized_session_input_snapshot` reads metadata, the source database, all JSONL sidecars and `localized_price_tags.json` exactly once through descriptor-stable reads (`_stable_read_bytes`/`_read_jsonl_stable`), parses the same bytes, and derives the manifest identities from them. The bytes bound by `session_input_bundle_sha256` are therefore exactly the bytes localization/review/export consume; `build_session_input_manifest` stays as a re-verification path and the render before/after checks remain tamper gates. The source database is never opened by SQLite directly: a descriptor-verified immutable copy (Plan A) is created and verified against the snapshot identity, and SQLite only opens that copy. Metadata identity and the v1/v2/v3 version decision, including Recovery and ESL burst watermarks, come from one stable read.

## Prior-map strict JSON schema (C5)

All formal prior-map JSON documents go through the shared strict helpers (strict UTF-8, NaN rejection, `object_pairs_hook` duplicate rejection, iterative nesting depth). Integers, numbers, booleans, geometry coordinates and bounds are read with `StrictJSONScalar` on device, so fractional versions, boolean counts/bytes/visibility, boolean coordinates/bounds and duplicate or escaped-equivalent keys are rejected identically on both readers. `manifest.json` 的 element/visible/role/ignored/source/warning counts 与 `element_statistics`，以及 `validation_report.summary` 的 element/floor/node/edge/warning/malformed/role counts，都必须是严格 JSON integer；`warnings`/`malformed_rows` 必须是数组，count 必须与数组、manifest 和 `road_graph.json` 精确一致。legacy manifest v1 同样重新派生 `element_statistics` 和 visible/hidden counts，不能因历史版本放宽 token 类型。

## Status words

IMPLEMENTED, UNIT TESTED, INTEGRATION TESTED (C1/C2 U1-U10/TJ9/TJ10 and L1-L6 Swift host; C3 integrity-suite; C4 S1-S12 PC snapshot; C5 N1-N9 strict schema; shared Swift/PC fixtures). Exact-final-SHA CI on the P7R6C HEAD, the clean Apple build and the independent read-only review remain NOT RUN; human Sam re-test and real-device field runs are NOT RUN and must never be reported as PASS.
