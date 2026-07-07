# 单设备多阶段 PC 后处理设计文档

日期：2026-07-07

## 一、设计目标

在不改动现有 iOS 扫描代码的前提下，新增 PC 端 stage-aware 后处理能力：

- 用配置文件把 segments 分组为 stages。
- 对 stage 应用二维刚体变换。
- 对 segment 应用局部微调。
- 输出 stage 质量报告。
- 调用现有 2D 地图生成逻辑输出校正后的地图包。

## 二、工具设计

新增工具：

```text
tools/Supermarket2DMap/supermarket_staged_map.py
```

职责：

- 读取单个 `SupermarketSession-*`。
- 读取 `stage_config.json`。
- 发现 segments。
- 分配 stage id。
- 应用 stage transform。
- 应用 segment transform。
- 输出地图和报告。

## 三、Stage 配置格式

```json
{
  "format": "SupermarketStageConfig",
  "version": 1,
  "stages": [
    {
      "id": "anchor",
      "name": "入口锚定区",
      "segments": [1],
      "role": "anchor",
      "transform": {"dx": 0, "dy": 0, "yaw_deg": 0}
    },
    {
      "id": "aisle_a",
      "name": "A 区主通道",
      "segments": [2, 3],
      "transform": {"dx": 0.2, "dy": -0.1, "yaw_deg": 1.0}
    }
  ],
  "segment_transforms": {
    "3": {"dx": 0.1, "dy": 0.0, "yaw_deg": -0.3}
  }
}
```

### 1. Stage transform

作用于该 stage 内所有 segment。

### 2. Segment transform

作用于单个 segment，并在 stage transform 之前应用：

```text
map_point = T_stage * T_segment * local_point
```

### 3. 默认配置

如果不提供 config：

- 每个 segment 自动成为一个 stage。
- 第一个 stage 角色为 anchor。
- 所有 transform 为 0。

## 四、输出设计

输出目录：

```text
StageMap2D-YYYYMMDD-HHMMSS/
  map.json
  stage_manifest.json
  stage_quality_report.json
  alignment_config_used.json
  occupancy_grid.png
  occupancy_grid.yaml
  preview.png
  trajectory.geojson
  price_tags.geojson
  vector_map.geojson
  semantic_layers.json
  quality_report.json
  review_items.json
  source_manifest.json
```

## 五、质量指标

### 1. Stage 内指标

- `segment_count`
- `node_count`
- `price_tag_count`
- `trajectory_length_m`
- `start_xy`
- `end_xy`
- `end_to_start_distance_m`
- `is_anchor`

### 2. Stage 间指标

- 当前 stage 起点到前一 stage 终点的距离。
- 当前 stage transform。
- 修正 yaw 是否过大。
- 修正平移是否过大。

### 3. 警告规则

第一版规则：

- stage 无有效 pose。
- stage transform yaw 超过 10 度。
- stage transform 平移超过 5 米。
- segment transform yaw 超过 5 度。
- segment transform 平移超过 2 米。
- stage 与前一 stage 连接距离超过 5 米。
- 没有结构点，只能生成覆盖图。

这些阈值不是最终算法判断，只是提示人工复核。

## 六、算法流程

```text
parse_args
  -> load_stage_config
  -> discover_segments(session)
  -> load points.csv
  -> assign stages
  -> apply segment transform
  -> apply stage transform
  -> generate grid / geojson / map package
  -> write stage_manifest
  -> write stage_quality_report
```

## 七、与现有 supermarket_2d_map.py 的关系

复用现有模块：

- SQLite pose 解析。
- price tag 读取。
- points.csv 读取。
- 占据栅格构建。
- PNG/GeoJSON/YAML/质量报告输出。

新增 stage 层只负责组织和变换，不重复实现底层地图生成逻辑。

## 八、后续扩展

### 1. Checkpoint 支持

配置中加入：

```json
"checkpoints": [
  {
    "id": "pillar_01",
    "stage": "aisle_a",
    "segment": 3,
    "xy": [12.3, 4.5],
    "type": "manual"
  }
]
```

### 2. Stage 间自动配准

基于结构点或局部 grid：

- 搜索相邻 stage 重叠区域。
- 输出候选 transform。
- 置信度低则只提示。

### 3. Stage 图优化

把 stage 作为节点，连续性、重叠、checkpoint 作为边，优化 stage transform。

### 4. 多设备扩展

在 stage 层之上增加 device 层：

```text
map_point = T_device * T_stage * T_segment * local_point
```
