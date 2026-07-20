# RTAB-Map 大型超市扫描与地图工作台

> 文档状态：**当前有效**。最后一次与源码交叉核对日期：2026-07-20。

本项目是在开源 **RTAB-Map** 基础上进行的业务化改造，面向大型超市、仓储卖场等室内场景，形成从 iPhone Pro 连续采集，到 PC 端离线优化，再到二维地图、彩色俯视图和三维预览的一套本地工作流。

当前源码中的 RTAB-Map 版本为 **0.23.5**。上游项目原始 README 已保存在 [doc/README.md](doc/README.md)，便于查询 RTAB-Map 官方主页、安装说明、ROS 支持和上游 CI 信息。

> 本仓库不是 RTAB-Map 官方发行版。RTAB-Map 的原始著作权和 BSD 许可仍归原作者所有；本仓库在其通用 SLAM 能力之上增加了超市连续采集、离线处理和地图交付功能。

## 项目目标

原始 RTAB-Map 是一个通用的实时外观建图系统，提供视觉/激光里程计、回环检测、位姿图优化、RGB-D 数据库、点云和占据栅格等能力。本项目保留这些基础能力，并针对实际超市作业补充以下闭环：

```text
iPhone Pro RGB-D / LiDAR / IMU / ARKit 采集
  -> 连续写入单个 RTAB-Map SQLite 数据库
  -> 位姿质量门控、内存与设备安全保护
  -> 完整会话导出到 PC
  -> 数据库检查与自适应离线闭环/全局优化
  -> 轨迹安全验证
  -> 2D 占据图、彩色俯视图、3D 预览与业务图层
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
| iOS 采集 | 增加超市扫描会话、连续流式单库、中文界面、扫描状态、sidecar 数据和外部目录复制 |
| 移动原生层 | 增加相机原点保持、连续地图模式、有界实时渲染、数据库操作和 Swift/C++ 桥接能力 |
| 稳定性 | 对 ARKit tracking 恢复和不合理位姿跳变进行质量门控；按内存、磁盘和热状态降低预览或安全结束 |
| PC 优化 | 扩展 `rtabmap-reprocess` 的进度、约束统计和最终求解流程，支持工作台执行自适应离线优化 |
| 地图生成 | 新增单设备、历史多阶段、多设备二维地图脚本，输出占据图、轨迹、GeoJSON 和质量报告；保留旧价签数据兼容解析 |
| 可视化工作台 | 新增仅监听本机的 Web 工作台，统一进行输入检查、处理编排、2D/3D 预览、日志和结果检查 |
| 性能加速 | 提供 Release/OpenMP 配置，以及 Apple Metal 或 NVIDIA CUDA 深度投影 helper；不可用时明确回退 CPU |

Android 目录中的部分 C++ 原生实现也因共享移动渲染和数据库能力而被扩展，但当前完整的超市现场采集交互主要实现在 iOS 应用中。

## 当前采集方案

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

发生异常瞬跳时，后续原始位姿会重新基准到最后一个可信连续位姿。缓慢累计漂移则由 PC 端视觉/邻近闭环、RGB-D 几何、重力约束、鲁棒核和全局位姿图优化处理。

### 设备资源与数据安全

- 内存压力只缩小在线工作图和实时预览，不主动切换数据库。
- 磁盘空间不足或设备达到严重热状态时先告警并降低预览开销。
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
    trajectory_samples.json
    trajectory_samples.csv
    scan_events.jsonl
```

主要内容：

- `rtabmap_segment_0001.db`：RGB-D 帧、节点、约束、位姿和 RTAB-Map 管理数据。
- `metadata.json`：扫描模式、完成状态、节点数、面积、存储、设备状态和处理配置。
- `price_tags.*`：为旧会话兼容保留；当前扫描不采集 NFC，正常情况下为空。
- `scan_area_cells.json`：移动端轻量覆盖面积估算使用的栅格。
- `trajectory_samples.*`：移动端采样轨迹，供检查和兼容流程使用。
- `scan_events.jsonl`：tracking、中断恢复、内存、热状态、磁盘、闭环和结束事件的结构化日志。

如果会话中仍存在 `live_checkpoint.json`，PC 工作台会把它视为正在写入或异常未完成的数据，拒绝自动重处理。

## PC 端处理

### Supermarket Map Studio

`tools/SupermarketMapStudio/` 是本项目推荐的统一入口。它使用 Python 标准库提供仅绑定 `127.0.0.1` 的本机服务，并在浏览器中完成：

- 连续流式单库、旧版分段会话和多设备会话检查；
- SQLite 完整性、RGB-D/标定、时间戳和节点统计检查；
- `rtabmap-reprocess` 离线闭环与全局优化编排；
- 优化前后轨迹覆盖率、步长、旋转、垂直跨度和尺度验证；
- 二维结构图、彩色 RGB-D 俯视图和 WebGL 三维预览；
- 手机采集日志、PC 处理日志、质量结论与成果文件浏览；
- 已完成结果发现和相同参数结果复用。

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
  preview_3d.json
  preview_frames/
  trajectory.geojson
  price_tags.geojson
  vector_map.geojson
  semantic_layers.json
  quality_report.json
  review_items.json
  source_manifest.json
  rtabmap_optimized/
  offline_processing_report.json
  pc_acceleration_report.json
```

其中 `source_manifest.json` 用于记录输入文件 hash，`quality_report.json` 和 `review_items.json` 用于自动检查及人工复核，`offline_processing_report.json` 记录实际命令、优化路径、耗时、闭环和发布判定。

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
