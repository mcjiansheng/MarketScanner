# 超市分段扫描问题修复与合并功能总结

本文总结本次 iOS 超市分段扫描项目修改中遇到的问题、定位原因、修复方法，以及新增“合并已保存分段”功能的实现逻辑。重点覆盖启动卡死、前后台恢复崩溃、分段后 `Optimization failed`、分段数据库合并、合并交互误判和相关本地化补充。

## 修改范围

本轮核心提交包括：

```text
1d5b2bd Add saved segment database merging
fad7f0f Improve saved segment merge flow
```

主要涉及文件：

```text
app/android/jni/RTABMapApp.cpp
app/android/jni/RTABMapApp.h
app/ios/RTABMapApp/NativeWrapper.cpp
app/ios/RTABMapApp/NativeWrapper.hpp
app/ios/RTABMapApp/RTABMap.swift
app/ios/RTABMapApp/SupermarketScanSession.swift
app/ios/RTABMapApp/ViewController.swift
app/ios/RTABMapApp/zh-Hans.lproj/Localizable.strings
app/ios/RTABMapApp/zh-Hans.lproj/Main.strings
app/ios/Settings.bundle/Mapping.plist
app/ios/Settings.bundle/zh-Hans.lproj/Mapping.strings
```

## 问题一：启动界面卡住，Xcode 提示启动过久

### 现象

Xcode 弹出提示：

```text
Launching "RTABMapApp" is taking longer than expected.
LLDB is likely reading from device memory to resolve symbols.
```

同时 App 停在启动界面，看起来像卡死。

### 原因分析

这类提示本身不一定代表代码崩溃。它通常说明调试器在真机上解析符号或读取设备内存花费较长时间。但本项目启动时还存在一个放大问题：

```text
viewDidLoad()
  -> 创建 RTABMap()
  -> setupCallbacksWithCPP()
  -> initGlContent()
  -> register defaults / update UI settings
```

RTAB-Map 原生对象和 OpenGL 内容初始化都比较重。它们如果在首屏生命周期早期直接执行，会和 UIKit 首帧渲染、LLDB 符号解析、系统权限/资源初始化叠在一起，使启动阶段更容易超过 Xcode 的等待阈值。

### 修复方法

将重型原生初始化从 `viewDidLoad()` 延后到界面已经出现后的 `finishStartup()`：

```swift
private func finishStartup() {
    guard !startupCompleted else {
        return
    }
    startupCompleted = true

    rtabmap = RTABMap()
    rtabmap?.setupCallbacksWithCPP()
    rtabmap?.addObserver(self)

    if let context = context {
        EAGLContext.setCurrent(context)
        rtabmap?.initGlContent()
    }

    updateDisplayFromDefaults()
}
```

这样首屏可以先完成展示，RTAB-Map 原生对象和 GL 内容再初始化，降低启动阶段被系统和调试器误判为卡住的概率。

### 修复效果

- 避免在 `viewDidLoad()` 中执行过多重型原生初始化。
- 首屏生命周期更清晰。
- 后续设置同步统一从 `finishStartup()` 完成。

## 问题二：前台恢复时 Swift nil 崩溃

### 现象

Xcode 中显示：

```text
Thread 1: Swift runtime failure:
Unexpectedly found nil while unwrapping an Optional value
```

调用栈指向：

```text
ViewController.updateDisplayFromDefaults()
ViewController.appMovedToForeground()
```

崩溃行附近存在大量 `rtabmap!` 强制解包。

### 原因分析

为了修复启动过重，`rtabmap` 的创建被延后。这带来一个时序问题：

```text
App 进入前台 / UserDefaults 变化
  -> appMovedToForeground() 或 defaultsChanged()
  -> updateDisplayFromDefaults()
  -> rtabmap! 强制解包
```

如果通知发生在 `finishStartup()` 完成之前，`rtabmap` 仍然是 `nil`，强制解包就会崩溃。

### 修复方法

在设置同步入口增加空值保护：

```swift
func updateDisplayFromDefaults()
{
    let defaults = UserDefaults.standard
    applySupermarketSettings()
    guard rtabmap != nil else {
        return
    }

    rtabmap!.setOnlineBlending(enabled: defaults.bool(forKey: "Blending"))
    ...
}
```

同时 `defaultsChanged()` 只在 `rtabmap != nil` 时触发完整更新。

### 修复效果

- App 前后台切换不会因为原生对象尚未初始化而崩溃。
- 超市扫描设置仍然会先更新 Swift 层 session 配置。
- RTAB-Map 原生参数只在对象存在后同步。

## 问题三：分段后选择优化提示 `Optimization failed`

### 现象

用户扫描了多个分段后，选择优化或组装，提示：

```text
Optimization failed!
```

用户预期是把已经保存的多个分段合并或优化，但实际失败。

### 原因分析

原有 `optimization()` 的语义是“优化当前打开的 RTAB-Map 数据库或当前内存中的扫描图”。分段保存后，当前扫描会打开新的临时数据库，上一段已经保存到 `segment_xxxx/rtabmap_segment_xxxx.db`。

因此在这种状态下可能出现：

```text
磁盘上已经有多个已保存分段
当前临时库没有节点，mMapNodes == 0
用户点击 Optimize
  -> postProcessing() 在空当前库上执行
  -> 原生层没有可优化节点
  -> Optimization failed
```

也就是说，这不是已保存分段损坏，而是操作入口语义不对：优化当前图不能自动代表“合并所有已保存分段”。

### 修复方法

在 `optimization()` 入口增加当前节点检查：

```swift
guard mMapNodes > 0 else {
    let savedSegments = supermarketSession?.savedSegmentDatabaseCount() ?? 0
    if savedSegments > 0 {
        showToast(message: String(format: localized("%d saved segment databases are available. Use Merge Saved Segments to combine them."), savedSegments), seconds: 5)
    }
    else {
        showToast(message: localized("No mapping data to optimize yet."), seconds: 3)
    }
    return
}
```

如果当前图为空但磁盘上存在已保存分段，就提示用户使用“合并已保存分段”，不再对空图执行后处理。

### 修复效果

- 避免空数据库触发无意义的 `postProcessing()`。
- 用户能明确知道下一步应该使用合并入口。
- `Optimization failed` 不再承担“分段未合并”的错误提示职责。

## 新功能：合并已保存分段

### 功能目标

新增菜单项：

```text
合并已保存分段
```

目标是将多个自动保存或手动保存的分段数据库：

```text
SupermarketSession-YYYYMMDD-HHMMSS/
  segment_0001/rtabmap_segment_0001.db
  segment_0002/rtabmap_segment_0002.db
  segment_0003/rtabmap_segment_0003.db
```

合并生成一个新的 RTAB-Map 数据库：

```text
Documents/SupermarketMerged-yyMMdd-HHmmss.db
```

合并成功后 App 自动打开这个新数据库供用户查看和后续优化。

### 分段数据库发现逻辑

在 `SupermarketScanSession` 中新增：

```swift
func savedSegmentDatabaseURLs() -> [URL]
func savedSegmentDatabaseCount() -> Int
```

扫描范围包括：

```text
1. App 本地 session 根目录
2. 用户选择的外部保存目录下同名 session 根目录
```

只收集满足以下条件的文件：

```text
扩展名 == db
文件名以 rtabmap_segment_ 开头
确认为普通文件
```

最后按路径排序并返回，避免本地和外部副本混乱。

### Swift 到 C++ 的调用链

合并入口从 Swift 调到原生层：

```text
ViewController.mergeSavedSegments()
  -> RTABMap.mergeDatabases(inputDatabasePaths:outputDatabasePath:)
  -> mergeDatabasesNative(...)
  -> RTABMapApp::mergeDatabases(...)
```

其中 Swift 使用分号拼接输入数据库路径：

```swift
inputDatabasePaths.joined(separator: ";")
```

C++ 端再用 `uSplit(inputDatabasePaths, ';')` 还原为数据库列表。

本轮同时修复了 `RTABMap.save(databasePath:)` 中传参不一致的问题，确保 `saveNative()` 使用 `utf8CString` 的 buffer 指针，而不是直接把 Swift `String` 传给 C 接口。

## C++ 合并实现逻辑

核心实现位于：

```text
RTABMapApp::mergeDatabases(...)
```

### 输入校验

合并前会检查：

```text
输入数据库数量 >= 2
每个输入路径存在
每个输入文件扩展名为 .db
每个数据库可以被 DBDriver 打开
所有输入数据库合计至少包含一个节点
```

如果输出路径已经存在，会先删除旧输出，避免混入旧数据。

### 参数设置

合并使用当前 App 的 RTAB-Map 参数作为基础，并覆盖部分关键参数：

```text
Rtabmap/WorkingDirectory = 输出数据库目录
Db/Sqlite3InMemory = false
Mem/IncrementalMemory = true
Mem/GenerateIds = true
Mem/UseOdomFeatures = false
Rtabmap/PublishStats = true
```

关键点是：

- 使用磁盘数据库，避免大场景合并时内存压力过高。
- `Mem/GenerateIds=true` 让合并后的数据库重新生成节点 ID，降低多个输入库 ID 冲突风险。
- 保留当前 App 的图优化、回环检测等参数，使合并结果尽量符合用户当前设置。

### 重放各分段数据

合并不是简单拼 SQLite 表，而是使用 `DBReader` 读取输入数据库中的传感器数据，再交给新的 `rtabmap::Rtabmap` 实例重新处理：

```text
DBReader(input db list)
  -> takeData()
  -> merged.process(sensorData, odomPose, odomCovariance, odomVelocity)
  -> merged.close(true)
```

这样可以：

- 重新生成一个一致的新数据库。
- 让 RTAB-Map 在合并过程中尝试重新建立图关系。
- 支持后续继续执行标准优化、组装、导出。

### 多 map 边界处理

如果读到高协方差的里程计信息，说明可能进入了新 map/session 边界：

```cpp
if(!odometryIgnored &&
   !info.odomCovariance.empty() &&
   info.odomCovariance.at<double>(0,0) >= 9999 &&
   processed > 0)
{
    merged.triggerNewMap();
}
```

这样不同分段之间如果没有可靠连续位姿，不会被强行当作一条连续轨迹硬拼。

### 取消与失败处理

合并过程接入 `progressionStatus_`：

```text
progressionStatus_.reset(totalIds)
progressionStatus_.increment()
cancelProcessing() 可取消
```

如果用户取消：

```text
merged.close(false)
删除不完整输出数据库
返回 false
```

避免留下半成品数据库误导用户。

## iOS 合并交互逻辑

### 原交互问题

最初合并入口使用：

```swift
guard mMapNodes == 0 else {
    showToast("请先保存当前分段，再合并已保存分段")
    return
}
```

这个判断不合理，因为 `mMapNodes > 0` 只能说明“当前 RTAB-Map 内存里有节点”，并不能说明“当前分段未保存”。以下场景都会误判：

```text
用户已经保存了地图，但当前打开的数据库仍有节点
用户正在查看某个地图
用户刚保存完分段但状态尚未完全重置
```

因此用户会看到“请先保存当前分段”，但实际上前几个分段早已在切换分段时自动保存，用户也无法切回旧分段再保存一次。

### 新交互规则

现在菜单启用条件改为：

```text
已保存分段数 + 当前正在扫描且未保存的分段数 >= 2
当前不在 STATE_PROCESSING
当前没有正在导出的分段
```

具体逻辑：

```swift
let savedSegmentCount = supermarketSession?.savedSegmentDatabaseCount() ?? 0
let currentUnsavedSegmentCount = (mState == .STATE_MAPPING && mMapNodes > 0) ? 1 : 0
let mergeableSegmentCount = savedSegmentCount + currentUnsavedSegmentCount
```

### 场景一：已经停止扫描

如果用户已经完成 3 个分段并停止扫描：

```text
磁盘上有 segment_0001/0002/0003
当前不在 STATE_MAPPING
点击 合并已保存分段
  -> 直接读取磁盘分段
  -> 合并
  -> 打开 SupermarketMerged-...
```

不会再要求“保存当前分段”。

### 场景二：正在扫描新分段

如果用户已经有 2 个已保存分段，同时正在扫描第 3 段：

```text
点击 合并已保存分段
  -> 自动保存当前第 3 段
  -> 保存完成后不恢复扫描
  -> 重新读取所有已保存分段
  -> 合并
```

实现上给 `rolloverCurrentSegment()` 增加了：

```swift
resumeAfterSave: Bool
completion: ((Bool) -> Void)?
```

合并前自动保存时传入：

```swift
rolloverCurrentSegment(reason: .manual, resumeAfterSave: false) { saved in
    if saved {
        self.mergeSavedSegments()
    }
}
```

这样用户不需要手动保存，也不需要切回旧分段。

### 场景三：正在保存或处理中

如果当前已有分段保存任务或合并任务正在执行：

```text
提示用户等待
不启动新的合并
```

避免保存和合并同时访问同一批数据库文件。

## 二维地图生成入口的同步调整

同样的“先保存当前分段再处理”的交互也适用于二维地图包生成：

```text
如果正在扫描且当前分段有节点
  -> 先保存当前分段
  -> 保存成功后再生成二维地图包
```

这样二维地图不会漏掉用户最后正在扫描的当前分段。

## 本地化和设置补充

新增 `zh-Hans` 本地化资源：

```text
RTABMapApp/zh-Hans.lproj/Localizable.strings
RTABMapApp/zh-Hans.lproj/Main.strings
Settings.bundle/zh-Hans.lproj/Mapping.strings
```

补充的文案包括：

```text
合并已保存分段
正在合并分段
至少需要两个已保存的分段数据库才能合并
正在先保存当前分段，然后合并
当前分段保存失败，已取消合并
已有 %d 个已保存的分段数据库
```

Settings 中超市扫描阈值也统一为当前代码默认值：

```text
扫描面积阈值 = 120 m2
数据库阈值 = 700 MB
内存阈值 = 1200 MB
分段前最少节点数 = 30
```

## 验证方式

已执行 iOS Debug 构建：

```text
xcodebuild -project app/ios/RTABMapApp.xcodeproj \
  -scheme RTABMapApp \
  -configuration Debug \
  -destination generic/platform=iOS \
  CODE_SIGNING_ALLOWED=NO \
  build
```

结果：

```text
BUILD SUCCEEDED
```

构建中仍有项目原有 warning，例如 run script 未声明输出、重复 `Images.xcassets`，但本轮修改没有引入编译错误。

## 当前功能边界和注意事项

### 合并不是魔法对齐

合并功能会把多个分段数据库重新处理成一个新的 RTAB-Map 数据库，但空间对齐仍依赖：

```text
分段之间存在重叠区域
场景有足够可识别特征
轨迹和深度数据质量足够
RTAB-Map 能检测到可靠回环
```

如果多个分段完全没有重叠，合并结果可能只是同一个数据库里的多个 map/session，不一定会自动拼成连续无缝地图。

### Sidecar 数据尚未合并进 RTAB-Map 数据库

当前合并重点是 `.db` 地图数据库。以下 sidecar 仍按分段保存：

```text
metadata.json
price_tags.json
price_tags.csv
scan_area_cells.json
trajectory_samples.json
```

二维地图包生成会读取这些 sidecar；但 `SupermarketMerged-...db` 本身不会自动包含价签 CSV/JSON 的合并结果。后续如果需要在合并后的 3D 地图中直接显示价签，需要再设计 sidecar 到数据库或独立语义层的导入流程。

### 输出文件位置

合并后的数据库输出到 App Documents：

```text
SupermarketMerged-yyMMdd-HHmmss.db
```

它不会覆盖原始分段。原始分段继续保留在本地 session 目录或用户选择的外部目录中。

### 内存与耗时

合并会重新读取并处理所有输入数据库。大场景下耗时和内存压力与以下因素相关：

```text
分段数量
每个分段节点数量
深度/点云数据量
回环检测和图优化参数
设备可用内存
输入数据库所在存储介质速度
```

因此 UI 中提供进度条和取消按钮，取消后会删除不完整输出。

## 总结

本轮修改把几个原本混在一起的问题拆开处理：

```text
启动卡死
  -> 延后 RTAB-Map/GL 重型初始化

前台恢复 nil 崩溃
  -> updateDisplayFromDefaults 增加 rtabmap 空值保护

空当前图 Optimization failed
  -> 不再对空图优化，提示使用合并入口

已保存分段无法合并
  -> 新增磁盘分段数据库发现和原生合并能力

合并入口误提示保存当前分段
  -> 不再用 mMapNodes 判断是否未保存
  -> 正在扫描时自动先保存当前分段
  -> 已停止扫描时直接合并磁盘分段
```

最终形成的用户流程是：

```text
开始扫描
  -> 自动或手动保存多个分段
  -> 点击 合并已保存分段
  -> 如有当前未保存分段，App 自动先保存
  -> 读取所有 rtabmap_segment_*.db
  -> 生成 SupermarketMerged-...
  -> 自动打开合并后的地图
```

这个流程比之前更符合用户直觉，也避免要求用户“切回旧分段再保存”这种实际无法完成的操作。
