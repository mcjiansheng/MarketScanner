# 已有地图辅助定位架构

> 文档状态：**当前有效（阶段一至阶段三草稿复核）**。最后核对日期：2026-08-16。

## 范围

阶段二在阶段一先验地图和双模式采集基础上增加深度结构匹配与 Vision 价签定位；阶段三增加 PC 派生轨迹优化、质量门禁、人工复核和最终导出。现有自由扫描、连续 RTAB-Map 单库和 NFC 暂停策略保持不变。

正式超市 XLSX 路径以 `Basic Info + Element Info` 为双权威输入，`Shelf Info` 只审计。iOS 与 PC 共用 production role、top-left anchor、strict XLSX、canonical v3 和 prior-map package v2 合同；包完整性从 active elements 确定性重建 canonical identity、road graph、spatial grid、distance fields 与 shelves-v2 方向语义。2026-08-09 MapCase02 局部链路结论为 `MAPCASE02 / STANDARD SUPERMARKET XLSX FORMAT PASS`，不改变整体 **REJECTED / NO-GO / developer smoke only** 或 J-04 **BLOCKER / NOT CLOSED**。

阶段一定位范围限定为单次扫描绑定单一楼层。地图包可包含多个楼层供开始前选择，但扫描中不切换楼层，也不建立跨楼层约束。ARKit `x/z` 投影到地图 `x/y`；楼层内少量竖直位移不进入二维先验位姿，原始 ARKit/RTAB-Map 三维数据照常保存。

```text
Basic Info + Element Info XLSX（只读；Shelf Info 仅审计）
  -> tools/PriorMap 统一坐标与几何
  -> 版本化 PriorMap-* 包
       ├─ PC Map Studio 导入、校验、缩放预览
       ├─ iOS 五步向导与 2D HUD
       └─ synthetic / trajectory_samples 回放

iOS prior_map_localized
  ARKit 高频相对运动
    -> T_map_from_arkit ARKit 预测
    -> 跨帧稳定结构点（最多 1200 点）
    -> 0.40/0.20/0.10 m 距离场粗中细搜索
    -> Top-3 + 几何/唯一性/连续性/修正幅度门控
    -> 小步更新地图对齐锚点（不重置 ARKit）
    -> localization trace / constraints / state events
    -> 人工确认 -> manual_localization_events.jsonl
  用户触发 ESL Capture Mode（持续复用 ARFrame，不暂停扫描）
    -> camera-only preview + 真实/扩展 Vision ROI（10 Hz / one-in-flight）
    -> 2-frame candidate lock -> 3 minimum / 4 target durable frames
    -> 同帧 depth 中值/MAD 或货架平面射线
    -> 至少 3 个逐帧可靠的同 segment+side quorum
    -> 同一次 atomic node snapshot 生成 node-local observation v2
    -> complete burst -> 专用货架确认
    -> algorithm evidence + additive user evidence v2
  同时继续写入原 RTAB-Map 连续数据库
  同时约每 5 秒写 performance_samples.jsonl
    -> CPU / 内存 / 磁盘 / 热 / 电池 / FPS / RTAB-Map update / 数据增长
    -> final metadata 提交 count / last sequence / last timestamp / complete 水位

PC prior-map localized
  原始 SQLite（只读）
    -> rtabmap-reprocess 新数据库副本
    -> RTAB-Map 全局一致相对轨迹
    -> native 完整相对 SE(2) 因子图
       （相对/闭环边 + 在线结构/道路软约束 + 严格人工绝对锚点）
       -> helper 缺失/失败时 bounded correction field draft fallback
       -> 图不完整但 raw Node.pose 完整可恢复时
          raw_continuous_vio_diagnostic_recovery diagnostic draft
          （坐标系 reset 需多条独立短 Link 的唯一一致桥接）
    -> manifest v3 绑定 Recovery + tag burst sidecar
    -> 全部价签重算/重关联并检查现场确认冲突
    -> 自动质量门禁
    -> manual_edits.json 可撤销重放
    -> localized/.staging-* 完整生成和校验
    -> localized/versions/vNNNNNN 不可变版本
    -> current.json 原子切换；published.json 受硬门控制

PC Map Studio result
  performance_samples.jsonl（只读）
    -> strict framing / finite scalar / identity / sequence / timestamp / metadata watermark
    -> performance/phone/ 原始 JSONL + CSV + summary
    -> Web 有界降采样趋势、峰值、分位数、热状态与采样缺口
```

## 模块边界

- `tools/PriorMap/coordinate_system.py` 是 PC 侧唯一坐标转换实现。
- `tools/PriorMap/xlsx_reader.py` 只读解析 XLSX 的标准 ZIP/XML，不依赖 Excel、Pandas 或 OpenPyXL。
- `tools/PriorMap/xlsx_to_prior_map.py` 生成确定性地图包、逐楼层预览、道路图、空间索引和多分辨率结构距离场。
- `tools/PriorMap/distance_field.py` 生成并验证逐层 RLE 距离场；`replay_stage2.py` 是确定性结构匹配回放。
- `tools/PriorMap/stage1_localizer.py` 是回放使用的阶段一定位器。
- `PriorMapScanMatcher.swift`、`PriorMapDepthSampler.swift` 和 `PriorMapLocalization.swift` 分别负责距离场匹配、深度证据与串行状态/地图对齐。
- `RTABMap.swift`/`NativeWrapper.*` 以一次原子快照返回最近 node ID、node map/component ID、node stamp、CameraMobile timebase offset、generation 和 `T_opengl_world_from_node`；Swift 人工定位或价签证据不得把分次 getter 拼成跨时刻证据。
- `PriceTagVisionScanner.swift` 只消费 ARKit 当前帧和同帧 software-stabilized camera transform，执行真实 ROI、串行 one-in-flight Vision；`PriceTagCaptureCore.swift` 负责 generation、节流、候选锁定、bounded capture 和可靠多帧 quorum；`PriceTagCaptureUI.swift` 提供 camera-only preview 与专用货架确认页；`PriorMapLocalization.swift` 用 atomic node pose 计算 `P_node = inverse(T_opengl_world_from_node) × P_opengl_world`，`PriceTagLocalizationCore.swift` 负责 schema-v2 node-local 记录、平台无关货架关联、segment+side identity 和 additive v2 用户证据。
- `PriorMapPackageIntegrityCore.swift` 在 iOS 导入前核验包清单、逐文件摘要和跨文件关系。
- `tools/PriorMap/offline_localization.py` 是阶段三派生 SE(2) 修正、价签重关联、质量门禁、人工编辑重放和导出实现。
- `tools/PriorMap/localized_output_store.py` 在 POSIX/Windows 跨进程文件锁内管理 staging、不可变 version、成果 schema/hash 清单、输入身份和 current/published 单提交点原子指针；Windows 使用 write-through 原子移动，读取和 artifact 下载按 version 内清单及已打开文件字节再次复核完整性。
- `SupermarketScanSession.swift` 只负责安全落盘和审计 sidecar；原始数据库仍是权威输入。
- `performance_samples.jsonl` 是独立可观测性 sidecar，不是 pose、地图坐标或发布授权。`tools/SupermarketMapStudio/performance_analysis.py` 流式校验并生成结果包性能工件；坏证据关闭性能资格但不删除有限地图数据。

## 安全边界

- 源 XLSX 和扫描 SQLite 数据库只读。
- 性能时间线受 250,000 条、256 MiB 文件和 64 KiB 单行硬上限约束；正常采样约 5 秒一条，48 小时资格规模为 34,560 条。序号/时间必须严格递增，tracking session 必须与 metadata 精确一致，禁止 NaN/Infinity、空行和缺 final newline。
- iOS 不提供普通应用可用的可靠整机 GPU utilization 百分比。写侧固定声明 `not_available_public_ios_api`，PC 不允许用 CPU、FPS 或 Metal helper 是否存在推导手机 GPU 利用率。
- 性能写失败只把 `performanceEvidenceComplete` 置为 false 并写审计；它不能升级为定位坐标损坏，也不能删除安全落盘的数据库。PC 对安全大小内的坏原始日志使用 `.invalid.jsonl` 完整保留，同时拒绝生成可信趋势。
- 转换先写临时目录，通过 schema 校验后原子发布。
- prior-map 定位失败、较弱或丢失不会停止或改写 RTAB-Map 原始采集。
- 结构匹配最多使用 600 点；距离残差、角覆盖、Top-K 唯一性、两帧一致性均通过后才允许修正。自动结构修正平移上限按冻结规格收紧为 0.25 m（角度仍为 8°），应用增益 0.35。
- 道路只作显示/弱先验，不把相似平行通道当作结构证据硬吸附。
- 大幅自动修正继续拒绝。手机人工位置只有在 v3、exact node、identity、node stamp/time delta、atomic snapshot generation 全部通过时，才作为约 3 m/15°不确定度的绝对地图锚点；PC `set_anchor` 也必须从不可变复核版本 authoritative recheck 唯一 exact node/time/floor/coordinate-contract/bounds 后才取得相同语义。旧 v2、历史 timestamp-only 和无 exact binding 的编辑仍受 5 m/30°兼容门约束，但不能取得冻结规格下的新锚点 authority。
- iOS ARFrame 回调按 0.5 s 节流；同一时刻只允许一个定位更新，忙时丢弃新更新并记录计数，避免队列积压。
- iOS 使用道路网格索引只查询当前位置附近边；没有 `road_cells` 的旧包才兼容回退到全量道路。
- 地图导入先复制并校验临时目录，再原子替换应用缓存；外部源包和已有可用缓存不会先被删除。
- NFC 入口保持关闭。
- Vision 不创建 `AVCaptureSession`；检测、深度和相机位姿来自同一个 `ARFrame`。对齐快照按实际时间差和版本滞后分为 fresh/aging/stale，stale 观测强制复核。
- Capture Mode 不暂停 ARSession、RTAB-Map、连续数据库、Clock、Pose、node creation 或 prior-map localization。Vision/preview/evidence/UI completion 全部受 generation gate；取消、系统中断、最终化和 prior-map unload 会统一失效旧工作。
- session admission gate 是 localization/confirmation writer 与 finalization 的唯一线性化点。finalization 关闭新 admission 后等待所有已登记 transaction/reservation；已登记 writer 在取得序列化锁后不会被内部二次 finalization 检查误拒。finalization 排空在主线程之外完成，timeout 只改变等待提示，不允许在实际 drain 前半封口或发布 snapshot。
- prior-map queue 在入队前和执行前都检查 generation 与 finalization；因此 drain sentinel 后排入的普通 ARFrame 任务不能更新 localizer 或写普通 Recovery。普通 frame-driven Recovery 显式使用 `allowDuringFinalization=false`，只有 terminal teardown/finalization Recovery 使用 true。
- 原始价签观测先落盘，complete burst 再落盘，最终价签才允许用户明确确认。最终化与 PC reader 对每个 `observation_id / burst_id / frame_id / payload / symbology` 做精确交叉绑定，v2 tag 的 frame set 必须精确等于一个 verified complete burst，tag payload/symbology 必须与 burst 相等，burst sequence 必须为正且严格递增。schema-v2 depth observation 还必须精确匹配源数据库 node ID/stamp/map ID，并声明 `coordinate_frame=RTABMAP_BOUND_NODE_LOCAL`；最终位置只按 `P_final = T_final_node × P_node` 重投影。weak/recovering、低测量/低关联置信不能授权自动确认，但只要 complete burst、exact node 和 node-local 位置权威齐全，就保留为 `LOW_CONFIDENCE`；不足 3 帧、身份/图质量、exact node 或 node-local 位置权威缺失仍为 `RESCAN_REQUIRED`。历史 v1 的 prior-map `raw_map_position` 不再进入传播公式，只保留业务记录并要求重扫。
- 手机 immutable result 使用 coordinate contract v2。`COMPLETE/publish_permitted=true` 必须同时满足：prior-map 坐标权威、图质量通过、无 pipeline degradation、coordinate-frame audit 通过、legacy coordinate count 为 0、低置信/空坐标/未关联价签均为 0、rescan task 为 0。结果库读取和任务恢复会重复检查该不变量；旧 coordinate contract v1 只可作为不可发布复核工件读取。
- capture generation 冻结 exact tracking session identity。ESL audit 只通过 active-only API 追加到已存在的 `segment_0001`，不隐式启动 session；普通迟到 audit 在 finalization 后拒绝，只有 scan-stop 自有 cancellation/continuity audit 可使用窄范围 override，因此旧 callback 不会创建空后继 session 或污染新扫描。
- 算法候选与用户选择在 schema 中分离；用户确认不得修改算法字段、SLAM、地图对齐、node pose 或 localization constraint。替代候选使用 `shelfSegmentId + side` 精确 identity。
- native helper 可用时阶段三运行完整相对 SE(2) 因子图；只有 helper 缺失或失败才标记 `bounded_correction_field`，该 fallback 不具备正式发布资格。可信人工锚点造成的大绝对 pose update 只能在 native caller 明确证明 gauge authority 时跳过绝对更新量门，相对边、闭环残差、图连通与 correction-field 梯度仍 fail closed。
- bounded fallback 使用 O(N) 三对角精确求解连续 correction field，避免固定迭代在千节点轨迹上形成锚点尖峰。可信人工锚点允许大 maximum/P95 绝对修正进入 current draft，但相邻 correction 平移超过 0.5 m 或航向超过 15°仍阻断 review。
- RTAB-Map 图不完整时，恢复路径要求 raw `Node.pose` 全量有限、时间严格递增；相邻运动连续时可用 `initialMapPose` 保留低置信度轨迹，严格 v3 人工锚点提供更强地图 gauge。若绝对 Node.pose 因坐标 epoch 重置发生大跳变，至少两条独立短距离结构 Link 必须对同一刚体变换形成唯一一致，且缝合后步长/旋转仍安全；缺少桥接、多解或真实大跳变继续拒绝。结果固定 diagnostic-only、不从坏 `Admin.opt_poses` 生成点云、不发布。
- 阶段三每次处理前后核对原数据库 SHA-256；所有必需 sidecar 严格校验 UTF‑8、JSON、format/version、身份、时间戳、大小和唯一 ID。失败不切换旧 current。
- iOS 必需定位 sidecar 的每次追加都返回结构化结果；失败会粘性写入 `captureHealth` 并持续显示红色告警，同时停止新的地图修正、人工校正和价签确认，原始 DB 继续录制到用户结束。`metadata.json` 是 sidecar bundle 的最后提交标记：提交前失败可恢复录制；`finalized=true` 提交后 checkpoint 清理失败只能进入关闭数据库的待清理终态；证据不完整则提交 `finalized=false` 恢复包并终止会话，不能恢复 prior-map 录制。
- PC 对已有地图会话同时要求显式 `finalized=true`、`localizationEvidenceComplete=true`、零必需写失败和空 blocker 列表，缺失旧字段也按不可处理拒绝。
- PC session input manifest v3 在 v2 Recovery 绑定之上纳入 `tag_observation_bursts.jsonl` 的 exact bytes/hash。共享 validator 统一 writer、bundle hash、snapshot/replay 与 output store：严格 integer version；v1/v2/v3 Recovery marker；case-insensitive filename uniqueness；source database 安全 basename、source-manifest 名称 cross-binding、single-link regular-file 身份，以及 non-empty WAL/journal 拒绝。现场选择与可靠离线关联一致时为 `NO_CONFLICT` 且保持 approved；可靠冲突为 `USER_CONFIRMATION_CONFLICT`，离线证据不足为 `OFFLINE_ASSOCIATION_UNAVAILABLE`，后两者都强制 review/rescan，且不覆盖用户或算法证据。
- 人工编辑由服务端生成旧值、UUID、UTC 时间和 base revision；version/revision CAS 必填，重放成功后才提交新不可变版本。

2026-08-15 已将 PC corridor route、手机 top-K basin 和 concrete shelf identity 升级为正式证据链：manifest v5 绑定 epoch transition、corridor top-K、shelf observation window 和 shelf loop；手机提交单一 top1 并在多解时标记 `LOW_CONFIDENCE`，不阻塞扫描；PC 仅把冻结门接受的两侧 shelf loop 转成 shelf-face 因子，native helper 用各向异性平移信息矩阵只强约束货架面法向、弱化沿架方向，并在全图优化后执行 point/swept-segment free-space 与 corridor 自洽发布门。价签最终坐标是采集侧货架长边投影，不是货架中心线或原始融合点。阈值标定、真机性能和现场矩阵仍未关闭，因此整体仍为 **NO-GO / NOT PRODUCTION READY**。

阈值、线程所有权、恢复策略和失败矩阵的权威说明见 `STAGE_2_DESIGN.md`。
