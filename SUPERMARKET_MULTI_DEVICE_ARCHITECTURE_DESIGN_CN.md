# 多设备大型超市扫描架构与设计文档

日期：2026-07-07

## 一、总体架构

多设备方案采用“手机端独立采集、PC 端统一后处理”的离线架构。

```text
多台 iPhone
  -> 各自 SupermarketSession
  -> 外部存储或文件传输
  -> PC 多设备导入
  -> 设备级对齐
  -> segment 级微调
  -> 结构地图生成
  -> 质量报告和人工复核
```

### 1. 手机端职责

手机端继续沿用当前代码：

- `ViewController.rolloverCurrentSegment(...)` 负责分段保存。
- `SupermarketScanSession` 负责 session、segment、价签、轨迹和覆盖 sidecar。
- `PriceTagNFCReader` 负责 NDEF 价签读取。
- 手机端 `Generate 2D Map Package` 只作为快速覆盖预览。

手机端不参与多设备全局坐标融合。

### 2. PC 端职责

PC 端新增多设备后处理工具：

```text
tools/Supermarket2DMap/supermarket_multi_device_map.py
```

第一版负责：

- 读取多个 session。
- 发现每个 session 的 segments。
- 解析每个 segment 的 RTAB-Map `Node.pose`。
- 读取价签和可选结构点。
- 为所有 segment 分配全局 id。
- 设备级对齐。
- segment 级修正。
- 输出统一地图包和质量报告。

后续可扩展为完整 pipeline：

- 数据校验。
- 局部 grid / 点云提取。
- 公共锚点识别。
- 自动配准。
- 鲁棒图优化。
- 结构线提取。
- 高质量 2D map。

## 二、坐标系统设计

### 1. 坐标层级

系统中存在四层坐标：

```text
device_local
  每台手机自己的 ARKit / RTAB-Map 坐标系。

session_local
  每台设备的 SupermarketSession 坐标系，通常等同 device_local。

segment_local
  每个 segment 中的局部节点和 sidecar 坐标。

map_2d
  PC 端统一输出的二维地图坐标系。
```

第一版只处理二维自由度：

```text
x, y, yaw
```

默认沿用现有 iOS 超市扫描约定：

```text
RTAB-Map x/z -> map_2d x/y
```

不优化 `z/roll/pitch`，因为目标是单层二维平面地图。

### 2. 设备级变换

每台设备一个变换：

```text
T_map_device = [dx, dy, yaw]
```

来源优先级：

1. 配置文件显式指定 `transform`。
2. 配置文件指定 anchor source/target。
3. `--align-common-start` 自动将设备第一个有效 pose 对齐到参考设备第一个有效 pose。
4. 默认零变换。

### 3. Segment 级变换

每个 segment 可再叠加微调：

```text
T_device_segment = [dx, dy, yaw]
```

配置 key 使用：

```text
device_id:local_segment_index
```

例如：

```json
"phone_b:3": {"dx": 0.3, "dy": -0.1, "yaw_deg": 1.2}
```

最终点位变换：

```text
map_point = T_map_device * T_device_segment * local_point
```

第一版采用二维刚体变换，不做尺度变换。ARKit/RTAB-Map 的米制尺度通常足够稳定，错误更多来自 yaw 漂移和局部错位。

## 三、共同起点设计

### 1. 共同起点的意义

多台手机不能自然共享坐标系。共同起点用于建立初始对齐：

- 统一朝向。
- 统一原点。
- 给后续自动配准提供初值。

### 2. 现场要求

公共起点区域应满足：

- 结构稳定。
- 可被所有设备扫描。
- 有足够特征。
- 最好包含人工锚点。
- 不被顾客频繁遮挡。

推荐：

- 入口附近固定墙角。
- 柱子。
- 服务台。
- 收银区固定边界。
- 临时放置的标记板。

### 3. 第一版对齐方式

第一版支持两种方式：

```text
自动共同起点：
  将每台设备第一个有效 pose 对齐到参考设备第一个有效 pose。

手动配置：
  在 JSON 中设置每台设备的 dx/dy/yaw。
```

自动共同起点只是初值，不保证最终精确。质量报告必须提示人工复核。

## 四、数据模型

### 1. DeviceSession

```text
device_id
session_dir
local_segments
device_transform
alignment_mode
warnings
```

### 2. GlobalSegment

```text
global_segment_id
device_id
local_segment_index
source_segment_dir
database_path
poses
price_tags
metadata
segment_transform
```

### 3. MultiDeviceMapPackage

```text
format = SupermarketMultiDeviceMap2D
version = 1
devices[]
segments[]
coordinate_frame
outputs[]
quality_report
```

## 五、算法流程

### 1. 输入解析

```text
读取 config
  -> 解析 devices
  -> 解析每个 session
  -> discover_segments()
  -> 读取 price_tags
  -> 读取 points.csv
```

复用现有 `supermarket_2d_map.py` 中的：

- `discover_segments`
- `load_projected_points`
- `transform_point`
- `build_grid`
- `render_grid`
- `trajectory_geojson`
- `price_tags_geojson`
- `quality_report`

### 2. Global segment 重编号

多设备 segment 重编号规则：

```text
global_segment_id = 按输入设备顺序和 local segment 顺序递增
```

输出 manifest 保留映射关系。

### 3. 设备对齐

结构点输入分两类：

- 设备本地 `points_csv`：在设备配置中声明，会先应用该设备内部的 stage/segment 校正，再应用 device transform。
- 全局 `--points-csv`：命令行传入，表示已经位于最终 `map_2d` 坐标系，不再套用某台设备的变换。

```text
for each device:
  if config transform:
    use transform
  else if anchor source/target:
    compute transform
  else if align_common_start:
    align first pose to reference first pose
  else:
    identity
```

### 4. Segment 微调

```text
for each global segment:
  read transform by "device_id:local_segment_index"
  apply before device transform
```

### 5. 地图生成

将所有变换后的 segment 合并到统一列表：

```text
segments[]
points[]
price_tags[]
```

再调用现有 grid/geojson/render/report 能力输出统一包。

## 六、人工微调设计

### 1. 配置文件

配置文件是后处理的核心控制面：

```json
{
  "format": "SupermarketMultiDeviceConfig",
  "version": 1,
  "reference_device": "phone_a",
  "devices": [
    {
      "id": "phone_a",
      "session": "sessions/phone_a/SupermarketSession-...",
      "points_csv": "points/phone_a_points.csv",
      "transform": {"dx": 0, "dy": 0, "yaw_deg": 0}
    },
    {
      "id": "phone_b",
      "session": "sessions/phone_b/SupermarketSession-...",
      "transform": {"dx": 2.1, "dy": -0.4, "yaw_deg": 1.5}
    }
  ],
  "segment_transforms": {
    "phone_b:2": {"dx": 0.2, "dy": 0.1, "yaw_deg": -0.8}
  }
}
```

### 2. 复核闭环

```text
生成 preview
  -> 查看轨迹颜色和冲突区域
  -> 修改 config
  -> 重跑工具
  -> 对比 quality_report
```

所有修改可追溯，不改原始数据。

## 七、质量控制

第一版报告包括：

- 每台设备 session 路径。
- 每台设备 segment 数量。
- 每台设备节点数。
- 每台设备价签数。
- 设备级 transform。
- segment 级 transform。
- 是否使用共同起点自动对齐。
- 缺失数据库警告。
- 没有结构点警告。
- 占据图冲突比例。

后续增强：

- 公共锚定区域残差。
- 段间重叠评分。
- 结构线一致性。
- 价签吸附置信度。
- 人工锚点误差。

## 八、与 RTAB-Map 技术的关系

当前设计继续使用 RTAB-Map 作为：

- 移动端实时建图和数据记录核心。
- 节点 pose、图像、深度、局部网格的数据来源。
- 可选 PC 端数据库合并工具来源。

但最终多设备地图生成不直接依赖 RTAB-Map 原生 2D/3D 导出作为唯一结果，而是把 RTAB-Map 数据库作为原始证据输入，建立可解释、可校正、可重跑的后处理管线。

这是因为大型超市环境中：

- 重复货架容易产生错误回环。
- 多设备坐标系不同。
- 手机端全量 mesh 开销过大。
- 最终业务地图需要质量报告和人工可控修正。

## 九、阶段性实现

### 阶段 1：多设备基础合并

- 多 session 输入。
- 共同起点对齐。
- 设备级 transform。
- segment 级 transform。
- 统一 2D 地图包。
- 质量报告。

### 阶段 2：结构点和真实 occupied layer

- 导出 RTAB-Map 局部 grid 或点云。
- 高度过滤。
- occupied/free 融合。
- 冲突图层。

### 阶段 3：自动配准

- 公共区域匹配。
- ICP/NDT/栅格相关。
- 结构线约束。
- 鲁棒图优化。

### 阶段 4：人工校正工具

- 可视化多设备轨迹。
- 拖动设备/segment。
- 添加点对和线约束。
- 生成 config。

### 阶段 5：最终地图产品化

- 高质量无毛刺 2D 平面图。
- 矢量货架/通道图层。
- 价签吸附和置信度。
- 可选 tiled 3D 模型。
