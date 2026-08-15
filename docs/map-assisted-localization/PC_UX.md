# PC 先验地图工作台交互

> 文档状态：**当前有效（阶段三草稿复核）**。最后核对日期：2026-08-16。

Map Studio 保留单设备、多设备和“导入/管理先验地图”入口，并新增“先验地图会话优化”。自由扫描不要求地图，也不显示无意义的价签复核步骤。

## 地图导入

1. 选择含 `Basic Info + Element Info` 的正式 XLSX；`Shelf Info` 如存在只做审计。
2. 正式工作簿的门店、地图名、画布和 top-left 合同来自 `Basic Info`；界面字段只能留空或提供精确断言，不能覆盖权威值。
3. 选择空输出目录。
4. 后台完成坐标/几何转换、逐文件 hash、跨文件 schema 校验和预览。
5. 显示地图 ID、包 SHA‑256、楼层、范围、元素统计、道路连通和 warning。

地图包成果只通过 artifact allowlist 读取；源 XLSX 不修改。界面说明阶段二有界 LiDAR 结构匹配已经实现，但真实 LiDAR 现场验收仍未完成。

MapCase02 已在 2026-08-09 通过 PC 转换、v2 schema、确定性 canonical/preview 与跨端 frozen golden；手机 host 还完成 compile → integrity → content-addressed install → register → list → exact ID/SHA read。四张真实 XLSX library smoke 通过，但这仍是 host 标准工作簿链路证据，真机重新导入、LiDAR 和现场资格尚未完成；更广产品仍是 **REJECTED / NO-GO / developer smoke only**，J-04 未关闭。PC 离线定位使用 production-default validator，旧 uppercase v2 开发包必须重新导入，不能通过 diagnostic-only 选项进入处理。

## 地图辅助会话向导

“先验地图会话优化”固定执行：

1. 选择并完整校验先验地图包；
2. 选择已正常结束、地图 ID/hash 一致的连续单库会话；服务端要求显式 `finalized=true`、零必需 sidecar 写失败、`localizationEvidenceComplete=true`、`processingEligibility.status=eligible` 且 blockers 为空，缺字段或存在 checkpoint 都拒绝；
3. 对原 SQLite 计算 SHA‑256 并保持只读；
4. `rtabmap-reprocess` 写入 `rtabmap_optimized/optimized.db`；
5. 从优化副本读取相对轨迹，并从 `localization_trace` 恢复不受 map alignment reset 污染的 gauge-neutral 物理移动；
6. 运行 native 完整相对 SE(2) 因子图，并对 helper 报告、factor digest、连通性、gauge、收敛和 node coverage 做严格二次校验；长会话再以 gauge-neutral 运动、严格人工锚点、道路连通性和结构自由空间硬约束生成道路路线复核草稿，native 结果保留审计；
7. 对 ESL v2 输入先验证 session input manifest v3、complete burst watermark、observation/burst exact binding，再按最终节点位姿重算价签位置和结构关联；
8. 运行轨迹点/线段碰撞、道路拓扑、物理步长、距离尺度、weak/lost 和证据质量门禁，再进入轨迹/价签复核；
9. 导出 JSON/CSV/GeoJSON、节点级/秒级校准坐标和预览，以及审计日志。

人工位置证据分为两类。手机持久化的 `MarketScannerManualLocalizationEvent v3` 只有在 tracking/map/floor 身份、递增 alignment version、exact node ID、node stamp、time delta 和 atomic snapshot generation 全部严格通过时，才成为“可信绝对地图锚点”。PC 复核页的新 `set_anchor` 也必须由服务端从不可变 `localized_review.json` 重新绑定唯一 exact node ID、精确 timestamp、floor、coordinate-contract 和 canonical bounds，只有全项一致时才获得相同可信绝对语义。两者按冻结规格的约 3 m 平移和 15°航向不确定度参与求解，不再因相对累计漂移超过 5 m/30°而被丢弃。旧 v2 时间绑定事件、历史 timestamp-only PC 编辑和缺少 exact-node 权威的事件仍受 5 m/30°兼容门约束并以 `unverified_manual_anchor_safety_gate` 审计。

可信人工锚点造成的大 `maximum/P95 correction` 表示地图 gauge 修正，不等价于相邻节点物理瞬移。长会话不会把 correction-field gradient 当作物理连续性的权威：PC 先按每帧 alignment 语义恢复 gauge-neutral 运动，自动 correction 后以此前 `estimatedPose` 为下一增量原点，人工重定位后的首个 post-reset sample 物理位移为零。严格模式把完整结果保存并加载为可复核的 current `draft`；review gate 检查自由空间碰撞、道路拓扑、物理相邻步长、路线/物理距离尺度、节点覆盖、weak/lost、拒绝约束与价签证据。旧 correction-field 指标在自由空间路线生效后仅为诊断。

“测试诊断模式”仍只放宽其他不安全结果的草稿可见性，不放宽 review/publish gate：稳健硬门拒绝的手机约束不会参与求解，但仍完整写入 `localization_constraints.json`、`review_items.json` 和接受率/残差统计。报告固定写入 `diagnostic_mode=true`、`diagnostic_only=true` 和 `diagnostic_mode_enabled` 发布 blocker，因而不能提交为生产成果。

若 `rtabmap-reprocess` 的优化图覆盖不完整或探索性补环产生不安全结果，工作台会单独检查原始 `Node.pose`。全量位姿有限、时间严格递增且相邻平移不超过 3 m、相邻旋转不超过 120°时，可用 `initialMapPose` 生成 `raw_continuous_vio_diagnostic_recovery` 草稿；可信 v3 人工事件继续作为更强绝对锚点。若仅绝对坐标出现大跳变，必须有至少两条独立短距离结构 Link 推导出唯一一致的跨 epoch 刚体变换，且缝合后重新通过连续性门；无桥接、存在多解或真实运动不连续仍按原错误拒绝。该路径不从不完整 `Admin.opt_poses` 渲染 2D/3D 点云成果，强制禁止发布，也不会修改原始数据库；reset 节点、Link、变换与修复前后指标完整写入报告。

数据库轨迹用于先验地图定位时固定采用 `ios_prior` 坐标契约：从 native `R × ARKit × R⁻¹` 恢复手机 `(x,-z)` 和 yaw；地图成果渲染仍保留原选项以兼容既有输出。native 因子图对 RTAB‑Map reciprocal loop 做 canonical 确定性折叠，不因正反向独立细化的小差异整体中止。

默认按钮使用安全参数。GPU、线程、分辨率等仍位于折叠高级参数。源数据库处理前后 hash 不同会立即失败。

## 轨迹复核

`optimized_map_trajectory.geojson` 同时提供在线定位、RTAB‑Map 重处理和先验地图离线优化层，并在各层保存与坐标、node ID、时间戳一一对应的 `yaws_rad`。长路线层来自 gauge-neutral 物理运动、严格人工锚点、道路图连通性和货架/固定结构自由空间约束；它不是把原折线简单旋转或逐点投到最近通道。既有 Map Studio 预览继续显示 prior map/2D/3D 成果。`review_items.json` 列出被拒绝约束、高残差、通道多解、距离尺度偏差和待复核价签。

质量摘要同时显示在线/RTAB‑Map/离线轨迹长度、gauge-neutral 物理里程、道路路线里程、货架内点数、穿越结构线段数、道路拓扑断裂、最大物理/路线步长、各人工锚点分段的距离尺度、平行通道多解区间、weak/lost 总时长、地图约束接受率和实际求解器类型。任一距离尺度偏差超过 5% 时，结果与全部坐标仍保留，但整体标记低置信度并阻断 review/publish。没有外部测量真值时，这些是内部一致性诊断，不等同于绝对定位准确率或唯一通道识别。

独立导出工具会在不可变 version 之外写入 `calibrated_trajectory_export/`：`calibrated_positions_by_node.csv`、`calibrated_positions_1s.csv`、`calibrated_trajectory_on_prior_map.png`、`calibrated_trajectory_timestamped.png` 和 `export_manifest.json`。两个 CSV 均输出标准地图坐标、本地时间、route edge/corridor、通道身份置信度、距离尺度置信度和人工锚点状态；yaw 必须来自 `optimized_phone_pose`。缺少 `yaws_rad` 的旧结果会明确拒绝该导出，避免用运动切线伪造手机朝向。

人工编辑区支持：

- 设置轨迹锚点；
- 禁用错误匹配约束；
- 把区间指定到候选通道；
- 撤销/重做；
- 保存并按相同地图/会话 hash 重放。

联动复核画布同时显示先验结构、在线轨迹、RTAB‑Map 轨迹、离线轨迹与价签，并可按待复核/批准状态和货架筛选价签。选择“设置轨迹锚点”后直接点击绿色离线轨迹 exact node 并拖到正确地图位置；还可直接输入 canonical X/Y/yaw、选择 0.1/0.5/1.0 m 步长、用方向按钮或键盘方向键平移、用 `[`/`]` 或 ±1/±5/±15°按钮旋转，并用东/北/西/南快捷设置朝向。Shift+方向键使用 5 倍步长，Shift+方括号使用 15°；浏览器实际产生的 `{`/`}` 键值也按同一规则处理。数值字段在 change 和 blur 都提交并按 canonical bounds 钳制，避免辅助输入只改变显示值而未改变内部 payload。画布 y-down 只在投影边界转换一次，服务端提交值保持 canonical SE(2)，时间、node、floor、坐标合同、对象 ID 和 JSON 由界面自动生成。其他高级编辑仍保留严格 ID/JSON 入口。

编辑器会按操作类型显示 JSON 示例并在服务端做字段白名单、有限值、地图范围、exact node/time/floor/坐标合同、货架/侧面、边长、offset、位置一致性和批准前校验。服务端生成真实旧值、UUID、UTC 时间和审计事件；无效编辑不会写入新版本。合法人工编辑若生成了低置信度或其他非完整性门禁未通过的不可变版本，界面显示“结果已保留、current 未更新”而不是“处理失败”；原 current 保持可回滚，新的轨迹/价签/审计版本也不删除。

## 价签复核

结果文件同时保存 online、自动重算和 final 位置、online/offline 距离、货架 code/row/cross、`A/B` 或 `E##` 面、offset、高度、三项置信度、人工修改、来源 observation、needsReview 和审批状态。

手机 additive v2 结果把 algorithm evidence 与 on-device user evidence 分开；PC 不允许离线优化静默覆盖任一方。可靠 optimized association 与现场 segment+side 一致时写 `NO_CONFLICT` 并保持 approved；可靠但不一致时写 `USER_CONFIRMATION_CONFLICT`，没有可靠离线候选时写 `OFFLINE_ASSOCIATION_UNAVAILABLE`。后两种情况都必须进入 `REVIEW_REQUIRED`、`rescan_required=true`、`needs_review=true`、`approval_status=pending`。

每个不可变版本的 `session_input_manifest.json`：v1 为历史输入，v2 绑定 Recovery lifecycle，v3 在此基础上额外绑定 `tag_observation_bursts.jsonl`。共享 validator 被 builder、parse-and-hash-once snapshot、bundle hash validator、render/replay 和 localized output store 共同调用：version 必须是严格 JSON integer；v1 只能是 legacy Recovery binding，v2/v3 必须是 bound-v2；文件名按大小写不敏感规则唯一。source database 只能使用安全 basename，并与 `source_manifest.source_database_name` 完全一致；manifest 构建、snapshot 和 verified copy 都拒绝 hardlink、非空 WAL 和 rollback journal。count、last burst ID、payload/symbology、严格递增 burst sequence 或 frame membership 不一致都会在进入业务结果前 fail closed。

人工编辑支持修改价签字段、批准单个价签和批量批准显式 ID 列表。人工值不会被静默覆盖；重新处理先校验 `manual_edits.json` 的地图/会话 hash，再按 cursor 重放。

成果中的 `source_manifest.json` 不包含本机绝对路径。每个不可变版本的 `session_input_manifest.json` 绑定原数据库、metadata 和全部必需 sidecar 的名称、大小、SHA‑256 与 `input_identity_id`。重放所需路径按该 identity 保存在 Map Studio 本机输出根下的 `localized/local_inputs/<input_identity_id>.json`，不通过 artifact API 提供；旧版本不会读取当前版本的可变路径状态。移动成果到另一台电脑后应重新选择完全相同字节的原会话/地图建立本机状态，不能把旧机器路径当作可移植元数据。

## API

```text
POST /api/prior-map/convert
POST /api/prior-map/inspect
POST /api/jobs
  kind=localized, prior_map, session, output, manual_edits?, diagnostic_mode?
POST /api/jobs/<id>/cancel
POST /api/jobs/<id>/localized/edit
  action=append|undo|redo, expected_version_id, expected_revision
POST /api/jobs/<id>/localized/state
  action=submit_review|return_to_draft|publish|revoke
GET  /api/jobs/<id>
GET  /api/jobs
GET  /api/jobs/<id>/runtime-log/<exact-log-name>
GET  /api/jobs/<id>/artifact/<allowlisted-name>
GET  /api/jobs/<id>/localized/versions/<version>/artifact/<allowlisted-name>
```

## 发布含义

当前结果从 `draft` 可在 review gate 通过后生成新的 `review` 版本。只有严格验证通过的 `full_relative_se2_factor_graph` 才具备进入 `published` 状态的 solver capability；`bounded_correction_field` 与 `gauge_neutral_free_space_road_route` 都是不可发布复核草稿，固定包含 solver capability blocker。通道身份多解、路线距离尺度超过 5%、weak/lost 或拒绝约束不会删除结果，但会阻断 review/publish。真实设备与现场资格门在 P5/P6 完成前，产品整体仍为 NO-GO，当前也不向外部业务系统上传。

ESL capture 的 simulator build 已完成当前 App Swift module/文件编译证据，但最终 native C++ 编译被缺失的 platform-scoped Eigen/PCL/OpenCV headers 阻断；真机和现场测试见 [`ESL_CAPTURE_TODO.md`](ESL_CAPTURE_TODO.md)。该证据不是 Apple clean compile-link PASS。本轮最终源码已执行完整 PriorMap 291/291 和 Map Studio 120/120；其中 PriorMap 包含大数据 Swift host 方法。真实样本 `103343` 的自由空间路线仍因 6%–12% 分段距离尺度偏差、weak/lost 和拒绝约束保持不可发布，不得把自动测试通过解释为现场准确率或生产 GO。

## 任务恢复与取消

Map Studio 启动时恢复最近任务历史。浏览器刷新会重新连接活动任务；服务进程重启会把无法证明仍安全执行的任务标记为 `interrupted`，保留进度和原生日志但不自动发布或清理 staging。操作者可以取消活动任务，原生重处理子进程会被终止并回收；新任务仍须选择空输出目录。协议和保留边界见 [`PERSISTENT_JOBS.md`](PERSISTENT_JOBS.md)。
