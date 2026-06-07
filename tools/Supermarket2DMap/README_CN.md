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
