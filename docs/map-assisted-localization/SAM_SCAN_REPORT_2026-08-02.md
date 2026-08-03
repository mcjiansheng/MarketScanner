# Sam 先验地图辅助扫描诊断报告

> 文档状态：**当前有效**。最后核对日期：2026-08-02。
> 适用数据：`SupermarketSession-20260802-093522`、`SamTestCase1`、`MapStudio-Localized-Diagnostic-20260802-183000`。
> 结论边界：这是一次测试数据和只读数据库诊断，不构成生产资格验收。

## 1. 执行结论

本次原始扫描 **可用于算法调试和误差评估**。连续数据库正常结束、传感器时间连续、最终优化轨迹速度合理、闭环数量充足，未发现源数据库损坏、漏写或必须放弃本次扫描的证据。

当前“本地化质量门禁未通过”的首要原因不是操作者把整条路线扫坏，而是 PC 离线本地化读取 iOS/RTAB-Map 位姿时使用了错误的历史坐标约定：轨迹被近似旋转/镜像后，手机确认点被误算为相距 52—117 m，在线定位约束被误算为相距 66—68 m。按 iOS 实际坐标契约重新投影后，五个有效人工确认点的平面残差为约 **0.48、1.95、2.99、3.34、3.70 m**，与测试阶段允许 3—5 m 初始误差的目标一致。

第二个阻断原因是 native 因子图把 RTAB-Map 中方向相反、独立细化后有轻微差异的回环边当成“矛盾重复边”并中止。数据库中的这类差异属于正常图数据，不应令整条处理回退到不可发布的 bounded solver。

本次现场仍暴露了真实的操作、性能和算法问题：长时间高热降频、采样率频繁振荡、平行货架歧义、动态购物车遮挡、不规则货架证据不足、人工定位界面难操作，以及在线 localizer 缺少多候选轨道和闭环触发的全局恢复。这些问题需要修复，但不等同于原始扫描无效。

## 2. 输入与安全性

| 项目 | 结果 | 判断 |
| --- | ---: | --- |
| 扫描时长 | 62 分 55.7 秒 | 长时真实负载样本 |
| 连续数据库 | 1 个，约 1.861 GB | 符合当前连续单库协议 |
| finalized | `true` | 正常结束 |
| 必需 sidecar 写失败 | 0 | 证据链完整 |
| 源数据库处理方式 | 只读；优化写入新库 | 安全边界正确 |
| 传感器位姿 | 195,973 | 数据充足 |
| 接受映射帧 | 195,323 | 99.67% 被接受 |
| 质量拒绝帧 | 380 | 比例低 |
| 最大传感器时间间隔 | 0.05 s | 未见明显采集中断 |
| 最终 RTAB-Map 节点 | 4,442 | 与优化/成果一致 |

`metadata.nodeCount=170` 是结束时在线 working memory 计数，不是最终数据库只有 170 个节点；用它判断“绝大多数节点丢失”是错误的。最终节点覆盖检查和优化库均得到 4,442 个节点。

## 3. 扫描质量与操作者行为

### 3.1 正常操作

- 操作者完成了约 63 分钟连续扫描，没有产生额外 `segment_*`，也没有遗留 live checkpoint。
- 扫描过程中发生 13 次人工定位操作：5 次成功确认、8 次拒绝。成功确认能够绑定到真实 node/time 快照，说明已经使用了人工纠偏流程。
- 轨迹覆盖了较大区域并形成 386 个闭环候选，其中 330 个被标记为可靠闭环；最终轨迹不是一条无闭环的纯里程计链。
- 扫描结束和 finalization 约 3.012 秒，源数据与 sidecar 正常提交。

### 3.2 可改进的现场操作

- 19,128 帧被记录为低特征。白色重复货架、长直通道和视野被购物车占据时，应增加斜向观察货架端头、立柱、转角、天花/地面交界等非周期结构。
- 不规则货架区域的几何证据弱；建议在货架端头和凹凸转折处做短弧线或侧向移动，不要只沿通道中心直行。
- 购物车或人员长时间占据深度视野会被短时持久化为结构证据。现场应避免让大型动态物体持续位于相机前方，尤其是在人工确认后的数秒内。
- 当界面已显示 weak/lost 时，继续快速直行不会产生可靠地图约束；应减速、回看最近的稳定端头或交叉通道，再恢复前进。

以上属于操作建议，不是本次门禁失败的主要根因。现有 UI 也没有充分帮助操作者完成这些动作，因此不能把问题单独归因于人。

## 4. 性能与资源分析

| 指标 | 观测 | 分析 |
| --- | --- | --- |
| tracking limited / unavailable | 63 / 1 | 总量不高，但弱纹理区集中出现 |
| tracking recovery reject | 10 | 有恢复尝试被质量门拒绝 |
| thermal serious checkpoint | 65 | 存在持续高热区间，可能降低深度/特征处理频率 |
| adaptive rate changed | 467 | 调整过于频繁，存在阈值附近振荡 |
| 最终轨迹速度中位数 / P95 / 最大值 | 0.363 / 0.616 / 0.892 m/s | 实际行走速度正常 |
| 最终角速度中位数 / 最大值 | 3.48 / 74.34 °/s | 可接受，快速转身应保守处理 |
| 原始高频速度峰值 | 22.732 m/s | 采样间隔很小时的位姿抖动，不是真实行走速度 |
| 原始高频角速度峰值 | 285.492 °/s | 同上，应避免作为最终轨迹断裂结论 |
| Metal 深度投影 | 4,442/4,442 帧，12.012 s | Apple M5 后端正常，无 GPU 失败或 CPU 冒充 |
| matcher 耗时 | 中位数约 1.4 ms | 性能足够，主要问题是候选正确率而非速度 |

当前原始 pose discontinuity 门使用至少 0.45 m 的距离阈值。对 20—50 Hz 数据，这会放行“距离未到 0.45 m、但瞬时速度已不可能”的样本，造成夸张峰值和误导性报告。应同时使用基于 `dt` 的速度/角速度门，并将原始高频抖动与最终节点轨迹分开报告。

## 5. 地图与结构证据

原地图 `SamTestCase1` 包结构有效：1,563 个元素，楼层 1 的边界约 97.73 × 69.27 m；道路图含 281 个节点、333 条边。道路图有 3 个连通分量、2 个孤立点和 3 条 warning，属于应人工复核的地图拓扑问题，但不足以解释 50—100 m 的系统性残差。

本次深度结构侧写包含 6,180 个深度帧、9,753 个稳定单元、7,404 个多视角单元和 1,740 个地面冲突单元，覆盖分数约 0.6237。最终成果解析了全部 4,442 帧，检测 149 个货架/竖直结构，其中直接证据支持率约 45.43%。这说明：

- 深度数据不是空的，成果生成链可工作；
- 周期货架和动态遮挡使“可用于唯一定位”的结构远少于“可见结构”；
- 约 0.68 m 的垂直基准偏移 warning 需要在现场控制点中复核，但不是本次二维轨迹大角度错位的原因。

## 6. 在线本地化异常

`localization_trace.jsonl` 有 7,408 条记录，只有 2 条接受约束，接受率约 0.027%；7,300 条为 weak、90 条 lost、12 条 initializing、6 条 usable，没有进入 stable。主要拒绝原因：

| 原因 | 数量 | 含义 |
| --- | ---: | --- |
| ambiguity / 周期歧义 | 4,102 | 平行货架产生多个近似同分候选 |
| safety gate | 1,253 | 最佳候选相对当前估计跳变过大 |
| points/evidence insufficient | 1,212 | 可用静态结构点不足 |
| 其他状态/时效门 | 余量 | tracking、stale、初始化等 |

候选 confidence 中位数约 0.553，但 uniqueness 中位数仅约 0.0204。这表明 matcher 很快地找到了“看起来能对齐”的结果，却无法证明它是唯一通道。当前实现每帧只保留最佳候选、局部搜索窗仅约 1.2 m/12°、安全更新约 0.35 m/8°，也没有消费 RTAB-Map 闭环事件触发更大范围恢复。因此在错误初值、3—5 m 偏移、20—30°角度误差和平行通道中容易长期 weak/lost。

需要用多候选 lane hypothesis 跨帧跟踪：候选必须由连续运动、道路拓扑、转角/端头和闭环共同确认；在唯一性不足时宁可保持 weak，也不能静默跳到相邻通道。

## 7. 人工定位与交互异常

8 次人工定位被拒绝的共同原因是 `native_node_time_snapshot_unavailable`，说明确认动作发生时没有得到可审计的 native node/time 原子快照。另有 5 次成功确认，证明链路并非完全失效。

现场截图还显示：

- 手机端用 X/Y/yaw 数字输入调整起点，无法在真实货架环境中直观完成 3—5 m、20—30°修正；
- 地图/面板和红色方向箭头过大，遮挡相机和结构反馈；
- PC 端要求对象 ID 和 JSON，难以由非开发人员完成轨迹/锚点复核；
- PC 轨迹显示倾斜和错位，其中主要部分来自坐标契约错误，而不是实际走路轨迹整体倾斜。

修复目标是手机和 PC 都支持直接在地图上点击、拖动、缩放和平移，手机支持双指旋转或旋转手势；数字输入只作为高级诊断，不作为主流程。

## 8. PC 离线门禁失败根因

### 8.1 P0：iOS/PC 坐标契约不一致

iOS 本地定位使用 ARKit 水平面 `(x, -z)`，yaw 由 camera forward 在该平面推导。写入 RTAB-Map 数据库前，native 层保存的是：

```text
N = R × ARKit × inverse(R)
```

因此从数据库恢复 iOS prior-map 坐标应为：

```text
map_x = -N.translation.y
map_y =  N.translation.x
map_yaw = atan2(N.r21, N.r11)
```

旧 PC 路径却用了历史轨迹 sidecar 的 `(-N.y, -N.x)` 和另一套 yaw 公式。该错误会旋转/镜像整条轨迹。按正确公式对真实优化库只读重算，人工锚点残差由 52—117 m 降到 0.48—3.70 m，证明这是实际根因而非推测。

### 8.2 P0：正常 reciprocal loop 被当作矛盾重复边

优化库的 Link 类型计数为：type 0 = 8,392、type 1 = 640、type 2 = 312、type 3 = 1,284、type 9 gravity = 4,442；可接受的非自环相对边中有 5,222 对 reciprocal 记录。相邻 type 0 基本等价，但闭环 type 1/2/3 的正反向记录经过独立更新后存在小差异，最大约 0.084 m / 1.204°。

上游 RTAB-Map `filterDuplicateLinks()` 对同一 canonical edge 确定性保留一条。自定义 helper 却用接近浮点逐值相等的容差比较，随后抛出 `Contradictory duplicate relative Link`。正确策略是确定性折叠 reciprocal edge，让现有 residual、robust kernel 和质量策略判断坏边，而不是在求解前整体中止。

### 8.3 P1：冲突手机约束不能被安全忽略

旧逻辑对 `manual_anchor` 无上限豁免，极端错误锚点能够强拉整图。测试阶段应允许一般的 3—5 m、20—30°人工初始误差，但超过有界安全门的手机锚点必须进入 rejected/audit 并被忽略。在线结构约束仍使用更严格的默认硬门；道路软约束保持低权重。

## 9. 问题分级与修复验收

| 级别 | 问题 | 修复与验收 |
| --- | --- | --- |
| P0 | iOS/PC 坐标不一致 | 独立 `ios_prior` 契约；真实 DB 五个人工点残差回到 0.48—3.70 m |
| P0 | reciprocal loop 令 factor graph 中止 | canonical 确定性折叠；完整 relative SE(2) helper 可完成 |
| P1 | 手机约束冲突强拉轨迹 | 5 m/30°人工安全门，超限记录并忽略 |
| P1 | 单候选局部 matcher 无法恢复 | Top-N 多轨道、跨帧连续性、loop-triggered recovery、平滑 SE(2) |
| P1 | 平行通道可能静默跳转 | uniqueness + 通道拓扑 + 端头/转角确认；不确定时 weak/lost |
| P1 | 人工 node 快照偶发不可用 | 暂存最近有效原子快照、明确过期门和 UI 原因 |
| P1 | 手机/PC 人工交互困难 | 地图点击/拖动/缩放/旋转；PC 隐藏主流程 JSON/ID |
| P1 | 动态购物车污染结构 | 更长时序一致性、运动/占用变化过滤、静态结构优先 |
| P2 | 自适应采样频繁振荡 | 分离升/降阈值、最小驻留时间、热状态退避 |
| P2 | 原始速度峰值误导 | `dt` 速度门；原始传感器和最终节点轨迹分栏 |
| P2 | 不规则货架支持不足 | 端点/角点/立柱证据和非规则折线结构支持 |

## 10. 测试阶段结果策略

测试模式应始终生成一个可打开的 **diagnostic draft**，包含：原始优化轨迹、正确坐标下的 prior-map 轨迹、候选/约束接受与拒绝原因、累计/局部修正、人工锚点残差、通道歧义和质量指标。冲突手机约束可被忽略，但忽略事件必须留在审计中。

diagnostic draft 不能自动冒充 production `published`；只有完整因子图、身份、输入完整性和正式质量门均通过时才更新生产 current。界面需要把“已生成测试草稿”和“生产发布未通过”分别显示，避免把可分析结果误报成完全没有结果。

## 11. 当前修复进度

截至本报告最后核对时，代码整改和自动回归已经完成：

- PC 已使用独立 `ios_prior` 数据库位姿契约，Map Studio 地图渲染的旧坐标选项不受影响；
- reciprocal relative Link 已改为 canonical 确定性折叠；
- 人工锚点使用 5 m/30°安全门，超限约束写入 rejected/audit 并从求解中忽略；
- 手机 matcher 保留 Top‑5 独立盆地。P7R2 跟踪固定的全局 `T_map_from_arkit = T_candidate_map × inverse(T_arkit)`；P7R3 `0e2ce5133c8fb261fc1756111a5173c71d15b380` 进一步把 Recovery 改为独立 episode：开始时清历史 tracks 但保留已应用 anchor，4 帧门只认当前 episode 新证据，40 次有效 matcher attempt/30 秒双上限，无 depth/observation/足量点时不耗 attempt，重复闭环不重置，所有退出清除 wide-search tracks。5 m/30°总门和 0.35 m/8°单步门不变；
- 手机重定位已改为地图点击/拖动/平移/缩放/旋转，PC 锚点改为绿色轨迹点直接拖动并自动生成 node/time/JSON；
- 深度结构需至少 4 个近期帧的同一世界 voxel 证据，自适应检测率使用 8/12 秒升降驻留时间；原始位姿异常同时检查 3 m/s 和 180°/s；
- 非规则折线货架和立柱距离场、平行通道不跳转、4.8 m/29°恢复候选、冲突人工锚点、网页锚点入口均有自动回归。

用修复后的 helper 对同一优化数据库做只读真实回归，结果如下：

| 项目 | 修复后结果 |
| --- | ---: |
| 求解器 | `rtabmap_g2o_slam2d`，`solver_converged=true` |
| 完整图/连通性/完整性 | 全部通过 |
| 节点覆盖 | 4,442 / 4,442 |
| 因子总数 | 5,802 |
| relative neighbor / loop | 4,441 / 1,026 |
| canonical reciprocal 折叠 | 5,467 |
| 接受/拒绝绝对约束 | 335 / 2 |
| P95 relative 平移/角度残差 | 0.0424 m / 0.526° |
| P95 loop 平移/角度残差 | 0.2918 m / 1.702° |
| 最大 loop 平移/角度残差 | 0.8410 m / 5.921° |
| 最大轨迹修正 | 2.9638 m（旧错误结果约 12.83 m） |

被拒绝的两个人工锚点分别为 2.99 m/31.21° 和 3.34 m/34.81°，原因均为 `manual_anchor_safety_gate`；其余 3 个安全人工锚点、2 个在线结构约束和 330 个道路软约束参与求解。该结果作为 `diagnostic draft` 成功切换到测试 current，可查看轨迹、累计修正和残差。

它仍不能发布为生产成果：本次是在诊断模式下生成，质量策略仍是 candidate，最大 pose update 约 2.96 m，且旧手机 sidecar 中 weak/lost 时长约 3,758 秒。后者是 P7R2/P7R3 前 App 采集的在线结果，只有用 P7R3 修复后的 iPhone App 进行同路线、Recovery 专项和遮挡专项重扫，才能验证全局 hypothesis、episode fresh support、有效 attempt 预算和 track cleanup 是否改善。剩余工作包括最终 exact-SHA CI、Swift/iOS 编译执行、修复版真机重扫、现场准确率/累计误差控制点测试和独立人工复核。

P7R2 本地回归已确认 PriorMap 122 项通过，其中 Swift 核心可执行测试覆盖 T1—T11：identity、纯平移、0/90/180°、组合转动平移、±π、转弯中错误高分通道、等分平行通道、5 m/30°边界、5.01 m/30.1°拒绝，以及 100 组确定性随机 `apply(derive(A,C),A)=C` 重建；场景覆盖蛇形转弯、短时动态遮挡、四帧恢复、loop-only authorization 和 corrected HUD。此前同一累计基线的 Supermarket Map Studio 94 项、资格证据 11 项和 iOS unsigned arm64 build 已通过；P7R2 最终治理 HEAD 的完整套件、iOS build 与七组 hosted CI 仍需在本轮提交后重新执行，不能沿用旧 SHA 结果。

P7R3 在 Windows 已通过 15 项 iOS source/sidecar 合同和 20 项 PriorMap Python 可执行测试；Swift host 测试因本机没有 `xcrun`/Apple SDK 延期，新增的 R1—R12 Swift executable 尚未在本机执行。此处的 Python/source PASS 不等于生产 Swift 已执行；必须以 P7R3 final exact-SHA 的 macOS/iOS CI 和之后的 Xcode/真机结果为准。

# P7R4 Recovery confidence closeout note (2026-08-03)

The Sam evidence remains historical input and has not been rerun. P7R4 implementation `218f3ef69a5b68e3e317a4300ed76dd606cb531e` prevents a bounded intermediate Recovery step from making localization stable or auto-confirming a price tag, enforces pre/post-match wall-clock expiry, adds a 20-second automatic cooldown, preserves completion diagnostics under the correct episode, and exposes the actual localizer anchor and full Recovery update reducer to integration tests. This is implementation evidence only; Xcode, LiDAR iPhone, same-route Recovery/occlusion runs, and Sam re-test remain deferred. Do not interpret this note as `SAM FIELD PASS`, `FIELD QUALIFICATION PASS`, or `PRODUCTION READY`.
