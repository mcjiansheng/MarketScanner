# RTAB-Map 大型超市扫描与地图工作台

> 文档状态：**当前有效**。最后一次与源码交叉核对日期：2026-07-24。

本项目是在开源 **RTAB-Map** 基础上进行的业务化改造，面向大型超市、仓储卖场等室内场景，形成从 iPhone Pro 连续采集，到 PC 端离线优化，再到二维地图、彩色俯视图和三维预览的一套本地工作流。

当前源码中的 RTAB-Map 版本为 **0.23.5**。上游项目原始 README 已保存在 [doc/README.md](doc/README.md)，便于查询 RTAB-Map 官方主页、安装说明、ROS 支持和上游 CI 信息。

> 本仓库不是 RTAB-Map 官方发行版。RTAB-Map 的原始著作权和 BSD 许可仍归原作者所有；本仓库在其通用 SLAM 能力之上增加了超市连续采集、离线处理和地图交付功能。

## 项目目标

原始 RTAB-Map 是一个通用的实时外观建图系统，提供视觉/激光里程计、回环检测、位姿图优化、RGB-D 数据库、点云和占据栅格等能力。本项目保留这些基础能力，并针对实际超市作业补充以下闭环：

```text
iPhone Pro RGB-D / LiDAR / IMU / ARKit 采集
  -> 连续写入单个 RTAB-Map SQLite 数据库
  -> 位姿质量门控、在线回环 map→odom 同步、跨帧结构覆盖提示、自适应关键帧与设备安全保护
  -> 完整会话导出到 PC
  -> 数据库检查与自适应离线闭环/全局优化
  -> 轨迹安全验证
  -> 2D 占据图、货架/竖直结构轮廓、彩色俯视图、3D 预览与业务图层
  -> 质量报告、来源清单和人工复核
```

设计重点是：手机端优先保证原始数据连续、可靠落盘，计算量较大的闭环补充、全局优化、结构投影和成果整理放到 PC 端完成；原始扫描数据库保持只读，所有处理结果写入新的输出目录。

## 与原始 RTAB-Map 的关系

### 保留的上游能力

- `corelib/`：RTAB-Map 的记忆管理、回环检测、图优化、数据库、传感器数据和地图算法。
- `guilib/`：桌面图形界面与可视化组件。
- `utilite/`：日志、线程、文件和通用工具库。
- `app/`：桌面、Android 和 iOS 应用入口。
- `tools/`：数据库查看、重处理、导出、数据集转换等上游命令行工具。
- `examples/`、`archive/`、`docker/`：示例、研究材料和容器环境。
- CMake 构建体系、ROS 包描述以及原项目的 BSD `LICENSE`。

### 本项目的主要改编

| 范围 | 改编内容 |
| --- | --- |
| iOS 采集 | 增加超市扫描会话、连续流式单库、跨帧结构覆盖顾问、自适应关键帧、中文界面、sidecar 数据和外部目录复制 |
| 移动原生层 | 增加相机原点保持、连续地图模式、有界实时渲染、在线回环 map→odom 同步、数据库操作和 Swift/C++ 桥接能力 |
| 稳定性 | 对 ARKit tracking 恢复和不合理位姿跳变进行质量门控；用跨时间/视角的深度证据抑制单帧行人噪声；按内存、磁盘和热状态降低预览、限制采样或安全结束 |
| PC 优化 | 扩展 `rtabmap-reprocess` 的进度、约束统计和最终求解流程，支持工作台执行自适应离线优化 |
| 地图生成 | 新增单设备、历史多阶段、多设备二维地图脚本，输出占据图、融合地板空缺、自由空间、竖直面与层板证据的货架实例闭合边界、轨迹、GeoJSON 和质量报告；保留旧价签数据兼容解析 |
| 可视化工作台 | 新增仅监听本机的 Web 工作台，统一进行输入检查、处理编排、2D/3D 预览、日志和结果检查 |
| 性能加速 | 提供 Release/OpenMP 配置，以及 Apple Metal 或 NVIDIA CUDA 深度投影 helper；不可用时明确回退 CPU |

Android 目录中的部分 C++ 原生实现也因共享移动渲染和数据库能力而被扩展，但当前完整的超市现场采集交互主要实现在 iOS 应用中。

## 当前采集方案

### 自由扫描与已有地图辅助扫描

项目现在保留两个并列入口：

- **自由扫描建图**：继续使用既有 ARKit/RGB-D/LiDAR 连续单库采集和 PC 离线优化，默认行为与输出兼容不变。
- **已有地图辅助扫描（阶段一）**：先把 `Element Info` XLSX 转换为版本化先验地图包，在 iPhone 五步向导中选择地图、楼层、起点和朝向；扫描时用 `T_map_from_arkit` 显示 2D 位置，并以 2 Hz 道路候选做有上限的软约束。定位较弱或丢失不会停止 RTAB-Map 原始数据库记录，人工位置确认写入独立审计 sidecar。

阶段一**尚未实现** LiDAR/视觉结构自动地图匹配、Vision 扫码或价签位置测量，界面不会把初始/道路辅助定位称为精准定位。完整架构、格式、UI、测试和当前状态见 [docs/map-assisted-localization/](docs/map-assisted-localization/)。

### 连续流式单数据库

生产扫描不再通过频繁关闭数据库和创建新分段来控制内存。一次扫描会话持续写入同一个 SQLite 数据库：

- `Mem/STMSize` 和 `Rtabmap/MemoryThr` 限制在线工作图规模；旧节点通过数据库驱动持续写入磁盘。
- 实时渲染节点数有独立上限，释放退出工作图的点云和图形缓冲，避免预览内存无限增长。
- 暂时打开控制中心、锁屏或发生系统中断后，恢复到同一条连续轨迹，不人为创建新子图。
- `segment_0001` 仅为兼容早期 PC 工具保留的目录名，不表示生产模式仍会自动分段。

### NFC 功能暂停

当前项目暂停 NFC 相关功能的使用与开发。原因是 iOS 调起 Core NFC 会中断正在运行的摄像头采集，从而破坏连续扫描；同时，未具备相应认证、entitlement 和 provisioning profile 的 Apple 开发者账号无法在真机上调试 NFC。

因此当前版本隐藏 NFC 菜单和调试入口，不把 NFC 纳入扫描验收流程。`PriceTagNFCReader.swift`、相关数据结构、旧 `price_tags.*` 文件解析和地图兼容代码暂时保留，仅用于历史数据兼容及未来在具备认证条件、且完成摄像头连续性方案后恢复。不得在生产扫描过程中直接重新启用该入口。

### 纯软件误差控制

当前生产配置不依赖 AprilTag、ArUco、landmark 或外部 pose prior。手机端会拒绝把以下帧写入地图图结构：

- ARKit 处于初始化、重定位、不可用或其他不稳定 tracking 状态；
- tracking 刚恢复但尚未达到连续稳定帧数；
- 没有有效 ARKit 视觉特征；
- 相邻可信帧之间出现不符合手持步行设备物理范围的平移或旋转跳变。

发生异常瞬跳时，后续原始位姿会重新基准到最后一个可信连续位姿。手机端接受视觉或 local-space 回环后会在线更新 `map→odom`：实时地图、旧点云和结构覆盖立即使用优化地图坐标，而连续 `odomPose` 仍作为相邻图边输入，避免重复应用修正。只有跨越至少 50 个节点的全局/邻近回环才算累计漂移健康锚点；短回环不会掩盖长距离无可靠回环告警。手机的在线图是有界窗口，完整数据库上的闭环补充、RGB-D 重配准、重力约束、鲁棒核和最终全局优化仍由 PC 完成。

### 碎片化结构覆盖与自适应采样

货架及商品表面天然不规则，小平面也常只有零散 LiDAR 回波，因此手机端不要求一帧内出现完整平面或闭合矩形。扫描时会每 0.6 秒把中/高置信度深度用最新 `map→odom × odomPose` 投影到 0.2 米地图栅格，分别累计地面、低位/高位结构、观测时间和八方向视角；同一高于地面的栅格需要跨时间重复出现才算稳定结构，多方向再次看到后才算多视角覆盖。这样可将不同帧中的碎片保留下来，避免回环前后证据形成两套错位结构，同时让行人、购物车和单帧反射毛刺较难直接变成稳定证据。

结构新颖度高时，`Rtabmap/DetectionRate` 会从保守的 1 Hz 临时提高到 1.5 或 2 Hz，以便在小平面和不规则商品面附近保存更多 RGB-D 节点；证据重复后自动回落。`fair` 热状态最高 1.5 Hz，`serious/critical` 最高 1 Hz。HUD 会显示稳定/多视角结构栅格和覆盖分数，并提示保持货架底部、地面上下文或渐进改变视角。该层只改善采集覆盖和留下可审计证据，不在手机上凭空补货架；最终实例识别仍由 PC 使用完整数据库完成。

### 设备资源与数据安全

- 内存压力只缩小在线工作图和实时预览，不主动切换数据库。
- 设备进入 `fair` 热状态即先降低实时绘制并限制自适应采样；`serious` 时进一步缩小在线窗口。
- 可用空间低于安全线或热状态达到 `critical` 时完成并关闭当前数据库，避免继续写入造成损坏。
- 扫描期间周期写入 `live_checkpoint.json`；正常结束后写入最终元数据并删除 checkpoint。
- 选择外部保存目录时，应用在数据库关闭后后台复制整个会话，核对文件数量与字节数成功后才删除本地副本。

## 扫描会话数据

一次正常结束的连续扫描大致生成：

```text
SupermarketSession-YYYYMMDD-HHMMSS/
  segment_0001/
    rtabmap_segment_0001.db
    metadata.json
    price_tags.json             # 暂停功能的兼容空文件
    price_tags.csv              # 暂停功能的兼容空文件
    scan_area_cells.json
    structure_coverage_cells.json
    trajectory_samples.json
    trajectory_samples.csv
    scan_events.jsonl
```

主要内容：

- `rtabmap_segment_0001.db`：RGB-D 帧、节点、约束、位姿和 RTAB-Map 管理数据。
- `metadata.json`：扫描模式、完成状态、节点数、面积、存储、设备状态、处理配置、手机在线/可靠回环计数和最终 `map→odom` 修正（仅审计，不作为 PC 外部先验）。
- `price_tags.*`：为旧会话兼容保留；当前扫描不采集 NFC，正常情况下为空。
- `scan_area_cells.json`：移动端轻量覆盖面积估算使用的栅格。
- `structure_coverage_cells.json`：跨帧深度结构证据、时间/视角重复次数和最终覆盖摘要；用于审计采集是否充分，不替代原始 RGB-D 数据库。
- `trajectory_samples.*`：移动端采样轨迹，供检查和兼容流程使用。
- `scan_events.jsonl`：tracking、中断恢复、自适应采样、结构覆盖提示、闭环健康、内存、热状态、磁盘和结束事件的结构化日志。

如果会话中仍存在 `live_checkpoint.json`，PC 工作台会把它视为正在写入或异常未完成的数据，拒绝自动重处理。

## PC 端处理

### Supermarket Map Studio

`tools/SupermarketMapStudio/` 是本项目推荐的统一入口。它使用 Python 标准库提供仅绑定 `127.0.0.1` 的本机服务，并在浏览器中完成：

- 连续流式单库、旧版分段会话和多设备会话检查；
- SQLite 完整性、RGB-D/标定、时间戳和节点统计检查；
- 手机端稳定/多视角结构覆盖、地面冲突和自适应节点率摘要检查；
- `rtabmap-reprocess` 离线闭环与全局优化编排；
- 优化前后轨迹覆盖率、步长、旋转、垂直跨度和尺度验证；
- 二维结构图、白底黑色货架闭合边界、彩色 RGB-D 俯视图和 WebGL 三维预览；
- 手机采集日志、PC 处理日志、质量结论与成果文件浏览；
- 已完成结果发现和相同参数结果复用。
- 对连续单库结果执行人工区域误差修复：框选重复区域、预览 `kUserClosure` 节点约束，确认后在数据库副本上重新全局优化；只有全部人工约束端点仍存在，且平移残差、旋转残差和全图位移均通过安全门，才发布新的 `MapStudio-Merge-*` 版本；原始扫描库和基线结果保持不变。

默认优化流程为：

1. 只复用手机已经接受的邻接边和闭环约束，快速回放完整数据库。
2. 检查长程闭环数量及输入约束保留率。
3. 约束不足时才使用 ORB 特征执行 PC 补环，避免无条件重算所有视觉特征。
4. 节点回放期间使用少量在线迭代，结束后执行一次高质量稀疏全图求解。
5. 在新数据库中验证优化位姿，通过安全门后原子发布；源数据库始终保持只读。

### Supermarket2DMap 脚本

`tools/Supermarket2DMap/` 提供可独立调用的脚本接口：

- `supermarket_2d_map.py`：单会话二维地图包。
- `supermarket_staged_map.py`：兼容历史分段数据的阶段校正。
- `supermarket_multi_device_map.py`：多个设备会话的初始对齐、变换和统一地图包。

这些脚本可从 RTAB-Map 数据库读取优化位姿、RGB-D 深度和标定；也支持额外结构点输入。没有可解析深度时会退化为轨迹和业务图层结果，并在质量报告中说明限制。

### 输出地图包

典型 PC 输出包含：

```text
MapStudio-*/
  preview.png
  occupancy_grid.png
  occupancy_grid.yaml
  shelf_outline.png
  shelf_outline_evidence.json
  preview_3d.json
  preview_frames/
  trajectory.geojson
  price_tags.geojson            # 仅在旧输入含价签记录时有数据
  vector_map.geojson
  semantic_layers.json
  quality_report.json
  review_items.json
  source_manifest.json
  rtabmap_optimized/
  offline_processing_report.json
  pc_acceleration_report.json
  merge_edits.json                # 仅人工修复版本
  merge_manifest.json             # 仅人工修复版本
  merge_report.json               # 仅人工修复版本
```

其中 `source_manifest.json` 用于记录输入文件 hash，`quality_report.json` 和 `review_items.json` 用于自动检查及人工复核，`offline_processing_report.json` 记录实际命令、优化路径、耗时、闭环和发布判定。

`shelf_outline.png` 为保持地图包兼容而沿用旧文件名，内容是白底黑色的货架实例闭合外边界：内部保持白色，不输出零散开放线段，也不会把证据机械拟合成矩形框。生成器对数据库中全部可用 RGB-D 深度帧执行独立的结构证据通道，不再受彩色/3D 预览最多 96/240/384 帧的抽样预算限制；默认只接受至少两个独立帧重复看到的竖直面，以抑制行人、购物车和单帧深度毛刺。每帧深度优先直接使用 `Admin.opt_poses` 的完整 SE(3) 位姿投影（包括 roll、pitch 与垂直修正），缺失节点才回退 `Node.pose`；人工 stage/device 的 dx、dy、yaw 作为投影后的平面残差继续生效。高度再减去与该帧匹配的相机高度，以保守抵消优化图中仍可能残留的垂直漂移，然后分别提取地面、层板面和竖直面。货架下方通常缺少地面回波，因此会先在内部重建货架占地掩膜，但候选必须能在某一横截方向找到两侧地板或稳定自由空间；实测地面和重复射线清空区域用于保护通道，未知空间或只有单侧证据的区域不会被凭空填满。同一栅格若多帧稳定看到地面、却仅偶尔出现竖直面，还会按地面冲突率再次过滤；窄桥分水岭随后拆开被重影或噪声粘连的相邻实例，最终只提取每个实例的外侧闭合边界。`shelf_outline_evidence.json` 第 6 版除竖直面、地面、层板面、稳定自由空间及独立观测次数外，还记录结构识别实际可用、抽取和成功解码的帧数。Map Studio 可通过“更干净—更完整”滑杆、三档预设或高级门槛即时重算补全距离、通道保护、粘连拆分和轮廓线宽，并显示直接扫描支持率、下载当前 PNG，不必重新执行 PC 优化，也不会覆盖默认成果。旧第 4、5 版证据仍可读取。该结果仍是几何推断：仅凭深度几何不能绝对区分货架与墙体，累计水平位姿漂移造成的重影也无法由轮廓后处理完全消除；缺少两侧地板或结构视角的边缘区域会保守留空。彩色/3D 预览可按内存需要选择快速、详细或最高档，不会再减少货架识别使用的帧数。

## 快速开始

### 1. 配置 PC 处理环境

macOS Apple Silicon 推荐：

```bash
tools/SupermarketMapStudio/configure_pc_macos.sh
```

脚本会配置 CMake、Ninja、OpenCV 4、PCL、g2o、OpenMP，并构建 Release 版本的 `rtabmap-reprocess`。已有依赖的其他平台也可手动构建：

```bash
cmake -S . -B build -DBUILD_TOOLS=ON
cmake --build build --target rtabmap-reprocess --config Release -j
```

可选 GPU 地图投影：

```bash
# Apple Silicon / Metal
tools/SupermarketMapStudio/configure_gpu_apple_macos.sh

# Linux / WSL / NVIDIA CUDA，需要带 CUDA 模块的 OpenCV 4
OpenCV_DIR=/path/to/opencv-cuda/lib/cmake/opencv4 \
  tools/SupermarketMapStudio/configure_pc_nvidia.sh
```

GPU 主要用于 RGB-D 密集深度投影。RTAB-Map 数据库回放和 g2o 稀疏图优化仍包含 CPU/串行部分；工作台会在报告中记录实际后端和任何回退。

### 2. 启动工作台

macOS / Linux：

```bash
cd tools/SupermarketMapStudio
./start.sh
```

Windows 可运行：

```bat
tools\SupermarketMapStudio\start.bat
```

浏览器将打开 `http://127.0.0.1:8765/`。选择完整的 `SupermarketSession-*`、确认新的输出目录，然后执行单设备处理或多设备合并。

工作台“导入/管理先验地图”页签可把已有货架 Excel 转换为手机/PC 共用地图包。也可直接运行：

```bash
python3 tools/PriorMap/xlsx_to_prior_map.py /path/to/map.xlsx \
  --output /path/to/PriorMap-output
python3 tools/PriorMap/validate_prior_map.py /path/to/PriorMap-output
```

源 XLSX 只读；输出记录源 SHA-256、楼层、bounds、元素统计、道路连通性、空间索引、warning 和确定性 PNG 预览。

### 3. 直接生成二维地图

```bash
python3 tools/Supermarket2DMap/supermarket_2d_map.py \
  /path/to/SupermarketSession-YYYYMMDD-HHMMSS \
  --output /path/to/Map2D-output
```

### 4. 运行工作台测试

```bash
python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v
```

### 5. 构建 iOS 应用

使用 Xcode 打开 `app/ios/RTABMapApp.xcodeproj`。完整扫描流程需要支持 ARKit 和 LiDAR 的真机，建议使用 iPhone Pro 系列设备。NFC 当前暂停，不属于构建或验收范围。首次构建前仍需按上游 iOS 工程方式准备 RTAB-Map 依赖库和签名；生成的本地 Libraries 目录不会提交到 Git。

## 目录导航

| 路径 | 作用 |
| --- | --- |
| `app/ios/RTABMapApp/` | iOS 采集、会话、状态管理和 Swift/C++ 桥接；NFC 代码仅保留未启用 |
| `app/android/jni/` | 共享移动原生、数据库和渲染能力 |
| `corelib/` | 上游 RTAB-Map 核心 SLAM 与数据库实现 |
| `guilib/` | 上游桌面可视化组件 |
| `tools/Reprocess/` | 本项目扩展后的数据库重处理工具 |
| `tools/Supermarket2DMap/` | 二维、历史阶段和多设备地图生成脚本 |
| `tools/SupermarketMapStudio/` | 本地 Web 工作台、离线处理、GPU helper 和测试 |
| `tools/PriorMap/` | XLSX 先验地图转换、schema、预览、空间索引和定位回放 |
| `docs/map-assisted-localization/` | 可提交的地图辅助定位权威架构、格式、UI、测试和状态文档 |
| `doc/README.md` | 迁移保存的原始 RTAB-Map README |
| `doc/.local/` | 本地开发/交接文档；被 Git 忽略，不属于可提交内容 |

## 质量原则与实现边界

- 输入数据库和 sidecar 不就地修改；重处理和地图生成写入新目录。
- PC 优化使用临时文件、完整性检查和原子发布，失败结果不能覆盖已验证输出。
- 轨迹质量门能发现明显不连续、坏闭环、覆盖不足或异常尺度，但不能在没有实测控制点时证明绝对坐标精度。
- 多设备“共同起点对齐”只是初始值；最终结果需要通过重叠区域、已知距离或人工控制点复核。
- 当前三维成果是由抽样 RGB-D 关键帧重建的彩色表面预览，不是经过全局纹理融合、孔洞修补和封闭处理的交付级 mesh。
- 大型超市正式交付前，应使用闭合路线、已知货架间距或测量控制点做独立验收。

## 文档管理约定

- 根目录 `README.md` 是项目对外入口，应随实现变化同步维护。
- `doc/README.md` 保留上游原始说明，不用于描述本项目新增业务功能。
- Codex 生成的本地分析、交接、调试和阶段性设计文档统一保存在 `doc/.local/`。
- `doc/.local/` 已加入 `.gitignore`；其中内容只作为本机工作资料，不应进入提交或发布包。

## 许可与上游资料

除文件中另有声明的内容外，RTAB-Map 原始代码及 MarketScanner 改编代码均按仓库根目录的 [BSD 3-Clause 许可证](LICENSE) 提供。上游 RTAB-Map 的版权声明保持不变；MarketScanner 改编部分以 `mcjiansheng` 作为公开版权标识。仓库中单独标注许可证的第三方代码和依赖仍遵循各自的许可条款。

使用、分发或二次修改源码时必须保留许可证要求的版权声明、许可条件和免责条款。发布 iOS App、安装包或其他二进制成果时，也应在随附文档或应用内“开源许可/致谢”页面中提供相应声明。许可证管理代码的使用与分发，不决定 GitHub 仓库的协作者或分支写入权限。

- RTAB-Map 官方主页：<https://introlab.github.io/rtabmap/>
- RTAB-Map 上游仓库：<https://github.com/introlab/rtabmap>
- RTAB-Map Wiki：<https://github.com/introlab/rtabmap/wiki>
- 本仓库保存的上游 README：[doc/README.md](doc/README.md)
