# 价签最终定位（Mobile Tag Finalization）

> 状态：IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED（G1/G2/G4/G5/G6/G7/G10）

## 绑定优先级

1. explicit node ID + 匹配时间戳
2. nearest node timestamp
3. frame monotonic timestamp

拒绝：session mismatch、node missing、time delta 超限（5 s）、ambiguous nearby nodes（0.5 s 内第二近）、stale alignment（楼层不一致）。

## 位置传播

```text
P_final = T_final_node * inverse(T_raw_node) * P_raw
```
内部保留 3D，业务输出 2D。

## Burst 融合

新扫描 UX：识别条码 → 锁定 ROI → 0.8~1.5 秒多帧 depth/pose → 自动结束 → `TagObservationBurst`。
同物理价签（同 barcode + 同 floor + 空间接近）融合为一个 `tag_instance_id`；同 barcode 不同位置保持多个实例，不做全局去重。

## 货架关联

货架线段 A-B、价签点 P：
```text
d = B - A
s = dot(P-A, d) / length(d)
u = s / length(d)
distance_from_shelf_start_cm = s * 100
position_ratio = u
```
保留 shelf_code 与 shelf_side；端点模糊区（±0.15 m）标记 ambiguous。

## 自动质量门

ACCEPTED 要求：node/time 绑定通过、burst 样本数 ≥3、位置 spread ≤0.1 m、图质量通过、货架关联距离 ≤0.2 m、不在端点模糊区、side 无歧义、map/session identity 一致。否则 RESCAN_REQUIRED。

## 测试（Swift host）

- G1：explicit node 绑定 + 位置传播（T_final*inv(T_raw)*P）。
- G2：nearest-node 绑定。
- G4/G5：burst 融合成物理实例；同 barcode 两楼层两实例。
- G6：货架投影（500 cm / 0.5 ratio / 0.05 m 距离）。
- G7：端点模糊区 → RESCAN_REQUIRED。
- G10：充分支持的中段价签 ACCEPTED；burst 不足 RESCAN_REQUIRED。
