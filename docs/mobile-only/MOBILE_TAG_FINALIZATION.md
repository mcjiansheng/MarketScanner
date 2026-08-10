# 价签最终定位（Mobile Tag Finalization）

> 状态：**当前有效**；IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED。最后核对：2026-08-10。

## 绑定优先级

唯一生产绑定是 observation 写入时持久化的 exact `boundNodeID`，并用同一 binding snapshot 写入 node-timebase timestamp/offset。resolver 以 node ID O(1) 查找并验证时间恒等式；不存在 5 秒 nearest-node fallback，也不混用第二次独立 node-timebase 查询。

拒绝：session/map/floor mismatch、node missing/duplicate、node timebase 恒等式错误、stale alignment、非有限 pose、formal measurement 不变量矛盾。

## 位置传播

```text
P_final = T_final_node * inverse(T_raw_node) * P_raw
```
内部保留 3D，业务输出 2D。

## Burst 融合

新扫描 UX：识别条码 → 锁定 ROI → 最多 4 秒多帧 depth/pose（目标 4 帧、最低 3 帧）→ 自动结束 → `TagObservationBurst` v2。Vision 最多 10 Hz；主 ROI 无结果时只对同一 ARFrame 追加一次有界扩展 ROI，ARKit autofocus 保持启用。
同物理价签（同 barcode + 同 floor + 空间接近）融合为一个 `tag_instance_id`；同 barcode 不同位置保持多个实例，不做全局去重。

只有 `complete=true`、非空且通过 watermark 的 verified burst 可被消费。burst summary 必须从 frame 重算；frame ID 与 observation ID 在文件全局唯一，每个 frame 必须恰好对应一个 observation，且 observation 必须反向精确引用同一 burst/frame。tie 投票输出 `unknown`，不得任意选一方。

## 货架关联

货架线段 A-B、价签点 P：
```text
d = B - A
s = dot(P-A, d) / length(d)
u = s / length(d)
distance_from_shelf_start_cm = s * 100
position_ratio = u
```
以 `shelf_segment_id` 作为物理唯一键，同时保留展示用 `shelf_code` 与 `shelf_side`；start/end/axis 使用 compiler v2 语义。遮挡检测使用完整 tag→shelf sight segment、AABB broad phase 与 polygon edge/collinear overlap，相交柱体/结构会阻断关联；端点模糊区（±0.15 m）标记 ambiguous。

## 自动质量门（三态）

`ACCEPTED` 要求：exact node/time 绑定、verified complete burst、有效多帧支持、位置 spread ≤0.1 m、图质量通过、uncertainty 可用且通过阈值、货架 segment/side 唯一、关联距离 ≤0.2 m、无遮挡、不在端点模糊区、map/session/floor identity 一致且 `needsReview=false`。

`LOW_CONFIDENCE` 表示 complete burst、exact node/raw pose、会话身份和可重算位置均有效，但 recovering/weak、depth/view、node uncertainty、spread 或货架关联不足以自动批准。该行保留在 PriceTags，使用最终 node pose 重投影，不自动生成 RescanTask。

`RESCAN_REQUIRED` 只用于缺失权威证据：burst 不完整、identity/graph 失败、exact node/raw pose 不存在、measurement method/可解析位置不可用等。它与 `LOW_CONFIDENCE` 不得混计，后者绝不能升级为 `ACCEPTED`。

## 测试（Swift host）

- G1：explicit node 绑定 + 位置传播（T_final*inv(T_raw)*P）。
- G2：exact bound-node 不存在或时间恒等式错误时 fail closed。
- G4/G5：burst 融合成物理实例；同 barcode 两楼层两实例。
- G6：货架投影（500 cm / 0.5 ratio / 0.05 m 距离）。
- G7：端点/平行货架/遮挡歧义 → LOW_CONFIDENCE。
- G10：充分支持的中段价签 ACCEPTED；complete 但 weak/review → LOW_CONFIDENCE；burst 不足或 exact raw-node pose 缺失 → RESCAN_REQUIRED。
