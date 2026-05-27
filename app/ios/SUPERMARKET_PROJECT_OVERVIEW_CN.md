# 超市扫描与电子价签定位项目说明

## 一、最终项目实现目标

本项目的最终目标是基于 iPhone Pro 设备，将 RTAB-Map 改造为一套面向超市场景的移动扫描、建图和电子价签空间定位系统。

在实际使用中，店员手持 iPhone Pro 在超市中行走扫描。系统利用 iPhone Pro 的相机、LiDAR、IMU、ARKit 位姿能力以及 RTAB-Map 的 SLAM/建图能力，逐步建立超市整体空间结构。同时，店员可以在扫描过程中读取货架或柜台上的电子价签 NFC 信息，系统会将该电子价签的信息与当前空间位置绑定，形成“电子价签信息 - 空间位置 - 地图坐标”的对应关系。

最终系统希望实现以下能力：

### 1. iPhone Pro 高精度空间扫描

- 使用 iPhone Pro 的 LiDAR、相机和 ARKit 位姿能力进行室内扫描。
- 使用 RTAB-Map 保存关键帧、位姿、点云、地图和数据库。
- 支持超市货架、通道、柜台等大面积场景的扫描建模。
- 在扫描过程中尽量保持实时反馈，降低普通店员使用难度。

### 2. 大面积超市动态分段存储

超市面积可能达到上千平方米，单次连续扫描会带来较高内存、数据库和渲染压力。

最终系统应支持：

- 根据已扫描面积自动分段。
- 根据内存占用自动分段。
- 根据数据库大小自动分段。
- 支持手动分段保存。
- 分段保存后自动继续采集，不需要店员重新开始整个任务。
- 每个分段保存为独立数据包，便于后续上传、分析、合并和归档。

### 3. 简洁的二维地图界面

最终用户不是 SLAM 工程师，而是超市现场店员，因此界面应尽量简洁。

最终界面应重点显示：

- 当前二维平面地图。
- 已扫描区域。
- 当前 iPhone 位置和朝向。
- 行走轨迹。
- 已读取的电子价签位置。
- 当前分段编号。
- 扫描面积。
- 内存/保存状态。
- 开始、暂停、手动保存、读取价签等核心按钮。

应尽量隐藏 RTAB-Map 原始界面中的复杂调试信息，例如点云参数、回环边、特征点、网格优化细节等。

### 4. NFC 电子价签读取与空间绑定

超市中的电子价签带有 NFC 卡，卡中包含价签 ID、商品 ID、货架 ID 或其他业务信息。

最终系统应支持：

- iPhone 读取电子价签 NFC。
- 自动记录读取时间。
- 自动记录读取时的空间位置。
- 自动记录当前地图分段。
- 自动记录对应 RTAB-Map 节点或最近关键帧。
- 在二维地图上显示电子价签点位。
- 导出电子价签与空间位置的对应关系表。

最终导出的表应至少包含：

```text
tag_id
tag_payload
product_id
shelf_id
segment_id
node_id
timestamp
x
y
z
roll
pitch
yaw
confidence
```

### 5. 后处理与数据合并

由于超市面积大，最终系统需要支持多个 segment 的后处理。

后续目标包括：

- 跨分段地图合并。
- 跨分段统一坐标系。
- 根据回环或人工标记修正分段之间的位置关系。
- 重新计算电子价签的优化后位置。
- 导出统一的超市二维平面图。
- 导出统一的电子价签空间位置表。

## 二、第一版已经完成的功能

当前第一版的目标不是完成全部最终系统，而是先打通最关键的业务闭环：

```text
iPhone Pro 扫描建图
  -> 动态分段保存
  -> NFC 读取电子价签
  -> 记录价签当前位置
  -> 导出分段数据和价签表
```

第一版主要完成了以下功能。

### 1. 新增超市扫描会话管理

新增文件：

```text
app/ios/RTABMapApp/SupermarketScanSession.swift
```

该模块负责：

- 创建超市扫描会话目录。
- 管理当前 segment 编号。
- 维护当前 segment 的扫描面积估算。
- 保存当前 segment 的电子价签记录。
- 判断是否需要自动分段。
- 输出当前 segment 的元数据和价签表。

第一版生成的数据目录格式为：

```text
Documents/SupermarketSession-YYYYMMDD-HHMMSS/
  segment_0001/
    rtabmap_segment_0001.db
    metadata.json
    price_tags.json
    price_tags.csv
  segment_0002/
    rtabmap_segment_0002.db
    metadata.json
    price_tags.json
    price_tags.csv
```

### 2. 实现扫描面积估算

第一版实现了一个轻量面积估算器。

当前估算方式：

- 使用 iPhone 当前空间位姿中的水平面坐标。
- 沿店员行走轨迹进行栅格化。
- 给轨迹周围设置一个固定扫描半径。
- 根据被覆盖的栅格数量估算已扫描面积。

默认参数：

```text
cellSize = 0.25 m
scanRadius = 1.25 m
```

说明：

第一版面积估算是为了触发动态分段，优先保证稳定和简单。它不是最终的精确二维占据栅格面积。后续可以替换为 RTAB-Map 二维占据栅格面积计算。

### 3. 实现自动分段触发

第一版支持三类自动分段条件：

```text
估算扫描面积 >= 250 m2
RTAB-Map 数据库内存 >= 900 MB
App 已使用内存 >= 2500 MB
```

对应代码位于：

```text
app/ios/RTABMapApp/SupermarketScanSession.swift
```

字段包括：

```swift
areaThresholdM2
databaseThresholdMB
usedMemoryThresholdMB
minimumNodesBeforeRollover
```

当满足条件后，系统会：

1. 暂停当前扫描。
2. 保存当前 RTAB-Map 数据库到当前 segment 目录。
3. 写出当前 segment 的 `metadata.json`。
4. 写出当前 segment 的 `price_tags.json` 和 `price_tags.csv`。
5. 创建下一个 segment。
6. 打开新的临时数据库。
7. 自动恢复扫描。

### 4. 支持手动保存当前分段

第一版在 iOS 菜单中增加了：

```text
Save Current Segment
```

该功能用于现场测试时手动提前保存当前分段。

适用场景：

- 一个通道扫描完成。
- 即将进入另一个大区域。
- 内存还没达到阈值，但希望提前切分数据。
- 测试人员希望验证分段导出流程。

### 5. 接入 NFC 电子价签读取

新增文件：

```text
app/ios/RTABMapApp/PriceTagNFCReader.swift
```

该模块使用 iOS `CoreNFC` 读取 NDEF 格式 NFC 标签。

第一版在菜单中增加：

```text
Read Price Tag NFC
```

读取成功后，系统会记录：

```text
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

这些记录在当前 segment 保存时写出为：

```text
price_tags.json
price_tags.csv
```

### 6. 在 HUD 中显示扫描状态

第一版在现有 HUD 中增加了：

```text
Scanned Area
Segment
```

这样测试人员可以在扫描过程中看到当前估算扫描面积和当前分段编号。

### 7. 配置 iOS NFC 权限

第一版已经在 iOS 工程中加入：

- `CoreNFC.framework`
- `NFCReaderUsageDescription`
- `com.apple.developer.nfc.readersession.formats`

相关文件：

```text
app/ios/RTABMapApp/Info.plist
app/ios/RTABMapApp/RTABMapApp.entitlements
app/ios/RTABMapApp.xcodeproj/project.pbxproj
```

### 8. 提供中文调试文档

已新增中文调试文档：

```text
app/ios/SUPERMARKET_DEBUG_CN.md
```

该文档说明了：

- 如何在 Xcode 中构建。
- 如何使用 iPhone Pro 真机测试。
- 如何测试基础扫描。
- 如何测试 NFC 价签读取。
- 如何检查分段导出文件。
- 如何排查常见问题。

## 三、第一版尚未完成的内容

第一版是可验证业务闭环的原型版本，还没有完成最终系统中的所有功能。

当前尚未完成：

### 1. 还没有专门的干净二维地图界面

目前只是复用原 RTAB-Map iOS 界面，并在 HUD 中增加面积和分段信息。

后续需要新增专门的超市二维平面图界面。

### 2. 价签点还没有绘制到二维地图上

第一版已经记录价签的位置，但还没有在地图中可视化显示价签点。

### 3. 面积不是最终占据栅格面积

第一版使用轨迹扫掠估算面积。

后续应改为基于 RTAB-Map 二维占据栅格计算已探索面积。

### 4. 价签数据还没有写入 RTAB-Map 数据库

第一版使用 sidecar 文件：

```text
price_tags.json
price_tags.csv
```

后续可以扩展 RTAB-Map SQLite schema，将电子价签记录直接写入数据库。

### 5. 暂未支持非 NDEF NFC 标签

第一版使用 `NFCNDEFReaderSession`。

如果实际电子价签使用 ISO15693、MiFare 或只读 UID，需要改用 `NFCTagReaderSession`。

### 6. 暂未做跨分段地图合并

第一版每个 segment 是独立 RTAB-Map 数据库。

后续需要实现：

- 跨 segment 坐标统一。
- 多段地图合并。
- 多段价签位置统一。

### 7. 分段保存时会短暂停顿

第一版采用“暂停、保存、重新开始”的稳定方案。

后续可以优化为后台快照导出或滑动窗口式采集。

## 四、第一版验收重点

第一版建议重点验收以下内容：

1. iPhone Pro 是否能正常扫描建图。
2. HUD 是否显示扫描面积和 segment 编号。
3. 手动保存 segment 是否成功。
4. 自动达到阈值后是否能保存 segment 并继续采集。
5. NFC 是否能读取电子价签。
6. NFC 信息是否能写入 `price_tags.csv/json`。
7. 每个 segment 是否都生成 RTAB-Map 数据库。
8. 长时间扫描时，内存压力是否比原始连续扫描更可控。

## 五、建议的后续开发顺序

建议按以下顺序继续推进：

1. 在 iPhone Pro 真机上完成第一版构建和基础测试。
2. 根据真实超市场景调整分段阈值。
3. 确认电子价签 NFC 卡类型，决定是否需要支持非 NDEF。
4. 增加价签点在地图上的可视化。
5. 开发简洁二维地图界面。
6. 使用真实二维占据栅格计算扫描面积。
7. 设计跨 segment 合并方案。
8. 将价签数据写入 RTAB-Map 数据库或统一业务数据库。
