# 阶段一测试计划

> 文档状态：**当前有效**。最后核对日期：2026-07-24。

## 自动测试

```bash
python3 -m unittest discover -s tools/PriorMap/tests -v
python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v

python3 -m py_compile \
  tools/PriorMap/*.py \
  tools/Supermarket2DMap/supermarket_2d_map.py \
  tools/SupermarketMapStudio/server.py

xcrun swiftc -parse \
  app/ios/RTABMapApp/PriorMapLocalizationCore.swift \
  app/ios/RTABMapApp/PriorMapLocalization.swift \
  app/ios/RTABMapApp/SupermarketScanSession.swift \
  app/ios/RTABMapApp/ViewController.swift

node --check tools/SupermarketMapStudio/web/app.js
git diff --check
```

覆盖：

- XLSX `Element Info`、六种 shape；
- 损坏 JSON、未知类型、隐藏元素；
- 业务字段保留；
- 坐标轴、厘米/米、90° 旋转矩形、bounds；
- 道路字符串/数字 ID、缺失引用、连通统计；
- 空间网格边界查询；
- schema 和逐字节可复现输出；
- PNG 预览有效；
- PC API 异步导入、检查、artifact allowlist、源 XLSX 不变；
- 自由扫描旧会话兼容和连续单库识别；
- 直接编译运行 iOS 无 UI 核心，验证双模式启动门控和 SE(2) 投影；
- 平行通道歧义拒绝、唯一道路软修正上限；
- synthetic drift、tracking lost、道路分配和数值误差。

## 样例地图验收

```bash
out="$(mktemp -d /private/tmp/prior-map.XXXXXX)"
rmdir "$out"
python3 tools/PriorMap/xlsx_to_prior_map.py map/mapcase01/mapcase01.xlsx --output "$out"
python3 tools/PriorMap/validate_prior_map.py "$out"
python3 tools/PriorMap/replay_localization.py "$out" \
  --output /private/tmp/prior-map-replay \
  --floor 1 \
  --translation-drift-per-m 0.01 \
  --rotation-drift-deg-per-m 0.02 \
  --tracking-loss-start 30 \
  --tracking-loss-length 8
```

核对 manifest 元素统计为 1,563、楼层为 1/2，并视觉对比 preview 与用户 PNG 的方向、结构和比例。

## iOS 手工干跑

无需超市场景：

1. 构建到支持 ARKit 的 iPhone。
2. 新建自由扫描，确认原连续单库和 sidecar 不变。
3. 新建已有地图辅助扫描，完成五步向导。
4. 在办公室步行，确认 HUD 轨迹连续；遮挡相机后变 weak/lost，但数据库继续增长。
5. 人工确认/重新选择位置，检查两个 JSONL。
6. 正常结束，确认 metadata 地图身份、无 checkpoint、NFC 不可见。

正式超市验收不属于阶段一。
