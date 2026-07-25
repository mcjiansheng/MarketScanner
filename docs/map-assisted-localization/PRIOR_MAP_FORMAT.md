# 先验地图格式与坐标证据

> 文档状态：**当前有效（格式版本 1）**。最后核对日期：2026-07-25。

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
  package_manifest.json
  manifest.json
  elements.json
  shelves.json
  fixed_structures.json
  road_graph.json
  spatial_index.json
  distance_fields.json
  preview.png
  preview_floor_001_<floor>.png
  ...
  validation_report.json
```

`prior_map_id` 为安全文件名化的源文件 stem 加源 SHA-256 前 12 位。所有 JSON 使用 UTF-8 和排序 key；距离场为控制手机包体采用稳定紧凑 JSON，其余文件采用稳定缩进。不写入当前时间，因此相同输入和参数产生逐字节相同输出。

`package_manifest.json` 是手机和 PC 共用的规范完整性入口，精确列出包内每个权威文件的文件名、字节数、SHA‑256、媒体类型以及 JSON 格式/版本，并记录规范化 `package_sha256`。清单不自哈希；包 hash 按清单顺序对 `file/bytes/sha256/format/version` 计算。iOS 在显示“完整性通过”前必须完成全部摘要和下述跨文件关系校验。

`manifest.json` 记录：

- `format = MarketScannerPriorMap`
- `version = 1`
- 源文件名与 SHA-256
- 源/内部坐标系
- 楼层、每层 bounds 和对应 `preview_file`
- `localization_scope.floor_mode = single_floor_per_scan`
- `localization_scope.cross_floor_switching = false`
- `localization_scope.vertical_motion = ignored_in_prior_map_2d_preserved_in_raw_3d`
- 全图 bounds
- 元素统计、隐藏数和 warning 数

`elements.json` 保存所有可解析行；业务字段 `code/cross_code/row_flag/subsection/visible/locked` 独立保留，完整原始 JSON 位于 `source`。

`road_graph.json`：

- `MapRoadPoint` 为节点；
- 每个 `crossCodes` 指向一条 `MapCross`；
- 同一路上的节点按完整折线的最近投影弧长排序连接，不能用首尾弦替代弯折道路；
- 字符串/数字 ID 统一转为字符串；
- 重复 ID 获得稳定后缀，不丢节点；
- 缺失道路、零长度边和孤立点进入 warning/statistics。

`spatial_index.json` 使用每层 5 m 网格：`cells` 索引可见货架、柱子、柜台和柜台特征，`road_cells` 索引道路边。iOS 查询只访问当前位置候选半径覆盖的网格，不在每次更新遍历全部道路。

`distance_fields.json` 为每层保存 0.40/0.20/0.10 m 三层截断距离场。可见货架、柱子、柜台和柜台特征的 polygon 边界为零距离种子，距离在 2 m 截断并量化为无符号厘米；每行使用 `[run_length, value]` RLE。每层记录 canonical rows 的 SHA‑256，PC schema 和 iOS 导入都完整解码并核验。用户样例两层包的紧凑距离场为 5,547,756 bytes；该数值是包体基线，不是设备内存峰值。

校验器不只检查文件存在：它解析全部 JSON 和 PNG，核对格式/版本、SHA-256、元素与楼层 bounds、子集内容、道路节点/边引用、结构/道路索引覆盖及验证报告统计。每层独立预览必须可解码；`preview.png` 是首层兼容预览。

## 结构关联边语义

- `MapShelf` 使用源 `width/height/yaw_rad` 定义稳定局部长轴；即使正方形、近正方形、polygon 起点旋转或环方向反转，仍只产生相对局部长轴法向稳定的 `A/B` 两个业务面。
- `A` 是局部长轴正方向左侧的面，`B` 是右侧；offset 起点沿局部长轴正方向固定。
- `MapTable/MapTableFeature` 允许所有可见边参与关联，按稳定几何顺序使用 `E01/E02/...`，不强制解释成两个长边。
- `MapPillar` 仅作为遮挡/结构证据，不是价签关联面。

## 单楼层定位边界

地图包可以包含多个楼层，但每次扫描必须在开始前选择并绑定一个楼层。当前阶段不允许扫描中切层或跨楼层匹配。地图二维位姿只使用水平运动：ARKit `+x -> 地图 +x`、ARKit `-z -> 地图 +y`，地图 yaw 0 指向 `+y`、正方向逆时针。ARKit 竖直 `y` 不进入二维位姿，因此同一楼层内少量坡度或高度变化可以存在；这些变化仍保存在原始三维采集数据中，并可用于同层价签相对地面的高度估计。

## 命令

```bash
python3 tools/PriorMap/xlsx_to_prior_map.py input.xlsx --output /path/to/PriorMap-output
python3 tools/PriorMap/validate_prior_map.py /path/to/PriorMap-output
python3 tools/PriorMap/render_prior_map.py /path/to/PriorMap-output --floor 1
```
