# 已有地图辅助定位架构

> 文档状态：**当前有效（阶段一至阶段三草稿复核）**。最后核对日期：2026-08-09。

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
    -> camera-only preview + 真实 Vision ROI（8 Hz / one-in-flight）
    -> 2-frame candidate lock -> 3 minimum / 4 target durable frames
    -> 同帧 depth 中值/MAD 或货架平面射线
    -> 至少 3 个逐帧可靠的同 segment+side quorum
    -> raw observation -> complete burst -> 专用货架确认
    -> algorithm evidence + additive user evidence v2
  同时继续写入原 RTAB-Map 连续数据库

PC prior-map localized
  原始 SQLite（只读）
    -> rtabmap-reprocess 新数据库副本
    -> RTAB-Map 全局一致相对轨迹
    -> bounded correction field（非完整相对 SE(2) 因子图）
       （在线结构约束 + 道路软约束 + 人工锚点/通道区间 + 鲁棒拒绝）
    -> manifest v3 绑定 Recovery + tag burst sidecar
    -> 全部价签重算/重关联并检查现场确认冲突
    -> 自动质量门禁
    -> manual_edits.json 可撤销重放
    -> localized/.staging-* 完整生成和校验
    -> localized/versions/vNNNNNN 不可变版本
    -> current.json 原子切换；published.json 受硬门控制
```

## 模块边界

- `tools/PriorMap/coordinate_system.py` 是 PC 侧唯一坐标转换实现。
- `tools/PriorMap/xlsx_reader.py` 只读解析 XLSX 的标准 ZIP/XML，不依赖 Excel、Pandas 或 OpenPyXL。
- `tools/PriorMap/xlsx_to_prior_map.py` 生成确定性地图包、逐楼层预览、道路图、空间索引和多分辨率结构距离场。
- `tools/PriorMap/distance_field.py` 生成并验证逐层 RLE 距离场；`replay_stage2.py` 是确定性结构匹配回放。
- `tools/PriorMap/stage1_localizer.py` 是回放使用的阶段一定位器。
- `PriorMapScanMatcher.swift`、`PriorMapDepthSampler.swift` 和 `PriorMapLocalization.swift` 分别负责距离场匹配、深度证据与串行状态/地图对齐。
- `RTABMap.swift`/`NativeWrapper.mm` 以一次原子快照返回最近 node ID、node stamp、CameraMobile timebase offset 和 generation；Swift 人工定位事件不得把分次 getter 拼成跨时刻证据。
- `PriceTagVisionScanner.swift` 只消费 ARKit 当前帧并执行真实 ROI、串行 one-in-flight Vision；`PriceTagCaptureCore.swift` 负责 generation、节流、候选锁定、bounded capture 和可靠多帧 quorum；`PriceTagCaptureUI.swift` 提供 camera-only preview 与专用货架确认页；`PriceTagLocalizationCore.swift` 负责平台无关的货架关联、segment+side identity 和 additive v2 用户证据。
- `PriorMapPackageIntegrityCore.swift` 在 iOS 导入前核验包清单、逐文件摘要和跨文件关系。
- `tools/PriorMap/offline_localization.py` 是阶段三派生 SE(2) 修正、价签重关联、质量门禁、人工编辑重放和导出实现。
- `tools/PriorMap/localized_output_store.py` 在 POSIX/Windows 跨进程文件锁内管理 staging、不可变 version、成果 schema/hash 清单、输入身份和 current/published 单提交点原子指针；Windows 使用 write-through 原子移动，读取和 artifact 下载按 version 内清单及已打开文件字节再次复核完整性。
- `SupermarketScanSession.swift` 只负责安全落盘和审计 sidecar；原始数据库仍是权威输入。

## 安全边界

- 源 XLSX 和扫描 SQLite 数据库只读。
- 转换先写临时目录，通过 schema 校验后原子发布。
- prior-map 定位失败、较弱或丢失不会停止或改写 RTAB-Map 原始采集。
- 结构匹配最多使用 600 点；距离残差、角覆盖、Top-K 唯一性、两帧一致性均通过后才允许修正。自动修正上限为 0.35 m/8°，应用增益 0.35。
- 道路只作显示/弱先验，不把相似平行通道当作结构证据硬吸附。
- 大幅修正只来自用户明确确认，并写入审计日志。
- iOS ARFrame 回调按 0.5 s 节流；同一时刻只允许一个定位更新，忙时丢弃新更新并记录计数，避免队列积压。
- iOS 使用道路网格索引只查询当前位置附近边；没有 `road_cells` 的旧包才兼容回退到全量道路。
- 地图导入先复制并校验临时目录，再原子替换应用缓存；外部源包和已有可用缓存不会先被删除。
- NFC 入口保持关闭。
- Vision 不创建 `AVCaptureSession`；检测、深度和相机位姿来自同一个 `ARFrame`。对齐快照按实际时间差和版本滞后分为 fresh/aging/stale，stale 观测强制复核。
- Capture Mode 不暂停 ARSession、RTAB-Map、连续数据库、Clock、Pose、node creation 或 prior-map localization。Vision/preview/evidence/UI completion 全部受 generation gate；取消、系统中断、最终化和 prior-map unload 会统一失效旧工作。
- session admission gate 是 localization/confirmation writer 与 finalization 的唯一线性化点。finalization 关闭新 admission 后等待所有已登记 transaction/reservation；已登记 writer 在取得序列化锁后不会被内部二次 finalization 检查误拒。finalization 排空在主线程之外完成，timeout 只改变等待提示，不允许在实际 drain 前半封口或发布 snapshot。
- prior-map queue 在入队前和执行前都检查 generation 与 finalization；因此 drain sentinel 后排入的普通 ARFrame 任务不能更新 localizer 或写普通 Recovery。普通 frame-driven Recovery 显式使用 `allowDuringFinalization=false`，只有 terminal teardown/finalization Recovery 使用 true。
- 原始价签观测先落盘，complete burst 再落盘，最终价签才允许用户明确确认。最终化与 PC reader 对每个 `observation_id / burst_id / frame_id / payload / symbology` 做精确交叉绑定，v2 tag 的 frame set 必须精确等于一个 verified complete burst，tag payload/symbology 必须与 burst 相等，burst sequence 必须为正且严格递增。weak/lost、低测量/低关联置信或不足 3 个逐帧可靠证据均不能授权确认。
- capture generation 冻结 exact tracking session identity。ESL audit 只通过 active-only API 追加到已存在的 `segment_0001`，不隐式启动 session；普通迟到 audit 在 finalization 后拒绝，只有 scan-stop 自有 cancellation/continuity audit 可使用窄范围 override，因此旧 callback 不会创建空后继 session 或污染新扫描。
- 算法候选与用户选择在 schema 中分离；用户确认不得修改算法字段、SLAM、地图对齐、node pose 或 localization constraint。替代候选使用 `shelfSegmentId + side` 精确 identity。
- 阶段三求解器明确标记为 `bounded_correction_field`：x/y/yaw 带状平滑没有实现 RTAB‑Map 相对边/闭环边的耦合 SE(2) 残差，不具备正式发布资格。
- 阶段三每次处理前后核对原数据库 SHA-256；所有必需 sidecar 严格校验 UTF‑8、JSON、format/version、身份、时间戳、大小和唯一 ID。失败不切换旧 current。
- iOS 必需定位 sidecar 的每次追加都返回结构化结果；失败会粘性写入 `captureHealth` 并持续显示红色告警，同时停止新的地图修正、人工校正和价签确认，原始 DB 继续录制到用户结束。`metadata.json` 是 sidecar bundle 的最后提交标记：提交前失败可恢复录制；`finalized=true` 提交后 checkpoint 清理失败只能进入关闭数据库的待清理终态；证据不完整则提交 `finalized=false` 恢复包并终止会话，不能恢复 prior-map 录制。
- PC 对已有地图会话同时要求显式 `finalized=true`、`localizationEvidenceComplete=true`、零必需写失败和空 blocker 列表，缺失旧字段也按不可处理拒绝。
- PC session input manifest v3 在 v2 Recovery 绑定之上纳入 `tag_observation_bursts.jsonl` 的 exact bytes/hash。共享 validator 统一 writer、bundle hash、snapshot/replay 与 output store：严格 integer version；v1/v2/v3 Recovery marker；case-insensitive filename uniqueness；source database 安全 basename、source-manifest 名称 cross-binding、single-link regular-file 身份，以及 non-empty WAL/journal 拒绝。现场选择与可靠离线关联一致时为 `NO_CONFLICT` 且保持 approved；可靠冲突为 `USER_CONFIRMATION_CONFLICT`，离线证据不足为 `OFFLINE_ASSOCIATION_UNAVAILABLE`，后两者都强制 review/rescan，且不覆盖用户或算法证据。
- 人工编辑由服务端生成旧值、UUID、UTC 时间和 base revision；version/revision CAS 必填，重放成功后才提交新不可变版本。

本轮未修改 MapCase02 几何、地图坐标转换或任何 store/map/file-specific scale、offset、rotation 规则；只修改 canonical filesystem ID、package bytes、production validator 和 MobileMapLibrary 安装身份合同。真机/性能/现场矩阵和低影响增强见 [`ESL_CAPTURE_TODO.md`](ESL_CAPTURE_TODO.md)；当前整体仍为 **REJECTED / NO-GO / developer smoke only**，J-04 未关闭。

阈值、线程所有权、恢复策略和失败矩阵的权威说明见 `STAGE_2_DESIGN.md`。
