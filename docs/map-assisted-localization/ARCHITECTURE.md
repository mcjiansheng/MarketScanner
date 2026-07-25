# 已有地图辅助定位架构

> 文档状态：**当前有效（阶段一至阶段三）**。最后核对日期：2026-07-25。

## 范围

阶段二在阶段一先验地图和双模式采集基础上增加深度结构匹配与 Vision 价签定位；阶段三增加 PC 派生轨迹优化、质量门禁、人工复核和最终导出。现有自由扫描、连续 RTAB-Map 单库和 NFC 暂停策略保持不变。

阶段一定位范围限定为单次扫描绑定单一楼层。地图包可包含多个楼层供开始前选择，但扫描中不切换楼层，也不建立跨楼层约束。ARKit `x/z` 投影到地图 `x/y`；楼层内少量竖直位移不进入二维先验位姿，原始 ARKit/RTAB-Map 三维数据照常保存。

```text
Element Info XLSX（只读）
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
  用户触发 Vision（复用 ARFrame）
    -> 同帧 depth 中值/MAD 或货架平面射线
    -> 货架/侧面/offset/高度和三项置信度
    -> raw observation -> 用户确认 -> localized tag
  同时继续写入原 RTAB-Map 连续数据库

PC prior-map localized
  原始 SQLite（只读）
    -> rtabmap-reprocess 新数据库副本
    -> RTAB-Map 全局一致相对轨迹
    -> robust banded SE(2) correction IRLS
       （在线结构约束 + 道路软约束 + 人工锚点/通道区间 + 鲁棒拒绝）
    -> 全部价签重算/重关联
    -> 自动质量门禁
    -> manual_edits.json 可撤销重放
    -> JSON/CSV/GeoJSON + audit_log.jsonl
```

## 模块边界

- `tools/PriorMap/coordinate_system.py` 是 PC 侧唯一坐标转换实现。
- `tools/PriorMap/xlsx_reader.py` 只读解析 XLSX 的标准 ZIP/XML，不依赖 Excel、Pandas 或 OpenPyXL。
- `tools/PriorMap/xlsx_to_prior_map.py` 生成确定性地图包、逐楼层预览、道路图、空间索引和多分辨率结构距离场。
- `tools/PriorMap/distance_field.py` 生成并验证逐层 RLE 距离场；`replay_stage2.py` 是确定性结构匹配回放。
- `tools/PriorMap/stage1_localizer.py` 是回放使用的阶段一定位器。
- `PriorMapScanMatcher.swift`、`PriorMapDepthSampler.swift` 和 `PriorMapLocalization.swift` 分别负责距离场匹配、深度证据与串行状态/地图对齐。
- `PriceTagVisionScanner.swift` 只消费 ARKit 当前帧；`PriceTagLocalizationCore.swift` 负责平台无关的货架关联和安全判定。
- `PriorMapPackageIntegrityCore.swift` 在 iOS 导入前核验包清单、逐文件摘要和跨文件关系。
- `tools/PriorMap/offline_localization.py` 是阶段三派生 SE(2) 修正、价签重关联、质量门禁、人工编辑重放和导出实现。
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
- 原始价签观测先落盘；最终价签需要用户明确确认。weak/lost 以及低测量/低关联置信结果强制 `needs_review=true`。
- 阶段三求解器是专用的鲁棒带状 SE(2) 修正 IRLS，不声称是通用完整因子图；RTAB-Map 重处理轨迹保持相对运动权威，人工锚点和地图观测只作用于派生结果。
- 阶段三每次处理前后核对原数据库 SHA-256；失败或质量门未通过时只生成待复核派生结果，不发布为权威成果。

阈值、线程所有权、恢复策略和失败矩阵的权威说明见 `STAGE_2_DESIGN.md`。
