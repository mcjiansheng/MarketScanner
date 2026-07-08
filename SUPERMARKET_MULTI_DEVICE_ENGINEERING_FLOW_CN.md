# 多设备大型超市扫描工程实现流程设计

日期：2026-07-07

## 一、工程原则

1. 原始数据不可变。
2. 手机端只做稳定采集和安全导出。
3. PC 端后处理必须可重跑。
4. 所有人工微调写入配置，不直接修改数据库。
5. 每次输出必须包含 manifest、参数和质量报告。
6. 大型任务按阶段缓存，不一次性把所有点云/mesh 压进内存。

## 二、第一版实现范围

本次工程实现第一版 PC 端多设备基础工具：

```text
tools/Supermarket2DMap/supermarket_multi_device_map.py
```

功能：

- 输入多个 `SupermarketSession-*`。
- 支持 JSON 配置。
- 支持 `--align-common-start`。
- 支持设备级变换。
- 支持 segment 级变换。
- 输出统一 2D 地图包。
- 输出多设备 manifest。
- 输出质量报告和 review items。

不实现：

- 真实点云提取器。
- 自动 ICP/NDT。
- GUI 人工校正。
- 全量 3D mesh。

## 三、命令行设计

### 1. 直接传入多个 session

```bash
python3 tools/Supermarket2DMap/supermarket_multi_device_map.py \
  /path/phone_a/SupermarketSession-... \
  /path/phone_b/SupermarketSession-... \
  --output /path/MultiDeviceMap-output \
  --align-common-start
```

设备 id 默认使用 session 父目录名或 session 目录名。

### 2. 使用配置文件

```bash
python3 tools/Supermarket2DMap/supermarket_multi_device_map.py \
  --config multi_device_config.json \
  --output /path/MultiDeviceMap-output
```

配置示例：

```json
{
  "format": "SupermarketMultiDeviceConfig",
  "version": 1,
  "reference_device": "phone_a",
  "devices": [
    {
      "id": "phone_a",
      "session": "sessions/phone_a/SupermarketSession-20260707-090000",
      "points_csv": "points/phone_a_points.csv",
      "transform": {"dx": 0.0, "dy": 0.0, "yaw_deg": 0.0}
    },
    {
      "id": "phone_b",
      "session": "sessions/phone_b/SupermarketSession-20260707-090100",
      "transform": {"dx": 1.4, "dy": -0.6, "yaw_deg": 2.0}
    }
  ],
  "segment_transforms": {
    "phone_b:2": {"dx": 0.2, "dy": 0.0, "yaw_deg": -0.5}
  }
}
```

## 四、输入处理流程

```text
load_config_or_sessions()
  -> resolve paths
  -> create DeviceInput[]
  -> discover_segments(session)
  -> load projected points
  -> compute device transforms
  -> apply segment transforms
  -> assign global segment ids
```

## 五、输出处理流程

```text
build_grid(all_segments, all_points)
  -> render occupancy_grid.png
  -> render preview.png
  -> write occupancy_grid.yaml
  -> write trajectory.geojson
  -> write price_tags.geojson
  -> write vector_map.geojson
  -> write semantic_layers.json
  -> write multi_device_manifest.json
  -> write quality_report.json
  -> write review_items.json
  -> write map.json
```

## 六、质量报告检查项

第一版检查：

- 输入设备数是否大于 1。
- 每台设备是否有有效 segment。
- 每台设备是否有有效 pose。
- 是否存在缺失数据库。
- 是否存在缺失 sidecar。
- 是否未提供 projected structure points。
- 是否使用了自动共同起点对齐。
- 每台设备首 pose 与参考首 pose 的初始修正量。
- segment 级修正量是否过大。

## 七、人工微调流程

1. 第一次运行 `--align-common-start`。
2. 查看 `preview.png` 中不同设备轨迹是否大致重合。
3. 查看 `quality_report.json` 的 warnings。
4. 编辑 `multi_device_config.json` 中设备级 transform。
5. 如局部错位，编辑 `segment_transforms`。
6. 重跑工具。
7. 将最终配置和输出包一起归档。

## 八、后续代码任务

### 1. Grid/point exporter

新增 C++ 或 Python 工具：

```text
rtabmap_grid_exporter
```

职责：

- 打开 RTAB-Map `.db`。
- 解码局部 grid 或点云。
- 输出 `points.csv`。

### 2. 自动配准模块

新增：

```text
align_segments.py
```

职责：

- 读取结构点。
- 做栅格相关/ICP。
- 输出候选 constraints。
- 输出置信度。

### 3. 图优化模块

新增：

```text
optimize_layout.py
```

职责：

- 读取 constraints。
- 优化设备和 segment transform。
- 输出 corrections。

### 4. 人工校正工具

可先做网页或桌面轻量工具：

- 加载 preview 和 trajectory。
- 拖动设备/segment。
- 添加对应点。
- 保存 config。

## 九、Git 管理建议

每个阶段单独提交：

```text
docs: add multi-device supermarket requirements
tools: add multi-device supermarket map pipeline
docs: document multi-device tool usage
```

由于当前工作区已有未提交 iOS 改动，本次提交应只包含多设备相关新增文件和必要 README 更新，避免混入无关生成文件。
