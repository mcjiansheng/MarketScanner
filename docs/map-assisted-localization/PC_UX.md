# PC 先验地图工作台交互

> 文档状态：**当前有效（阶段三）**。最后核对日期：2026-07-25。

Map Studio 保留单设备、多设备和“导入/管理先验地图”入口，并新增“先验地图会话优化”。自由扫描不要求地图，也不显示无意义的价签复核步骤。

## 地图导入

1. 选择含 `Element Info` 的 XLSX。
2. 可选输入业务地图名称。
3. 选择空输出目录。
4. 后台完成坐标/几何转换、逐文件 hash、跨文件 schema 校验和预览。
5. 显示地图 ID、包 SHA‑256、楼层、范围、元素统计、道路连通和 warning。

地图包成果只通过 artifact allowlist 读取；源 XLSX 不修改。界面说明阶段二有界 LiDAR 结构匹配已经实现，但真实 LiDAR 现场验收仍未完成。

## 地图辅助会话向导

“先验地图会话优化”固定执行：

1. 选择并完整校验先验地图包；
2. 选择已正常结束、地图 ID/hash 一致的连续单库会话；
3. 对原 SQLite 计算 SHA‑256 并保持只读；
4. `rtabmap-reprocess` 写入 `rtabmap_optimized/optimized.db`；
5. 从优化副本读取全局一致相对轨迹；
6. 运行鲁棒带状 SE(2) 派生修正；
7. 重算价签位置和结构关联；
8. 运行质量门禁并进入轨迹/价签复核；
9. 导出 JSON/CSV/GeoJSON 和审计日志。

默认按钮使用安全参数。GPU、线程、分辨率等仍位于折叠高级参数。源数据库处理前后 hash 不同会立即失败。

## 轨迹复核

`optimized_map_trajectory.geojson` 同时提供在线定位、RTAB‑Map 重处理和先验地图离线优化层；既有 Map Studio 预览继续显示 prior map/2D/3D 成果。`review_items.json` 列出被拒绝约束、高残差和待复核价签。

人工编辑区支持：

- 设置轨迹锚点；
- 禁用错误匹配约束；
- 把区间指定到候选通道；
- 撤销/重做；
- 保存并按相同地图/会话 hash 重放。

联动复核画布同时显示先验结构、在线轨迹、RTAB‑Map 轨迹、离线轨迹与价签，并可按待复核/批准状态和货架筛选价签；点击价签或问题会自动带入编辑对象。对象 ID 和 JSON 值仍用于精确、可审计编辑；地图上直接拖拽锚点仍是后续可用性增强。

编辑器会按操作类型显示 JSON 示例并在服务端做结构/时间戳校验；无效编辑不会写入日志或触发无效果的重放。

## 价签复核

结果文件同时保存 online、自动重算和 final 位置、online/offline 距离、货架 code/row/cross、`A/B` 或 `E##` 面、offset、高度、三项置信度、人工修改、来源 observation、needsReview 和审批状态。

人工编辑支持修改价签字段、批准单个价签和批量批准显式 ID 列表。人工值不会被静默覆盖；重新处理先校验 `manual_edits.json` 的地图/会话 hash，再按 cursor 重放。

## API

```text
POST /api/prior-map/convert
POST /api/prior-map/inspect
POST /api/jobs
  kind=localized, prior_map, session, output, manual_edits?
POST /api/jobs/<id>/localized/edit
  action=append|undo|redo
GET  /api/jobs/<id>
GET  /api/jobs/<id>/artifact/<allowlisted-name>
```

## 发布含义

`automatic_publish_allowed=false` 的结果只是“需要人工复核”，不是失败，也不能作为权威发布。当前没有实现向外部业务系统自动上传；用户检查后导出的本地文件仍保留完整审计链。
