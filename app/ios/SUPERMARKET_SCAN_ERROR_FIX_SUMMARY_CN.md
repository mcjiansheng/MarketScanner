# 超市扫描误差问题与修复总结

本文总结本轮超市扫描项目修改中遇到的主要误差问题、定位过程、修复方法、验证方式和仍需继续改进的方向。重点覆盖大型区域分段扫描、分段保存后继续采集、分段数据库合并、二维平面地图预览以及 ARKit/RTAB-Map 移动端姿态连续性相关问题。

## 背景

项目目标是在 iPhone LiDAR 设备上完成大型超市场景扫描，并支持：

- 大面积扫描过程中的自动分段保存。
- 每个分段写出 RTAB-Map 数据库和轻量 sidecar。
- 后续将多个分段合并。
- 基于扫描结果生成手机端二维地图包。
- 在 App 中查看二维地图预览。

大型超市扫描和普通小房间扫描不同，核心难点不是单帧建图，而是长时间运行后的累计误差、内存增长、分段边界连续性、重定位跳变、外部存储速度以及后处理合并稳定性。

## 问题一：分段后直线走廊出现明显折角

### 现象

用户在理论上笔直的走廊中扫描，3D 轨迹和点云显示在某些分段边界附近出现明显转折。走廊本应是直线，但扫描结果像被折成两段或多段。

### 初始推测

怀疑分段保存和新分段初始化时，手机旋转姿态或坐标原点没有被正确继承。

### 根因

分段 rollover 时，App 会执行：

```text
pause ARSession / pause mapping
stopCamera()
保存当前数据库
openDatabase(新的临时库)
startCamera(resetTracking: false)
继续扫描
```

虽然 `startCamera(resetTracking: false)` 保留了 ARKit tracking，但原生层会创建新的 `CameraMobile` 实例。`CameraMobile::poseReceived()` 在 `originUpdate_` 时会用第一帧重新定义 `originOffset_`：

```cpp
originOffset_ = manualOriginOffset_.isNull() ? pose.translation().inverse() : manualOriginOffset_;
```

也就是说，ARKit 端没有 reset tracking，不等于 RTAB-Map 移动端相机原点没有重置。新分段第一帧被当成新的局部原点后，同一条直线走廊在 RTAB-Map 坐标系中可能出现折角。

### 修复方法

新增原生相机原点保留机制：

- `CameraMobile` 暴露 `getOriginOffset()`。
- `RTABMapApp` 增加 `setPreserveCameraOrigin(bool enabled)`。
- 分段保存前开启 preserve。
- `stopCamera()` 时保存当前 `originOffset_`。
- `startCamera()` 初始化新 `CameraMobile` 后重新 `resetOrigin(preservedCameraOriginOffset_)`。
- 新建完整扫描时关闭 preserve 并清空保存的 origin。

涉及文件：

- `app/android/jni/CameraMobile.h`
- `app/android/jni/RTABMapApp.h`
- `app/android/jni/RTABMapApp.cpp`
- `app/ios/RTABMapApp/NativeWrapper.hpp`
- `app/ios/RTABMapApp/NativeWrapper.cpp`
- `app/ios/RTABMapApp/RTABMap.swift`
- `app/ios/RTABMapApp/ViewController.swift`

### 修复效果

分段 stop/start 不再重新定义移动端相机原点，减少直线场景在分段边界处出现突然折角的风险。

### 剩余风险

该修复解决的是“分段导致的坐标原点重置”，不是所有轨迹漂移。长走廊纹理重复、光照不足、快速移动、ARKit 重定位、LiDAR 深度不稳定仍可能导致渐进漂移。

## 问题二：走廊来回扫描出现夹角分叉

### 现象

用户在同一条直线走廊上走一个来回，3D 呈现中去程和回程轨迹出现一定角度的分叉。理论上同一条通道应该大体重合，但实际有明显偏角。

### 根因

排查发现 iOS 端在 ARKit tracking 状态不可接受时，仍会继续向原生层提交 frame：

```swift
rtabmap?.postOdometryEvent(frame: frame, orientation: rotation, viewport: self.view.frame.size)
```

而在 `RTABMap.swift` 中，当 tracking state 不是 normal/excessiveMotion/insufficientFeatures 时，会把 pose 置空：

```swift
lost = true
postOdometryEventNative(... pose = 0 ...)
```

原生层 `RTABMapApp::postOdometryEvent()` 收到空 pose 后执行：

```cpp
if(pose.isNull())
{
    camera_->resetOrigin();
    return;
}
```

也就是说，ARKit 处于 `.limited(.relocalizing)`、`.limited(.initializing)` 或 `.notAvailable` 时，App 仍然提交 frame，原生层会把短暂 tracking 不稳定误判为需要 reset origin。这会放大走廊来回扫描中的轨迹分叉。

### 修复方法

在 `ViewController.session(_:didUpdate:)` 中只在 tracking 可接受时提交 frame：

```swift
if accept, let rotation = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation {
    rtabmap?.postOdometryEvent(frame: frame, orientation: rotation, viewport: self.view.frame.size)
}
```

这样 ARKit 正在初始化、不可用或重定位时，不再把空 pose 的图像/深度帧送入 RTAB-Map，也不会触发原生层 `resetOrigin()`。

### 修复效果

避免短暂 ARKit relocalizing 状态造成移动端原点重置，减少直线来回扫描时出现突然分叉和角度偏移的概率。

### 剩余风险

如果 ARKit 本身产生连续、缓慢的 yaw 漂移，且没有被标记为 relocalizing，这个修复不会完全消除漂移。后续需要结合走廊结构约束、回环检测、线特征或离线图优化进一步修正。

## 问题三：后续分段越来越小，扫描效率降低

### 现象

第一次分段后，后续分段更容易触发保存，分段大小变小，扫描效率下降。

### 根因

自动分段有内存阈值。如果用 App 启动后的总内存占用判断当前分段内存增长，第一次保存、复制、清理、重新打开数据库后留下的系统缓存会被算进后续分段，导致后续分段更早触发内存阈值。

### 修复方法

改为记录每个新分段开始时的内存基线：

```swift
mSegmentStartUsedMemoryMB = max(0, mMaximumMemory - getAvailableMemory())
```

之后触发阈值时使用：

```swift
segmentUsedMem = max(0, usedMem - mSegmentStartUsedMemoryMB)
```

这样自动分段依据的是“当前分段内 App 内存增长”，而不是 App 从启动以来的累计占用。

### 修复效果

降低后续分段因为系统缓存或上一次保存残留而过早切分的概率，使各分段大小更接近真实扫描压力。

### 剩余风险

如果采样频率提高、场景复杂、节点增长快，真实数据库和内存仍会更快增长。此时后续分段变短是合理结果，不应全部归因于基线错误。

## 问题四：分段保存与重启耗时过长

### 现象

分段时需要暂停、保存、重开数据库、重启扫描。用户质疑在新款 iPhone Pro Max 上是否仍需要这么长时间。

### 根因

原流程把多个步骤串行放在停扫窗口里：

```text
暂停扫描
保存本地数据库
写 sidecar
复制 segment 到外部位置
校验外部副本
删除本地副本
打开新临时库
重启相机
继续扫描
```

其中“复制到外部位置、校验、删除本地副本”不影响坐标连续性，也不是继续下一段扫描的必要条件。它们受外接盘、文件提供器、iOS 安全作用域和存储介质速度影响较大，即使用最新 iPhone，也可能被外部 I/O 拖慢。

### 修复方法

缩小必须同步完成的停扫窗口：

```text
暂停扫描
保存本地数据库
写 sidecar
打开新临时库
重启相机并继续扫描
后台复制 segment 到外部位置
后台校验
后台删除本地副本
```

同时增加性能日志：

```text
save=... sidecar=... resume=... paused=... copy=...
```

### 修复效果

外部复制、校验、清理不再阻塞继续扫描。停顿时间主要由本地数据库落盘、sidecar 写入、重新打开临时库和相机恢复决定。

### 安全边界

没有把“本地数据库保存”移到继续扫描之后，因为新分段必须从干净临时库开始。上一段数据库必须先完成本地落盘，才能安全打开下一段临时库，否则存在数据边界混乱或丢失风险。

## 问题五：二维地图只有灰白图，看不到结构

### 现象

生成的二维地图预览只有灰色和白色。灰色表示未知区域，白色表示扫描覆盖区域。用户期望看到更接近真实超市平面图的墙体、货架、障碍物，但当前图并不包含这些结构信息。

### 根因

手机端第一版二维地图使用的是轻量 sidecar：

```text
scan_area_cells.json
price_tags.json
```

`scan_area_cells.json` 来自 `FloorAreaEstimator`，它根据行走轨迹位置和固定扫描半径标记覆盖栅格：

```text
cellSize = 0.25 m
scanRadius = 1.25 m
```

它不是从 RTAB-Map 局部 occupancy grid、点云或 LiDAR 深度边界直接生成的结构地图。因此当前手机端预览本质上是“覆盖图”，不是“货架/墙体占据图”。

### 修复方法

明确手机端地图语义，并增强可诊断性：

- 继续保留灰色 unknown 和白色 estimated covered floor。
- 分段保存时新增 `trajectory_samples.json/csv`。
- 生成二维地图包时读取 trajectory sidecar。
- 在 `preview.png` 中绘制彩色分段轨迹中心线。
- 输出合并后的 `trajectory_samples.json`。
- 更新 `quality_report.json`，明确当前手机端地图是覆盖和轨迹预览，不是结构 occupied 图。
- 在 App 菜单增加查看最新二维地图入口。
- 生成二维地图后自动打开预览。

### 修复效果

用户现在可以通过彩色轨迹线判断：

- 分支位置错误是否来自真实轨迹漂移。
- 覆盖白色区域是否只是由轨迹半径扩张形成。
- 不同分段之间是否连续。

### 剩余风险

要获得真正的墙体、货架、障碍物 occupied layer，需要从 RTAB-Map 数据库中提取局部栅格或点云，再离线生成结构地图。当前手机端覆盖图不能替代最终结构地图。

## 问题六：二维地图分支位置与真实场景不完全对应

### 现象

2D 预览能看出直线走廊和两个分支，但分支位置与实际扫描场景不完全对应。

### 根因

当前 2D 预览基于轨迹覆盖估计。如果 ARKit/RTAB-Map 轨迹已经漂移，2D 覆盖图会继承这个误差。另外早期实现只输出覆盖格子，没有输出轨迹样本，难以判断偏差来源。

同时修复中还发现一个栅格尺寸边界问题：地图宽高使用 `maxCell - minCell + margin * 2 + 1` 的方式计算，和 `originCell = minCell - margin` 搭配时容易在边界解释上不够清晰。后续改为用 origin 反推 width/height，保证 margin 计算一致。

### 修复方法

- 合并 area cells、trajectory samples、price tags 来确定地图边界。
- 用统一的 `imagePoint(x:z:)` 方法转换世界坐标到图片坐标。
- 预览中绘制轨迹线，分段使用不同颜色。
- `quality_report.json` 增加 trajectory 样本统计。

### 修复效果

2D 图不再只是白色覆盖块，可以看见实际记录的中心轨迹，有助于定位偏差来源。

## 问题七：分段合并时误差与重复通道风险

### 现象

多个已保存 segment 合并后，长走廊、重复货架通道或来回扫描区域可能出现偏移、分叉、局部错位。

### 根因

分段合并本质上依赖每个分段内部轨迹质量、分段间坐标连续性、回环检测和图优化。超市环境存在以下难点：

- 货架通道重复，视觉特征相似。
- 长直走廊缺少足够几何约束。
- 去程和回程视角相反，光照和纹理观测差异大。
- 分段边界如果发生 origin reset，会直接破坏全局连续性。
- ARKit relocalizing 如果被错误提交，可能产生跳变。
- 手机端覆盖图不是结构图，无法自动纠正货架边界。

### 已完成修复

- 保留 `CameraMobile originOffset`，避免分段边界重新定义原点。
- 跳过不可接受 tracking 状态，避免空 pose 触发 reset。
- 保存轨迹 sidecar，便于诊断分段间连续性。
- 手机端 2D 预览显示分段轨迹线。
- 分段内存基线修复，避免无意义过早分段。
- 后台外部复制，减少分段停顿导致的用户移动和姿态变化。

### 仍需后续增强

分段合并误差最终需要更强的后处理：

- 从数据库导出局部 occupancy grid 或点云。
- 用结构点/墙体/货架边界生成 occupied layer。
- 在 2D 平面中做分段间刚体或 Sim2 优化。
- 对长直走廊加入线约束。
- 对已知回访点、价签、人工标记点加入锚点约束。
- 对分段重叠区域做 ICP/NDT 或栅格相关匹配。

## 问题八：采样间隔与误差、内存、分段频率之间的取舍

### 现象

用户询问是否应缩小扫描间隔，以提高地图质量。

### 结论

当前全局默认 `1 Hz` 稳定优先，但对超市通道、转角和价签定位略偏稀疏。综合算法、iPhone Pro 性能、LiDAR 范围、人类移动速度和内存占用，建议：

```text
大型稳定扫描：1 Hz
一般超市扫描推荐：2 Hz
慢速高质量短分段：3 Hz
4/5 Hz/Max：只作为诊断或短距离实验
```

### 原因

提高频率会让轨迹更密、价签附近定位更好、转角覆盖更自然，但节点数、数据库增长、内存压力和分段保存次数也会近似线性增加。过高频率还可能在重复货架场景中引入更多相似观测，增加错误匹配风险。

### 文档

详细分析见：

```text
app/ios/SUPERMARKET_SCAN_INTERVAL_ANALYSIS_CN.md
```

## 当前已形成的关键数据文件

每个 segment：

```text
rtabmap_segment_0001.db
metadata.json
price_tags.json
price_tags.csv
scan_area_cells.json
trajectory_samples.json
trajectory_samples.csv
```

二维地图包：

```text
Map2D-YYYYMMDD-HHMMSS/
  map.json
  occupancy_grid.png
  occupancy_grid.yaml
  preview.png
  trajectory_samples.json
  semantic_layers.json
  price_tags.geojson
  quality_report.json
```

这些文件将原本只存在于 RTAB-Map 数据库中的部分信息拆成轻量 sidecar，便于手机端快速预览和问题诊断。

## 推荐验证流程

### 1. 分段边界连续性测试

```text
路线：笔直走廊向前 20-30 m
操作：中途手动保存分段，保存完成后继续直走
检查：3D 轨迹是否在分段边界出现折角
检查：2D preview 彩色轨迹线是否连续
```

### 2. 来回走廊测试

```text
路线：同一条直线走廊去程 + 回程
速度：0.5-0.8 m/s
频率：先用 2 Hz
检查：去程和回程是否大体重合
检查：是否出现 relocalizing 提示后轨迹突然分叉
```

### 3. 二维地图分支测试

```text
路线：主通道 + 两个真实分支
检查：preview 白色覆盖区是否显示通道形状
检查：彩色轨迹线与真实行走路线是否对应
检查：price tag 位置是否落在合理区域
```

### 4. 分段性能测试

```text
设备：用户 iPhone 17 Pro Max
场景：同一条路线，分别使用默认本地保存和外部保存位置
记录：save / sidecar / resume / paused / copy
判断：停顿主要来自本地数据库保存还是外部复制
```

## 当前修复的边界

已经解决或明显缓解：

- 分段 restart 时 CameraMobile origin 被重置。
- ARKit relocalizing/initializing frame 误触发原生 resetOrigin。
- 后续分段因内存基线错误越来越小。
- 外部复制阻塞继续扫描。
- 手机端 2D 图缺少轨迹诊断信息。
- App 不能查看生成二维地图。

尚未彻底解决：

- 长走廊中的渐进 yaw 漂移。
- 重复货架通道中的错误回环。
- 基于真实墙体/货架结构的手机端 occupied map。
- 多分段离线结构约束优化。
- 旧数据库中已经产生的轨迹误差自动修复。

## 后续技术路线

### 阶段一：继续稳定移动端采集

- 默认超市扫描建议使用 2 Hz。
- 强化 tracking 状态提示。
- 在分段性能日志基础上统计平均停顿。
- 对低光照、快速移动、relocalizing 频繁出现的路线给出现场操作建议。

### 阶段二：增强二维地图结构层

- 从 RTAB-Map 数据库导出局部 grid 或点云。
- 生成 occupied/free/unknown/conflict 多层地图。
- 保留当前覆盖图作为快速预览层。
- 将轨迹、价签、结构层叠加显示。

### 阶段三：分段合并后处理优化

- 利用分段重叠区域做 2D 配准。
- 对长直走廊加入线约束。
- 对价签或人工标记点作为锚点。
- 对回环候选做更严格的几何一致性检查。
- 输出合并质量报告，标出高风险分段边界。

## 总结

本轮修复的核心判断是：超市扫描误差并不是单一问题，而是由移动端 tracking、RTAB-Map 相机原点、分段数据库边界、ARKit 重定位状态、内存阈值、二维地图表达方式和外部 I/O 串联造成的系统性问题。

因此修复也分为几层：

```text
坐标连续性：保留 CameraMobile origin，避免分段重置。
输入可靠性：跳过不可接受 tracking 状态，避免空 pose reset。
分段稳定性：使用分段内存基线，避免后续分段过早。
诊断能力：保存 trajectory sidecar，在 2D 预览中绘制轨迹线。
用户体验：App 内查看 2D 地图，外部复制后台化。
工程验证：增加分段耗时日志和质量报告。
```

这些修复让系统更适合在真实大型超市中连续运行，但它们还不是最终的精确地图方案。最终要得到可靠的二维平面地图，仍需要引入结构点云/局部栅格提取和多分段离线优化。
