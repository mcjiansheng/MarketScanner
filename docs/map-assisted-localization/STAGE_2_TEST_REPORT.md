# 阶段二实现与验证报告（历史归档）

> 文档状态：**历史归档**。最后核对日期：2026-07-25。
> 当前实现与验证状态以 `IMPLEMENTATION_STATUS.md` 和 `STAGE_3_IMPLEMENTATION_REPORT.md` 为准。
>
> 结论限定：已根据 2026-07-24 阶段一/二综合代码审查修复全部代码项并完成自动化回归；真实 LiDAR iPhone 干跑、正式超市场景和修复后独立复审仍待完成。本报告不把模拟回放当作现场精度。

## 实现范围

- 三层结构距离场：0.40/0.20/0.10 m、2 m 截断、厘米量化、逐行 RLE、逐层 SHA‑256。
- ARKit 预测 + 跨帧 scene depth 结构证据 + 粗中细多盆地传播和全搜索窗 Top‑3 匹配。
- 结构点数、角覆盖、残差、真实次佳唯一性、校正变换两帧一致性、0.35 m/8° 自动修正上限和 0.35 应用增益。
- initializing/stable/usable/weak/lost/manualCorrection 状态与 stale/连续帧滞回。
- 用户触发 Vision QR/EAN/Code128/UPC‑E/PDF417，复用当前 ARFrame。
- 捕获时对齐快照、四方向 Vision/深度 ROI 映射、同帧深度中值/MAD 测量；无可靠深度时结构平面射线回退。
- 稳健楼面法向/残差/时序置信度；货架与固定柜台、A/B 侧、起点 offset、高度、跨结构遮挡、raw/snapped 点和人工复核门控。
- finalization 开始时立即失效并有界排空定位任务；所有定位写入校验 tracking session ID 和 finalizing 状态。
- 定位 constraint/state event、raw tag observation、confirmed localized tag sidecar 和 PC inspect 汇总。

## 自动验证

验证命令：

```bash
python3 -m unittest tools.PriorMap.tests.test_prior_map -v
python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v
python3 -m py_compile \
  tools/PriorMap/distance_field.py \
  tools/PriorMap/replay_stage2.py \
  tools/PriorMap/prior_map_schema.py \
  tools/PriorMap/xlsx_to_prior_map.py \
  tools/SupermarketMapStudio/server.py
xcodebuild -project app/ios/RTABMapApp.xcodeproj \
  -scheme RTABMapApp -configuration Debug -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

覆盖项目：

- 相同输入距离场逐字节复现、RLE 解码、尺寸、截断值和 checksum 损坏拒绝；
- Swift 状态滞回、单一楼层 SE(2)、移动/转弯校正变换门控、弱/丢失价签安全；
- 周期等价盆地保守拒绝、四方向 ROI、稳健楼面、同侧/对侧/端点/重叠/旋转货架、跨货架遮挡和固定柜台关联；
- 与 iOS 相同的两帧门控、0.35 gain、锚点更新和状态迟滞；动态干扰、错误初始位姿、tracking loss/recovery、yaw P95、通道与灾难跳变指标；
- PC inspect 对 constraint/event/observation/final tag/malformed 的有界统计；
- iPhone arm64 全工程 Swift/C++ 编译和链接。

2026-07-24 修复后结果：PriorMap 18 项通过，Map Studio 54 项通过，Python 语法检查通过，iPhone arm64 `BUILD SUCCEEDED`。Xcode 仍报告仓库既有的旧 API、VTK 部署版本和搜索路径 warning；本次未新增编译 error。真实 LiDAR 设备尚未执行走测。

## 可复现回放基线

输入为本地用户样例 `map/mapcase01/mapcase01.xlsx`，只用于验证且 `map/` 保持 Git ignored。参数：楼层 1、seed 24、24 个位姿、20% 动态干扰点。

| 指标 | 结果 |
| --- | ---: |
| Python 单帧几何候选/总样本 | 24 / 24 |
| 通过两帧门控并实际应用修正/总样本 | 22 / 24 |
| 预测位置误差中位数 | 0.0878 m |
| 修正后位置误差中位数 | 0.0566 m |
| 修正后位置误差 P95 | 0.1143 m |
| 修正后最大位置误差 | 0.1800 m |
| 航向误差 P95 | 0.3761° |
| 正确通道（误差不超过 0.5 m） | 24 / 24 |
| 灾难性跳变（误差超过 2 m） | 0 |
| Python 多盆地参考 matcher P50 | 417.6 ms |
| Python 多盆地参考 matcher P95 | 498.4 ms |
| initializing / stable / usable | 1 / 15 / 8 |

错误初始位置额外偏移 3 m 的同 seed 场景实际应用修正数为 0。周期双结构定向负例返回 `ambiguous_structure_match`；短时 tracking loss 进入 lost，恢复后重新等待至少两帧一致校正。上述回放是确定性 Python 参考实现，耗时不能等同于 iPhone Swift 真机耗时。

用户样例两楼层的 `distance_fields.json` 紧凑包体为 5,547,756 bytes；pretty JSON 曾达到约 36 MB，因此生产转换固定使用确定性紧凑 JSON。

## 待完成真机项目

1. 支持 scene depth 的真实 iPhone 上测 matcher P50/P95、内存、温度和连续 30 分钟丢帧率。
2. 覆盖低纹理、玻璃/反光、行人/购物车遮挡、平行通道、端头和错误起点。
3. 覆盖 QR/EAN/Code128/UPC‑E/PDF417 的近/中/远距离、无深度回退、取消/确认和结束复制。
4. 校验结束目录的所有新增 sidecar、空文件行为、断电 checkpoint 和原始 DB SHA/只读边界。
5. 独立复审阶段一整改与阶段二实现后再安排正式超市场景。
