# MarketScanner 地图辅助定位与价签定位：Agent 实现 Prompt 集（历史归档）

> 文档状态：**历史归档**。最后核对日期：2026-07-28。
> 适用基线：阶段一至阶段三最初实现，不是当前 RepairV2 执行入口。
> 当前实现状态：[`../../IMPLEMENTATION_STATUS.md`](../../IMPLEMENTATION_STATUS.md)。

> 适用对象：Codex、Claude Code、OpenAI Codex CLI 或其他能够读取仓库、修改代码、运行测试和操作 Git 的工程 Agent。
>
> 仓库：`https://github.com/mcjiansheng/MarketScanner`
>
> 示例先验地图：`map-hs.6599-20260723193601(1).xlsx`
>
> 本文将任务压缩为三个阶段。前两个阶段应通过模拟、回放和室内小范围测试完成；只在第三阶段安排一次正式超市场景验收，以减少现场测试成本。

---

## 0. 项目背景与最终目标

MarketScanner 基于 RTAB-Map 0.23.5 攋造，当前已经具备：

- iPhone Pro 使用 ARKit、LiDAR、RGB-D、IMU 进行连续扫描；
- 一次扫描连续写入一个 RTAB-Map SQLite 数据库；
- ARKit tracking 和异常位姿跳变门控；
- 内存、磁盘、温度保护与扫描事件日志；
- PC 端 `SupermarketMapStudio`、离线重处理、2D 地图、彩色俯视图和 3D 预览；
- 历史 NFC 代码保留，但 NFC 当前暂停，不得重新作为生产路径启用。

真实业务目标不是重新绘制一张未知超市地图，而是：

1. 读取已有的二维货架结构图；
2. 在扫描过程中实时估计手机在该二维地图中的位置；
3. 使用 ARKit 提供连续相对运动，使用 LiDAR/视觉结构和道路拓扑持续校正；
4. 扫描二维码或条形码时计算价签本身的位置，而不是简单记录手机位置；
5. 将价签绑定到 `货架编号 + 货架侧面 + 沿货架起点距离 + 高度`；
6. PC 端进行离线优化、人工复核和最终导出；
7. 完整保留现有“自由扫描建图”模式，新功能作为并列的“已有地图辅助扫描”模式加入。

### 示例 Excel 数据特征

示例工作簿包含 `Element Info` 工作表：

```text
floor | element
```

`element` 是 JSON 字符串，可能包含：

- `MapShelf`
- `MapTable`
- `MapPillar`
- `MapTableFeature`
- `MapCross`
- `MapRoadPoint`

常见字段包括：

```text
shapeType, x, y, width, height, rotation,
code, crossCode, rowFlag, visible, locked, subsection
```

坐标和尺寸以厘米表达。不要假设 `x/y` 一定是中心点或左上角；必须通过解析样例、与截图对照渲染、旋转矩形测试确定源格式的几何语义，并形成自动化测试。

---

## 1. 必须遵守的全局工程约束

### 1.1 双模式兼容

系统必须同时保留：

```text
A. 自由扫描建图
   - 保持当前连续 RTAB-Map 单库扫描流程；
   - 不要求先验地图；
   - 现有输出和 PC 处理方式不得被破坏。

B. 已有地图辅助扫描
   - 选择先验货架地图；
   - 选择起点与初始朝向；
   - ARKit 连续预测；
   - LiDAR/视觉与先验地图匹配校正；
   - 扫码并定位价签；
   - PC 离线复核和输出。
```

不得通过替换、删除或改变旧流程默认语义来实现新模式。共享底层采集组件可以复用，但模式行为必须由明确的策略或状态机隔离。

### 1.2 原始数据不可变

- 手机原始 RTAB-Map 数据库是权威原始输入；
- PC 端不得就地修改原始数据库；
- 新定位轨迹、约束、价签观测和优化结果写入独立 sidecar 或输出目录；
- 所有处理必须有来源 hash 和参数清单。

### 1.3 坐标与单位

- Excel 原始单位保留为厘米；
- 算法内部统一使用米；
- 内部二维位姿统一表示为 SE(2)：`x_m, y_m, yaw_rad`；
- 只允许一个权威坐标转换模块；
- 不允许在 UI、解析器、定位器和导出器中各自重复实现坐标轴翻转、旋转或单位换算；
- manifest 必须记录源坐标系、内部坐标系、原点和转换方式。

### 1.4 实时定位原则

- ARKit 负责高频相对运动预测；
- 先验地图观测只作为带置信度的软校正，不得每帧强制吸附；
- 相似货架通道中必须允许多候选或不确定状态；
- 匹配不可靠时应保持 ARKit 推算并降低置信度，而不是跳到另一个相似通道；
- 大幅修正只能发生在明确重定位、用户手动确认或高唯一性地标条件下；
- 所有接受和拒绝的地图校正都必须记录原因和分数。

### 1.5 扫码原则

- 生产路径使用 Vision/系统条码识别处理 `ARFrame.capturedImage`；
- 不得启动第二个独立相机会话破坏 ARKit 连续性；
- NFC 保持暂停；
- 价签位置必须通过相机射线、深度或货架平面求交得到；
- 不允许直接把手机位置当作价签位置；
- 定位置信度不足时允许暂存观测，但不得静默生成高置信度最终结果。

### 1.6 性能与线程

- ARKit 帧回调不得执行重型同步计算；
- 地图匹配应在后台队列运行；
- UI 主线程不得被单次任务阻塞超过 50 ms；
- 扫描匹配目标频率初始为 1–2 Hz，ARKit 位姿显示目标为 30 Hz 或系统可提供频率；
- 使用有界点数、有界历史、有界候选数量；
- 所有缓存需要有明确上限和回收策略。

### 1.7 文档与 Git 同步

必须创建并持续维护可提交到 Git 的文档目录。不要把权威文档只放在已经被忽略的 `doc/.local/`。

建议路径：

```text
docs/map-assisted-localization/
├── ARCHITECTURE.md
├── PRIOR_MAP_FORMAT.md
├── MOBILE_UX.md
├── PC_UX.md
├── DATA_FORMATS.md
├── TEST_PLAN.md
├── FIELD_TEST_PLAN.md
├── IMPLEMENTATION_STATUS.md
└── CHANGELOG.md
```

每个阶段必须：

1. 先更新设计文档中的计划状态；
2. 实现代码与测试；
3. 更新 `IMPLEMENTATION_STATUS.md`，逐项注明：已实现、部分实现、未实现、测试证据；
4. 更新根 `README.md` 的当前能力与入口链接；
5. 确认文档描述不超前于代码；
6. 使用小而清晰的 Git 提交；
7. 不得把未完成的能力写成“已完成”。

推荐分支：

```text
feature/prior-map-localization
```

推荐提交前缀：

```text
feat(prior-map): ...
feat(ios-localization): ...
feat(tag-localization): ...
feat(map-studio): ...
test(...): ...
docs(...): ...
fix(...): ...
```

禁止：

- force push；
- 大量无关格式化；
- 修改不相关 RTAB-Map 上游代码；
- 未运行测试就声称完成；
- 把生成目录、构建产物和私有扫描数据提交到 Git。

---

## 2. 统一移动端交互与 UI 规范

### 2.1 首页

首页应面向非专业工作人员，只显示明确业务动作：

```text
[新建扫描]
[继续未完成扫描]
[扫描记录]
[先验地图]
[设置与诊断]
```

点击“新建扫描”后显示两个大卡片：

```text
自由扫描建图
无需已有地图，使用现有 RTAB-Map 连续扫描流程。

已有地图辅助扫描
在已有货架图上实时定位，并扫描、定位价签。
```

不得使用“SLAM、位姿图、闭环”等术语作为主界面文案。技术信息放在“高级诊断”中。

### 2.2 已有地图辅助扫描向导

采用五步向导：

```text
1. 选择地图
2. 选择楼层
3. 确认起点和朝向
4. 设备检查
5. 开始扫描
```

起点页面必须支持：

- 地图缩放和平移；
- 点击设置起点；
- 拖动或旋转方向箭头；
- 选择预设入口或锚点；
- 可选加载预定路线；
- 显示地图比例尺；
- 明确提示“起点和方向错误会影响定位”。

设备检查应显示：

- 相机；
- ARKit tracking；
- LiDAR/深度可用性；
- 剩余空间；
- 温度；
- 先验地图完整性；
- 数据保存位置。

### 2.3 扫描主界面

主视图默认显示二维货架地图：

- 货架轮廓；
- 当前角色位置和方向；
- 最近轨迹；
- 预定路线；
- 当前通道；
- 定位置信度范围；
- 已扫描价签；
- 需要复核的价签。

顶部状态使用业务文案：

```text
定位稳定
定位可用
定位较弱
定位已丢失
```

底部主操作：

```text
[扫描价签]  [暂停]  [结束]
```

次级菜单：

```text
确认当前位置
重新选择位置
切换相机/三维预览
查看扫描质量
高级诊断
```

低置信度时：

- 黄色提示，不执行强制跳转；
- 提示用户继续走到交叉口、柱子或端头；
- 允许人工确认位置；
- 允许暂存扫码结果，但标记待复核。

定位丢失时：

- 红色提示；
- 暂停自动提交价签位置；
- 保持原始扫码和图像观测；
- 提供“在地图上确认当前位置”；
- 不停止 RTAB-Map 原始数据记录。

### 2.4 扫码确认界面

高置信度时可一键确认；中低置信度时必须显示：

- 识别到的码值；
- 原始测量位置；
- 建议货架；
- 建议货架侧面；
- 沿货架起点距离；
- 测量置信度；
- 定位置信度；
- “确认”“重新扫描”“选择其他货架”。

### 2.5 结束页面

显示：

- 扫描时长；
- 轨迹长度；
- 标签总数；
- 已确认标签数；
- 待复核标签数；
- 定位较弱区间；
- 保存位置；
- 是否需要 PC 端处理。

---

## 3. 统一 PC 端交互与 UI 规范

`SupermarketMapStudio` 应增加面向非专业人员的向导，同时保留高级参数折叠区。

首页提供：

```text
[处理自由扫描]
[处理已有地图辅助扫描]
[导入/管理先验地图]
[查看历史结果]
```

地图辅助扫描处理流程：

```text
1. 选择先验地图
2. 选择扫描会话
3. 数据检查
4. 自动处理
5. 轨迹与定位复核
6. 价签复核
7. 导出结果
```

复核界面使用左右布局：

```text
左：二维地图/轨迹/标签
右：当前告警、候选货架、置信度、操作按钮
```

图层开关：

- 先验货架；
- 通道与道路；
- 在线实时轨迹；
- PC 优化轨迹；
- RTAB-Map 原始/优化轨迹；
- 定位约束；
- 已确认价签；
- 待复核价签；
- 置信度热区。

人工修复工具：

- 设置轨迹锚点；
- 将轨迹区间重新指定到候选通道；
- 排除错误地图匹配约束；
- 调整价签位置；
- 重新分配货架、侧面和沿货架距离；
- 批准/拒绝复核项；
- 撤销和重做；
- 保存编辑日志。

所有高级参数默认折叠，并提供安全默认值。

---

# 阶段一：先验地图基础、双模式 UI 与可回放验证框架

## 阶段一完整实现目标

本阶段不实现完整 LiDAR 自动匹配。目标是建立不会返工的基础：

1. 将 Excel 结构图转换为版本化先验地图包；
2. 建立统一坐标、几何、道路图和空间索引；
3. 在 PC 工作台导入、校验和预览地图；
4. 在 iOS 新建双模式入口；
5. 已有地图模式可选择地图、楼层、起点和朝向；
6. ARKit 轨迹可以实时显示在先验地图中；
7. 提供基于道路/预定路线的软约束和人工位置确认；
8. 完整保留自由扫描模式；
9. 建立模拟、录制和回放框架，使后续定位算法无需频繁去超市测试；
10. 建立权威文档和数据格式。

## 阶段一实现 Prompt

```text
你是 MarketScanner 项目的主实现工程师。请在仓库
https://github.com/mcjiansheng/MarketScanner
中完成“阶段一：先验地图基础、双模式 UI 与可回放验证框架”。

输入文件：
- 示例先验地图：<PRIOR_MAP_XLSX_PATH>/map-hs.6599-20260723193601(1).xlsx
- 对应截图仅用于视觉校验；Excel 中的结构化元素才是数据源。

开始前必须执行：
1. 阅读根 README、Git 状态、最近提交、app/ios、tools/SupermarketMapStudio、tools/Supermarket2DMap 和现有测试。
2. 确认当前连续单库扫描、保存、PC 重处理和 NFC 暂停逻辑。
3. 创建或切换到 feature/prior-map-localization 分支。
4. 写出简短实施计划并列出预计修改文件，避免修改无关上游 RTAB-Map 代码。
5. 在 docs/map-assisted-localization/ 创建并提交权威文档骨架。

必须实现以下内容。

一、先验地图转换工具

在 tools 下新增合适目录，例如：

tools/PriorMap/
  xlsx_to_prior_map.py
  validate_prior_map.py
  render_prior_map.py
  prior_map_schema.py
  tests/

要求：
- 读取 Element Info 工作表；
- 解析 floor 和 element JSON；
- 支持 MapShelf、MapTable、MapPillar、MapTableFeature、MapCross、MapRoadPoint；
- 未知 shapeType 不应导致崩溃，应保留原始数据并产生 warning；
- 过滤或标记 visible=false 元素，不能静默丢弃；
- 保留 code、crossCode、rowFlag、subsection 等业务字段；
- 通过样例和截图确定 x/y、width/height、rotation 的真实含义；
- 为旋转矩形生成统一 polygon；
- 原始单位厘米，算法输出米；
- 生成 map bounds、楼层列表、元素统计、源文件 SHA-256；
- 生成 MapCross/MapRoadPoint 道路图；
- 生成货架、柱子、柜台的空间索引；
- 输出版本化地图包，建议目录格式：

PriorMap-<id>/
  manifest.json
  elements.json
  shelves.json
  fixed_structures.json
  road_graph.json
  spatial_index.json 或等价有界索引
  preview.png
  validation_report.json

格式可以调整，但必须版本化、可验证、可被 Swift 和 Python 共同读取，且在 DATA_FORMATS.md 中完整记录。

二、坐标系统

新增单一权威坐标模块：
- 明确 Excel 坐标原点、x/y 方向、旋转正方向；
- 内部使用 x_m、y_m、yaw_rad；
- PC 预览和 iOS 显示必须共用相同转换逻辑或相同 golden fixtures；
- 生成一个与用户截图方向一致的 preview.png；
- 添加矩形旋转、坐标轴翻转、厘米/米转换、边界计算测试。

三、PC Map Studio

增加“先验地图”页面或入口：
- 导入 xlsx；
- 显示转换进度；
- 显示地图名称、楼层、范围、元素统计、warning；
- 可缩放预览；
- 验证结果必须用非技术语言解释；
- 保存可复用地图包；
- 不影响现有扫描会话处理页面。

四、iOS 双模式入口

实现以下业务入口：
- 新建扫描时显示“自由扫描建图”和“已有地图辅助扫描”；
- 自由扫描建图必须继续走原有流程，输出不变；
- 已有地图辅助扫描进入五步向导：选择地图、选择楼层、起点和方向、设备检查、开始扫描；
- 支持导入或选择地图包；
- 起点页面支持缩放、拖动、点击设置位置、旋转朝向箭头；
- 初始位置必须保存到 session metadata；
- 已有地图模式仍然启动现有 RTAB-Map 连续数据库采集，不得改成只记录 ARKit。

五、阶段一定位 MVP

本阶段只实现：
- 使用初始 T_map_from_arkit 将 ARKit 位姿实时投影到先验地图；
- 基于 road graph 或可选预定路线进行软约束和候选道路判断；
- 不允许硬吸附造成跳转；
- 显示当前道路/通道候选、定位状态和置信度；
- 提供“确认当前位置”和“重新选择位置”；
- 每次人工校准写入 manual_localization_events.jsonl；
- 每隔固定间隔写 localization_trace；
- 定位丢失或不确定时不停止 RTAB-Map 原始扫描。

六、回放与模拟框架

必须实现无需超市即可运行的验证工具：
- 从 synthetic path 或已有 trajectory_samples 生成 ARKit 相对增量；
- 可注入平移漂移、旋转漂移、随机噪声、短时 tracking 丢失；
- 可基于道路图生成蛇形路线；
- 可回放到阶段一定位器；
- 输出 ground truth、estimated pose、road assignment 和误差报告；
- 测试中不得依赖真实超市数据库。

七、数据格式

新增并记录：
- scanMode = free_mapping 或 prior_map_localized；
- priorMapId、priorMapSha256、floorId；
- initialMapPose；
- localizationTrace；
- manualLocalizationEvents；
- 当前格式版本。

兼容旧会话：缺少这些字段时按 free_mapping/legacy 处理。

八、测试

至少包括：
- Excel 解析单元测试；
- 各 shapeType 几何测试；
- golden preview 或关键坐标测试；
- road graph 连通性测试；
- 未知/损坏 JSON 和隐藏元素测试；
- schema 校验测试；
- PC API 测试；
- 自由扫描模式回归测试；
- iOS 坐标转换和模式状态机测试；
- synthetic drift replay 测试；
- 同一输入多次转换结果可复现测试。

阶段一验收目标：
- 示例 xlsx 可一条命令转换并通过验证；
- PC 和 iOS 显示的货架位置、方向和比例一致；
- 自由扫描旧流程测试全部通过；
- 已有地图模式能完成选择地图、起点、方向并开始连续扫描；
- 模拟路线可以显示并生成误差报告；
- 不要求真实 LiDAR 自动校正；
- 不要求正式超市场景测试。

九、UI 文案

主界面不得使用晦涩技术术语。所有错误需提供：
- 发生了什么；
- 数据是否安全；
- 用户下一步应该做什么。

十、文档和 Git

更新：
- 根 README；
- ARCHITECTURE.md；
- PRIOR_MAP_FORMAT.md；
- MOBILE_UX.md；
- PC_UX.md；
- DATA_FORMATS.md；
- TEST_PLAN.md；
- IMPLEMENTATION_STATUS.md；
- CHANGELOG.md。

每项文档必须与实际实现一致。使用原子提交。最终回复必须列出：
- 改动文件；
- 数据格式；
- 测试命令和结果；
- 已知限制；
- 提交列表；
- 下一阶段可以安全依赖的接口。

不要实现 NFC，不要删除历史 NFC 兼容代码，不要开始阶段二的重型 LiDAR 匹配，除非它是建立接口所需的最小空实现。
```

---

# 阶段二：实时地图匹配、定位置信度与二维码价签测量

## 阶段二完整实现目标

本阶段完成手机端核心业务闭环：

1. ARKit 连续预测；
2. LiDAR/RGB-D 局部二维结构提取；
3. 与先验货架、柱子、柜台、通道结构匹配；
4. 更新 `T_map_from_arkit`，持续校正漂移；
5. 重复通道中维护不确定性，不发生灾难性跳转；
6. Vision 扫描二维码/条形码；
7. 通过深度或货架平面求交测量价签位置；
8. 自动关联货架、侧面、沿货架距离和高度；
9. UI 提供稳定、较弱、丢失、人工恢复流程；
10. 使用模拟和回放完成大部分验证，只进行办公室/走廊小范围实机干跑，不要求正式超市测试。

## 阶段二实现 Prompt

```text
你是 MarketScanner 项目的实时定位负责人。请在已经完成并通过审查的阶段一基础上，实现“阶段二：实时地图匹配、定位置信度与二维码价签测量”。

开始前：
1. 阅读 docs/map-assisted-localization/ 下全部权威文档和 IMPLEMENTATION_STATUS.md。
2. 运行阶段一完整测试，确认自由扫描模式和先验地图导入没有回归。
3. 检查当前 Git 分支和工作树，禁止在未清理状态下开始大规模修改。
4. 先提交设计补充，明确定位状态、线程模型、输入输出和失败策略。

一、定位器架构

实现一个明确的模块边界，建议：

app/ios/RTABMapApp/
  PriorMapLocalizer.swift
  PriorMapLocalizationState.swift
  PriorMapDepthSampler.swift
  PriceTagVisionScanner.swift
  PriceTagMeasurement.swift
  ShelfAssociation.swift

app/android/jni 或新的共享 native 目录：
  PriorMapScanMatcher.hpp
  PriorMapScanMatcher.cpp

可以调整路径，但必须分离：
- ARKit 位姿预测；
- 深度点提取；
- 地图扫描匹配；
- 置信度管理；
- 标签测量；
- UI 状态。

二、状态定义

定位器最少具有：
- uninitialized
- initializing
- stable
- usable
- weak
- lost
- manualCorrection

状态改变必须有明确阈值和结构化事件日志，不能由 UI 自行猜测。

三、ARKit 预测

维护：
- T_map_from_arkit；
- 最近可信 ARKit 位姿；
- 当前 map pose；
- 协方差或等价不确定度；
- topological road candidates。

ARKit 每帧只做轻量预测和 UI 更新。不得在 frame delegate 中同步执行完整点云匹配。

四、LiDAR/深度二维结构提取

从 ARFrame sceneDepth/smoothedSceneDepth 或当前项目已有 RGB-D 数据中：
- 有界采样深度点；
- 使用相机标定和 ARKit 位姿变换到局部水平平面；
- 过滤无效深度、过近/过远点；
- 过滤明显地面和天花板；
- 优先保留货架立面、柱子、固定柜台；
- 使用鲁棒统计降低人员、购物车和临时堆头影响；
- 记录有效点数、覆盖角度和深度质量。

不要把语义识别作为本阶段依赖。可以使用几何高度范围和时间一致性。

五、先验地图距离场与扫描匹配

在地图包中增加适合手机读取的多分辨率距离场或等价结构：
- 低分辨率用于恢复和粗搜索；
- 中/高分辨率用于局部精确匹配；
- 文件格式必须版本化、文档化并有完整性校验；
- 不引入不必要的大型运行时依赖。

扫描匹配：
- 以 ARKit 预测为中心做有限 SE(2) 搜索；
- 使用鲁棒距离损失；
- 同时计算最佳分数、次佳分数和唯一性；
- 使用 road graph 降低不可能道路候选权重，但不要硬裁剪所有候选；
- 重复货架区域至少保留 Top-K 候选，K 建议为 3；
- 只有在分数、唯一性、有效点数和连续性同时满足时接受校正；
- 大幅跳变必须拒绝或进入明确 recovery；
- 校正应平滑更新 T_map_from_arkit；
- 不修改 ARKit 自身世界坐标；
- 不修改原始 RTAB-Map 数据库。

每次匹配必须记录：
- 输入时间；
- 预测位姿；
- 候选；
- 最佳/次佳分数；
- 有效点数；
- 接受或拒绝；
- 拒绝原因；
- 修正量；
- 定位状态。

六、定位安全规则

必须实现：
- 单次普通校正平移和角度上限；
- 多帧一致性；
- 地图结构与现实长期不一致时标记 mapMismatch，而不是强拉轨迹；
- tracking 中断后重新稳定若干帧再恢复匹配；
- 定位 weak/lost 时不自动提交最终价签位置；
- 手动校准写入独立事件并作为高置信锚点，但保留审计记录；
- UI 显示置信度和最近一次成功校正时间。

七、二维码/条形码识别

使用 Vision 或平台原生能力处理 ARFrame.capturedImage：
- 与现有 ARSession 共用相机；
- 有界识别频率；
- 识别任务在后台运行；
- 支持 QR 和常见条形码类型；
- 去重短时间重复结果；
- 保留原始码值、角点、图像时间戳和对应 ARFrame 位姿。

八、价签三维测量

不得使用手机位置替代价签位置。

优先流程：
1. 取得码框中心和角点；
2. 在对应深度图采样多个点；
3. 采用中位数和有效性检查；
4. 反投影到相机三维坐标；
5. 转换到 ARKit 和先验地图坐标；
6. 估计价签朝向或货架表面法线；
7. 关联货架边缘。

深度不足时：
- 尝试拟合周围货架平面；
- 或使用相机射线与候选货架平面求交；
- 若仍不可靠，则创建 pending observation，要求人工确认；
- 不得伪造高置信度位置。

九、货架关联

输出不只包含 XY：
- shelfCode
- rowFlag
- crossCode
- shelfSide
- distanceFromShelfStartCm
- heightCm
- rawMapPosition
- snappedMapPosition
- localizationConfidence
- measurementConfidence
- associationConfidence
- needsReview

关联算法必须考虑：
- 到货架边的距离；
- 扫码射线方向；
- 手机所在道路侧；
- 货架法线；
- 不得穿过其他货架关联到远侧结构；
- 相邻候选分数接近时标记待复核。

十、移动端 UI

严格实现文档中的主界面：
- 地图角色、朝向、轨迹、路线；
- stable/usable/weak/lost；
- 当前道路；
- 最近校正；
- 大按钮“扫描价签”；
- weak/lost 引导；
- 价签确认界面；
- 人工重定位界面；
- 高级诊断折叠。

自由扫描模式 UI 和行为不得被改变。

十一、sidecar

至少新增：
- localization_trace.jsonl 或等价有界格式；
- localization_constraints.jsonl；
- localization_events.jsonl；
- tag_observations.jsonl；
- localized_price_tags.json；
- manual_localization_events.jsonl；
- schema version；
- prior map hash。

扫描中采用追加或原子写入策略，避免崩溃损坏全文件。

十二、模拟和回放测试

扩展阶段一 replay harness：
- 生成二维结构观测；
- 注入 ARKit 平移/旋转漂移；
- 相似平行通道；
- 交叉口；
- 柱子；
- 动态障碍离群点；
- tracking 丢失与恢复；
- 地图结构变化；
- 错误起点；
- 手动重定位；
- 标签像素、深度和货架关联。

测试目标可作为初始验收基线：
- 合成无歧义路线定位中位误差 <= 0.25 m；
- 95% 误差 <= 0.60 m；
- 95% 朝向误差 <= 8°；
- 通道分配准确率 >= 99%；
- 不允许无 recovery 记录的 >2 m 灾难性跳转；
- 高置信标签货架关联准确率 >= 98%；
- 动态障碍不应导致位置跳转；
- weak/lost 状态能在唯一交叉口或人工锚点后恢复。

这些是模拟验收目标，不得冒充真实超市精度。

十三、实机干跑

本阶段只要求办公室或走廊小范围干跑：
- 使用简化先验图；
- 走一条包含直行和转弯的路线；
- 放置少量打印二维码；
- 验证相机连续、扫码不中断 ARKit、UI 可操作、日志完整；
- 不以该测试证明超市场景精度。

十四、性能测试

记录：
- 匹配频率；
- 每次匹配耗时 p50/p95；
- 有效点数；
- 内存增长；
- CPU/热状态；
- UI 卡顿；
- sidecar 增长。

十五、文档和 Git

更新所有权威文档，特别是：
- ARCHITECTURE.md
- DATA_FORMATS.md
- MOBILE_UX.md
- TEST_PLAN.md
- IMPLEMENTATION_STATUS.md
- CHANGELOG.md

新增算法限制说明：
- 长直重复通道的纵向不可观测；
- 地图过期；
- 动态障碍；
- 人工锚点和固定二维码的作用。

使用原子提交。最终报告必须包含：
- 定位算法；
- 安全阈值；
- 数据格式；
- 测试矩阵和实际结果；
- 性能数据；
- 实机干跑结果；
- 已知限制；
- 提交列表。
```

---

# 阶段三：PC 离线优化、人工复核、最终导出与一次正式现场验收

## 阶段三完整实现目标

本阶段把手机端结果变成可以交付和审计的最终结果：

1. PC 同时读取先验地图、RTAB-Map 数据库、在线定位轨迹、地图约束和扫码观测；
2. 先执行现有 RTAB-Map 离线优化，再执行先验地图坐标下的轨迹优化；
3. 在线校正、手动锚点、道路约束和地图观测作为带权约束；
4. 自动产生定位质量报告和复核项；
5. PC UI 可以修正错误轨迹区间和价签关联；
6. 所有人工编辑可撤销、可追踪、可重复应用；
7. 导出最终价签位置及货架业务信息；
8. 完成端到端自动测试、性能测试和一次正式超市场景验收；
9. 将文档、Git、版本和实际能力完全对齐。

## 阶段三实现 Prompt

```text
你是 MarketScanner 项目的 PC 优化、复核和发布负责人。请在阶段一、阶段二已通过独立审查后，实现“阶段三：PC 离线优化、人工复核、最终导出与正式现场验收”。

开始前：
1. 运行全部现有 Python、C++ 和 iOS 可运行测试。
2. 阅读所有数据格式和阶段二定位日志。
3. 确认原始数据库不可变约束。
4. 对尚未解决的 blocker 先修复，不允许在错误基础上扩展。

一、PC 处理管线

地图辅助会话应采用：

原始 RTAB-Map 数据库
  -> 现有自适应 RTAB-Map 离线重处理
  -> 获取连续、全局一致的相对轨迹
  -> 读取在线 prior-map localization constraints
  -> 在先验地图坐标系中执行 SE(2) 离线优化
  -> 重新计算全部标签位置和货架关联
  -> 自动质量评估
  -> 人工复核
  -> 最终导出

不得跳过现有 RTAB-Map 处理，也不得把在线地图吸附结果直接当作最终权威轨迹。

二、先验地图轨迹优化

实现独立的派生轨迹优化层，源数据库保持只读。

优化变量：
- 关键节点或降采样轨迹节点的 SE(2) 位姿。

约束至少包括：
- ARKit/RTAB-Map 相邻相对运动；
- RTAB-Map 闭环提供的相对约束；
- 手机端接受的地图匹配观测及协方差；
- 道路方向和道路区域软约束；
- 手工确认锚点；
- 可选固定定位二维码锚点。

要求：
- 使用鲁棒核；
- 不可靠约束可自动降权或拒绝；
- 原始约束和处理后约束都保留；
- 输出优化前后误差和被拒绝约束；
- 不得为了贴合地图而破坏明显正确的相对轨迹；
- 地图和现实不一致区间应允许保留偏离并产生 review item。

优先使用项目已有 g2o 能力或明确、可测试的专用 SE(2) 优化器。如果采用简化算法，必须在文档中诚实说明，不能称为完整因子图优化。

三、结果数据

输出建议：

MapStudio-Localized-*/
  prior_map_manifest.json
  source_manifest.json
  processing_manifest.json
  rtabmap_optimized/
  online_localization_trace.json
  optimized_map_trajectory.geojson
  localization_constraints.json
  localization_report.json
  review_items.json
  manual_edits.json
  localized_price_tags.json
  localized_price_tags.csv
  localized_price_tags.geojson
  shelf_tag_index.json
  audit_log.jsonl
  preview.png
  preview_3d.json

最终标签必须包含：
- tagId/payload；
- mapXcm/mapYcm/heightCm；
- shelfCode/rowFlag/crossCode；
- shelfSide；
- distanceFromShelfStartCm；
- online 和 offline 位置差；
- 各置信度；
- 是否人工修改；
- 来源观测 ID；
- needsReview；
- 审批状态。

四、PC UI

在 Supermarket Map Studio 增加非专业向导：

1. 选择先验地图；
2. 选择扫描会话；
3. 自动检查；
4. 一键处理；
5. 轨迹复核；
6. 价签复核；
7. 导出。

轨迹复核：
- 同时显示 prior map、在线轨迹、RTAB-Map 轨迹、离线优化轨迹；
- 显示定位 weak/lost 区间；
- 显示被拒绝或高残差约束；
- 可以点击问题列表跳转；
- 可设置锚点；
- 可将区间指定到候选通道；
- 可禁用错误匹配约束；
- 可撤销/重做；
- 修改保存到 manual_edits.json，重新处理可重复应用。

价签复核：
- 列表和地图联动；
- 按 needsReview、货架、通道、置信度筛选；
- 显示二维码截图或可用的观测预览；
- 显示原始位置、自动吸附位置、最终位置；
- 可修改 shelfCode、side、offset、height；
- 支持批量批准高置信结果；
- 不允许在没有提示的情况下覆盖人工修改。

高级参数折叠，默认按钮必须能完成安全处理。

五、兼容自由扫描

自由扫描会话：
- 继续使用当前 Map Studio 地图生成和 3D 预览；
- 不要求先验地图；
- 不显示无意义的价签定位步骤；
- 旧会话和历史分段会话仍可读取；
- 新增代码不得改变旧结果的默认参数和输出含义。

六、质量报告

localization_report.json 至少包括：
- 地图和会话 hash；
- 节点覆盖率；
- 在线/离线轨迹长度；
- 位置修正分布；
- 最大修正；
- weak/lost 时长；
- 地图约束接受率；
- 高残差区间；
- 通道切换序列；
- 手工锚点数量；
- 标签总数、已确认数、待复核数；
- 货架关联置信度；
- 警告和拒绝原因；
- 是否允许自动发布。

自动发布必须有安全门。未通过安全门的结果只能标记为“需要人工复核”。

七、自动测试和回放

必须建立完整 end-to-end fixture：
- 先验地图；
- synthetic ARKit trajectory；
- synthetic depth observations；
- simulated RTAB-Map pose/DB fixture；
- QR observations；
- manual correction；
- expected final shelf association。

测试：
- 一条命令从地图转换运行到最终导出；
- 源数据库 hash 不变；
- 相同输入和参数结果可复现；
- 在线漂移被离线约束降低；
- 错误地图约束被鲁棒核拒绝；
- 人工编辑可重复应用；
- 撤销/重做正确；
- 自由扫描回归；
- 旧会话兼容；
- 并发任务锁；
- 中断和恢复；
- 大会话有界内存和进度日志。

八、正式现场测试

只安排一次正式超市场景验收。现场前必须完成全部模拟、回放和办公室干跑。

现场测试准备：
- 使用示例货架地图或现场对应最新版；
- 确认地图版本和 hash；
- 在地图中设置明确起点和方向；
- 使用用户规划的蛇形路线；
- 选择若干已测量的控制点、交叉口、柱子和货架端点；
- 在不同区域放置或选择不少于 20 个可扫码标签，记录人工真值；
- 预留重复货架、长直通道和转弯场景；
- 准备一次 tracking 中断和一次人工重定位测试。

现场记录：
- 手机型号、系统版本、电量、温度；
- 扫描时长、节点数、数据库大小；
- 定位状态时间线；
- 所有人工操作；
- 标签真值；
- PC 处理参数和耗时。

建议初始验收目标：
- 通道/道路分配准确率 >= 99%；
- 正常区域定位中位误差 <= 0.50 m；
- 95% 定位误差 <= 1.00 m；
- 不存在未记录 recovery 的灾难性跨通道跳转；
- 高置信价签正确货架关联率 >= 98%；
- 高置信价签沿货架位置中位误差 <= 0.50 m；
- 所有失败结果都能在 PC review items 中被发现；
- 非专业操作员可以在说明下完成开始、扫码、结束和 PC 导出。

如果真实数据达不到指标：
- 不得通过放宽报告或隐藏异常来通过验收；
- 记录失败类型；
- 优先修复可重复的软件问题；
- 对地图过期、传感器遮挡等非软件原因明确标记；
- 更新 FIELD_TEST_PLAN.md 和 IMPLEMENTATION_STATUS.md。

九、文档、发布和 Git

完成：
- ARCHITECTURE.md
- PRIOR_MAP_FORMAT.md
- MOBILE_UX.md
- PC_UX.md
- DATA_FORMATS.md
- TEST_PLAN.md
- FIELD_TEST_PLAN.md
- IMPLEMENTATION_STATUS.md
- CHANGELOG.md
- 根 README。

增加用户操作手册，分别写：
- 手机自由扫描；
- 手机已有地图辅助扫描；
- PC 自由扫描处理；
- PC 地图辅助扫描处理；
- 定位弱/丢失处理；
- 价签复核；
- 数据备份与失败恢复。

最终代码和文档必须使用同一术语。所有测试证据和现场结果写入版本控制，但不要提交敏感原始超市图像或大型数据库；仅提交脱敏摘要和小型测试 fixture。

使用原子提交，并生成最终发布说明。最终回复必须列出：
- 架构；
- UI 流程；
- 数据输出；
- 自动测试结果；
- 性能结果；
- 现场验收结果；
- 未解决风险；
- 提交列表；
- 是否达到生产试运行条件。
```

---

# 4. 总控 Agent Prompt

当你希望一个 Lead Agent 管理三个阶段、但仍要求每阶段独立提交和审查时，可使用以下 Prompt：

```text
你是 MarketScanner 地图辅助定位项目的 Lead Engineer。

仓库：https://github.com/mcjiansheng/MarketScanner
示例地图：map-hs.6599-20260723193601(1).xlsx

最终目标：在保留现有自由扫描建图功能的同时，新增“已有地图辅助扫描”。手机使用 ARKit 提供连续运动，使用 LiDAR/视觉和既有二维货架地图持续校正位置；使用 Vision 扫描二维码/条形码，通过深度测量价签本身的位置，并绑定到货架编号、侧面、沿货架距离和高度；PC 端进行离线优化、人工复核和最终导出。

请严格按三个阶段执行：
1. 先验地图基础、双模式 UI、模拟/回放框架；
2. 实时地图匹配、定位置信度、二维码价签测量；
3. PC 离线优化、人工复核、最终导出和一次正式现场验收。

规则：
- 每个阶段开始前提交设计和文档更新；
- 每个阶段完成后运行该阶段全部测试和全量回归；
- 每个阶段结束必须停止开发，输出审查包，等待独立 Review Agent 通过后才能进入下一阶段；
- 不得把未实现内容写成已完成；
- 不得修改原始扫描数据库；
- 不得破坏现有自由扫描模式；
- NFC 继续暂停；
- 优先使用模拟、回放和办公室干跑，正式超市测试仅在第三阶段执行一次；
- 权威文档必须提交到 Git，并与代码同步；
- 所有变更使用原子提交，不 force push，不提交大型或敏感扫描数据。

首先只执行阶段一。完成后输出：
- 实施摘要；
- 修改文件；
- 数据格式；
- UI 流程；
- 测试命令和结果；
- 已知限制；
- Git 提交；
- 给 Review Agent 的检查重点。

在阶段一审查通过前，不要执行阶段二。
```
