# 阶段二实时定位与价签测量设计

> 文档状态：**当前有效（已实现设计）**。最后核对日期：2026-07-24。
> 阶段一状态仍为“整改后待独立复审”，阶段二也待独立复审与真机干跑；本文不把任何阶段描述为已获独立批准。

## 范围与边界

阶段二在 `prior_map_localized` 模式中增加：

- ARKit 高频水平预测；
- scene depth 有界结构采样；
- 单楼层先验结构距离场上的有限 SE(2) 搜索；
- Top-3 假设、唯一性、连续性和多帧一致性门控；
- Vision QR/条形码识别；
- 深度反投影或货架边射线求交；
- 货架、侧面、沿货架起点距离和高度关联；
- 追加式定位/观测日志与原子标签快照。

不改变：

- 自由扫描默认流程；
- 连续单 SQLite 数据库；
- 原始 ARKit/RTAB-Map 三维数据；
- 单次扫描绑定一个楼层；
- NFC 暂停；
- PC 原始数据库只读策略。

## 模块

```text
PriorMapLocalizationCore.swift
  ├─ SE(2)、阈值、状态滞回、更新门控
  └─ 可在 macOS 直接执行的数学契约

PriorMapDepthSampler.swift
  └─ ARFrame sceneDepth -> 有界局部水平结构点

PriorMapScanMatcher.swift
  └─ 多分辨率距离场、有限搜索、鲁棒评分、Top-K

PriceTagVisionScanner.swift + PriceTagLocalizationCore.swift
  ├─ Vision 识别调度与帧时间绑定
  ├─ 深度中位数、反投影、射线 fallback
  └─ ShelfAssociation

PriorMapLocalization.swift
  └─ 包加载、localizer 编排、HUD 和确认 UI

SupermarketScanSession.swift
  └─ 追加 JSONL、原子 localized_price_tags.json
```

## 线程与生命周期

- `ARSessionDelegate` 把当前 `ARFrame` 引用交给有界调度器；最多一个结构任务和一个用户触发的 Vision 任务在途，任务结束后释放帧。
- 结构匹配使用单独串行队列，目标 1–2 Hz；最多一个任务在途，忙时丢弃旧价值较低的新任务。
- Vision 使用独立串行队列，只有用户点击“扫描价签”后才接受一个有时限请求，不启动第二相机。
- 每个后台结果带 session generation 和 gate ticket；暂停、清理、结束或新会话会使旧结果失效。
- 深度点最多 1,200 个，matcher 最多使用 600 点，搜索候选最多 3 个，标签去重窗口 2 秒。
- 内存/温度保护继续由现有扫描控制器负责；原始采集按现有资源策略处理。

## 坐标

- 地图二维：米，`+x` 向右、`+y` 向上、yaw 0 指向 `+y`、逆时针为正。
- ARKit 水平：`+x -> map +x`、`-z -> map +y`；ARKit 竖直 `y` 只用于标签高度和原始三维数据。
- 深度像素先按对应帧内参反投影到相机坐标，再用该帧 camera transform 变到 ARKit 世界坐标，最后使用当前 `T_map_from_arkit`。
- 任何 Vision observation 必须与创建它的 ARFrame 时间、相机 transform、内参和深度缓冲绑定，不使用“当前最新 pose”替代历史帧 pose。

## 地图结构与扫描匹配

地图包新增 version 1 `distance_fields.json`，每层提供：

- 0.40 m coarse 栅格，用于恢复搜索；
- 0.20 m medium 栅格，用于常规有限搜索；
- 0.10 m fine 栅格，用于局部精修；
- 栅格原点、宽高、2 m 截断距离、量化厘米距离、逐行 RLE 和 canonical rows SHA-256。

距离场由可见货架、柱子、柜台和柜台特征边界生成。扫描匹配：

1. 以 ARKit 预测为中心；
2. coarse/medium/fine 逐级搜索有限 `dx/dy/dyaw`；
3. 使用截断平方鲁棒损失；
4. 计算有效点数、覆盖角、最佳/次佳分数和唯一性；
5. 道路只保留为显示/弱先验，不参与结构唯一性的硬判定；
6. 保留 Top-3 非极大候选；
7. 通过平移、角度、连续性、多帧一致性和 tracking 恢复门后才更新 `T_map_from_arkit`；
8. 普通单次接受上限 0.35 m / 8°，更大变化只能进入 recovery 或人工校准。

地图长期不匹配时记录 `mapMismatch`，保持 ARKit 预测，不强拉到地图。

## 状态与集中阈值

状态源只有定位器：

```text
uninitialized -> initializing -> stable | usable | weak | lost
                                      \-> manualCorrection -> initializing
```

集中阈值：

- stable：有效点不少于 80、唯一性不少于 0.22、连续接受至少 3 帧；
- usable：有效点不少于 45、唯一性不少于 0.10；
- weak：tracking limited、匹配拒绝或最后成功校正超过 4 秒；
- lost：tracking unavailable，或超过 10 秒无可信观测；
- 从 weak/lost 接受新可信观测后先进入 usable，连续 3 个高质量可信帧才进入 stable；
- 置信度综合 tracking、有效点、覆盖角、唯一性、残差、连续性和观测新鲜度。

`weak/lost` 不自动确认最终价签；只保存 `needsReview=true` 的原始观测。

## Vision 与价签测量

- 使用 `VNDetectBarcodesRequest` 处理当前 `ARFrame.capturedImage`。
- 支持 QR、EAN-8/EAN-13、Code 128、UPC-E 和 PDF417。
- 识别请求由用户按钮触发，后台执行，保留 payload、symbology、归一化框和帧时间。
- 深度路径使用码框中心/角点及内点的有效深度中位数，拒绝非有限、过近/过远、离群和时间不匹配。
- 无可靠深度时，只能用相机射线与候选货架边的竖直平面求交；若几何不唯一或射线方向不合理，保留 pending observation。
- 永远同时记录 raw 与 snapped 位置；手机位置不得作为标签位置。

货架关联评分综合到边距离、射线朝向、货架法线、边内投影和遮挡。最佳/次佳接近、超出边范围、背面或隔着其他结构时标记复核。

## Sidecar

已有文件继续保留，并新增：

```text
localization_constraints.jsonl
localization_events.jsonl
tag_observations.jsonl
localized_price_tags.json
```

JSONL 每次写一条完整记录；标签集合写临时文件并原子替换。每条记录包含 schema version、prior map ID/hash、floor ID、tracking session ID 和来源时间。定位日志记录全部接受/拒绝原因和 Top-3，而不只记录成功结果。

## 失败策略

- 缺深度：Vision 结果仍保存，但不伪造高置信三维位置。
- 候选相似：保持 Top-K，降低状态，不跨通道跳转。
- 地图结构缺失/变化：记录 `mapMismatch`，继续 ARKit 和原始数据库。
- tracking 中断：停止接受地图校正，恢复后等待连续可信帧。
- 队列忙/任务过期：丢弃并记录，不积压。
- 标签定位 weak/lost：保存待复核，不自动确认。
- sidecar 写入失败：记录扫描错误并提示用户；不修改或回滚原始数据库。

## 验证

自动回放必须覆盖平行通道、周期货架、交叉口/柱子、动态离群点、地图缺段、错误起点、tracking 恢复、Top-K 分数接近、深度离群、无深度、pose 时间不匹配和货架关联边界。

模拟指标只用于软件基线，不作为真实超市精度：

- 无歧义路线 median ≤ 0.25 m、p95 ≤ 0.60 m、yaw p95 ≤ 8°；
- 通道准确率 ≥ 99%；
- 无未记录 recovery 的 >2 m 跳转；
- 高置信标签关联准确率 ≥ 98%。

真实 iPhone 办公室/走廊干跑仍是阶段二独立复审条件，不能由模拟结果替代。
