# iPhone Pro 超市扫描第一版调试流程

这份文档用于调试第一版“超市扫描 + 自动分段保存 + NFC 电子价签定位”功能。该版本基于现有 iOS RTAB-Map App 增加了：

- 超市扫描会话管理
- 自动分段保存
- 扫描面积估算
- NFC 电子价签读取
- 价签与当前位置绑定
- 分段数据导出

## 一、构建准备

1. 在 macOS 上使用 Xcode 打开：

```text
app/ios/RTABMapApp.xcodeproj
```

2. 选择 `RTABMapApp` target。

3. 使用真实 iPhone Pro 设备调试。

注意：不要使用 iOS Simulator。ARKit、LiDAR 和 NFC 都需要真机才能完整测试。

4. 在 `Signing & Capabilities` 中确认：

- 已配置有效 Apple 开发者签名。
- 如果开发者账号和 provisioning profile 支持，启用 `Increased Memory Limit`。
- 启用 `Near Field Communication Tag Reading`。

5. 确认 `Info.plist` 中存在：

```text
NFCReaderUsageDescription
```

6. 连接 iPhone Pro，Build & Run 到真机。

## 二、基础扫描测试

1. 启动 App。
2. 点击新建扫描。
3. 点击 `Record` 开始采集。
4. 在特征比较丰富的区域缓慢行走一小圈。
5. 观察 HUD 中是否显示：

```text
Scanned Area
Segment
RAM Usage
```

6. 打开菜单，点击：

```text
Save Current Segment
```

7. 预期结果：

- 当前扫描会短暂停止。
- 当前 segment 被保存。
- App 自动创建下一个 segment。
- 摄像头和扫描会自动恢复。
- HUD 中的 segment 编号递增。

## 三、分段保存文件位置

保存后的数据位于 App 的 Documents 目录下：

```text
Documents/SupermarketSession-YYYYMMDD-HHMMSS/segment_0001/
  rtabmap_segment_0001.db
  metadata.json
  price_tags.json
  price_tags.csv
```

其中：

- `rtabmap_segment_0001.db`：当前分段的 RTAB-Map 数据库。
- `metadata.json`：该分段的面积、节点数、内存、阈值等信息。
- `price_tags.json`：当前分段记录的电子价签数据。
- `price_tags.csv`：电子价签表格，便于后续导入系统或人工检查。

因为 App 已启用 `UIFileSharingEnabled`，可以通过 Finder 的 iPhone 文件共享、Files App 或 Xcode Devices 面板导出这些文件。

## 四、NFC 电子价签测试

1. 确认当前处于扫描状态，即已经点击 `Record`。
2. 打开菜单。
3. 点击：

```text
Read Price Tag NFC
```

4. 将 iPhone 靠近电子价签中的 NFC 卡。
5. 预期结果：

- 系统弹出 NFC 读取界面。
- 读取成功后 App 显示 toast 提示。
- 当前 NFC 信息会被绑定到当前空间位置。
- 保存 segment 时，该记录会写入 `price_tags.json` 和 `price_tags.csv`。

每条价签记录包含：

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

说明：

- `tagIdentifier` 是 NFC 标签标识。
- `payload` 是 NFC 中读取出的业务信息。
- `x/y/z` 是读取 NFC 时 iPhone 当前空间位置。
- `roll/pitch/yaw` 是读取 NFC 时 iPhone 当前姿态。
- `nodeCount` 可辅助定位该价签对应的 RTAB-Map 采集进度。
- `segmentIndex` 表示该价签属于哪个扫描分段。

## 五、自动分段触发条件

第一版会在任一条件满足时自动保存当前 segment：

```text
估算扫描面积 >= 250 m2
RTAB-Map 数据库内存 >= 900 MB
App 已使用内存 >= 2500 MB
```

这些默认值位于：

```text
app/ios/RTABMapApp/SupermarketScanSession.swift
```

对应字段：

```swift
areaThresholdM2
databaseThresholdMB
usedMemoryThresholdMB
```

如果现场测试发现 250 平米过大或过小，可以调整 `areaThresholdM2`。

建议初期测试值：

```text
150 - 250 m2
```

## 六、面积估算说明

第一版中的面积不是直接来自最终二维占据栅格，而是根据 iPhone 的移动轨迹估算：

- 使用当前位姿的水平面坐标。
- 沿行走轨迹扫掠一个固定半径区域。
- 根据被覆盖的栅格数量估算已扫描面积。

这样做的优点是实现简单、运行稳定，适合第一版验证动态分段逻辑。

后续如果需要更精确，可以改为基于 RTAB-Map 生成的二维占据栅格计算：

```text
已知格子数量 * cellSize * cellSize
```

## 七、真实超市场景测试建议

1. 优先使用带 LiDAR 的 iPhone Pro。
2. 开启 LiDAR 模式。
3. 店员沿货架通道缓慢行走。
4. 每个通道尽量来回走一次，增加回环机会。
5. 读取价签时，保持 iPhone 与价签距离和姿态相对一致。
6. 初期测试建议每个通道手动保存一次 segment。
7. 测试完成后检查：

- 每个 segment 是否生成 `.db`。
- `metadata.json` 中面积和节点数是否合理。
- `price_tags.csv` 是否包含所有读过的价签。
- 价签位置是否与地图中对应货架区域大致一致。

## 八、常见问题排查

### 1. 看不到 NFC 读取按钮

确认当前是否处于 Mapping 状态。只有点击 `Record` 后，菜单中的 `Read Price Tag NFC` 才可用。

### 2. NFC 读取失败

检查：

- iPhone 型号是否支持 NFC。
- Xcode 是否启用了 NFC capability。
- provisioning profile 是否包含 NFC 权限。
- 电子价签中的 NFC 是否为 NDEF 格式。

注意：当前第一版使用 `NFCNDEFReaderSession`。如果电子价签是 ISO15693、MiFare 或只读 UID 的卡，需要下一版改为 `NFCTagReaderSession`。

### 3. 扫描过程中内存仍然升高

可以降低：

```text
areaThresholdM2
databaseThresholdMB
usedMemoryThresholdMB
```

也可以手动点击 `Save Current Segment` 提前分段。

### 4. 分段保存后地图不连续

第一版采用“独立 segment 数据库”的方式控制内存。每段都是独立 RTAB-Map 数据库，跨段拼接和全局优化属于下一阶段功能。

### 5. 价签位置有偏差

可能原因：

- 读取 NFC 时 iPhone 与价签有距离。
- ARKit 当前定位漂移。
- 该区域缺少回环。
- 分段之间坐标系尚未统一。

建议测试时先在小区域内验证，确认 NFC 记录流程可靠后，再做跨通道、跨分段测试。

## 九、第一版已知限制

- 自动分段保存时会短暂停顿。
- 每个 segment 是独立数据库，暂未做跨 segment 自动合并。
- 价签数据暂时保存为 sidecar 文件，即 `price_tags.json/csv`，还没有写入 RTAB-Map SQLite schema。
- 二维地图界面目前先通过 HUD 显示面积和 segment 状态，后续应增加专门的简洁平面图视图。
- 面积估算是轨迹扫掠估算，不是最终占据栅格面积。

## 十、建议的下一阶段

1. 增加专门的超市二维平面图界面。
2. 将价签点显示在二维地图上。
3. 支持 ISO15693/MiFare 等非 NDEF NFC 标签。
4. 将价签记录写入 RTAB-Map 数据库。
5. 增加跨 segment 拼接与统一坐标系。
6. 使用真正二维占据栅格计算已探索面积。
