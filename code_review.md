# MarketScanner 第一、二、三阶段最终综合代码审查与需求验收报告

**审查日期：** 2026-07-25  
**仓库：** `https://github.com/mcjiansheng/MarketScanner`  
**审查分支：** `feature/prior-map-localization`  
**审查提交：** `d3eefcf8e8e54b9fb517f00fb189aab737b161ff`  
**提交说明：** `feat(prior-map): complete stage-three localized workflow`  
**对比基线：** `main@b390b98675a8036b503cd78dfaedc237808f60b3`  
**上一轮审查点：** `b6aa0163ed2da7df8e3e95364c7c91209d6e72a9`  
**范围约束：** 单次扫描固定一个楼层；允许楼层内少量竖直位移；不审查跨楼层自动切换。  
**审查方式：** 远端 Git 与源码只读审计、三阶段需求追踪、上一轮问题复核、测试设计审计、数据格式与生命周期审计、定向数值推演。未修改仓库。

> **独立验证限制：** 当前审查环境无法克隆并构建该 iOS 仓库，且头提交没有 GitHub Actions workflow run。因此，仓库文档中“26 项 PriorMap 测试、55 项 Map Studio 测试、Xcode 构建成功”等结果记为实现方提供的证据，未被本次审查环境独立复现。上一轮对 `mapcase01.xlsx` 的转换与回放结果可作为历史证据，但不能替代本提交的重新运行、真机和现场验收。

---

## 1. 最终结论

| 范围 | 结论 | 审查意见 |
|---|---|---|
| 第一阶段 | **APPROVED WITH CONDITIONS（有条件通过）** | 地图包完整性、双模式隔离、道路索引、原子导入、分楼层预览及设备检查已形成完整工程基线。仍需在当前头提交上完成独立 Xcode 构建、真实地图重新转换和 iPhone 冒烟回归。 |
| 第二阶段 | **APPROVED WITH CONDITIONS（有条件通过）** | 上一轮重复结构唯一性、时序门、跨结构遮挡、稳定侧面、深度证据、对齐快照和结束并发问题均有实质修复。仍缺真实 LiDAR 深度、平行货架、转弯、遮挡和长时运行证据。 |
| 第三阶段 | **REJECTED（不通过）** | 最终价签重算没有应用完整 SE(2) 旋转；PC 端重关联退化为“最近边”且无遮挡/候选歧义门禁；人工锚点时间基准不明确；人工编辑和成果发布不具备事务与并发安全。 |
| 跨阶段综合结论 | **REJECTED** | 当前证据只支持“内部工程原型/算法联调”，不支持受控试运行。修复 BLOCKER/HIGH 并完成独立真机与现场指标验收后，才可重新评估 `APPROVED FOR PILOT`。 |

### 1.1 问题统计

| 严重度 | 数量 | 含义 |
|---|---:|---|
| BLOCKER | 2 | 可直接生成错误最终价签业务坐标或错误货架绑定，且可能通过发布门。 |
| HIGH | 6 | 会破坏人工锚点、可重复性、质量门或轨迹几何安全，必须在试运行前修复。 |
| MEDIUM | 6 | 不一定立即产生错误结果，但削弱证据、可用性、报告真实性或数据治理。 |
| LOW / 验收条件 | 3 | CI、真机、现场和文档表述等发布工程条件。 |

### 1.2 当前可接受的产品定位

- 可以继续作为开发分支进行 PC/iOS 联调。
- 第一、二阶段可以作为受限技术基线，但不能宣称真实超市精度已经验收。
- 第三阶段生成的成果不得作为权威价签坐标导入业务系统。
- `automatic_publish_allowed=true` 在当前实现中不能等价于“可发布”。
- 原始 RTAB-Map 数据库的只读保护设计基本成立，但派生成果的事务发布仍不成立。

---

## 2. 审查基线与变更概况

### 2.1 Git 状态

远端 `feature/prior-map-localization` 相对 `main` 超前 7 个提交、落后 0 个提交。相对上一轮审查点 `b6aa0163`，本轮新增一个大型提交 `d3eefcf`，共修改 34 个文件。主要变化包括：

- iOS：新增 `PriorMapPackageIntegrityCore.swift`；增强价签侧面、深度证据、快照新鲜度和结束队列处理。
- PC：新增约 1,462 行 `offline_localization.py`，实现第三阶段派生轨迹、标签重算、质量门、编辑重放和导出。
- Map Studio：增加 `kind=localized` 工作流、复核画布、编辑接口和新增成果 allowlist。
- 测试：新增 `test_stage3.py`、Swift 合约测试和 Map Studio UI 标记测试。
- 文档：新增第三阶段实现报告、用户指南，并更新架构、数据格式、PC/Mobile UX、测试计划和状态文档。

### 2.2 审查依据

本报告采用以下优先级：

1. 实际源码与 Git 变更；
2. `MarketScanner_Agent_Implementation_Prompts(2).md`；
3. `MarketScanner_Agent_Test_Review_Prompts(2).md`；
4. `docs/map-assisted-localization/` 当前远端文档；
5. 仓库测试代码和实现方测试报告；
6. 上一轮综合审查及 `mapcase01.xlsx` 历史验证结果。

实现摘要和测试报告不被直接视为通过证据；必须与源码、失败路径和负例测试相互印证。

---

## 3. 上一轮问题关闭情况

| 上一轮问题 | 当前状态 | 复核结果 |
|---|---|---|
| iOS 地图包只做格式检查，缺少完整内容绑定 | **已关闭** | 新增 `package_manifest.json` 和 `PriorMapPackageIntegrity.validate()`，检查 allowlist、逐文件 SHA-256、包摘要及跨文件关系；向导保存 package SHA。 |
| 货架 A/B 侧按“最长两边”定义，不稳定 | **大部分关闭** | Swift/Python 均引入业务轴、确定方向和 A/B/E##；标准矩形货架已稳定。非标准退化几何仍应保留 fail-closed 测试。 |
| 价签深度只采 7 点，可能把背景当标签 | **大部分关闭** | 改为内缩 9×9 采样，增加样本数、内点率、MAD、平面残差和法向证据，并写入 observation。真实 LiDAR 平面证据仍未独立验收。 |
| 重复/周期结构只保留一个匹配盆地 | **已关闭** | coarse/medium/fine 每级保留空间分离假设；缺少第二独立极小值时唯一性为 0 并拒绝。 |
| 时序门比较绝对相机位姿 | **已关闭** | 改为比较 `candidatePose ⊖ rawPose` 的校正变换；不合格候选会清空门状态，不能预热下一帧。 |
| 跨货架遮挡和固定柜台未参与在线关联 | **已关闭（在线）** | iOS 关联器检查全部结构遮挡，柜台可关联、柱体仅遮挡；负例测试覆盖后排货架和柱体。第三阶段离线关联没有继承这些安全门，见 B-02。 |
| 扫码帧使用执行时的可变地图对齐 | **已关闭** | 检测携带冻结快照；记录 age/version lag；stale 时强制降级复核。 |
| Vision 方向固定 | **已关闭** | 依据界面方向映射 `.up/.down/.left/.right`，Swift 数值测试覆盖四向。 |
| 楼面估计缺法向/残差/时序门 | **已关闭** | 使用水平法向、低分位种子、内点比例、残差和连续稳定帧计算置信度。 |
| 扫描结束可能与定位/扫码任务并发写 sidecar | **已关闭** | 结束前失效 generation、设置 finalizing、异步等待串行队列 barrier；session 写接口继续校验会话 ID。 |

**结论：** 第一、二阶段的上一轮 BLOCKER/HIGH 已获得实质修复。第三阶段重新实现了标签关联和时序/轨迹传播，其中没有复用第二阶段的全部安全语义，形成新的跨阶段回归。

---

## 4. 第一阶段完整审查

### 4.1 需求状态矩阵

| 第一阶段要求 | 状态 | 证据/意见 |
|---|---|---|
| 读取 `Element Info`，保留支持类型和业务字段 | 通过 | 转换器支持 `MapShelf/MapTable/MapPillar/MapTableFeature/MapCross/MapRoadPoint`，未知/隐藏/损坏行进入 warning。 |
| 厘米到米和坐标轴单一权威实现 | 通过 | PC 集中在 `coordinate_system.py`；Swift 投影有独立数值合约。 |
| 旋转矩形、bounds、分楼层预览 | 通过 | 生成 `polygon`、逐楼层 bounds/preview；单次扫描锁定一个楼层。 |
| 输出可复现、schema/version、源摘要 | 通过 | `package_manifest.json`、文件摘要和包摘要加入确定性输出。 |
| 道路图 ID 归一化、连通性、空间索引 | 通过 | 数字/字符串 ID 归一化，孤立/缺失道路 warning，`road_cells` 有界查询。 |
| PC UI 不改源文件，失败不留下半成品 | 通过 | 转换端临时目录/校验/发布；源 XLSX 只读。 |
| iOS 导入完整校验与原子缓存 | 通过 | 包清单和跨文件校验在复制到缓存前执行，缓存采用临时目录替换。 |
| 双模式并列，自由扫描不依赖地图 | 静态通过 | workflow gate 独立；未发现自由扫描路径被先验地图对象强制依赖。仍需真机回归。 |
| 选择地图、楼层、起点、朝向、设备检查 | 通过 | 五步向导、ARKit/相机/深度/磁盘/温度检查均存在。 |
| 真实地图转换和屏幕方向复核 | 条件未完成 | 上一轮在旧提交对 `mapcase01.xlsx` 验证成功；当前 package manifest 变更后未独立重跑。 |

### 4.2 第一阶段结论

**APPROVED WITH CONDITIONS**。当前没有发现新的第一阶段阻断代码问题。合并前条件：

1. 在干净 macOS/Xcode 环境构建头提交；
2. 使用 `mapcase01.xlsx` 重新转换并验证 package manifest、所有楼层 preview 和包摘要；
3. iPhone 完成自由扫描与地图辅助扫描的开始、暂停、恢复、结束、重新开始回归；
4. 核对至少 3 个地图控制点和 2 个转向的显示方向；
5. 建立 CI，使 Swift 合约测试不再长期处于“实现方本机通过、远端无状态”的状态。

---

## 5. 第二阶段完整审查

### 5.1 定位链路

当前 iOS 定位链路为：

```text
ARKit pose
  -> map projection
  -> bounded depth structure observation
  -> 0.40/0.20/0.10 m distance-field search
  -> independent multi-basin Top-K
  -> geometry + uniqueness + correction magnitude
  -> correction-transform temporal gate
  -> gain=0.35 alignment-anchor update
```

关键安全性质：

- 不重置 ARKit，不写入先验约束到 RTAB-Map 原始数据库；
- 单次自动修正上限 0.35 m / 8°；
- 缺少独立第二候选时拒绝唯一性；
- 道路只作为显示/弱先验；
- 不合格候选不能积累时序门；
- busy 时丢弃新定位更新，而不是无界排队。

### 5.2 价签链路

当前在线价签链路为：

```text
用户点击扫描
  -> 复用 ARFrame.capturedImage
  -> Vision 条码检测
  -> 冻结对齐快照
  -> 内缩 9×9 depth 采样
  -> sample/inlier/MAD/plane evidence
  -> 深度反投影；失败时使用可见结构射线
  -> 全结构遮挡、近分、端点、侧面关联
  -> 原始 observation 先落盘
  -> 用户显式确认后保存 final tag
```

### 5.3 第二阶段要求矩阵

| 第二阶段要求 | 状态 | 审查意见 |
|---|---|---|
| 结构匹配不在 ARSessionDelegate 同步重计算 | 通过 | 独立串行队列、0.5 s 节流、单 in-flight。 |
| 多分辨率距离场和真实 Top-K 唯一性 | 通过 | 每一级保留 8 个独立盆地，周期结构负例 fail-closed。 |
| 动态物体/噪声抑制、点数上限 | 通过 | 跨帧 voxel persistence，输入/输出点数有界。 |
| 时序一致性比较校正而非相机绝对位姿 | 通过 | 使用局部校正变换；拒绝候选重置门。 |
| stable/usable/weak/lost 有迟滞 | 通过（代码） | 状态集中管理；真实长路径尚无独立端到端回放。 |
| 不启动第二相机、不启用 NFC | 通过 | Vision 只消费 ARFrame；NFC 入口保持关闭。 |
| 帧、图像方向、对齐快照绑定 | 通过 | 四向映射和 freshness/version lag 已实现。 |
| 标签不是手机位置 | 通过（代码/合约） | 使用 ROI depth 反投影或结构射线，不使用相机平移作为标签点。 |
| 跨货架遮挡、近分和固定柜台 | 通过（在线） | iOS 有对应几何与负例。 |
| weak/lost 不静默保存 | 通过 | 所有结果均显示确认框；风险结果 `needs_review=true`。 |
| 结束/暂停不丢 sidecar | 通过（静态） | generation + finalizing + queue barrier。 |
| 真实 LiDAR、转弯、遮挡、长时资源指标 | 未完成 | 文档仍明确待办；无远端 CI/真机附件。 |

### 5.4 M-01 — MEDIUM：深度“平面”法向仍是启发式四极值构造

**位置：** `app/ios/RTABMapApp/PriceTagVisionScanner.swift:330-370`

当前代码从 retained 点中分别取 x 最小、x 最大、y 最小、y 最大的四个点，用两个向量叉积构造法向，再以中位点到平面的残差判定。这比上一版显著可靠，但不是最小二乘、PCA 或 RANSAC 平面拟合：

- 极值点可能来自边缘背景或深度飞点；
- 法向由四个单点主导，而残差使用全部点；
- 缺少法向朝向、条件数和二维覆盖面积检查；
- 小码框在低分辨率 depth 上可能产生重复像素，名义 81 个样本并不等于 81 个独立点。

**建议：** 使用协方差最小特征向量或小型 RANSAC；记录唯一像素数、平面条件数和覆盖范围；以真实 iPhone LiDAR 对前景码、倾斜码、货架背景、反光膜和遮挡码做负例。

### 5.5 第二阶段结论

**APPROVED WITH CONDITIONS**。核心算法安全回归已修复，但必须把“合约测试通过”与“真实超市精度通过”严格区分。第二阶段重新验收至少需要：

- 30 分钟以上单楼层 LiDAR 走测；
- 平行通道、周期货架、柱网、转弯、端头和 tracking interruption；
- 位置 median/P95、航向 P95、通道准确率、灾难跳变数、恢复时间；
- 标签本体误差、货架/侧面/offset/height 正确率；
- matcher iPhone P50/P95、内存峰值、sidecar 增长；
- 自由扫描回归。

---

## 6. 第三阶段完整审查

### 6.1 实现概述

第三阶段已经形成完整代码骨架：

1. 完整校验地图包和会话身份；
2. 对源 SQLite 做 SHA-256；
3. `rtabmap-reprocess` 生成优化数据库副本；
4. 读取优化轨迹和在线 sidecar；
5. 构造在线结构、道路、人工锚点和人工通道约束；
6. 对 x/y/yaw correction field 求解；
7. 重算标签、生成质量报告和 review items；
8. 通过 Map Studio 编辑、撤销/重做；
9. 输出 JSON/CSV/GeoJSON、manifest 和 audit log。

该实现规模和文档覆盖度较高，但最终业务坐标与发布安全仍存在阻断问题。

---

## 7. BLOCKER 问题

### B-01 — BLOCKER：离线轨迹的航向修正没有作用到价签坐标

**位置：** `tools/PriorMap/offline_localization.py:1093-1114`

标签重算代码只计算：

```text
dx = optimized_node.x - baseline_node.x
dy = optimized_node.y - baseline_node.y
final_tag.x = online_tag.x + dx
final_tag.y = online_tag.y + dy
```

它没有使用节点的 yaw correction，也没有计算完整刚体变换：

```text
DeltaT_i = T_offline_i * inverse(T_baseline_i)
P_final = DeltaT_i * P_online
```

因此，只要离线优化改变航向，标签相对相机/节点的方向就不会旋转。示例：基线节点位于 `(0,0,0°)`，标签位于节点右侧 `(1,0)`；离线节点修正为 `(0,0,90°)`。正确标签应为 `(0,1)`，当前代码仍输出 `(1,0)`。

这会直接影响：

- `final_map_position`；
- 后续最近货架选择；
- `shelf_side`；
- `distance_from_shelf_start_cm`；
- CSV/GeoJSON 最终业务坐标；
- 自动发布门的判断。

**为什么是 BLOCKER：** 第三阶段的核心职责是将优化后的轨迹正确传播到标签；该缺陷会在“轨迹看起来更好”的同时生成系统性错误标签，而且当前测试没有航向修正标签用例。

**必须修复：**

1. 保存/重建标签捕获时的在线节点位姿；
2. 使用完整 `SE(2)` 变换差作用到标签点；
3. 对高度保持独立，不把二维 yaw 误作用到竖直轴；
4. 加入 90°、180°、平移+旋转、跨 ±π 和非零节点位置测试；
5. 输出标签变换前后 node ID、时间差、DeltaT 和旋转贡献，便于审计。

---

### B-02 — BLOCKER：第三阶段货架重关联退化为“最近边”，丢失在线遮挡和歧义安全门

**位置：** `tools/PriorMap/offline_localization.py:700-748`

第三阶段 `_associate_tag()`：

- 遍历货架/柜台边；
- 保留 1.2 m 内候选；
- 仅按距离、ID、边 ID 排序；
- 直接选择第一名；
- 距离小于约 0.42 m 时可能达到 `association_confidence >= 0.65`；
- 没有相机位置、视线、最近遮挡物、远侧面、端点、第二候选 margin 或同侧朝向判断。

这与第二阶段在线关联器的安全逻辑不一致。典型错误场景：

- 相机与后排货架之间有前排货架；
- 两排平行货架距离相近；
- 标签位于端头，两个面候选接近；
- 柜台/柱体遮挡；
- 轨迹修正将点移动到两结构之间。

当前实现仍可能给出一个明确 `shelf_code/side/offset`，且 `needs_review=false`，从而通过 `automatic_publish`。

**为什么是 BLOCKER：** “稳定绑定到货架编号 + 侧面 + offset”是业务目标。第三阶段是最终权威输出，却比第二阶段使用更弱的关联器，形成安全回归。

**必须修复：**

1. 将在线和离线关联抽取为共享规范/共享测试；
2. observation 中保留捕获相机地图位置或可重建的节点相对向量；
3. 对全部结构做最近射线命中和遮挡判断；
4. 计算最优/次优独立候选 margin；
5. 端点、远侧面、遮挡、近分候选必须 fail-closed；
6. 任何无法证明唯一性的离线重关联不得覆盖在线人工确认值，只能生成 review proposal；
7. 加入前后两排、平行通道、旋转货架、不规则柜台、柱体遮挡和近分候选测试。

---

## 8. HIGH 问题

### H-01 — HIGH：人工定位事件使用 Unix 时间绑定轨迹节点，缺少同一时间基准

**位置：**

- `app/ios/RTABMapApp/SupermarketScanSession.swift:181-196, 1049-1073`
- `tools/PriorMap/offline_localization.py:1005-1026`

iOS `ManualLocalizationEvent` 只记录 `timestampUnix = Date().timeIntervalSince1970`，没有记录 `ARFrame.timestamp`、RTAB-Map node stamp 或 node ID。第三阶段直接把 `timestampUnix` 传给 `_nearest_pose_index()`，与优化数据库 `Node.stamp` 比较。

代码和文档没有建立“Node.stamp 必然等于 Unix wall clock”的不变量；其他定位/价签记录使用的是 ARFrame/扫描时间。若两者时间基准不同，所有人工锚点会被绑定到错误节点，通常是轨迹端点。

**必须修复：**

- iOS 人工确认时记录 `frame_timestamp`、最近 node ID、alignment version 和 wall-clock；
- PC 仅使用与 Node.stamp 明确同源的字段；
- 校验最近节点时间差上限，超限强制人工选择节点；
- 旧会话无统一时间基准时不得自动应用 manual anchor；
- 增加真实 SQLite stamp 与 iOS sidecar 对时测试。

---

### H-02 — HIGH：第三阶段成果写入不是事务发布，失败可留下新旧混合文件

**位置：** `tools/PriorMap/offline_localization.py:59-70, 1284-1458`

`_json_write()` 直接 `path.write_text()`；`process_localized_session()` 在最终目录中依次覆盖十余个文件和 CSV。人工编辑重放同样直接写回已验证输出目录。

若在中途发生：

- JSON 序列化异常；
- CSV 类型转换异常；
- 磁盘不足；
- 进程中断；
- 人工 edit_tag 注入不合法类型；

目录会包含部分新文件和部分旧文件。该行为直接违反第三阶段需求“任何失败都不会发布为成功结果，临时文件不会覆盖已验证输出”。

**必须修复：**

1. 每次运行写入同级临时目录；
2. 完成 schema、hash、CSV/GeoJSON 可读性和成果清单校验；
3. 生成完整 `processing_manifest` 后原子 rename/swap；
4. 保存上一个验证版本或版本化结果目录；
5. 初始任务失败和人工重放失败都不得改变当前 active result 指针。

---

### H-03 — HIGH：人工编辑缺少并发锁、乐观版本和优化数据库身份绑定

**位置：** `tools/SupermarketMapStudio/server.py:1196-1272`

`apply_localized_edit()` 对已完成 job：

1. 读取当前 `manual_edits.json`；
2. append/undo/redo；
3. 重新读取优化数据库；
4. 直接重跑并覆盖同一输出。

问题：

- 没有 per-job edit lock；
- 请求不携带 revision/ETag；
- 两个并发请求可能都从同一 cursor 开始，后写覆盖前写；
- 处理期间 GET 可能读取半更新成果；
- manual journal 只绑定地图包和源数据库 hash，没有绑定 `optimized.db` hash、重处理参数或代码版本；
- `optimized.db` 被替换后，旧编辑仍可在不同轨迹上重放。

**必须修复：** per-job mutex + journal revision/hash + compare-and-swap；把优化数据库 SHA、重处理配置、工具版本写入 journal identity；编辑重放同样使用事务目录。

---

### H-04 — HIGH：关键 JSONL 损坏被静默跳过，质量门可能在不完整证据上通过

**位置：** `tools/PriorMap/offline_localization.py:31-55`

`_read_jsonl()` 对空行、超长行、JSON 错误和非对象记录全部 `continue`，不返回 malformed count、文件名、行号或警告。随后流程把剩余记录当作完整输入。

风险：

- 损坏的拒绝约束消失，使 `not rejected` 成立；
- 损坏的待复核 observation/tag 消失，使 review 数减少；
- accepted/source denominator 被改变；
- 审计日志无法证明输入完整；
- 输出仍可能 `automatic_publish_allowed=true`。

**必须修复：** 解析器返回 records + malformed diagnostics；对 constraints、manual events、tag observations 进行 format/version、trackingSessionId、map ID/hash、floor、timestamp 和有限数检查；关键文件有损坏时强制失败或至少禁止自动发布。

---

### H-05 — HIGH：所谓 SE(2) 优化没有显式相对位姿残差，可能扭曲 RTAB-Map 权威轨迹

**位置：** `tools/PriorMap/offline_localization.py:398-520`

当前求解器分别对 x、y、yaw 三个 correction array 做一维相邻索引平滑：

```text
c_i ≈ average(c_{i-1}, c_{i+1}, absolute observations)
```

它没有显式构造：

- `T_i^-1 T_{i+1}` odometry/RTAB-Map relative residual；
- loop closure residual；
- 与节点距离或时间间隔相关的协方差；
- SE(2) translation/yaw 耦合；
- objective before/after、收敛状态和正定性诊断。

相同 smoothness 被用于“相邻节点”，不考虑相邻节点是 2 cm 还是 5 m、0.1 s 还是 10 s。文档称“RTAB-Map relative trajectory authority”，但代码只能保证 correction field 平滑，不能保证相对轨迹几何不被拉伸、缩短或改变曲率。

**必须修复：** 至少以基线 `DeltaT_i` 建立相对 SE(2) 残差；按时间/里程设置权重；显式 gauge；输出目标函数和收敛；对路径长度、局部速度、曲率、闭环残差设置变化门限。若继续采用 correction field，应把文档和质量门降级为“平滑形变”，不得声称保持相对轨迹。

---

### H-06 — HIGH：自动发布门无法证明位置精度、通道正确性或标签正确性

**位置：** `tools/PriorMap/offline_localization.py:1150-1160, 1192-1274`

当前自动发布条件主要是：

- 有轨迹；
- accepted source rate ≥ 0.55；
-最大 correction ≤ 1.5 m；
- 无 rejected constraints；
- 无待复核标签。

缺少：

- 轨迹 ground truth / 控制点误差；
- 通道判对率和灾难性跳转；
- 航向 P95；
- 局部轨迹形变；
- 标签点误差和货架/侧面/offset/height 正确率；
- 地图覆盖、变化区间、weak/lost 比例硬门；
- 真实现场验收状态。

`needs_review` 又依赖 B-02 的弱关联器，因此质量门可能同时受到错误输入和错误判定。

**必须修复：** 在完成正式现场验收前禁用自动权威发布；将门禁改为“是否允许进入人工复核/是否允许导出草稿/是否允许受控发布”三级，并将字段级、轨迹级和现场级硬门全部纳入。

---

## 9. MEDIUM 问题

### M-01 — MEDIUM：第三阶段测试主要是同源 synthetic fixture，未覆盖真实重处理链

**位置：** `tools/PriorMap/tests/test_stage3.py`

测试的积极点：有漂移收敛、错误约束、道路软约束、通道编辑、undo/redo、hash 绑定和确定性导出。

局限：

- fixture 轨迹是规则直线；
- source/optimized DB 使用简单字节占位；
- 直接调用 `process_localized_session()`，不验证真实 `rtabmap-reprocess`、SQLite Node/Admin、WAL、stamp 和数据库复制；
- 单个标签、无旋转修正；
- 无前后货架遮挡、近分候选、错误货架自动批准；
- 无并发编辑、磁盘中断、回滚和部分写；
- benchmark 同样是小型合成输入。

**建议：** 增加脱敏真实 SQLite fixture、mapcase01、完整服务器 API E2E、故障注入和并发测试。

### M-02 — MEDIUM：`job_payload()` 对 localized job 返回错误的摘要文件

**位置：** `tools/SupermarketMapStudio/server.py:430-443`

除 prior_map 外，统一读取 `quality_report.json` 和 `map.json`。localized 工作流的权威报告是 `localization_report.json`、视图是 `localized_review.json`。因此 job 状态接口的 `quality_report/map` 可能为空或仍是基础 2D 地图，而不是第三阶段结果。

**建议：** 为 `job.kind == "localized"` 建立专用 payload，并暴露 publish gate、tag review、constraint rejection、trajectory corrections 和 review view。

### M-03 — MEDIUM：人工 `edit_tag` 允许任意字段和类型，批准可直接清除 review

**位置：** `tools/PriorMap/offline_localization.py:769-865`

`edit_tag` 只要求非空对象，然后 `tag.update(new_value)`。用户可写入任意字段、错误类型或无效坐标；后续 `approve_tag`/batch approve 可把 `needs_review=false`。CSV 阶段才可能因 `float()` 失败。

**建议：** 定义允许字段、类型、坐标 bounds、合法 side、shelf ID、offset 范围和 confidence 范围；验证 target 存在；批准前重新运行结构一致性校验；人工 override 单独保存，不要覆盖原始自动字段。

### M-04 — MEDIUM：报告部分统计值不能真实反映覆盖或约束质量

**位置：** `tools/PriorMap/offline_localization.py:1192-1274`

- `node_coverage_ratio` 只要有 optimized poses 就固定为 1.0；
- acceptance rate 分母为 source accepted + manual event count，人工锚点却不计入 accepted source numerator；
- accepted_count 混合 online、road、manual；
- `aisle_switch_sequence` 只是在线道路候选列表，不是离线优化后的通道序列；
- 没有记录 malformed input、未匹配 observation、标签时间差分布。

**建议：** 给每个指标明确公式、分母和来源；提供可从原始文件复算的明细表；质量门不得使用语义混合指标。

### M-05 — MEDIUM：派生成果包含本机绝对路径，存在隐私和可移植性风险

**位置：** `tools/PriorMap/offline_localization.py:1287-1302`

`source_manifest.json` 写入 session、source database、optimized database、prior map 的绝对路径。导出给其他人员时可能泄露用户名、目录结构或挂载卷名称，且换电脑后无法重放。

**建议：** 默认存相对路径/逻辑 ID；绝对路径放本机私有状态文件；发布前执行 privacy scrub；重放时允许用户重新解析路径并验证 hash。

### M-06 — MEDIUM：优化数据库 hash 已报告但未作为人工编辑重放前置条件

`localization_report.json` 记录 `optimized_database_sha256`，但 `manual_edits.json` identity 和 `apply_localized_edit()` 不验证它。相同源 DB 在不同 RTAB-Map 版本、参数或 GPU fallback 下可能产生不同 optimized DB，旧编辑仍被应用。

**建议：** journal identity 同时绑定：source DB SHA、optimized DB SHA、prior-map package SHA、reprocess profile/parameters、代码/schema version。

---

## 10. LOW / 发布条件

### L-01 — 无远端 CI 状态

头提交没有 workflow run。Swift 合约测试、Python 全量测试、Xcode build 和 diff check 只存在文档声称，不能由远端持续复现。

### L-02 — 现场验收仍为空

实现报告明确说明尚未完成 LiDAR iPhone 办公室干跑、真实超市、标签真值、控制点、长时资源和多设备/多场地验证。当前不得给出 pilot 或正式商用结论。

### L-03 — 文档存在“完整链路已通过”式表述，需要进一步收敛

`STAGE_3_IMPLEMENTATION_REPORT.md` 同时声明“不代表生产批准”和“完整链路已通过”，但测试本身没有覆盖本报告 B/H 问题。建议统一写成“实现方本地合成链路通过，待独立审查与现场验收”。

---

## 11. 第三阶段需求追踪矩阵

| 第三阶段要求 | 状态 | 结论 |
|---|---|---|
| 源数据库只读、处理前后 SHA 相同 | 通过（代码） | 读取源 DB，重处理写副本，前后 hash 比较。 |
| RTAB-Map 离线重处理 | 通过（架构） | `run_localized_map` 强制重处理并读取优化副本。独立运行未复现。 |
| 读取在线约束 | 部分通过 | 读取 JSONL，但缺 schema/provenance 和 malformed 门。 |
| SE(2) 优化数学 | 不通过 | correction field 独立平滑，不含显式相对 SE(2) 残差。 |
| 错误约束拒绝/鲁棒核 | 部分通过 | online constraint 有 Huber+hard gate；manual/road 豁免，报告不含完整 objective。 |
| 道路软约束 | 通过（代码） | 投影到道路，低权重。 |
| 地图变化区间和收敛 | 不通过 | 无明确区间、objective、收敛失败和局部形变指标。 |
| 标签按优化轨迹重计算 | **不通过** | 只应用 dx/dy，忽略 yaw，见 B-01。 |
| 标签货架/侧面/offset 安全关联 | **不通过** | 最近边、无遮挡/歧义，见 B-02。 |
| manual_edits 有版本、旧值/新值、撤销重做 | 基本通过 | journal/cursor/event 已实现。 |
| 地图/会话 hash 变化拒绝旧编辑 | 部分通过 | 绑定 map/source DB；未绑定 optimized DB/参数。 |
| 人工结果不被自动处理覆盖 | 部分通过 | 编辑在自动关联后重放；但非事务和并发会丢失/混合。 |
| PC UI 选择、检查、一键处理 | 通过（代码/UI 标记） | 工作流入口和进度已加入。 |
| 跳转问题、设置锚点、禁用约束、标签编辑、批准 | 部分通过 | JSON 编辑器/画布存在；直接拖拽锚点仍未实现；并发锁缺失。 |
| 浏览器刷新恢复 | 部分通过 | completed result restore 机制存在；人工编辑中的恢复/版本冲突未验证。 |
| 并发处理锁 | 不通过（编辑） | 初始 job 对输入有 reservation；completed job edit 无 per-job lock。 |
| JSON/CSV/GeoJSON 字段完整 | 部分通过 | 输出字段广泛；标签最终坐标和关联语义错误会传播至三种格式。 |
| 质量报告可复算 | 不通过 | 指标定义混合、coverage 固定、malformed 未记录。 |
| 自动发布条件真实且无 blocker | 不通过 | B-01/B-02 可在 publish gate 之外发生。 |
| 失败不覆盖已验证输出 | 不通过 | 文件顺序覆盖，无事务发布。 |
| end-to-end 源 hash 不变、可复现 | 部分通过 | synthetic 测试证明简单情况；真实 DB/中断/并发未覆盖。 |
| 性能和内存 | 条件不足 | 仅小型 synthetic benchmark，不能代表大型超市。 |
| 现场验收 | 未完成 | 无正式数据。 |
| 数据与隐私 | 部分通过 | Git 未见 DB/现场数据；导出 manifest 泄露绝对路径。 |

---

## 12. 跨阶段最终十问

| 问题 | 回答 |
|---|---|
| 1. 自由扫描模式是否完整保留？ | **静态上是。** workflow gate、UI 和原连续单库路径仍存在；必须用真机和旧会话回归最终确认。 |
| 2. 地图辅助扫描是否真正持续校正？ | **是。** 第二阶段在结构唯一、幅度安全、连续一致时更新 map↔ARKit 对齐锚点，不只是显示轨迹。 |
| 3. 重复货架通道是否可能静默跳错？ | **在线匹配已大幅 fail-closed；离线标签关联仍可能静默串货架。** |
| 4. 扫码是否保持 ARKit 连续？ | **是（代码层）。** 复用 ARFrame，不创建第二相机；NFC 关闭。 |
| 5. 价签位置是否为标签本身而非手机位置？ | **在线是。** 使用深度/射线；第三阶段传播旋转错误会使最终标签偏离。 |
| 6. 标签是否稳定绑定 code/side/offset/height？ | **在线基本是；最终离线结果不成立。** B-01/B-02 会破坏稳定绑定。 |
| 7. 原始数据库是否始终不可变？ | **设计和代码基本是。** 源 hash 前后检查，重处理写副本；派生成果不是事务发布。 |
| 8. PC 是否能发现、修复和审计错误？ | **部分。** 有 review/edit/audit 骨架，但输入损坏静默、并发/事务和重放身份不足。 |
| 9. 文档、代码、测试和 Git 是否一致？ | **部分一致。** 第一、二阶段较好；第三阶段关于 SE(2) 权威、失败不覆盖和安全重关联的表述高于代码证据。 |
| 10. 当前证据支持什么？ | **内部工程测试，不支持受控试运行。** |

---

## 13. 重新送审前的最低修复清单

### 13.1 必须修复的代码

1. 使用完整 `DeltaT = T_offline * inverse(T_online)` 重算价签位置；
2. 第三阶段复用/等价实现在线遮挡、侧面、端点和候选 margin 安全门；
3. 人工定位事件增加同源 frame/node timestamp，并对旧数据 fail-closed；
4. 第三阶段输出采用临时目录校验后原子发布；
5. 人工编辑增加 per-job lock、revision/ETag 和 compare-and-swap；
6. manual journal 绑定 optimized DB SHA、reprocess 参数和工具版本；
7. JSONL 解析记录所有异常并禁止在不完整证据上自动发布；
8. 优化器增加显式相对 SE(2) 残差或降低算法声明，并增加局部形变门；
9. 质量门加入轨迹、通道、标签和现场硬指标；
10. 人工 tag edit 建立严格 schema、范围和目标一致性校验。

### 13.2 必须增加的自动测试

- 标签在 90°/180°/跨 ±π 轨迹修正下的完整刚体传播；
- 两排货架、遮挡、近分候选、端点、不规则柜台、柱体；
- manual event Unix/ARFrame/DB stamp 时间基准负例；
- malformed/truncated/oversized JSONL；
- 输出中途异常、磁盘满、进程中断后的原版本保持；
- 两个并发 append、append+undo、重复 revision；
- optimized DB 被替换、参数变化、工具版本变化时旧 edit 拒绝；
- 相对路径长度、局部速度、曲率、闭环在优化前后变化门；
- 真实脱敏 SQLite + `rtabmap-reprocess` API E2E；
- mapcase01 + 平行通道/周期货架回放；
- JSON/CSV/GeoJSON 标准解析器 round-trip。

### 13.3 必须提供的独立验收证据

- GitHub Actions 或可复现 CI：Python、Swift core、Map Studio、静态检查；
- 干净 Xcode 构建；
- LiDAR iPhone 办公室 30 分钟 dry run；
- 至少一个真实超市单楼层完整路线；
- 控制点和标签真值，不得只挑选成功样本；
- median/P95 位置、P95 航向、通道准确率、灾难跳转；
- 标签位置、货架、侧面、offset、高度正确率；
- tracking recovery、matcher P50/P95、内存、磁盘和 sidecar 增长；
- 原始 DB 前后 hash、派生成果版本和失败回滚证据；
- 自由扫描旧会话回归。

---

## 14. 建议的发布门

### Gate A — 合并开发分支

允许条件：B/H 全部修复，CI 绿色，静态审查无新增 HIGH。

### Gate B — 内部办公室联调

允许条件：真实 SQLite E2E、事务/并发故障测试、iPhone dry run 通过。输出仍标记 `internal_only`。

### Gate C — 受控试运行（APPROVED FOR PILOT）

允许条件：

- 单场地正式 FIELD_TEST_PLAN 完整执行；
- 所有硬指标达标；
- 无灾难性跳转；
- 标签绑定正确率达到预设业务门槛；
- 人工复核和回滚经过非开发人员操作；
- 数据隐私和导出路径清理完成。

### Gate D — 正式生产

当前不在本轮可批准范围。至少需要多场地、多设备、地图版本变化、长期稳定性和独立精度验证。

---

## 15. 修复优先级建议

| 优先级 | 工作项 | 原因 |
|---|---|---|
| P0 | B-01 完整 SE(2) 标签传播 | 直接决定最终标签坐标正确性。 |
| P0 | B-02 离线关联安全门 | 直接决定 shelf/side/offset 正确性。 |
| P0 | H-01 人工锚点统一时间基准 | 大权重锚点绑定错误会扭曲整段轨迹。 |
| P0 | H-02/H-03 事务发布与并发编辑 | 防止已验证结果被损坏或编辑丢失。 |
| P1 | H-04 输入完整性和 provenance | 防止在缺失证据上通过质量门。 |
| P1 | H-05 优化相对残差与形变门 | 建立“保持 RTAB-Map 相对轨迹”的数学证据。 |
| P1 | H-06 发布门重构 | 禁止把内部质量分误当业务准确性。 |
| P2 | 深度平面、报告指标、UI payload、隐私路径 | 提升可解释性、鲁棒性和可用性。 |
| P2 | CI、真实资产、现场计划 | 将实现方声明转化为独立、持续证据。 |

---

## 16. 最终发布建议

**REJECTED**

拒绝原因不是第三阶段功能数量不足，而是最终业务结果的两个核心不变量尚未成立：

1. 优化轨迹发生旋转时，标签必须随捕获节点执行完整刚体变换；当前只平移。
2. 最终货架绑定必须证明可见、唯一且不是被遮挡的更远结构；当前离线流程只选最近边。

在这两个问题存在时，轨迹图、质量分、人工复核 UI 和导出格式即使全部生成，也不能证明最终 `shelfCode + side + offset + height` 是正确的。加上人工锚点时间基准、输出事务、并发编辑、输入完整性和质量门缺口，本提交不应进入受控试运行。

第一、二阶段的修复值得保留，并已达到可继续开发和独立真机验证的水平。建议先完成上述 P0/P1，再进行一次聚焦第三阶段的重新审查；通过后再执行正式 FIELD_TEST_PLAN。

---

## 附录 A：主要源码证据位置

| 主题 | 文件与位置 |
|---|---|
| iOS 包完整性 | `PriorMapPackageIntegrityCore.swift`；`PriorMapLocalization.swift:141-286` |
| 多盆地匹配 | `PriorMapScanMatcher.swift:350-545` |
| 时序校正门 | `PriorMapScanMatcher.swift:227-275`；`PriorMapLocalization.swift:476-522` |
| 深度证据 | `PriceTagLocalizationCore.swift:55-200`；`PriceTagVisionScanner.swift:255-370` |
| 在线货架关联 | `PriceTagLocalizationCore.swift:500-900` |
| 对齐新鲜度 | `PriceTagLocalizationCore.swift:202-241`；`PriorMapLocalization.swift:607-700` |
| 结束队列与写保护 | `ViewController.swift:3537-3800`；`SupermarketScanSession.swift` localization transaction methods |
| 第三阶段求解器 | `offline_localization.py:398-520` |
| 第三阶段标签传播 | `offline_localization.py:1093-1114` |
| 第三阶段货架关联 | `offline_localization.py:700-748` |
| 第三阶段发布门 | `offline_localization.py:1150-1274` |
| 成果输出 | `offline_localization.py:1284-1458` |
| 人工编辑重放 | `server.py:1196-1272` |
| 第三阶段测试 | `tools/PriorMap/tests/test_stage3.py` |

## 附录 B：审查环境与未执行项目

- 已读取远端头提交、比较提交和关键源文件。
- 已读取三阶段实现/审查规范和当前远端文档。
- 已审计测试代码、实现方测试报告和 GitHub workflow 状态。
- 未修改仓库。
- 未能在当前环境独立运行 Xcode、Swift、Python 全量回归或真实 `rtabmap-reprocess`。
- 未执行 ARKit/LiDAR 真机测试、办公室 dry run 或真实超市 FIELD_TEST_PLAN。
- 头提交没有 GitHub Actions workflow run。

因此本报告对代码逻辑缺陷给出确定结论；对“构建通过、性能数字、真机效果和现场精度”只评价证据充分性，不替代实际执行结果。
