# 已有地图辅助扫描数据格式

> 文档状态：**当前有效（版本 1）**。最后核对日期：2026-07-24。

## 会话元数据

为保持既有连续单库识别不变，两个概念分字段保存：

```json
{
  "scanMode": "continuous_streaming",
  "workflowMode": "free_mapping | prior_map_localized",
  "formatVersion": 1
}
```

`scanMode` 是存储布局标记，继续使用 `continuous_streaming`；不能改成业务模式，否则旧 PC 工具会把连续数据库误判为历史分段。`workflowMode` 是地图辅助扫描业务模式。旧会话缺少它时按 `free_mapping` 兼容，并由 PC 标记 `workflow_legacy=true`。

已有地图模式还包含：

```json
{
  "priorMapId": "mapcase01-0cf6949652d4",
  "priorMapSha256": "<64 hex>",
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
  "localizedPriceTagCount": 12
}
```

`floorId` 在会话开始时固定，当前版本没有扫描中楼层切换事件。二维 `rawPose/estimatedPose` 只表达所选楼层内的 `x/y/yaw`：ARKit `+x` 对应地图 `+x`，ARKit `-z` 对应地图 `+y`，地图 yaw 0 指向 `+y` 且逆时针为正。ARKit 竖直 `y` 不写入二维定位 sidecar，但仍由原始 ARKit/RTAB-Map 三维链路保存。

实时 `live_checkpoint.json` 同步记录业务模式和地图身份。正常结束后仍删除 checkpoint。

## localization_trace.jsonl

固定最多 2 Hz 追加，每行一个 `MarketScannerLocalizationTrace` version 1：

```json
{
  "timestamp": 123.4,
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

## 阶段二定位审计

- `localization_constraints.jsonl`：每个匹配周期的预测/估计、Top‑3、残差、唯一性、有效点数、角覆盖、耗时、接受标记和原因。
- `localization_events.jsonl`：状态发生变化时记录 previous/state/confidence/reason。
- `tag_observations.jsonl`：每次成功 Vision 识别的原始观测，即使用户取消最终保存也保留；包含条码、归一化框、捕获帧时间、`alignment_snapshot_timestamp`、真实 `pose_timestamp_delta_ms`、`alignment_version`、原始地图点、测量方式、三维/定位置信度、地图身份、楼层和 `needs_review`。地图点必须使用提交 Vision 时冻结的对齐快照计算。
- `localized_price_tags.json`：用户确认后的数组；包含 shelf code、row flag、cross code、货架侧面、沿货架起点距离、相对地面高度、raw/snapped 位置、定位/测量/关联三项置信度、测量方式、`needs_review` 和 `user_confirmed`。

JSONL 文件逐行独立编码和同步追加；最终价签数组用原子替换写入。写入前必须确认 tracking session ID 与活动会话一致且未进入 finalization，不允许日志接口自动创建新会话目录。价签 sidecar 与旧 `price_tags.json/.csv` 分开，后者继续只是暂停 NFC 功能的兼容空文件。

## manual_localization_events.jsonl

每次人工确认写 `MarketScannerManualLocalizationEvent` version 1，包含：

- ISO 时间和 Unix 时间；
- tracking session ID；
- 原因；
- 确认时 ARKit SE(2)；
- 用户确认的地图 SE(2)。

即使没有事件或扫码，正常 prior-map 会话也生成空 JSONL 和空最终价签数组，使 sidecar 清单稳定。

## 原始数据

上述 sidecar 不写入 SQLite，不作为外部 pose prior 注入 RTAB-Map。自动地图修正只改变先验地图 HUD 的 ARKit→地图对齐，不改写 ARKit、Node pose 或原始数据库。PC 离线处理继续复制数据库并在新输出目录优化。来源 hash 和参数分别保存在 prior-map manifest、会话 metadata 和现有 PC source manifest。
