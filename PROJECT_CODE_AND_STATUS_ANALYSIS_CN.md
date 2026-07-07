# RTAB-Map 超市扫描项目代码与状态分析

日期：2026-07-07

本文档基于当前仓库中的 README、中文交接文档、iOS/Android native 入口、核心 C++ 模块和 `tools/Supermarket2DMap` 离线工具整理。目标是帮助后续开发者快速理解：原始项目做什么、本地改造要解决什么、当前已经完成哪些功能、仍待完成哪些功能、主要实现逻辑，以及当前可见的风险和缺陷。

本次只阅读和整理代码/文档，没有修改现有代码。

## 一、项目总体定位

### 1. 原始项目

本仓库是 RTAB-Map，完整名称为 Real-Time Appearance-Based Mapping。它是一个以 C++ 为核心的实时 SLAM / 建图系统，主要能力包括：

- RGB-D、双目、单目、LiDAR、IMU 等传感器输入。
- 视觉里程计、回环检测、图优化。
- 点云地图、二维占据栅格、OctoMap 等地图表达。
- SQLite 数据库存储。
- Qt 桌面 GUI。
- Android / iOS 移动端入口。
- ROS / ROS 2 集成。
- 数据库查看、导出、后处理等工具链。

原始目录职责大致如下：

```text
corelib/       RTAB-Map 核心算法、数据库、图优化、地图生成
guilib/        Qt 桌面 GUI 库
app/           桌面、Android、iOS 应用入口
tools/         数据库查看、导出、后处理、数据集转换等工具
examples/      示例程序
utilite/       通用工具库
docker/        构建和运行环境
```

当前 `README.md` 和 `package.xml` 显示项目版本线在 `0.23.x`，顶层 `CMakeLists.txt` 中版本为 `0.23.5`。

### 2. 本地业务改造

当前仓库不是纯上游 RTAB-Map，已经叠加了面向“iPhone Pro 超市扫描 + 电子价签定位”的改造。业务目标是：

```text
店员手持 iPhone Pro 扫描超市
  -> 使用 ARKit / LiDAR / RTAB-Map 建图
  -> 大面积场景自动分段保存
  -> 扫描时读取电子价签 NFC
  -> 将价签信息绑定到当前空间位姿和 segment
  -> 导出分段数据库、sidecar 数据、二维地图包
  -> 后续合并分段和生成完整超市二维地图
```

这类场景和普通房间扫描的差异很明显：面积更大、重复货架更多、长走廊更容易漂移、单个数据库更容易过大，保存和导出阶段也更容易触发内存或 I/O 峰值。

## 二、关键代码入口

### 1. iOS Swift 层

核心文件：

```text
app/ios/RTABMapApp/ViewController.swift
app/ios/RTABMapApp/RTABMap.swift
app/ios/RTABMapApp/SupermarketScanSession.swift
app/ios/RTABMapApp/PriceTagNFCReader.swift
app/ios/RTABMapApp/NativeWrapper.hpp
app/ios/RTABMapApp/NativeWrapper.cpp
```

主要职责：

- `ViewController.swift`：iOS 主控制器，负责 ARSession、菜单、状态机、分段触发、NFC 入口、合并入口、2D 地图入口。
- `RTABMap.swift`：Swift 封装层，把 Swift 调用转换为 native C 接口。
- `NativeWrapper.cpp/.hpp`：Objective-C++ / C++ 桥接层，调用 Android/JNI 目录中复用的 `RTABMapApp` C++ 类。
- `SupermarketScanSession.swift`：新增的超市扫描会话管理模块。
- `PriceTagNFCReader.swift`：新增的 NFC NDEF 价签读取模块。

iOS 每帧数据主链路仍是：

```text
ARSession didUpdate frame
  -> ViewController.session(_:didUpdate:)
  -> RTABMap.postOdometryEvent(frame:)
  -> postOdometryEventNative(...)
  -> RTABMapApp::postOdometryEvent(...)
  -> RTAB-Map core
```

### 2. 复用的 Android/JNI C++ 层

iOS native 实际复用了不少 `app/android/jni` 下的 C++ 代码：

```text
app/android/jni/RTABMapApp.cpp
app/android/jni/RTABMapApp.h
app/android/jni/CameraMobile.cpp
app/android/jni/scene.cpp
```

当前超市改造相关的 native 能力包括：

- `RTABMapApp::save()`：保存当前数据库。
- `RTABMapApp::mergeDatabases()`：合并多个分段数据库。
- `RTABMapApp::setPreserveCameraOrigin()`：分段保存前后保留移动端相机原点偏移，降低分段边界折角风险。
- `CameraMobile` 中的 relocalization / origin offset 逻辑：影响长走廊、来回扫描和分段连续性。

### 3. 离线工具

新增或当前相关工具：

```text
tools/Supermarket2DMap/supermarket_2d_map.py
tools/Supermarket2DMap/README_CN.md
```

这个 Python 工具用于从分段扫描结果生成离线二维地图包。它可以读取：

- `segment_*/metadata.json`
- `segment_*/price_tags.json`
- `segment_*/*.db` 中的 `Node.pose`
- 可选 `points.csv`

输出包括：

- `occupancy_grid.png`
- `occupancy_grid.yaml`
- `preview.png`
- `vector_map.geojson`
- `semantic_layers.json`
- `price_tags.geojson`
- `trajectory.geojson`
- `quality_report.json`
- `source_manifest.json`
- `review_items.json`

当前离线工具可以做轨迹 free-space 栅格化、价签读取、GeoJSON 输出、冲突/未知/可通行/占据统计和质量报告，但还没有直接解码 RTAB-Map 数据库中的 `Data.ground_cells / obstacle_cells / empty_cells` blob。

## 三、当前已经完成的功能

### 1. 超市扫描会话和分段目录

`SupermarketScanSession` 已实现 session 和 segment 管理。输出目录形态为：

```text
Documents/SupermarketSession-YYYYMMDD-HHMMSS/
  segment_0001/
    rtabmap_segment_0001.db
    metadata.json
    price_tags.json
    price_tags.csv
    scan_area_cells.json
    trajectory_samples.json
    trajectory_samples.csv
  segment_0002/
    ...
```

与早期文档相比，当前代码已经不只输出数据库和价签表，还额外写出：

- `scan_area_cells.json`：轨迹扫掠覆盖格。
- `trajectory_samples.json/csv`：扫描轨迹采样。

这些 sidecar 文件支撑手机端快速二维预览和离线二维地图生成。

### 2. 扫描面积估算

当前面积估算由 `FloorAreaEstimator` 完成：

- 使用位姿的 `x/z` 作为水平面坐标。
- 沿轨迹插值。
- 用固定半径圆盘标记栅格。
- 覆盖格数乘以栅格面积得到估算面积。

默认参数：

```text
cellSize = 0.25 m
scanRadius = 1.25 m
```

这不是精确的货架/墙体/地面占据图，只是为了稳定触发分段和快速展示覆盖范围。

### 3. 自动分段保存

当前自动分段在 `ViewController.statsUpdated(...)` 中触发。每次 RTAB-Map stats 更新时，代码会：

1. 更新节点数、数据库内存、最新位姿。
2. 更新当前 segment 的估算面积。
3. 显示 HUD 信息，包括：
   - `RAM Usage`
   - `Segment RAM Growth`
   - `Scanned Area`
   - `Segment`
4. 如果处于 `STATE_MAPPING` 且自动分段开启，调用 `SupermarketScanSession.rolloverReason(...)` 判断是否保存当前段。

当前默认阈值已经比早期第一版文档更保守：

```text
面积阈值 = 120 m2
数据库阈值 = 700 MB
分段内内存增长阈值 = 1200 MB
最少节点数 = 30
```

触发条件为：

```text
估算面积 >= 面积阈值
或 RTAB-Map 数据库内存 >= 数据库阈值
或 当前分段内 App 内存增长 >= 内存阈值
```

同时要求节点数达到 `minimumNodesBeforeRollover`，避免刚开始扫描时过早切分。

### 4. 手动保存当前分段

菜单中已加入：

```text
Save Current Segment
```

手动保存会调用：

```text
ViewController.rolloverCurrentSegment(reason: .manual)
```

适用于现场测试、通道结束、进入新区域前主动切段。

### 5. 稳定优先的两阶段外部保存

当前不是让 native RTAB-Map 直接写外接盘或文件提供器目录，而是：

```text
1. 暂停 ARSession / location / RTAB-Map mapping / camera
2. native 层保存数据库到 App Documents 内的 segment 目录
3. Swift 写出 metadata、价签、轨迹、覆盖格等 sidecar
4. 打开新的临时数据库
5. 恢复下一段扫描
6. 如果用户选择了外部目录，后台复制 segment
7. 校验文件数量和总字节数
8. 校验成功后删除本地 segment 副本
```

这个策略可以降低 iOS security-scoped URL、文件提供器、外接盘同步延迟等问题对 native 保存的影响。

### 6. NFC 电子价签读取和绑定

已新增：

```text
app/ios/RTABMapApp/PriceTagNFCReader.swift
```

当前使用 `NFCNDEFReaderSession` 读取 NDEF 标签。读取成功后，在 `ViewController.readPriceTagNFC()` 中把当前最新 pose、当前节点数、当前 segment 编号和 NFC payload 写入 `SupermarketScanSession.priceTags`，segment 保存时输出到：

```text
price_tags.json
price_tags.csv
```

字段包括：

```text
id
tagIdentifier
payload
timestamp
segmentIndex
nodeCount
x
y
z
roll
pitch
yaw
note
```

### 7. 分段数据库合并

当前已经实现了“合并已保存分段”：

```text
ViewController.mergeSavedSegments()
  -> RTABMap.mergeDatabases(inputDatabasePaths:, outputDatabasePath:)
  -> mergeDatabasesNative(...)
  -> RTABMapApp::mergeDatabases(...)
```

C++ 实现会：

- 校验至少两个输入 `.db`。
- 校验输入文件存在且含节点。
- 创建输出数据库 `SupermarketMerged-yyMMdd-HHmmss.db`。
- 用 `DBReader` 依次重放各数据库中的 `SensorData`。
- 使用 `Mem/GenerateIds=true` 避免多库节点 ID 冲突。
- 遇到高协方差 odometry 时触发 `merged.triggerNewMap()`。
- 完成后保存合并数据库。

合并成功后，App 会自动打开新的合并数据库供查看和后续优化。

### 8. 手机端 2D 地图包

`SupermarketScanSession.generate2DMapPackage()` 已实现手机端轻量 2D 地图包生成。它读取已保存 segment 的 sidecar，输出：

```text
Map2D-YYYYMMDD-HHMMSS/
  occupancy_grid.png
  occupancy_grid.yaml
  overview_map.png
  preview.png
  trajectory_samples.json
  semantic_layers.json
  price_tags.geojson
  quality_report.json
  map.json
```

当前手机端 2D 图本质是“扫描覆盖证据图”：

- 白色表示轨迹扫掠后的已覆盖区域。
- 边界为估算覆盖边界。
- 轨迹按 segment 着色。
- 价签点叠加显示。

它还不是从点云/局部栅格生成的真实货架、墙体、障碍物结构图。

### 9. 离线二维地图工具

`tools/Supermarket2DMap/supermarket_2d_map.py` 已实现更完整的离线地图生成管线，支持：

- 解析 RTAB-Map `Node.pose`。
- 多 segment 输入。
- 轨迹 free-space 栅格化。
- 可选 `points.csv` occupied/free 结构点融合。
- 价签 GeoJSON。
- 轨迹 GeoJSON。
- 矢量结构草图。
- 质量报告和待复核项。
- 输入文件 hash 追踪。
- 可选人工 `corrections.json` 和自动段间平移/yaw 对齐。

这部分适合作为下一阶段“更真实二维地图”的基础。

### 10. 中文本地化和设置项

当前已存在：

```text
app/ios/RTABMapApp/zh-Hans.lproj/Localizable.strings
app/ios/RTABMapApp/zh-Hans.lproj/Main.strings
app/ios/Settings.bundle/zh-Hans.lproj/Mapping.strings
```

Xcode 工程里也加入了 `zh-Hans` 区域和 `Localizable.strings` 资源。

App 内“Supermarket Scan Settings”提供：

- 启用/禁用自动分段。
- 设置面积阈值。
- 设置数据库阈值。
- 设置内存阈值。
- 设置最少节点数。
- 选择保存位置。
- 恢复默认位置。

Settings.bundle 里也有对应阈值设置。

## 四、核心实现逻辑

### 1. 新建扫描

主流程位于 `ViewController.newScan(...)`：

```text
newScan
  -> applySupermarketSettings()
  -> supermarketSession.startNewSessionIfNeeded()
  -> supermarketSession.resetCurrentSegment()
  -> rtabmap.setPreserveCameraOrigin(false)
  -> rtabmap.openDatabase(tmpDatabase, clearDatabase: true)
  -> mSegmentStartUsedMemoryMB = 当前已用内存
  -> startCamera()
```

超市扫描正常建图时强制使用磁盘数据库，避免大面积扫描把数据库长期放在内存中。

### 2. 统计更新与分段触发

主流程位于 `ViewController.statsUpdated(...)`：

```text
statsUpdated
  -> 计算 usedMem / segmentUsedMem
  -> 更新 mMapNodes / mLatestDatabaseMemoryMB / mLatestPose
  -> supermarketSession.updateArea(...)
  -> HUD 显示面积和 segment
  -> rolloverReason(nodes, databaseMemoryMB, segmentUsedMem)
  -> rolloverCurrentSegment(reason)
```

内存判断使用“当前分段开始后的内存增长”，不是 App 启动后的总内存占用。这个修复避免第一次保存、复制、重开数据库后留下的缓存导致后续分段越来越短。

### 3. 分段保存

主流程位于 `ViewController.rolloverCurrentSegment(...)`：

```text
rolloverCurrentSegment
  -> 防重入 isExportingSegment
  -> 检查 mMapNodes > 0
  -> currentSegmentDirectory()
  -> 检查本地可用空间
  -> pause ARSession / location / mapping / camera
  -> setPreserveCameraOrigin(true)
  -> updateState(.STATE_PROCESSING)
  -> 后台 rtabmap.save(databasePath)
  -> 后台 writeSidecarFiles(...)
  -> nextSegment()
  -> openDatabase(tmpDatabase, clearDatabase: true)
  -> startCamera(resetTracking: false)
  -> 恢复 mapping 或 camera 状态
  -> 如有外部保存位置，后台复制和清理
```

保存期间会短暂停顿，这是当前设计的安全边界。因为下一段必须从干净临时库开始，上一段必须先完成本地落盘，才不会混淆分段数据边界。

### 4. 分段连续性保护

当前分段保存前调用：

```text
rtabmap?.setPreserveCameraOrigin(enabled: true)
```

C++ 层 `RTABMapApp::setPreserveCameraOrigin()` 会保存 `CameraMobile` 的 origin offset，避免 stop/start 后重新定义移动端相机原点，降低长走廊分段边界出现明显折角的概率。

但这不是全局对齐算法，只是减少分段边界的突然跳变。ARKit 自身的缓慢 yaw 漂移、重复货架错误回环、长通道特征不足仍需要后处理。

### 5. 合并分段

用户点击 `Merge Saved Segments` 后：

```text
如果当前仍在 mapping 且有未保存节点
  -> 先保存当前 segment，resumeAfterSave=false
  -> 再递归进入 mergeSavedSegments

否则
  -> 找到所有 rtabmap_segment_*.db
  -> 至少需要两个
  -> 调 native mergeDatabases
  -> 成功后打开 SupermarketMerged-*.db
```

合并的本质是重放多个数据库中的传感器数据到一个新的 RTAB-Map 数据库，而不是自动保证货架/墙体严格对齐。

### 6. 2D 地图包生成

手机端 `Generate 2D Map Package`：

```text
如果当前仍在 mapping 且有未保存节点
  -> 先保存当前 segment，resumeAfterSave=false
  -> 再生成 2D map

否则
  -> 读取 scan_area_cells / trajectory_samples / price_tags / metadata
  -> 合并覆盖格、轨迹、价签确定边界
  -> 平滑覆盖格
  -> 输出 occupancy_grid / preview / geojson / quality_report
  -> 打开 preview.png 全屏预览
```

离线 `tools/Supermarket2DMap` 则可以进一步读取 `.db` 里的节点位姿和可选结构点，输出更丰富的地图交付包。

## 五、当前待完成内容

### 1. 真正的专用超市二维地图界面

当前 iOS 主界面仍是 RTAB-Map 原始扫描/查看界面，加了一些菜单和 HUD。手机端 2D 地图只是生成后预览 `preview.png`，还不是一个完整的可交互超市平面图界面。

后续应实现：

- 实时或近实时二维地图视图。
- 当前设备位置和朝向。
- 分段轨迹显示。
- 价签点显示和点击查看 payload。
- 保存/合并/导出状态。
- 问题区域或低置信区域标记。

### 2. 价签点尚未写入 RTAB-Map 数据库

当前价签数据只在 sidecar 中：

```text
price_tags.json
price_tags.csv
price_tags.geojson
```

合并后的 `SupermarketMerged-*.db` 不会自动包含价签记录。若后续要在 3D 地图或 RTAB-Map 数据库中直接查询价签，需要设计：

- 扩展 SQLite schema。
- 或独立业务数据库。
- 或 sidecar 到数据库的导入工具。

### 3. NFC 仅支持 NDEF

当前 `PriceTagNFCReader` 使用 `NFCNDEFReaderSession`。如果真实电子价签是 ISO15693、MiFare、Felica 或只读 UID，需要改用 `NFCTagReaderSession`，并相应调整 entitlement、读取逻辑和字段解析。

### 4. 精确面积和真实结构图仍未完成

当前面积和手机端 2D 图都基于轨迹扫掠覆盖，不是 RTAB-Map 局部 occupancy grid 或 LiDAR 点云投影后的真实结构图。

后续需要：

- 从 RTAB-Map 数据库提取局部 grid 或点云。
- 生成 `points.csv` 或直接在离线工具中解码 blob。
- 做高度过滤、射线清空、occupied/free 概率融合。
- 生成货架、墙体、障碍物和通道边界。

### 5. 跨分段自动校正仍不充分

当前已有数据库合并，但合并不是“魔法对齐”。它不能自动解决：

- 重复货架导致错误回环。
- 长走廊 yaw 漂移。
- 分段边界弱约束。
- 大范围累计弯曲。
- 同一货架边界出现双线。

后续需要结合：

- 相邻 segment 重叠检测。
- 2D ICP / NDT / 栅格相关匹配。
- 结构线匹配。
- 人工锚点。
- 位姿图优化。
- 段间质量报告。

### 6. 采样频率仍需要实测调参

当前文档建议默认不贸然提高采样频率。更高频率能改善转角和价签附近定位，但也会线性增加节点数、数据库增长、内存压力和分段频率。

后续可以做动态策略：

- 根据 `updateTime`。
- 根据分段内存增长。
- 根据数据库增长。
- 根据 fast movement。
- 根据 tracking quality。

### 7. 自动化测试和真机验证仍不足

仓库中有文档记录曾执行 iOS Debug 真机构建，但当前阅读未再次运行 Xcode 构建或真机测试。由于 ARKit、LiDAR、NFC、外接存储和 increased memory entitlement 都依赖真机环境，后续必须在真实 iPhone Pro 上验证。

## 六、当前可见问题和缺陷

### 1. NFC 权限配置与文档不一致

现有中文文档说已经配置：

```text
NFCReaderUsageDescription
com.apple.developer.nfc.readersession.formats
CoreNFC.framework
```

但当前源码检查结果是：

- `CoreNFC.framework` 已加入 Xcode 工程。
- `PriceTagNFCReader.swift` 已存在并 import `CoreNFC`。
- `app/ios/RTABMapApp/Info.plist` 当前未看到 `NFCReaderUsageDescription`。
- `app/ios/RTABMapApp/RTABMapApp.entitlements` 当前只看到 increased memory entitlement，未看到 `com.apple.developer.nfc.readersession.formats`。

影响：

- App 在真机上启动 NFC 读取时可能失败。
- App Store / 系统权限检查可能拒绝使用 NFC。
- 文档和实际工程状态不一致，容易误导调试。

建议优先补齐并在 Xcode Signing & Capabilities 中确认 NFC capability。

### 2. Info.plist 设备能力仍较宽泛

`Info.plist` 中 `UIRequiredDeviceCapabilities` 包含 `arkit`，但没有强制 LiDAR。业务目标明确偏向 iPhone Pro / Pro Max + LiDAR，如果要避免非 LiDAR 设备误用，需要在 UI 或能力检测中明确提示。是否在 plist 强制限制设备，需要看发布策略。

### 3. 外部复制校验较轻量

当前外部复制后的校验是目录内文件数量和总字节数。这能发现常见的复制中断或漏文件，但不能证明每个文件内容完全一致。

如果后续用于正式交付，建议增加：

- 文件清单。
- 单文件大小。
- SHA-256 hash。
- 复制完成后的 manifest。

### 4. Sidecar 写入失败不会阻止 segment 继续

`rolloverCurrentSegment` 中后台写 sidecar 失败时会 `print`，但流程仍继续。这样可以避免保存流程被辅助文件阻断，但风险是：

- `.db` 已保存，metadata/price_tags/trajectory/area 文件缺失。
- 后续 2D 地图或价签导出不完整。
- 用户可能只看到“segment saved”的 toast。

建议后续在 sidecar 写入失败时给用户明确提示，并在 segment 目录写一个错误标记或质量报告。

### 5. 合并数据库不合并价签 sidecar

当前 C++ 合并只处理 RTAB-Map 数据库。价签仍在各 segment 的 sidecar 中。手机端和离线 2D 工具可以读取这些 sidecar，但合并后的 `.db` 本身没有价签语义。

影响：

- 打开 `SupermarketMerged-*.db` 看 3D 地图时，价签不可见。
- 如果只传递合并数据库，业务数据会丢失。

建议把“合并后的地图数据库”和“价签/语义 sidecar 包”作为一个整体交付，或实现 sidecar 合并。

### 6. 手机端 2D 地图容易被误解为结构地图

当前手机端 `preview.png` 是覆盖图，不是真实墙体/货架占据图。文档中已有警告，但产品层面仍容易被误解。

建议在 UI 或 `quality_report.json` 中保持明确标识：

```text
该图为扫描覆盖证据图，不代表最终货架/墙体结构。
```

### 7. 分段保存仍会暂停

当前分段保存会暂停采集、保存数据库、写 sidecar、打开新数据库再恢复。这是稳定优先方案，但现场用户会感知短暂停顿。超大分段仍可能因本地落盘和数据库 close/flush 产生较长暂停。

建议继续用更保守阈值控制单段大小，不建议追求很大单段。

### 8. 长走廊和重复货架仍是算法风险

即使已保留 camera origin，以下问题仍未彻底解决：

- ARKit 缓慢 yaw 漂移。
- 货架重复纹理导致错误匹配。
- 长直通道缺少可区分特征。
- 来回扫描产生夹角分叉。
- 动态人员/购物车污染结构。

这类问题需要扫描路线、回环策略、结构后处理和人工校正共同解决。

### 9. 当前工作区存在未提交改动和生成文件

当前 `git status --short` 显示存在已修改文件和未跟踪文件，包括：

```text
.gitignore
app/ios/RTABMapApp/Base.lproj/Main.storyboard
app/ios/RTABMapApp/Info.plist
app/ios/RTABMapApp/RTABMapApp.entitlements
app/ios/SUPERMARKET_*.md
corelib/include/rtabmap/core/Version.h
corelib/include/rtabmap/core/rtabmap_core_export.h
guilib/include/rtabmap/gui/rtabmap_gui_export.h
utilite/include/rtabmap/utilite/utilite_export.h
```

其中 `*_export.h` 和 `Version.h` 可能是 CMake 生成或本地构建产物，需要确认是否应纳入版本管理。后续开发前建议先整理工作区，避免把构建产物和业务改动混在一起提交。

## 七、建议的后续开发顺序

### 阶段 1：先修配置和真机基础验证

优先级最高：

1. 补齐 NFC `Info.plist` 和 entitlements 配置。
2. 在 Xcode Signing & Capabilities 确认 NFC 和 Increased Memory Limit。
3. iPhone Pro 真机测试基础扫描。
4. 测试 `Save Current Segment`。
5. 测试 NFC 读取并确认 `price_tags.csv/json`。
6. 测试外部目录保存、后台复制、校验和本地清理。
7. 测试 `Merge Saved Segments`。
8. 测试 `Generate 2D Map Package`。

### 阶段 2：收敛数据包格式

建议定义一个稳定交付包规范：

```text
SupermarketSession-*/
  manifest.json
  segment_0001/
    rtabmap_segment_0001.db
    metadata.json
    price_tags.json
    scan_area_cells.json
    trajectory_samples.json
  Map2D-*/
  SupermarketMerged-*.db
```

重点是把 `.db`、sidecar、2D map、质量报告和 hash manifest 绑定起来，避免只传一个文件导致业务语义丢失。

### 阶段 3：增强二维地图结构层

在 `tools/Supermarket2DMap` 基础上推进：

1. 从 RTAB-Map 数据库提取局部 grid 或点云到 `points.csv`。
2. 做高度过滤和 occupied/free 证据融合。
3. 输出结构层，而不只是轨迹覆盖层。
4. 增加段间错位、双线、冲突区域的质量报告。
5. 形成可回归的测试数据集。

### 阶段 4：段间校正和人工锚点

建议实现：

- `corrections.json` 人工校正工作流。
- 价签/柱子/入口/货架端点作为锚点。
- 2D ICP 或栅格相关匹配。
- 结构线方向聚类。
- 合并质量评分。

### 阶段 5：产品化界面

在数据链路稳定后再做：

- 专用超市二维地图界面。
- 实时扫描覆盖显示。
- 价签点可视化。
- 分段状态、外部复制状态、错误状态。
- 地图包导出和分享。
- 低置信区域复核。

## 八、验收建议

### 1. 小区域功能闭环

测试目标：

- 扫描 10-30 平方米。
- 手动保存 segment。
- 读取 2-3 个 NFC 标签。
- 生成 2D map package。
- 检查文件完整性。

验收点：

- `.db` 存在。
- `metadata.json` 存在且 segmentIndex 正确。
- `price_tags.csv/json` 含 NFC 记录。
- `trajectory_samples` 和 `scan_area_cells` 存在。
- `preview.png` 可打开。

### 2. 自动分段

测试目标：

- 临时降低面积阈值，例如 5-10 m2。
- 连续扫描直到自动保存。

验收点：

- HUD segment 编号递增。
- 保存后自动继续 mapping。
- 新 segment 重新累计面积和内存增长。
- 没有出现重复保存或防重入失败。

### 3. 外部保存

测试目标：

- 选择外接盘或文件 App 中的目录。
- 保存多个 segment。

验收点：

- 本地先保存成功。
- 后台复制成功。
- 外部目录出现完整 session。
- 本地已完成 segment 在校验后被清理。
- 外部复制失败时本地副本保留。

### 4. 分段连续性

测试目标：

- 长直走廊扫描。
- 在中途手动保存 segment。
- 继续沿直线扫描。

验收点：

- 分段边界处轨迹没有明显折角。
- 合并数据库后轨迹大体连续。
- 若出现偏移，记录 ARKit tracking 状态、回环提示和分段前后位姿。

### 5. 真实超市场景

建议至少采集：

- 一条长通道。
- 来回扫描同一通道。
- 多个相邻货架通道。
- 有人员移动的区域。
- 带价签的货架。
- 至少 3 个 segment。

验收点：

- 分段稳定。
- 保存和外部复制稳定。
- 合并后可打开。
- 价签在覆盖图中大致落在扫描轨迹附近。
- 质量报告能指出明显风险。

## 九、结论

当前项目已经从“原始 RTAB-Map iOS App”推进到了“超市扫描原型”阶段。核心数据闭环基本具备：

```text
iPhone Pro 扫描
  -> 自动/手动分段
  -> 每段保存 RTAB-Map 数据库
  -> NFC 价签绑定当前位姿
  -> sidecar 数据输出
  -> 外部保存位置后台复制
  -> 分段数据库合并
  -> 手机端覆盖图预览
  -> 离线二维地图包生成
```

目前最需要优先处理的是工程一致性和真机验证，尤其是 NFC 权限配置与文档不一致的问题。算法层面，当前手机端二维图是覆盖图，不是最终货架/墙体结构图；分段合并也不是完整自动对齐。下一阶段应围绕“稳定采集 + 可追溯数据包 + 离线结构地图 + 段间校正 + 人工复核”继续推进。
