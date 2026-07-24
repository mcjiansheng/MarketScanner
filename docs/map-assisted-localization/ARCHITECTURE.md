# 已有地图辅助定位架构

> 文档状态：**当前有效（阶段一）**。最后核对日期：2026-07-24。

## 范围

阶段一建立先验地图、双模式采集和可回放验证基础，不实现 LiDAR/视觉结构自动匹配，也不实现价签测量。现有自由扫描、连续 RTAB-Map 单库、PC 重处理和 NFC 暂停策略保持不变。

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
    -> T_map_from_arkit 初始投影
    -> 2 Hz 道路候选与小幅软约束
    -> localization_trace.jsonl
    -> 人工确认 -> manual_localization_events.jsonl
  同时继续写入原 RTAB-Map 连续数据库
```

## 模块边界

- `tools/PriorMap/coordinate_system.py` 是 PC 侧唯一坐标转换实现。
- `tools/PriorMap/xlsx_reader.py` 只读解析 XLSX 的标准 ZIP/XML，不依赖 Excel、Pandas 或 OpenPyXL。
- `tools/PriorMap/xlsx_to_prior_map.py` 生成确定性地图包、逐楼层预览、道路图和结构/道路空间索引。
- `tools/PriorMap/stage1_localizer.py` 是回放使用的阶段一定位器。
- `app/ios/RTABMapApp/PriorMapLocalizationCore.swift` 定义可直接执行测试的双模式与 SE(2) 投影契约；`PriorMapLocalization.swift` 使用同一地图格式实现道路软约束和业务 UI。
- `SupermarketScanSession.swift` 只负责安全落盘和审计 sidecar；原始数据库仍是权威输入。

## 安全边界

- 源 XLSX 和扫描 SQLite 数据库只读。
- 转换先写临时目录，通过 schema 校验后原子发布。
- prior-map 定位失败、较弱或丢失不会停止或改写 RTAB-Map 原始采集。
- 道路约束只在附近候选唯一时接受，增量增益为 0.15，单次修正最大 0.25 m；相似平行通道候选接近时拒绝修正。
- 大幅修正只来自用户明确确认，并写入审计日志。
- iOS ARFrame 回调按 0.5 s 节流；同一时刻只允许一个定位更新，忙时丢弃新更新并记录计数，避免队列积压。
- iOS 使用道路网格索引只查询当前位置附近边；没有 `road_cells` 的旧包才兼容回退到全量道路。
- 地图导入先复制并校验临时目录，再原子替换应用缓存；外部源包和已有可用缓存不会先被删除。
- NFC 入口保持关闭。

## 阶段二接口

阶段二可安全依赖：

- `PriorMapPackage` version 1；
- 米制 SE(2) 和 `T_map_from_arkit` 方向；
- road graph、5 m 结构/道路有界空间索引；
- `localization_trace.jsonl` 的接受/拒绝原因和 Top-3 道路候选；
- `manual_localization_events.jsonl`；
- PC `workflow_mode` 兼容读取。

阶段二应在后台定位器中增加深度结构提取、距离场匹配、Top-K 假设和置信度滞回，不得改变上述原始数据安全边界。

阶段二实现的权威线程、状态、距离场、扫码测量和失败策略见 `STAGE_2_DESIGN.md`。在代码和自动测试完成前，该设计中的能力均属于计划状态。
