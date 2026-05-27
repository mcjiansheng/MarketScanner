# 给 macOS Codex 的项目交接说明

本文档用于帮助 macOS 环境中的 Codex 快速理解该项目的原始结构、业务目标、第一版改造方向和后续调试重点。

由于 Windows 环境和 macOS 环境中的项目文件不互通，macOS Codex 可能面对的是一份原始 RTAB-Map 项目，也可能面对的是部分已修改项目。请先根据本文档理解目标，再检查本地代码状态。

## 一、原始项目概况

该项目是 RTAB-Map。

RTAB-Map 是一个 C++ 为主的实时 SLAM / 建图系统，全称大致为：

```text
Real-Time Appearance-Based Mapping
```

项目能力包括：

- RGB-D / 双目 / 单目 / LiDAR / IMU 数据采集。
- 视觉里程计。
- 回环检测。
- 图优化。
- 点云地图。
- 二维占据栅格地图。
- 数据库存储。
- Qt 桌面 GUI。
- Android / iOS 移动端入口。
- ROS / ROS2 相关集成。

原始项目主要目录：

```text
corelib/       RTAB-Map 核心算法和数据库逻辑
guilib/        桌面 GUI 库
app/           桌面、Android、iOS 应用入口
tools/         数据库查看、导出、后处理等工具
examples/      示例程序
utilite/       通用工具库
```

和本次任务最相关的目录是：

```text
app/ios/RTABMapApp/
app/android/jni/
corelib/
```

需要注意：iOS App 复用了部分 Android/JNI 目录中的 C++ 场景代码，例如：

```text
app/android/jni/RTABMapApp.cpp
app/android/jni/RTABMapApp.h
app/android/jni/scene.cpp
app/android/jni/CameraMobile.cpp
```

iOS Swift 层通过 Objective-C++ / C++ wrapper 调用 native RTAB-Map 逻辑：

```text
app/ios/RTABMapApp/RTABMap.swift
app/ios/RTABMapApp/NativeWrapper.hpp
app/ios/RTABMapApp/NativeWrapper.cpp
```

现有 iOS 主界面和 ARKit 数据入口在：

```text
app/ios/RTABMapApp/ViewController.swift
```

ARKit 每帧数据大致流程为：

```text
ARSession didUpdate frame
  -> RTABMap.swift postOdometryEvent(frame:)
  -> NativeWrapper.cpp postOdometryEventNative()
  -> RTABMapApp.cpp postOdometryEvent()
  -> RTAB-Map core
```

## 二、本次业务场景

目标使用场景是超市场景。

店员手持 iPhone Pro 在超市中行走扫描。系统需要利用 iPhone Pro 的相机、LiDAR、IMU、ARKit 位姿能力，以及 RTAB-Map 的 SLAM / 建图能力，建立超市整体空间结构。

同时，超市货架或柜台上的电子价签带有 NFC 卡。店员在扫描过程中靠近电子价签，用 iPhone 读取 NFC 信息。系统需要将该电子价签信息与当前空间位置绑定，形成电子价签和空间位置的对应关系。

核心业务闭环：

```text
iPhone Pro 扫描超市
  -> RTAB-Map 建图
  -> 根据面积/内存/数据库大小动态分段保存
  -> 读取电子价签 NFC
  -> 记录价签信息和当前位置
  -> 导出每个分段的地图数据库和价签位置表
```

## 三、最终项目目标

最终系统希望实现：

### 1. iPhone Pro 高精度扫描

- 优先支持 iPhone Pro / Pro Max。
- 使用 ARKit + LiDAR + 相机 + IMU。
- 尽量使用 RTAB-Map 保存关键帧、位姿、地图和数据库。
- 适配超市中货架、通道、柜台等大面积室内环境。

### 2. 大面积动态分段存储

超市可能有上千平方米。实际测试中，连续扫描 200-300 平方米就可能导致较高内存压力。

最终系统需要支持：

- 根据扫描面积自动分段。
- 根据 App 内存占用自动分段。
- 根据 RTAB-Map 数据库占用自动分段。
- 支持手动分段保存。
- 保存分段后自动继续采集。
- 每个分段形成独立数据包，后续可上传、归档、合并。

### 3. 简洁二维地图界面

现场店员不需要完整 RTAB-Map 调试界面。

最终界面应显示：

- 当前二维平面地图。
- 已扫描区域。
- 当前 iPhone 位置和朝向。
- 轨迹。
- 已读取电子价签位置。
- 当前 segment 编号。
- 扫描面积。
- 保存/导出状态。

复杂调试内容应隐藏，例如特征点、回环边、点云参数等。

### 4. NFC 电子价签与空间位置绑定

读取 NFC 后记录：

```text
tagIdentifier
payload
timestamp
segmentIndex
nodeId 或 nodeCount
x
y
z
roll
pitch
yaw
note
```

后续应支持：

- 将价签点显示在二维地图上。
- 导出 CSV / JSON / 数据库表。
- 在跨 segment 合并后重新计算价签统一坐标。

### 5. 后处理与跨分段合并

后续阶段需要：

- 多个 segment 统一坐标系。
- 多个 RTAB-Map 数据库合并。
- 价签点跨 segment 统一。
- 导出完整超市平面图和价签位置表。

## 四、第一版目标

第一版不要求完成最终系统全部能力，优先打通业务闭环。

第一版应实现：

```text
1. iPhone Pro 正常扫描建图
2. HUD 显示估算扫描面积和 segment 编号
3. 达到阈值自动保存当前 segment
4. 保存后自动继续扫描下一个 segment
5. 支持手动保存当前 segment
6. 支持读取 NFC 电子价签
7. 记录 NFC 信息与当前位姿
8. 每个 segment 输出 RTAB-Map 数据库和价签表
```

第一版不强求：

```text
1. 专门的漂亮二维地图界面
2. 价签点可视化
3. 精确二维占据栅格面积
4. 跨 segment 自动合并
5. 将价签写入 RTAB-Map SQLite schema
```

## 五、Windows 环境中已经设计/实现过的第一版改动

如果 macOS 项目中尚未包含这些改动，请按本节重新实现。

### 1. 新增 SupermarketScanSession.swift

建议路径：

```text
app/ios/RTABMapApp/SupermarketScanSession.swift
```

职责：

- 管理超市扫描 session 根目录。
- 管理当前 segment 编号。
- 估算当前扫描面积。
- 判断是否需要自动分段。
- 保存当前 segment 的价签记录。
- 写出 `metadata.json`、`price_tags.json`、`price_tags.csv`。

建议包含的数据结构：

```swift
struct PriceTagRecord: Codable
struct ScanSegmentMetadata: Codable
enum SegmentTriggerReason: String
final class FloorAreaEstimator
final class SupermarketScanSession
```

第一版默认阈值：

```swift
areaThresholdM2 = 250
databaseThresholdMB = 900
usedMemoryThresholdMB = 2500
minimumNodesBeforeRollover = 30
```

第一版面积估算：

```text
使用 iPhone 当前 pose 的 x/z 平面坐标。
沿轨迹用固定半径扫掠栅格。
根据覆盖栅格数量估算面积。
```

建议参数：

```swift
cellSize = 0.25
scanRadius = 1.25
```

注意：这是第一版稳定性优先方案。后续应替换为 RTAB-Map 二维占据栅格面积。

### 2. 新增 PriceTagNFCReader.swift

建议路径：

```text
app/ios/RTABMapApp/PriceTagNFCReader.swift
```

职责：

- 使用 `CoreNFC` 读取电子价签。
- 第一版可先使用 `NFCNDEFReaderSession`。
- 读取成功后返回：

```swift
(identifier: String, payload: String)
```

注意：

如果真实电子价签不是 NDEF，而是 ISO15693、MiFare 或只读 UID，需要改用：

```swift
NFCTagReaderSession
```

这是后续很可能需要根据实际硬件调整的地方。

### 3. 修改 ViewController.swift

建议修改点：

```text
app/ios/RTABMapApp/ViewController.swift
```

新增字段：

```swift
private var supermarketSession: SupermarketScanSession?
private var priceTagNFCReader: PriceTagNFCReader?
private var mLatestPose = (...)
private var mLatestDatabaseMemoryMB: Int = 0
private var mAutoSegmentExportEnabled = true
```

在 `viewDidLoad()` 中初始化：

```swift
supermarketSession = SupermarketScanSession(documentsDirectory: getDocumentDirectory())
```

在 `statsUpdated(...)` 中：

- 更新最新位姿。
- 更新 `mLatestDatabaseMemoryMB`。
- 更新估算扫描面积。
- 在 HUD 显示：

```text
Scanned Area
Segment
```

- 如果处于 `STATE_MAPPING`，判断是否触发自动分段。

新增菜单项：

```text
Read Price Tag NFC
Save Current Segment
```

新增方法：

```swift
func readPriceTagNFC()
func rolloverCurrentSegment(reason: SegmentTriggerReason)
```

`readPriceTagNFC()` 逻辑：

```text
1. 确认当前是 mapping 状态。
2. 启动 NFC reader。
3. 读取成功后获取当前 pose。
4. 调用 supermarketSession.addPriceTag(...)
5. toast 提示读取成功。
```

`rolloverCurrentSegment(...)` 逻辑：

```text
1. 暂停 ARSession。
2. 停止位置更新。
3. 暂停 RTAB-Map mapping。
4. 停止 camera。
5. 保存当前 RTAB-Map 数据库到 segment 目录。
6. 写出 metadata / price_tags。
7. 创建下一个 segment。
8. 清理计数。
9. 打开新的临时数据库。
10. 重启 camera。
11. 如果之前是 mapping 状态，则继续 mapping。
```

第一版采用“暂停、保存、重开数据库、继续采集”的方式，稳定性优先。

### 4. 修改 Info.plist

路径：

```text
app/ios/RTABMapApp/Info.plist
```

增加：

```xml
<key>NFCReaderUsageDescription</key>
<string>NFC is used to read electronic price tag identifiers while scanning the supermarket.</string>
```

### 5. 修改 entitlements

路径：

```text
app/ios/RTABMapApp/RTABMapApp.entitlements
```

增加：

```xml
<key>com.apple.developer.nfc.readersession.formats</key>
<array>
    <string>NDEF</string>
</array>
```

如果后续要读 ISO15693 / MiFare，需要确认 entitlement 和 capability 是否也要调整。

### 6. 修改 Xcode 工程

路径：

```text
app/ios/RTABMapApp.xcodeproj/project.pbxproj
```

需要加入：

```text
SupermarketScanSession.swift
PriceTagNFCReader.swift
CoreNFC.framework
```

如果不想手动改 pbxproj，可以在 Xcode 中直接把两个 Swift 文件拖入 target，并在 Build Phases / Link Binary With Libraries 中添加 `CoreNFC.framework`。

## 六、第一版输出目录格式

每个超市扫描任务创建一个 session 目录：

```text
Documents/SupermarketSession-YYYYMMDD-HHMMSS/
```

每次分段保存创建一个 segment 子目录：

```text
segment_0001/
segment_0002/
segment_0003/
```

每个 segment 内建议包含：

```text
rtabmap_segment_0001.db
metadata.json
price_tags.json
price_tags.csv
```

`metadata.json` 记录：

```text
segmentIndex
exportedAt
knownAreaM2
nodeCount
databaseMemoryMB
usedMemoryMB
thresholdAreaM2
thresholdDatabaseMB
thresholdUsedMemoryMB
priceTagCount
```

`price_tags.csv/json` 记录：

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

## 七、macOS 真机调试建议

macOS Codex 在实现或检查代码后，应指导用户在 Xcode 中做以下测试。

### 1. 构建准备

1. 打开：

```text
app/ios/RTABMapApp.xcodeproj
```

2. 使用真实 iPhone Pro。

不要使用 Simulator，因为 Simulator 不能完整测试：

```text
ARKit
LiDAR
NFC
真机内存压力
```

3. 检查 Signing & Capabilities：

```text
Near Field Communication Tag Reading
Increased Memory Limit
```

4. 检查 `Info.plist` 和 entitlements。

### 2. 基础扫描测试

```text
1. 新建扫描
2. 点击 Record
3. 缓慢走一小圈
4. 检查 HUD 是否显示 Scanned Area / Segment
5. 点击 Save Current Segment
6. 检查是否保存 segment 并自动继续扫描
```

### 3. NFC 测试

```text
1. 保持 mapping 状态
2. 点击 Read Price Tag NFC
3. 靠近电子价签
4. 读取成功后保存 segment
5. 检查 price_tags.csv/json 是否包含记录
```

### 4. 自动分段测试

可以先临时降低阈值，比如：

```swift
areaThresholdM2 = 5
minimumNodesBeforeRollover = 3
```

这样方便在小空间内快速触发自动分段。

测试通过后再改回较合理值，例如：

```swift
areaThresholdM2 = 150...250
```

## 八、重要技术判断

### 1. 为什么第一版采用分段数据库

iPhone 内存有限，大面积扫描时 RTAB-Map 数据库和渲染都会增加压力。

第一版采用：

```text
暂停当前段 -> 保存数据库 -> 新建下一段 -> 自动继续采集
```

优点：

- 稳定。
- 实现成本低。
- 不需要处理 SQLite 热备份和并发写入。
- 能尽快验证业务闭环。

缺点：

- 保存时会短暂停顿。
- segment 之间暂时不是统一地图。
- 后续需要跨 segment 合并。

### 2. 为什么第一版不直接做精确二维地图面积

RTAB-Map 可以生成二维占据栅格，但在 iOS 现有链路里直接实时取全局 occupancy grid 需要更多 native 层改造。

第一版先使用轨迹扫掠面积估算，用于控制分段阈值。

后续优化方向：

```text
从 RTAB-Map local grids / occupancy grid 获取真实已探索面积
```

### 3. 为什么价签先写 sidecar 文件

第一版不改 RTAB-Map SQLite schema，降低风险。

价签数据先写：

```text
price_tags.csv
price_tags.json
```

后续稳定后可新增数据库表：

```sql
PriceTags(
  id INTEGER PRIMARY KEY,
  tag_identifier TEXT,
  payload TEXT,
  segment_id INTEGER,
  node_id INTEGER,
  stamp REAL,
  x REAL,
  y REAL,
  z REAL,
  roll REAL,
  pitch REAL,
  yaw REAL,
  note TEXT
)
```

## 九、后续开发路线

建议 macOS Codex 后续按以下顺序继续：

```text
1. 确认第一版能在 iPhone Pro 真机编译运行。
2. 修复 CoreNFC / entitlement / signing 相关问题。
3. 用小阈值验证自动分段。
4. 用真实 NFC 电子价签验证读取格式。
5. 如果不是 NDEF，改为 NFCTagReaderSession。
6. 增加价签点在地图上的显示。
7. 开发简洁二维地图界面。
8. 将面积估算替换为 RTAB-Map 二维占据栅格面积。
9. 设计跨 segment 合并和统一坐标系。
10. 将价签数据写入数据库。
```

## 十、macOS Codex 接手时的检查清单

接手后请先检查：

```text
1. app/ios/RTABMapApp/SupermarketScanSession.swift 是否存在
2. app/ios/RTABMapApp/PriceTagNFCReader.swift 是否存在
3. ViewController.swift 是否包含 supermarketSession / readPriceTagNFC / rolloverCurrentSegment
4. Info.plist 是否包含 NFCReaderUsageDescription
5. RTABMapApp.entitlements 是否包含 NFC reader session formats
6. Xcode project 是否包含 CoreNFC.framework
7. 两个新增 Swift 文件是否加入 target Sources
8. 是否能在 Xcode 中通过编译
9. 是否能在 iPhone Pro 真机运行
10. 是否能生成 SupermarketSession-* 目录
```

如果 macOS 项目是原始未修改版本，请按本文档重新实现第一版。

如果 macOS 项目已经包含部分修改，请优先保留已有可运行逻辑，在此基础上修复编译和真机运行问题。
