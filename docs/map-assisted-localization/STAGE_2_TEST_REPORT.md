# 阶段二实现与验证报告

> 文档状态：**当前有效**。最后核对日期：2026-07-24。
>
> 结论限定：阶段二代码和自动化验证已完成；真实 LiDAR iPhone 干跑、正式超市场景和独立代码复审仍待完成。本报告不把模拟回放当作现场精度。

## 实现范围

- 三层结构距离场：0.40/0.20/0.10 m、2 m 截断、厘米量化、逐行 RLE、逐层 SHA‑256。
- ARKit 预测 + 跨帧 scene depth 结构证据 + 粗中细 Top‑3 匹配。
- 结构点数、角覆盖、残差、唯一性、两帧一致性、0.35 m/8° 自动修正上限和 0.35 应用增益。
- initializing/stable/usable/weak/lost/manualCorrection 状态与 stale/连续帧滞回。
- 用户触发 Vision QR/EAN/Code128/UPC‑E/PDF417，复用当前 ARFrame。
- 同帧深度中值/MAD 测量；无可靠深度时货架平面射线回退。
- 货架、A/B 侧、起点 offset、高度、raw/snapped 点、分项置信度和人工复核门控。
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
- Swift 状态滞回、单一楼层 SE(2)、弱/丢失价签安全；
- 同侧、对侧、端点、重叠货架歧义、旋转货架和超范围关联；
- 动态干扰结构点、错误初始位姿安全拒绝、误差改善和 matcher 耗时；
- PC inspect 对 constraint/event/observation/final tag/malformed 的有界统计；
- iPhone arm64 全工程 Swift/C++ 编译和链接。

2026-07-24 本次结果：PriorMap 17 项通过，Map Studio 54 项通过，Python 语法检查通过，iPhone arm64 `BUILD SUCCEEDED`。Xcode 仍报告仓库既有的旧 API、VTK 部署版本和搜索路径 warning；本阶段未新增编译 error。

## 可复现回放基线

输入为本地用户样例 `map/mapcase01/mapcase01.xlsx`，只用于验证且 `map/` 保持 Git ignored。参数：楼层 1、seed 24、24 个位姿、20% 动态干扰点。

| 指标 | 结果 |
| --- | ---: |
| 接受/总样本 | 24 / 24 |
| 预测位置误差中位数 | 0.2416 m |
| 匹配后位置误差中位数 | 0.0355 m |
| 匹配后位置误差 P95 | 0.0761 m |
| 匹配后最大位置误差 | 0.0779 m |
| Python 参考 matcher P50 | 79.7 ms |
| Python 参考 matcher P95 | 97.0 ms |
| stable / usable | 19 / 5 |

错误初始位置额外偏移 3 m 的同 seed 场景接受数为 0，验证自动修正上限不会把远处候选硬拉回。该回放是确定性 Python 参考实现，时间不能等同于 iPhone Swift 真机耗时。

用户样例两楼层的 `distance_fields.json` 紧凑包体为 5,547,756 bytes；pretty JSON 曾达到约 36 MB，因此生产转换固定使用确定性紧凑 JSON。

## 待完成真机项目

1. 支持 scene depth 的真实 iPhone 上测 matcher P50/P95、内存、温度和连续 30 分钟丢帧率。
2. 覆盖低纹理、玻璃/反光、行人/购物车遮挡、平行通道、端头和错误起点。
3. 覆盖 QR/EAN/Code128/UPC‑E/PDF417 的近/中/远距离、无深度回退、取消/确认和结束复制。
4. 校验结束目录的所有新增 sidecar、空文件行为、断电 checkpoint 和原始 DB SHA/只读边界。
5. 独立复审阶段一整改与阶段二实现后再安排正式超市场景。
