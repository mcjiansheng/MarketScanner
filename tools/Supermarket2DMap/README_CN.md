# Supermarket2DMap 离线二维地图生成工具

`supermarket_2d_map.py` 根据 iOS 超市分段扫描结果生成二维地图交付包。它对应文档 `app/ios/SUPERMARKET_2D_MAP_ROADMAP_CN.md` 中的第一阶段到第二阶段实现：读取分段数据，解析 RTAB-Map 节点轨迹，融合可选结构点，输出二维占据图、轨迹、价签、矢量结构草图和质量报告。

## 输入

推荐输入目录：

```text
SupermarketSession-YYYYMMDD-HHMMSS/
  segment_0001/
    rtabmap_segment_0001.db
    metadata.json
    price_tags.json
    price_tags.csv
  segment_0002/
    rtabmap_segment_0002.db
    metadata.json
    price_tags.json
    price_tags.csv
```

工具会自动读取：

- `segment_*/metadata.json`
- `segment_*/price_tags.json`
- `segment_*/*.db` 中的 `Node.pose`
- `segment_*/points.csv`，如果存在
- session 根目录下的 `points.csv`，如果存在

`Node.pose` 是 RTAB-Map sqlite 数据库中的 12 个 `float` Transform blob。工具会解析节点平移和 yaw，默认使用 `x/z` 作为水平面坐标，以匹配当前 iOS 超市扫描面积估算逻辑。

## 可选 points.csv

如果已经有点云或局部网格导出的二维结构点，可以提供 `points.csv` 增强 occupied 结构层。

格式：

```csv
x,y,z,kind,segmentIndex,nodeId
0.0,0.0,1.2,occupied,1,10
0.5,0.0,0.0,free,1,10
```

字段说明：

- `x,y,z`：原始三维点坐标。
- `kind`：`occupied`、`free`、`ground`、`empty` 等。
- `segmentIndex`：所属分段。
- `nodeId`：可选，来源节点。

如果没有 `points.csv`，工具仍会基于节点轨迹生成可通行区域、价签图层和质量报告，但不会凭空生成货架/墙体结构。

## 运行

```bash
python3 tools/Supermarket2DMap/supermarket_2d_map.py \
  /path/to/SupermarketSession-20260606-120000 \
  --output /path/to/Map2D-output
```

常用参数：

```bash
--resolution 0.05
--trajectory-radius 1.25
--points-csv /path/to/points.csv
--corrections /path/to/corrections.json
--auto-align-segments
--horizontal-axes xz
```

## 单设备多阶段扫描

大型超市中，一台手机也建议按阶段扫描。`segment` 是手机端自动保存的数据单位，`stage` 是 PC 后处理时用于控制累积误差的路线/区域单位。一个 stage 可以包含多个 segment。

新增工具：

```bash
python3 tools/Supermarket2DMap/supermarket_staged_map.py \
  /path/to/SupermarketSession-20260606-120000 \
  --stage-config /path/to/stage_config.json \
  --output /path/to/StageMap2D-output
```

`stage_config.json` 示例：

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
      "transform": {"dx": 0.0, "dy": 0.0, "yaw_deg": 0.0}
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

输出会在普通 2D 地图包基础上增加：

- `stage_manifest.json`：stage、segment 和实际应用变换的映射。
- `stage_quality_report.json`：每个 stage 的节点数、轨迹长度、起终点距离、与前一 stage 的连接距离和警告。
- `alignment_config_used.json`：本次生成使用的 stage/segment 校正配置。

如果不提供 `--stage-config`，工具会默认每个 segment 一个 stage，第一个 stage 作为 anchor。该工具不会修改原始 RTAB-Map 数据库或 sidecar，只在输出地图包时应用校正。

## 多设备 PC 合并

在单设备 stage 流程稳定后，可以用 PC 端多设备工具合并多台手机的 session。多设备工具会先处理每台设备内部的 stage，再应用设备级变换，最后输出统一地图包。

直接传入多个 session：

```bash
python3 tools/Supermarket2DMap/supermarket_multi_device_map.py \
  /path/phone_a/SupermarketSession-20260606-090000 \
  /path/phone_b/SupermarketSession-20260606-090100 \
  --align-common-start \
  --output /path/to/MultiDeviceMap2D-output
```

使用配置文件：

```bash
python3 tools/Supermarket2DMap/supermarket_multi_device_map.py \
  --config /path/to/multi_device_config.json \
  --output /path/to/MultiDeviceMap2D-output
```

`multi_device_config.json` 示例：

```json
{
  "format": "SupermarketMultiDeviceConfig",
  "version": 1,
  "reference_device": "phone_a",
  "align_common_start": true,
  "devices": [
    {
      "id": "phone_a",
      "session": "sessions/phone_a/SupermarketSession-20260606-090000",
      "stage_config": "configs/phone_a_stage_config.json",
      "points_csv": "points/phone_a_points.csv",
      "transform": {"dx": 0.0, "dy": 0.0, "yaw_deg": 0.0}
    },
    {
      "id": "phone_b",
      "session": "sessions/phone_b/SupermarketSession-20260606-090100",
      "stage_config": "configs/phone_b_stage_config.json"
    }
  ]
}
```

如果设备配置中提供了 `transform`，工具会使用该手动设备级变换；否则在 `--align-common-start` 或配置中的 `align_common_start=true` 开启时，会把该设备第一个有效 pose 对齐到参考设备第一个有效 pose。该自动对齐只适合作为公共起点初值，最终仍应查看 `preview.png`、`multi_device_manifest.json` 和 `quality_report.json` 后人工微调。

设备配置中的 `points_csv` 会随该设备的 stage 和 device transform 一起变换。命令行 `--points-csv` 则表示已经位于全局 `map_2d` 坐标系的额外结构点，不会再套用某台设备的变换。

多设备输出会额外包含：

- `multi_device_manifest.json`：设备、session、设备级变换、全局 segment id 与本地 segment 的映射。
- `alignment_config_used.json`：本次使用的设备级配置。

## 输出

```text
Map2D-YYYYMMDD-HHMMSS/
  map.json
  source_manifest.json
  occupancy_grid.png
  occupancy_grid.yaml
  preview.png
  vector_map.geojson
  semantic_layers.json
  price_tags.geojson
  trajectory.geojson
  quality_report.json
  review_items.json
```

输出说明：

- `occupancy_grid.png`：二维占据栅格。灰色未知，白色可通行，黑色占据，红色冲突。
- `preview.png`：占据栅格叠加蓝色轨迹和绿色价签。
- `trajectory.geojson`：每个 segment 的扫描轨迹。
- `price_tags.geojson`：价签位置和置信度。
- `vector_map.geojson`：从 occupied 栅格提取的结构组件草图。
- `semantic_layers.json`：occupied/free/unknown/conflict 面积统计。
- `quality_report.json`：节点数、价签数、冲突比例、警告和待检查项。
- `source_manifest.json`：输入文件 hash，保证可追溯。

## 人工校正

可以通过 `corrections.json` 对 segment 做平移和旋转校正。

```json
{
  "segment_transforms": {
    "2": {
      "dx": 1.2,
      "dy": -0.4,
      "yaw_deg": 3.0
    }
  }
}
```

工具不会修改原始扫描数据，只在生成地图包时应用校正。这样同一批原始数据可以用不同校正文件重复生成和比较。

## 当前实现边界

当前工具已经实现：

- RTAB-Map `Node.pose` 轨迹解析。
- 多 segment 地图包生成。
- 轨迹 free-space 栅格化。
- 可选 projected points 占据融合。
- 价签读取、吸附和 GeoJSON 输出。
- 冲突/未知/可通行/占据统计。
- 输入文件 hash 和质量报告。

当前工具暂未直接解压 RTAB-Map `Data.ground_cells / obstacle_cells / empty_cells` blob。脚本会检测到这些 blob 并在质量报告中提示。后续可以新增一个 C++/RTAB-Map 提取器，将局部 grid 或点云导出为 `points.csv`，再由本工具完成统一地图生成。
