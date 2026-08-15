# 通道/货架物理约束定位审查整改记录

> 文档状态：**当前有效**。最后核对日期：2026-08-16。

> 2026-08-15 后续状态：本文第 1 节的 P1-B～P2“未完成”是 2026-08-14 整改快照。后续实现已按冻结规格进入代码：manifest v5 四流、epoch/component、三态状态机、点+扫掠线段穿架门、PC 正式 corridor route、accepted concrete shelf-loop/shelf-face 因子和动态结构过滤均已补齐；`map_mismatch` 仲裁按冻结规格不实现。C-1/C-2/C-3 仍为 `CALIBRATION_PENDING`，真机与现场资格仍 NO-GO。当前结论以 [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) 和冻结规格为准。

## 1. 范围与结论

本次整改基于 2026-08-14 对 `fix/manual-anchor-continuous-recovery@bb09e1346a13945b1d4d8fa7eaf174959b528ab9` 的通道/货架物理约束设计审查。整改分支为 `fix/tag-node-local-publication-gate`，核心远端基线仍为 `origin/core-mobile-v1@9a93fbd0ee52944eae5aebedf59ec6a08dedc934`。

本次只关闭能够在当前跨端链路内确定性修复的两个发布阻断：

| 审查项 | 当前状态 | 结论 |
| --- | --- | --- |
| P0 价签坐标重复应用地图变换 | 代码完成，自动化通过 | observation v2 保存 exact-bound-node local 3D；手机/PC 只执行 `T_final_node × P_node` |
| P1-A 低置信/空坐标/未关联/rescan 未进入发布门 | 代码完成，自动化通过 | coordinate contract v2 使用统一 publication invariant，结果读取与任务恢复二次校验 |
| P1-B 正式 epoch/component 与证据合同 | 未完成 | `poseEpoch` 尚未成为 trace/tag/trajectory/manifest 的逐记录正式身份 |
| P1-C 手机 corridor/shelf/side 状态机 | 未完成 | 当前仍只有匿名 alignment basin 和 diagnostic shelf Top-K |
| P1-D PC 混合图正式化 | 未完成 | corridor/free-space route 仍是 review-only，成功后仍禁止发布 |
| P1-E concrete shelf-loop | 未完成 | 缺 loop-window structure、phone↔shelf SE(2)、协方差和 manifest v5 |
| P2 动态物体与地图失配 | 未完成 | 顾客/购物车、货架移动、合法开口和 `map_mismatch` 仍缺正式资格 |

因此，本次结论是：**P0 与 P1-A 已关闭到代码和自动化层；整体仍为 NO-GO / NOT PRODUCTION READY。**

## 2. 项目链路中的位置

当前生产方向仍是 iPhone Pro ARKit/RGB-D/LiDAR/IMU 连续写入单一 SQLite 数据库和严格 sidecar，PC 对原始数据库只读重处理、优化、验证并生成不可变业务成果。手机不使用 AprilTag、ArUco、landmark 或外部 pose prior；NFC 入口继续关闭。

本次修复不改变连续单库、原始数据库只读、PC 输出新目录、低置信成果保留和严格发布门等基本边界。它只修正价签坐标证据的坐标框，并把已有业务质量统计真正接入手机结果发布判断。

## 3. P0：node-local tag observation v2

### 3.1 原错误

旧 writer 将价签写成 prior-map frame 的 `raw_map_position`，后处理却将其当作 raw DB graph frame，执行：

```text
P_final = T_final_node × inverse(T_raw_node) × P_stored
```

当 prior-map gauge 含非零平移或旋转时，这会重复应用地图变换。审查给出的最小反例为：初始 gauge `(100, 50)`、node-local 点 `(1, 0)`，旧链会输出 `(201, 100)`，正确值应为 `(101, 50)`。

### 3.2 原子 node snapshot

`RTABMapApp::getNodeTimeSnapshot()` 与 iOS C ABI 现在在 camera/RTAB-Map 同一锁域内冻结：

- `node_id`
- `node_map_id`
- `node_stamp`
- CameraMobile epoch offset
- snapshot generation
- `T_opengl_world_from_node` 的 translation 和 quaternion

Swift `latestNodeBinding()` 只调用一次 native snapshot，验证有限值、非零 generation、单位四元数和一秒 node-timebase 合同后构造 `simd_float4x4`。价签采集期间的短暂 node publication gap只能复用同一秒内已经冻结的 exact-ID snapshot，不能恢复 nearest-time 猜测。

### 3.3 写入合同

scene-depth 点来自同一接受帧的 software-stabilized camera transform。writer 计算：

```text
P_node = inverse(T_opengl_world_from_node) × P_opengl_world
```

observation v2 的坐标核心为：

```json
{
  "format": "MarketScannerPriceTagObservation",
  "version": 2,
  "bound_node_id": 123,
  "bound_node_stamp": 1780000000.25,
  "bound_node_map_id": 0,
  "coordinate_frame": "RTABMAP_BOUND_NODE_LOCAL",
  "point_in_bound_node_frame": {
    "x_m": 1.0,
    "y_m": 0.2,
    "z_m": 0.1
  },
  "measurement_height_m": 1.3
}
```

`point_in_bound_node_frame` 是最终坐标传播权威。`measurement_height_m` 独立保存业务高度；`raw_map_position` 仅保留在线显示和审计。只有 `scene_depth` / `smoothed_scene_depth` 可以产生 node-local 3D 点；`shelf_plane_ray` 只有二维先验地图交点，不能伪造 node-local 证据。

### 3.4 严格解析与最终传播

Swift 和 Python reader 对 v2 共同复核：

- verified complete burst 中 exact observation/frame 一对一关系；
- bound node ID 唯一存在；
- observation `bound_node_stamp` 与源数据库 node stamp 在 `1e-6` 内相等；
- `bound_node_map_id` 与源数据库一致；
- coordinate frame 精确等于 `RTABMAP_BOUND_NODE_LOCAL`；
- node-local x/y/z 为有限、有界数值；
- depth measurement 必须有 node-local 点，ray/unavailable measurement 必须没有。

手机和 PC 最终统一执行：

```text
P_final = T_final_node × P_node
```

resolver 不再读取或组合 `T_raw_node`，也没有五秒 nearest-node fallback。PC 的非零 gauge 回归冻结为：final node `(100, 50, 90°)`、`P_node=(1,0)`，结果必须为 `(100,51)`。

### 3.5 历史 v1

历史 v1 的 `raw_map_position` 已在 prior-map frame，且没有完整 capture-time 可逆变换。当前兼容策略是：

- 严格解析并保留 barcode、symbology、burst/business identity；
- 不把 `raw_map_position` 放入最终坐标传播字段；
- 清空可发布地图坐标；
- `quality_status=LOW_CONFIDENCE`；
- 生成 `RESCAN_REQUIRED`，原因 `legacy_tag_coordinate_frame_rescan_required`；
- coordinate-frame audit 计入 legacy blocker。

该策略避免用猜测迁移历史坐标，也避免删除旧业务记录。

## 4. P1-A：统一 publication invariant

旧手机 pipeline 在统计价签质量之前，仅凭 prior-map frame、graph quality 和 pipeline degradation 决定 `COMPLETE`。因此存在有地图点但未关联货架、或价签为 `LOW_CONFIDENCE`，结果仍被标成可发布的路径。

coordinate contract v2 现在先完成全部计数，再按以下不变量决定发布：

```text
publish_permitted
iff coordinates_are_prior_map_frame
 AND graph_quality_passed
 AND degradation_count == 0
 AND coordinate_frame_audit_passed
 AND legacy_tag_coordinate_frame_count == 0
 AND low_confidence_tag_count == 0
 AND unpositioned_tag_count == 0
 AND unassociated_tag_count == 0
 AND rescan_task_count == 0
```

manifest、质量报告和 workbook RunSummary 新增/同步：

- `coordinate_contract_version = 2`
- `coordinate_frame_audit_passed`
- `legacy_tag_coordinate_frame_count`
- 原有 low-confidence、unpositioned、unassociated、rescan、degradation 计数

`MobileResultLibrary` 与 committed task recovery 都重复检查 manifest 不变量。coordinate contract v1 仍可作为历史 review artifact 读取，但不得声明 `COMPLETE/publish_permitted=true`。

PC localized output 同步统计 `tag_rescan_required_count`、`legacy_tag_coordinate_frame_count` 和 `coordinate_frame_audit_passed`，并把 unpositioned、unassociated、low-confidence、rescan、legacy/coordinate audit failure 全部作为 review/publish blocker。

## 5. 自动化证据

本次新增或更新的回归覆盖：

- native C/Swift/RTABMapApp symbol contract；
- Swift observation v2 writer/parser/resolver；
- exact node ID/stamp/map ID 复核；
- verified burst authority；
- 非零平移和 90° gauge 只应用一次；
- v1/v2 混合输入；
- `raw_map_position` 缺失/损坏不覆盖 node-local authority；
- node-local 点缺失/非法时清坐标并要求重扫；
- PC 源数据库只读与结果可复现；
- coordinate contract v2 manifest、result library 和 task recovery 发布门。

当前已执行：

- `tools.PriorMap.tests.test_stage3`：126/126 PASS；
- SE(2) propagation + tag binding focused：19/19 PASS；
- native symbol contract：73 C exports、72 Swift calls、71 RTABMapApp calls，PASS；
- Swift parse：受影响文件 PASS；
- 完整 PriorMap discover（含 Swift host 长方法）：329/329 PASS，378.876 s；
- 300,000 finalization：输入 114,933,372 bytes，wall 8.111 s，CPU 8.076 s，峰值 RSS 13,287,424 bytes；
- 1,728,000 trace：保留 172,801 条，wall 0.405 s，CPU 0.407 s，峰值 RSS 59,146,240 bytes；
- 400,000 tag evidence：输入 282,352,646 bytes，接受 200,000 条，wall 29.046 s，CPU 28.916 s，峰值 RSS 747,192,320 bytes；
- Qualification：30/30 PASS；Map Studio：131/131 PASS；native：7884 checks / 0 failures。

tag evidence v2 字段增加后，峰值高于之前记录的约 450 MiB，仍低于冻结的 768 MiB host 门但余量有限。最终 exact-SHA runner 必须继续报告真实输入字节、wall/CPU time 和 peak RSS；不能沿用旧数字，也不能把 CPU fallback 标成设备/GPU 成功。

## 6. 明确未完成的设计项

以下项目没有包含在本次补丁中，也不得从 P0/P1-A 的测试通过反推为已完成：

1. `poseEpoch`、raw/corrected transform、component 和 epoch bridge 的正式逐记录 sidecar 与 manifest/hash 合同；
2. 手机 `corridor_id/shelf_id/side` 资源有界 Top-K/beam 状态机与歧义 UI；
3. 人体/设备胶囊体、手机前伸容差、合法开口和 swept-segment 穿架检测；
4. 长货架 cross-axis/yaw 与 along-axis covariance 分离；
5. PC corridor/free-space 进入正式混合因子图或正式验证链；
6. exact loop windows、局部结构、concrete shelf identity、phone↔shelf SE(2)+covariance 的 shelf-loop factor；
7. session input manifest v5、跨端 strict parser、水位、资源上限、mutation tests 和不可变 hash tree；
8. 动态顾客/购物车抑制、长期静态一致性、货架移动/地图开口失配和 `map_mismatch` 降级；
9. 手机/PC 对同一 immutable session 的通道、货架、side 和价签控制点现场一致性资格。

PC 当前的 `corridor_route_matcher.py` 仍只生成 review draft；应用成功时仍明确设置 `full_factor_graph=false`、`published_capable=false`。手机回环附近 shelf Top-K 仍是 `diagnostic_only_not_localization_factor`。

## 7. 尚未执行的资格验证

本次没有执行或不能替代：

- exact-final-SHA 签名真机安装；
- LiDAR/scene-depth 近距离价签控制点；
- Files/FileProvider 大型数据库与 sidecar 导出；
- thermal serious、低磁盘、内存压力和两小时 soak；
- 动态顾客、购物车、手机伸手扫描和碰撞恢复；
- 真/假 loop、跨 component、跨 epoch 无 bridge；
- 多条平行合法通道、端头/转角消歧；
- Sam 现场轨迹 along/cross aisle、yaw、shelf ID/side、tag offset 指标；
- Device Lab、Field Evidence 和 production publication matrix。

## 8. 发布判定

允许表述：

- P0 node-local tag coordinate path 已实现并通过 host/PC 自动化；
- P1-A publication invariant 已实现并在 writer/read/recovery 层验证；
- 历史 v1 不再产生可发布坐标；
- 低置信、空坐标、未关联和 rescan 不再遗漏于手机发布门。

禁止表述：

- 已实现完整通道/具体货架连续配准；
- 已实现 concrete shelf-loop；
- 已证明不穿架轨迹唯一；
- 已证明最终价签现场精度合格；
- 已通过签名真机、Sam 现场或生产发布资格。

最终状态：**NO-GO / NOT PRODUCTION READY**。
