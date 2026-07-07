# 多设备大型超市扫描需求文档

日期：2026-07-07

## 一、背景

单台 iPhone Pro 扫描 3000 平方米以上大型超市时，现场时间成本过高，且长时间连续扫描会带来明显的内存、存储、发热、外部复制、分段数量和累计误差压力。为提高现场效率，需要支持多台手机同时扫描不同区域，最终在 PC 或服务器上统一合并、校正并生成高质量二维平面地图。

当前仓库已经具备以下基础：

- iOS 端分段保存 RTAB-Map 数据库。
- NFC 价签与当前位姿绑定。
- 分段 sidecar 输出：`metadata.json`、`price_tags.json/csv`、`scan_area_cells.json`、`trajectory_samples.json/csv`。
- 外部存储后台复制。
- 手机端轻量 2D 覆盖预览。
- PC 端 `tools/Supermarket2DMap/supermarket_2d_map.py` 可读取单个 session 并生成 2D 地图包。

本阶段目标是在此基础上扩展为多设备并行扫描流程。

## 二、目标

### 1. 多设备并行采集

系统应支持多台 iPhone Pro 同时扫描大型超市：

- 每台设备独立创建自己的 `SupermarketSession-*`。
- 每台设备仍按面积、数据库大小、内存增长自动分段。
- 每台设备输出完整 segment 数据包。
- 每台设备可独立读取 NFC 价签。
- 扫描结束后，所有设备的数据导入同一 PC/服务器后处理工程。

### 2. 统一起点和共同锚定

由于多台手机的 ARKit/RTAB-Map 坐标系天然不同，不能依赖手机传感器自动保证多设备全局一致。现场需要设置统一起点或公共锚定阶段。

第一版要求：

- 所有设备在扫描前共同扫描同一固定位置或公共起点区域。
- 公共区域应有稳定结构，例如入口、柱子、收银台、固定货架端点、人工标记板。
- PC 端根据公共起点或人工配置，将每台设备 session 转换到统一 `map_2d` 坐标系。

后续增强：

- 支持 AprilTag / ArUco / QR / NFC 锚点。
- 支持公共区域点云或局部栅格自动配准。
- 支持人工对应点和线约束。

### 3. 多阶段扫描

推荐现场流程分为两类阶段：

```text
阶段 0：公共锚定阶段
  所有设备依次或同时扫描同一公共区域，用于建立共同坐标参考。

阶段 1-N：区域延伸阶段
  各设备从公共区域或已知锚点出发，分别扫描不同通道/区域。
```

PC 端处理时，先对齐各设备公共锚定阶段，再合并各设备后续延伸段。

### 4. PC/服务器统一后处理

手机端不负责大型全量合并和最终建模。PC/服务器端应负责：

- 导入所有设备 session。
- 校验所有 segment 文件完整性。
- 读取各设备轨迹、价签、覆盖格、RTAB-Map pose。
- 对每台设备估计初始设备级变换。
- 对每个 segment 估计或读取 segment 级微调变换。
- 输出统一 2D 地图包。
- 输出质量报告和待人工复核项。
- 支持人工修改校正配置并重复生成。

### 5. 最终二维平面地图

最终目标是基于完整合并结果生成高质量、无明显毛刺、可解释的二维平面地图。当前不考虑：

- 多楼层。
- 大型海拔差异。
- 楼梯和坡道。
- 商品级 3D 建模。

二维地图应包含：

- 墙体、货架、柜台、柱子等结构边界。
- 可通行区域。
- 未扫描区域。
- 冲突区域。
- 价签点及其置信度。
- 扫描轨迹和数据来源。
- 质量报告。

## 三、非目标

第一版不要求：

- 多设备实时在线协同建图。
- 手机之间实时共享地图。
- 完全自动、无需人工检查的最终地图。
- 在手机端生成 3000 平米全量高质量 mesh。
- 在手机端完成多设备全局配准。
- 一次性输出单个巨大 3D OBJ。

## 四、核心用户流程

### 1. 现场准备

- 确定公共锚定区域。
- 放置或确认稳定锚点。
- 给每台设备分配 `device_id`。
- 每台设备选择外部保存位置。
- 约定扫描区域和重叠边界。

### 2. 公共锚定阶段

- 每台设备扫描同一公共区域。
- 保持低速移动。
- 至少包含 5 到 10 米有效轨迹或一个小闭环。
- 如果使用人工标记，确保每台设备都能看到。

### 3. 区域延伸阶段

- 每台设备从锚定区或已扫描重叠区进入各自区域。
- 每段保持合理重叠。
- 通道端头和区域交界尽量互扫。
- 避免在 tracking 不稳定时快速移动。

### 4. 数据导入

- 把所有 `SupermarketSession-*` 导入 PC。
- 生成多设备配置文件。
- 指定每台设备的 `device_id`、session 路径和初始对齐方式。

### 5. PC 合并与微调

- 先用共同起点做设备级对齐。
- 生成初始统一地图。
- 查看质量报告和冲突区域。
- 在配置中调整设备级或 segment 级变换。
- 反复生成，直到质量满足验收。

## 五、功能需求

### 1. 多设备输入

工具应支持：

- 多个 session 路径作为输入。
- JSON 配置描述设备。
- 每个设备一个 `device_id`。
- 每个设备独立 session 根目录。
- 支持相对路径和绝对路径。

### 2. 坐标对齐

第一版支持：

- 第一个设备作为参考坐标系。
- 其他设备按第一个有效 pose 自动对齐到参考设备第一个有效 pose。
- 支持通过 JSON 指定设备级 `dx/dy/yaw`。
- 支持通过 JSON 指定 segment 级微调。

后续支持：

- 锚点点对约束。
- 线约束。
- 自动公共区域配准。
- 图优化。

### 3. 全局 segment 重编号

多设备都会有 `segment_0001`，合并时必须避免 segment id 冲突。

工具应输出：

```text
global_segment_id
device_id
local_segment_index
source_session
source_segment_dir
```

### 4. 地图生成

第一版输出统一覆盖/结构地图包：

- 轨迹。
- 价签。
- 可选结构点。
- 占据栅格。
- GeoJSON。
- 质量报告。

若没有结构点，输出必须明确说明：地图主要来自轨迹覆盖，不是最终货架/墙体结构图。

### 5. 人工微调

工具必须支持配置文件反复重跑：

```json
{
  "devices": [
    {
      "id": "phone_a",
      "session": "/path/to/session_a",
      "transform": {"dx": 0, "dy": 0, "yaw_deg": 0}
    }
  ],
  "segment_transforms": {
    "phone_b:2": {"dx": 0.4, "dy": -0.2, "yaw_deg": 1.5}
  }
}
```

原始数据不能被修改，所有微调只体现在输出包和配置文件中。

### 6. 质量报告

质量报告至少包括：

- 设备数量。
- segment 数量。
- 每台设备节点数。
- 每台设备价签数。
- 每台设备初始变换。
- segment 级变换。
- 缺失数据库或 sidecar 警告。
- 没有结构点的警告。
- 多设备锚定方式说明。
- 冲突栅格比例。
- 待人工复核项。

## 六、性能需求

### 1. 手机端

手机端只负责：

- 当前 segment 实时建图/记录。
- segment 数据库落盘。
- sidecar 输出。
- 外部复制。
- 轻量覆盖预览。

手机端不应默认执行：

- 多设备合并。
- 全量 session 合并。
- 全量 Poisson mesh。
- 全量 texture mesh。

### 2. PC 端

PC 端处理应支持：

- 几十个 segment。
- 多个设备 session。
- 分阶段缓存中间产物。
- 可中断、可重跑。
- 输出清晰错误报告。

第一版 Python 工具可使用标准库完成基础合并；后续高质量点云/局部栅格提取可引入 C++ RTAB-Map 工具或专门点云库。

## 七、数据需求

推荐多设备工程目录：

```text
MultiDeviceSupermarketProject/
  multi_device_config.json
  sessions/
    phone_a/SupermarketSession-...
    phone_b/SupermarketSession-...
  output/
    MultiDeviceMap-YYYYMMDD-HHMMSS/
```

输出包：

```text
MultiDeviceMap-YYYYMMDD-HHMMSS/
  map.json
  source_manifest.json
  multi_device_manifest.json
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
```

## 八、验收需求

第一版验收标准：

- 能读取两个以上设备 session。
- 能自动给所有 segment 生成唯一 global segment id。
- 能用共同起点对齐多个设备。
- 能通过 JSON 微调设备级和 segment 级变换。
- 能输出统一地图包。
- 能输出质量报告和待复核项。
- 不修改原始 session 数据。

后续验收标准：

- 支持公共区域自动配准。
- 支持人工锚点约束。
- 支持结构点/局部栅格真实 occupied layer。
- 支持段间冲突可视化。
- 支持最终高质量二维地图回归测试。
