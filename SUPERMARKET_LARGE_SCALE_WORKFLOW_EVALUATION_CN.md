# 3000 平米级大型超市扫描、分段合并与建模流程评估

日期：2026-07-07

本文基于当前仓库代码和已有中文文档，评估大型超市场景，尤其是面积超过 3000 平方米、货架和商品表面细节较多时，手机端扫描、分段导出、预览、合并、建模和误差控制的合理流程。

结论先行：

```text
手机端适合做：
  稳定分段采集
  单段数据库安全落盘
  NFC/轨迹/覆盖 sidecar 输出
  外部存储后台复制
  低分辨率覆盖预览
  小规模或临时性的分段检查

手机端不适合做：
  3000 平米全量数据库合并
  全量高质量 3D mesh / texture mesh
  全量点云融合
  全局二维结构地图最终生成
  大范围段间自动校正

推荐主流程：
  手机分段采集
  -> 分段导出和校验
  -> PC/服务器离线读取所有 segment
  -> 逐段提取轨迹、局部栅格、点云和价签
  -> 建立段间约束
  -> 全局位姿图优化
  -> 生成最终 2D 地图和可选 3D 模型
```

## 一、当前代码中的实际行为

### 1. 分段导出时是否会建模上一段

当前代码中，自动或手动分段由 `ViewController.rolloverCurrentSegment(...)` 执行。

实际流程是：

```text
暂停 ARSession / location / RTAB-Map mapping / camera
  -> rtabmap.save(databasePath: rtabmap_segment_xxxx.db)
  -> writeSidecarFiles(metadata / price_tags / scan_area_cells / trajectory_samples)
  -> scanSession.nextSegment()
  -> openDatabase(tmpDatabase, clearDatabase: true)
  -> startCamera(resetTracking: false)
  -> 如有外部目录，后台复制刚保存的 segment
```

也就是说，分段导出后并不会在下一段扫描时自动对上一段做全量建模。当前后台只做外部复制、校验和本地清理，不做 Poisson mesh、texture mesh、全量点云融合或全局图优化。

这点很重要：当前设计避免了“边扫下一段，边重建上一段高质量模型”的巨大内存/CPU/GPU 开销。

### 2. 当前扫描过程中做了什么

扫描当前 segment 时，RTAB-Map 仍会实时处理当前段数据：

- 接收 ARKit pose、图像、深度/点云。
- 按 `Rtabmap/DetectionRate` 插入节点。
- 保存节点数据到当前临时数据库。
- 维护当前段的图、约束、局部可视化数据。
- 更新 HUD stats。
- 更新 `FloorAreaEstimator` 的覆盖面积。

这属于“当前段实时建图/记录”，不是“对已完成所有段做最终建模”。

### 3. 重型建模什么时候发生

当前代码里重型建模和后处理由用户手动触发：

- `ViewController.optimization(...)`
  - 调用 `rtabmap.postProcessing(...)`
  - 可能检测更多回环、做图优化、触发滤波/增益补偿等。

- `ViewController.export(...)`
  - 调用 `rtabmap.exportMesh(...)`
  - C++ 层 `RTABMapApp::exportMesh(...)` 会遍历所有 poses。
  - 读取每个节点的图像/深度/mesh 数据。
  - 融合点云。
  - 可选 Poisson mesh。
  - 可选纹理生成、纹理合并、mesh decimation。
  - 把 optimized mesh 保存回数据库。

- `ViewController.mergeSavedSegments()`
  - 调用 `rtabmap.mergeDatabases(...)`
  - C++ 层 `RTABMapApp::mergeDatabases(...)` 读取多个 `.db`，用 `DBReader` 重放传感器数据生成新数据库。

这些操作都不是分段保存自动后台触发的。它们一旦面对 3000 平方米全量数据，就会变成手机端高风险操作。

## 二、3000 平方米场景的性能压力

### 1. 面积不是唯一指标

大型超市的实际压力不只来自地面面积，还来自：

- 货架两侧表面都要扫。
- 商品包装纹理复杂，RGB/深度数据量大。
- 通道重复，回环验证困难。
- 长走廊会放大 yaw 漂移。
- 人员、购物车和临时堆货会产生动态噪声。
- 价签需要在货架边缘附近记录，往往需要更慢、更密的扫描。

因此 3000 平方米的“地面面积”，实际采集路径和表面观测量可能相当于更大的建图任务。

### 2. 从已有问题推断单段风险

已有文档记录过类似现象：

```text
约 170 平方米
约 1700 MB
保存阶段出现 SIGABRT / 闪退风险
```

这不能简单线性外推，但足以说明：如果 3000 平方米不分段，数据库很可能达到几十 GB 级别，手机端保存、优化、合并和 mesh 导出都不可控。

即使分段，若每段过大，单段保存仍可能出现：

- native `save()` 关闭和 flush 数据库时内存峰值。
- SQLite I/O 压力。
- 图像/深度 blob 写入压力。
- sidecar 写入和外部复制耗时。
- 前台 App 被系统内存压力终止。

当前默认阈值已经调整为较保守：

```text
面积阈值 = 120 m2
数据库阈值 = 700 MB
分段内存增长阈值 = 1200 MB
最少节点数 = 30
```

如果现场商品细节很多，建议用数据库阈值和内存增长阈值作为主要保护线，而不是只按面积判断。

### 3. 3000 平方米可能需要多少段

按 120 平方米阈值粗算：

```text
3000 / 120 = 25 段
```

但实际现场可能因为数据库大小、内存增长、货架密度和扫描频率提前分段。更实际的范围可能是：

```text
稳定优先：30 到 60 段
高细节扫描：可能更多
```

这不是坏事。大场景中更多小段通常比少数超大段更可靠，关键是后续必须有 PC 端自动整理、校验、合并和校正流程，不能要求用户在手机上手动处理几十段。

## 三、手机端合并和预览是否可控

### 1. 手机端低分辨率覆盖预览可控

当前手机端 `Generate 2D Map Package` 读取的是 sidecar：

```text
scan_area_cells.json
trajectory_samples.json
price_tags.json
metadata.json
```

它生成的是覆盖图：

- 已覆盖区域。
- 估算边界。
- 分段轨迹线。
- 价签点。
- 质量摘要。

它没有读取全量 RGB/深度 blob，也没有融合点云。因此对几十个 segment 来说，低分辨率覆盖预览相对可控。

但仍需注意：

- `scan_area_cells.json` 如果面积很大、分辨率很高，会变大。
- 当前 cellSize 是 0.25 m，3000 平方米理论格数约 48000 个，单纯覆盖格不算夸张。
- 真正风险来自点云、mesh、纹理，而不是这个覆盖图。

所以手机端可以保留：

```text
当前 session 快速覆盖预览
最近生成 2D map 预览
分段轨迹和价签检查
```

但不应把它包装成最终结构地图。

### 2. 手机端全量数据库合并不可作为主流程

当前 `mergeSavedSegments()` 会把所有 `rtabmap_segment_*.db` 交给 native C++：

```text
RTABMapApp::mergeDatabases(...)
  -> DBReader 依次读取输入数据库
  -> Rtabmap merged.process(...)
  -> 输出 SupermarketMerged-*.db
```

这适合：

- 小规模测试。
- 几个 segment 的现场验证。
- 检查分段保存和 native 合并链路是否可用。

但对 3000 平方米、几十段、几十 GB 数据，不建议作为默认流程。原因：

- 合并会重新读取并处理所有输入数据库。
- 需要在手机前台长时间运行。
- 输入可能位于外接存储或文件提供器，I/O 不稳定。
- 处理过程可能占用大量内存。
- 取消或失败后仍需要清理半成品。
- 合并后的数据库继续用于 mesh/export 时压力更大。

因此手机端合并入口应定位为“调试/小规模合并”，而不是大型超市最终生产流程。

### 3. 手机端全量 3D mesh 不可控

`RTABMapApp::exportMesh(...)` 对所有 poses 遍历，读取节点数据并组装点云/mesh。若启用 optimized mesh、Poisson、纹理，开销会显著增加：

```text
节点数越多
  -> 读取和解压图像/深度越多
  -> 点云融合越大
  -> 法线计算越多
  -> Poisson mesh 更重
  -> 纹理投影和合并更重
```

3000 平米不建议在手机端做全量 mesh。手机端最多适合：

- 当前小段的快速查看。
- 限制 polygon 数的局部导出。
- 小范围演示。

最终模型应离线生成，并且最好采用 tile / LOD / 分层表达，而不是一次性生成一个巨大 OBJ。

## 四、推荐的大规模流程

### 1. 手机端采集阶段

手机端只负责采集和数据安全。

```text
开始 SupermarketSession
  -> 扫描当前 segment
  -> 达到面积/数据库/内存阈值
  -> 本地保存 segment db
  -> 写出 sidecar
  -> 立即打开新临时库继续扫描
  -> 后台复制 segment 到外部存储
  -> 校验后清理本地副本
```

建议现场策略：

- 每段控制在 50 到 120 平方米，细节多时更小。
- 采样频率推荐 1 到 2 Hz，慢速高质量短段可 3 Hz。
- 移动速度控制在 0.5 到 0.8 m/s。
- 每段结束或相邻段开始处保留明显重叠。
- 不要在手机上做全量优化、全量组装、全量合并。

### 2. 每段导出内容

每段至少包含：

```text
segment_0001/
  rtabmap_segment_0001.db
  metadata.json
  price_tags.json
  price_tags.csv
  scan_area_cells.json
  trajectory_samples.json
  trajectory_samples.csv
```

建议新增或补强：

```text
segment_manifest.json
file_hashes.json
tracking_quality.json
segment_boundary.json
```

其中 `segment_boundary.json` 建议记录：

- segment 起止时间。
- 起止 pose。
- 起止 node id。
- 开始前/结束后若干秒轨迹。
- ARKit tracking state 摘要。
- 是否发生 relocalizing。
- 保存原因。

这对 PC 端判断段间连续性非常重要。

### 3. PC/服务器导入阶段

PC 端导入 session 后，第一步不是立刻全量建模，而是校验和索引：

```text
读取 session manifest
  -> 校验每个 segment 文件 hash
  -> 读取 metadata / trajectory / price tags
  -> 检查 segment 是否缺文件
  -> 检查数据库能否打开
  -> 提取每段 node poses
  -> 生成 session 总览报告
```

当前已有 `tools/Supermarket2DMap/supermarket_2d_map.py` 可作为起点。它已经能读取：

- segment 目录。
- metadata。
- price tags。
- RTAB-Map `Node.pose`。
- 可选 `points.csv`。

### 4. PC 端逐段轻量处理

建议先做逐段处理，而不是直接全量融合：

```text
segment db
  -> 提取节点轨迹
  -> 提取局部 grid 或点云摘要
  -> 降采样
  -> 高度过滤
  -> 输出 segment_submap
```

每段输出中间产物：

```text
pc_work/
  segment_0001/
    poses.geojson
    points_downsampled.laz 或 .ply
    local_grid_points.csv
    segment_2d_grid.tif/png
    segment_quality.json
```

关键是把大数据库拆成可缓存、可重跑、可检查的中间层。

### 5. PC 端段间约束

为每对相邻或可能重叠 segment 建立候选约束：

```text
连续性约束：
  segment_i 结束 pose -> segment_j 开始 pose

重叠约束：
  相邻通道或回访区域的点云/栅格匹配

结构约束：
  长直货架边界方向一致
  主通道方向一致

业务锚点：
  入口、收银台、柱子、固定货架端点
  可复扫的 NFC/二维码/AprilTag
```

每条约束应有：

```text
relative_transform
confidence
residual
source
manual_or_auto
```

低置信约束不应自动强制应用，只进入待复核列表。

### 6. PC 端全局优化

推荐优化对象不是每个原始点，而是：

- segment pose。
- segment 内关键子图 pose。
- 必要时再细化到关键帧 pose。

流程：

```text
读取所有 segment/submap 初始 pose
  -> 加入连续性约束
  -> 加入重叠配准约束
  -> 加入人工锚点约束
  -> 鲁棒图优化
  -> 输出 optimized_segment_transforms
```

输出示例：

```json
{
  "segment_transforms": {
    "1": {"dx": 0.0, "dy": 0.0, "yaw_deg": 0.0},
    "2": {"dx": 1.2, "dy": -0.4, "yaw_deg": 2.1}
  }
}
```

这可以直接兼容当前 `tools/Supermarket2DMap` 的 `corrections.json` 思路。

### 7. 最终二维地图生成

最终二维地图应离线生成：

```text
优化后的 segment/submap
  -> 点云高度过滤
  -> occupied/free 证据融合
  -> conflict 检测
  -> 可通行区域生成
  -> 结构边界提取
  -> 价签吸附到货架/边界
  -> 输出地图包
```

输出建议：

```text
SupermarketMapPackage/
  map.json
  source_manifest.json
  occupancy_grid.png
  occupancy_grid.yaml
  vector_map.geojson
  semantic_layers.json
  price_tags.geojson
  trajectory.geojson
  corrections.json
  quality_report.json
  review_items.json
  preview.png
```

### 8. 最终三维模型生成

如果业务确实需要 3D 模型，不建议只输出一个巨大 mesh。推荐：

```text
按区域/货架通道/tile 输出
  -> 每个 tile 限制点数和面数
  -> 输出 LOD
  -> 保留源 segment 引用
  -> 可按需加载
```

例如：

```text
Model3D/
  tiles/
    tile_0001/
      cloud.laz
      mesh_lod0.glb
      mesh_lod1.glb
      metadata.json
  tile_index.json
```

大多数超市业务，二维平面图 + 价签点 + 局部照片/点云证据比全量高精 3D mesh 更可控。

## 五、是否可以通过 PC 脚本合并

可以，而且应作为大型超市的主流程。

当前仓库已经有一个很好的起点：

```text
tools/Supermarket2DMap/supermarket_2d_map.py
```

它已能：

- 自动发现 segment。
- 读取 RTAB-Map 节点 pose。
- 读取价签。
- 生成 2D map package。
- 接收 `corrections.json`。
- 输出质量报告。

但要支撑 3000 平米最终生产，还需要补齐：

### 1. 数据提取器

新增 C++ 或 Python+RTAB-Map 工具，从 `.db` 中提取：

- 局部 occupancy grid。
- ground / obstacle / empty cells。
- 降采样点云。
- 节点 pose。
- 节点图像/深度的摘要或引用。

离线工具 README 已说明当前暂未直接解码 `Data.ground_cells / obstacle_cells / empty_cells` blob。建议新增：

```text
tools/Supermarket2DMap/rtabmap_grid_exporter
```

输出：

```text
points.csv
local_grids/
segment_2d_grid.npz
```

### 2. PC 端合并脚本

建议新增：

```text
tools/Supermarket2DMap/supermarket_pipeline.py
```

流程：

```text
validate
extract
align
optimize
render2d
export
report
```

示例命令：

```bash
python3 tools/Supermarket2DMap/supermarket_pipeline.py \
  /path/to/SupermarketSession-20260707-120000 \
  --work /path/to/work \
  --output /path/to/SupermarketMapPackage \
  --resolution 0.05 \
  --auto-align-segments \
  --corrections corrections.json
```

### 3. RTAB-Map 原生合并作为可选步骤

PC 上仍可以用 RTAB-Map 的数据库合并能力生成一个 `SupermarketMerged.db`，但不建议把它当作唯一结果。更稳的做法是：

```text
保留原始 segments
  + 输出 PC 端 map package
  + 可选输出 merged db
```

原因：

- `merged db` 不包含所有业务 sidecar 语义。
- 错误合并可能污染单一输出。
- 原始 segment 更利于重跑、回溯、局部修正。

## 六、如何避免累积误差

累积误差不能靠“最后一次全量合并”完全解决，必须从采集、分段、约束、优化和人工复核全链路控制。

### 1. 采集路线控制

推荐路线：

```text
入口或固定锚点开始
  -> 沿主通道扫描
  -> 每条货架通道形成小闭环
  -> 相邻通道在端头保留重叠
  -> 定期回到已扫描区域
  -> 每段开始/结束保留 5 到 10 米重叠
```

避免：

- 一条长通道从头扫到尾完全不回环。
- 每个 segment 之间没有重叠。
- 快速转身或甩动手机。
- 在 ARKit relocalizing 时继续移动并采集。
- 只扫货架一侧，缺少跨通道约束。

### 2. 分段边界控制

当前代码已经做了两件有帮助的事：

- `setPreserveCameraOrigin(true)`：减少分段 stop/start 导致的 origin reset。
- ARKit tracking state 不是 acceptable 时不向 RTAB-Map 投递帧。

但还建议现场操作：

- 分段保存时尽量站稳。
- 保存完成并恢复后，在原地或小范围缓慢移动几秒。
- 不要在转弯瞬间、快速移动中或货架尽头盲区触发手动分段。
- segment 开始和结束最好落在特征丰富、可回访的位置。

### 3. 人工锚点

大型超市中，仅靠自然视觉特征可能不够。建议引入至少一种人工锚点：

- AprilTag / ArUco 标记。
- 入口、柱子、固定收银台等人工点。
- 货架端点编号。
- 可重复读取的 NFC/二维码点。
- 简易 CAD 平面参考点。

当前 RTAB-Map 参数和代码中已有 marker detection 相关配置入口，可作为后续利用方向。

### 4. 价签位置不能直接等于货架位置

当前 NFC 记录的是读取时手机 pose，不是价签真实位置。误差来源包括：

- 手机与价签距离。
- 读取角度。
- 价签在货架边缘，手机在通道中。
- ARKit pose 漂移。
- 分段坐标后续被优化。

后处理时应：

```text
原始 NFC pose
  -> 随 segment transform 更新
  -> 向最近货架/结构边界吸附
  -> 保留 raw_pose 和 adjusted_pose
  -> 输出 confidence
```

不要覆盖原始记录。

### 5. 段间约束要带置信度

重复货架环境中，错误配准比无配准更危险。因此约束必须有质量门槛：

- ICP residual。
- 重叠面积。
- 主方向一致性。
- 轨迹连续性。
- 价签/锚点一致性。
- 是否产生不合理大修正。

低置信约束进入 `review_items.json`，不要自动应用。

### 6. 使用冲突图层暴露问题

最终 2D 地图不要只输出“平滑好看的图”。必须输出：

- `conflict` 栅格。
- 段间边界。
- 每个 segment 颜色轨迹。
- 被大幅修正的 segment。
- 低置信价签。
- 未知区域。

这能避免地图看起来平滑但实际错误。

## 七、推荐系统架构

```text
iPhone App
  - 分段采集
  - NFC 记录
  - 本地安全保存
  - 外部复制
  - 低分辨率覆盖预览

Transfer / Import
  - 文件 hash 校验
  - session manifest
  - 缺文件检查

PC/Server Pipeline
  - DB 读取
  - 局部 grid/点云提取
  - 降采样和高度过滤
  - 段间约束生成
  - 全局优化
  - 2D map / semantic layers / quality report
  - 可选 tiled 3D model

Review Tool
  - 查看冲突区域
  - 编辑 corrections.json
  - 确认价签吸附
  - 重跑输出
```

## 八、推荐开发任务拆分

### 1. 手机端近期任务

- 保持分段保存稳定。
- 增强导出 manifest 和 hash。
- 明确 UI 上“手机端 2D 图是覆盖预览，不是最终结构地图”。
- 大型 session 中默认不鼓励手机端全量合并。
- 合并入口增加数据规模提示，例如 segment 数量、估算总大小过大时提示转 PC。

### 2. PC 离线近期任务

- 给 `tools/Supermarket2DMap` 增加 session 校验命令。
- 增加 RTAB-Map grid/point exporter。
- 增加批处理 pipeline 脚本。
- 支持从 `corrections.json` 反复重跑。
- 输出更完整 `quality_report.json`。

### 3. 误差控制近期任务

- segment 起止 pose 和起止节点写入 sidecar。
- 记录 ARKit tracking state 摘要。
- 支持人工锚点输入。
- 生成 segment overlap 候选列表。
- 输出待复核段间边界。

### 4. 中长期任务

- 自动段间配准。
- 结构线提取和主方向约束。
- 价签点吸附到货架边界。
- tiled 3D 模型输出。
- 桌面/网页人工校正工具。

## 九、建议的最终生产流程

### 现场采集

```text
1. 创建 SupermarketSession
2. 选择外部保存位置
3. 按区域/通道扫描
4. 自动分段，必要时手动分段
5. 每段保留重叠和锚点
6. 读取 NFC 价签
7. 手机端只查看覆盖预览和保存状态
8. 不在手机端做全量 mesh / 全量合并
```

### 数据导入

```text
1. 把 SupermarketSession 导入 PC
2. 校验所有 segment db 和 sidecar
3. 生成 source_manifest
4. 生成初始 overview
5. 标出缺失、异常大、异常短、tracking 风险段
```

### 离线建图

```text
1. 逐段提取 pose / grid / point cloud
2. 生成 segment submap
3. 建立段间约束
4. 全局优化 segment transforms
5. 生成二维 occupancy / vector / semantic layers
6. 价签 raw pose -> optimized pose -> shelf snapping
7. 输出 quality_report 和 review_items
```

### 人工复核

```text
1. 查看 conflict 和低置信区域
2. 修改 corrections.json
3. 修正锚点或段间 transform
4. 重跑地图生成
5. 固化最终 SupermarketMapPackage
```

## 十、总体判断

对 3000 平方米以上的大型超市，当前代码的“分段采集 + sidecar + 外部复制 + 手机端覆盖预览”方向是合理的，性能开销基本可控。关键是不要把手机端合并和全量建模当成生产主流程。

当前分段导出后，上一段不会在下一段扫描时被自动高质量建模；这避免了边扫边重建带来的不可控开销。真正的全量建模和合并如果放到扫描结束后在手机上执行，会对 3000 平米场景产生过高风险。解决方案不是继续压榨手机，而是把最终合并、结构地图生成、全局优化和可选 3D 建模迁移到 PC/服务器离线管线。

推荐最终路线：

```text
手机端：
  只做稳定采集、分段、安全导出、轻量预览。

PC/服务器端：
  做校验、提取、段间约束、图优化、最终 2D 地图、质量报告和可选 3D tile。

误差控制：
  依靠重叠扫描、锚点、结构约束、鲁棒优化和人工复核，而不是依赖一次性全自动合并。
```

这样可以把大规模超市扫描拆成可恢复、可验证、可重跑的工程流程，避免手机端一次性处理全量数据导致保存失败、合并失败、内存峰值过高或地图看似完整但误差不可控。
