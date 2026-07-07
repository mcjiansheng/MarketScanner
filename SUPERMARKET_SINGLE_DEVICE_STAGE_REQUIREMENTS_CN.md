# 单设备多阶段大型超市扫描需求与误差控制文档

日期：2026-07-07

## 一、背景

在大型超市中，即使只使用一台 iPhone Pro 扫描，也不应把整个 3000 平方米场景理解为一次连续、无边界的扫描任务。连续扫描时间越长，越容易出现：

- ARKit / VIO 累计 yaw 漂移。
- 长直通道局部弯曲。
- 重复货架造成错误回环。
- 分段边界处弱约束。
- 保存暂停期间姿态变化。
- 单个 session 内后续区域相对早期区域逐渐偏移。

当前代码已经通过 segment 自动保存解决了一部分性能和存储压力，但 segment 只是存储单位，不等于业务上的扫描阶段。为了控制大型超市的累积误差，需要引入“stage”概念。

```text
segment = 存储和恢复单位
stage   = 扫描路线和误差控制单位
```

一个 stage 可以包含一个或多个 segment。

## 二、目标

### 1. 单设备多阶段扫描

支持一台手机按阶段扫描大型超市：

```text
Stage 0：公共锚定 / 起点小闭环
Stage 1：主通道 A
Stage 2：货架通道组 A
Stage 3：货架通道组 B
Stage 4：收银/冷柜区域
...
```

每个 stage 内部尽量形成局部闭环或局部重叠，每个 stage 与前一 stage 保留重叠区域。

### 2. 累积误差分段控制

PC 后处理应允许对 stage 级别做校正：

- stage 级 `dx/dy/yaw`。
- segment 级微调。
- 人工锚点约束。
- 回访点约束。
- 重叠区域质量检查。

这样可以避免只靠一次全局合并处理所有误差。

### 3. 与现有代码兼容

不要求 iOS 端立即新增复杂 UI。第一版可以通过 PC 端配置文件把 segment 分组为 stage。

现有输出保持：

```text
SupermarketSession-*/
  segment_0001/
  segment_0002/
  ...
```

新增 PC 配置：

```text
stage_config.json
```

## 三、术语

### 1. Segment

由当前 iOS 代码自动/手动保存生成：

- `rtabmap_segment_xxxx.db`
- `metadata.json`
- `price_tags.json/csv`
- `scan_area_cells.json`
- `trajectory_samples.json/csv`

segment 主要用于控制手机端内存、数据库大小和外部导出。

### 2. Stage

人为定义的扫描阶段：

- 可以包含多个 segment。
- 通常对应一个通道组、一个区域或一次明确的路线任务。
- 是 PC 后处理时进行误差评估和人工微调的基本单位。

### 3. Anchor Stage

特殊 stage，通常是 Stage 0：

- 位于入口或固定参照区域。
- 应形成小闭环。
- 后续所有 stage 尽量能回访或间接连接到它。

### 4. Checkpoint

扫描过程中可回访的检查点：

- 柱子。
- 货架端点。
- 收银台角点。
- 人工标记。
- 可重复读取的 NFC/二维码。

Checkpoint 用于发现和修正长期漂移。

## 四、单设备现场扫描流程

### 1. Stage 0：锚定阶段

要求：

- 选择稳定、开阔、容易回访的位置。
- 扫描一个小闭环或往返路径。
- 尽量包含明显几何结构。
- 若条件允许，放置人工标记或选择固定货架端点。

目的：

- 建立全局坐标参考。
- 为后续 stage 提供回访锚点。
- 检查设备和环境状态。

### 2. 后续 Stage：区域延伸

每个 stage 应遵循：

- 从已知区域或 checkpoint 出发。
- 进入新区域前保留 5 到 10 米重叠。
- stage 内部尽量形成局部小闭环。
- stage 结束时回到已知区域或另一个 checkpoint。
- 不在快速转身、遮挡严重、tracking 不稳定时结束 stage。

### 3. Segment 与 Stage 的关系

自动分段仍由手机控制，例如每 50 到 120 平方米保存一次。stage 可以跨多个 segment：

```text
Stage 1:
  segment_0002
  segment_0003
  segment_0004
```

如果某个 stage 很大，建议拆成多个 stage，而不是只依赖 segment 自动保存。

## 五、PC 后处理需求

### 1. Stage 配置

第一版通过 JSON 配置定义 stage：

```json
{
  "format": "SupermarketStageConfig",
  "version": 1,
  "stages": [
    {
      "id": "anchor",
      "name": "入口锚定区",
      "segments": [1],
      "role": "anchor"
    },
    {
      "id": "aisle_a",
      "name": "A 区主通道",
      "segments": [2, 3],
      "transform": {"dx": 0.0, "dy": 0.0, "yaw_deg": 0.0}
    }
  ],
  "segment_transforms": {
    "3": {"dx": 0.1, "dy": -0.1, "yaw_deg": 0.5}
  }
}
```

如果没有配置，PC 工具可默认：

- 每个 segment 一个 stage。
- 第一个 stage 为 anchor。

### 2. Stage 级质量报告

每个 stage 输出：

- 包含的 segment。
- 节点数。
- 价签数。
- 轨迹长度。
- 起点和终点距离。
- 是否近似闭环。
- 与前一 stage 的起终点距离。
- 是否有明显跳变。
- 应复核警告。

### 3. Stage 级校正

PC 工具应支持：

- stage 级变换。
- segment 级微调。
- 反复重跑。
- 输出实际使用的配置。

### 4. 地图生成

在 stage 校正后，调用统一地图生成逻辑输出：

- `occupancy_grid.png`
- `preview.png`
- `trajectory.geojson`
- `price_tags.geojson`
- `quality_report.json`
- `stage_manifest.json`
- `review_items.json`

## 六、累积误差规避策略

### 1. 扫描路线

推荐：

- 以 anchor stage 为根。
- 每个新区域从已知区域出发。
- 每隔一段距离回访 checkpoint。
- 每个通道组形成局部闭环。
- 相邻 stage 至少有一个重叠边界。

避免：

- 单向扫完整个超市不回头。
- 长直通道扫太快。
- 多个 stage 之间没有重叠。
- 在无纹理/反光/动态遮挡区域结束 stage。

### 2. 采样频率和移动速度

建议：

```text
稳定大范围：1 Hz
一般超市推荐：2 Hz
慢速重点区域：3 Hz
移动速度：0.5 到 0.8 m/s
```

更高频率会提高局部密度，但也会增加数据库、内存、分段频率和后处理压力。

### 3. Checkpoint

每个 stage 最好记录 checkpoint：

```text
checkpoint_id
stage_id
segment_index
node_count
x/y/yaw
type: visual / marker / nfc / manual
```

当前第一版可先在文档和 PC 配置中人工记录；后续可在 iOS UI 中增加“Mark Checkpoint”。

### 4. 质量阈值

PC 工具应标记：

- stage 起终点距离过大但声称闭环。
- stage 与前一 stage 起点距离过大。
- stage yaw 修正过大。
- segment 修正过大。
- 没有重叠或没有有效 pose。
- 只有覆盖图、没有结构点。

### 5. 人工微调

人工微调的优先级：

1. 先修 stage 级 yaw。
2. 再修 stage 级 dx/dy。
3. 最后修个别 segment。
4. 不直接改原始 `.db`。

## 七、验收标准

第一版验收：

- 能读取单个 session。
- 能按 stage 配置分组 segments。
- 能输出 stage manifest。
- 能输出 stage 质量报告。
- 能应用 stage 级和 segment 级 transform。
- 能生成校正后的 2D 地图包。
- 能输出待复核项。

后续验收：

- 支持 checkpoint。
- 支持 stage 间自动重叠检测。
- 支持 stage 级图优化。
- 支持结构点真实 occupied layer。
- 支持人工校正 UI。

## 八、与多设备方案的关系

单设备多阶段是多设备合并的前置能力。

```text
单设备：
  stage = 同一设备内的误差控制单元

多设备：
  device = 更高一级坐标单元
  stage  = 每台设备内部的误差控制单元
```

因此应先实现：

```text
单设备 stage 配置
  -> stage 级质量报告
  -> stage/segment 级 corrections
  -> 单设备校正地图
```

再扩展为：

```text
多设备 device transform
  -> 每台设备内部 stage transform
  -> 全局地图
```
