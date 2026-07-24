# 先验地图格式与坐标证据

> 文档状态：**当前有效（格式版本 1）**。最后核对日期：2026-07-24。

## 输入

输入为含 `Element Info` 工作表的 `.xlsx`。第一行必须包含：

```text
floor | element
```

`element` 是 JSON 对象。版本 1 支持：

- `MapShelf`
- `MapTable`
- `MapPillar`
- `MapTableFeature`
- `MapCross`
- `MapRoadPoint`

未知类型保留完整 `source` 对象并产生 warning。损坏 JSON 记录到 `validation_report.json.malformed_rows`；`visible=false` 元素保留，但不进入默认定位空间索引。

## 几何语义证据

2026-07-24 使用用户提供的 `mapcase01.xlsx`（SHA-256 `0cf6949652d4d9e848cb9bbf5669dc474974557283283c55c6685475d5744906`）和对应截图核对：

- 柱子从 `(x=1, y=2)` 开始，并沿截图上边界约每 1200 cm 排列，证明 `x/y` 是源画布左上角坐标而不是元素中心。
- `MapCross.points` 与截图道路中心线端点直接一致。
- `MapRoadPoint.x/y` 与所属 `MapCross` 的中心线坐标一致，按点处理。
- 矩形的 `x/y/width/height` 先确定未旋转外框，再绕矩形中心应用顺时针 `rotation`；对 90°、180°、270° 样例渲染后，位置、方向和比例与截图一致。

自动测试覆盖 90° 矩形、坐标轴翻转、厘米/米、bounds 和确定性预览。

## 权威坐标转换

源坐标：

- 单位：厘米；
- 原点：左上；
- `+x`：向右；
- `+y`：向下；
- rotation：顺时针角度。

内部坐标：

- 单位：米；
- 原点：源原点；
- `+x`：向右；
- `+y`：向上；
- yaw：逆时针弧度。

```text
x_m = x_cm / 100
y_m = -y_cm / 100
yaw_rad = -rotation_deg * π / 180
```

PC 实现位于 `coordinate_system.py`。iOS 解码已经规范化的米制 polygon 和 road graph，不重复解释 Excel 坐标。

## 地图包

```text
PriorMap-<id>/
  manifest.json
  elements.json
  shelves.json
  fixed_structures.json
  road_graph.json
  spatial_index.json
  preview.png
  validation_report.json
```

`prior_map_id` 为安全文件名化的源文件 stem 加源 SHA-256 前 12 位。所有 JSON 使用 UTF-8、排序 key 和稳定缩进；不写入当前时间，因此相同输入和参数产生逐字节相同输出。

`manifest.json` 记录：

- `format = MarketScannerPriorMap`
- `version = 1`
- 源文件名与 SHA-256
- 源/内部坐标系
- 楼层及每层 bounds
- 全图 bounds
- 元素统计、隐藏数和 warning 数

`elements.json` 保存所有可解析行；业务字段 `code/cross_code/row_flag/subsection/visible/locked` 独立保留，完整原始 JSON 位于 `source`。

`road_graph.json`：

- `MapRoadPoint` 为节点；
- 每个 `crossCodes` 指向一条 `MapCross`；
- 同一路上的节点按线段投影顺序连接；
- 字符串/数字 ID 统一转为字符串；
- 重复 ID 获得稳定后缀，不丢节点；
- 缺失道路、零长度边和孤立点进入 warning/statistics。

`spatial_index.json` 使用每层 5 m 网格索引可见货架、柱子、柜台和柜台特征。查询只访问覆盖半径内网格，不在每帧遍历全部结构。

## 命令

```bash
python3 tools/PriorMap/xlsx_to_prior_map.py input.xlsx --output /path/to/PriorMap-output
python3 tools/PriorMap/validate_prior_map.py /path/to/PriorMap-output
python3 tools/PriorMap/render_prior_map.py /path/to/PriorMap-output --floor 1
```
