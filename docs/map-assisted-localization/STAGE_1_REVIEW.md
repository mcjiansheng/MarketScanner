# 阶段一代码审查与整改记录（历史归档）

> 文档状态：**历史归档**。最后核对日期：2026-07-25。
> 当前实现状态以 `IMPLEMENTATION_STATUS.md` 为准；本文件仅保留 2026-07-24 审查整改快照。
> 审查来源：用户提供的独立审查文档 `MarketScanner_STAGE_1_CODE_REVIEW_UPDATED.md`。该审查结论为 **REJECTED**；本文件记录对应整改，不把实现者自测写成独立批准。

## 范围

- 先验地图转换、schema、道路图/空间索引和逐楼层预览；
- Map Studio 导入和检查；
- iOS 双模式、五步向导、ARKit 水平位姿、道路软约束和审计 sidecar；
- 合成/记录轨迹回放；
- 阶段一明确只支持单次扫描绑定一个楼层。

阶段一仍不包含 LiDAR/视觉结构自动匹配、条码/价签测量或 PC 价签复核。

## 独立审查问题与整改

| 等级 | 审查问题 | 整改 |
| --- | --- | --- |
| HIGH | ARKit `x/z`、地图 `x/y`、yaw 和 UI 箭头定义不一致 | 当前生产合同统一为 ARKit `+x -> map +x`、ARKit `-z -> map +y`，map yaw 0 指向 `+x`、`+π/2` 指向 `+y`、逆时针为正；配置、首帧对齐、深度局部点与 HUD 共享合同，并增加四方向、前进一步和非零原点 Swift 金标 |
| MEDIUM | 校验器主要检查文件存在，缺少跨文件一致性 | 解析全部 JSON/PNG；核对 hash、count、bounds、子集、道路引用、结构/道路索引完整覆盖、验证报告统计和逐楼层预览；增加损坏包负向测试 |
| MEDIUM | 旋转漂移只改 yaw，没有影响 XY，测试不足 | 回放改为逐段积分带旋转漂移的局部位移；报告 mean/max/p95 yaw 误差；测试断言旋转漂移改变 XY 误差 |
| MEDIUM | iOS 未使用空间索引，in-flight 门控未生效 | 地图包增加 `road_cells`；iOS 只查询附近道路边；同一时刻只执行一个更新，忙时丢弃并记录计数 |
| MEDIUM | iOS 更新缓存采用先删后拷贝 | 改为临时目录复制、完整加载校验，再原子 move/replace；失败时保留外部源包和旧缓存 |
| MEDIUM | 设备检查把 ARKit tracking 硬编码为成功 | 相机权限按系统状态请求/显示，检查设备是否支持世界跟踪；运行时 tracking 在扫描启动后实时报告，不再预先标绿 |
| 文档 | 多楼层、回放路线和完成度表述过强 | 明确一个地图包可含多层，但一次扫描固定一层；当前回放是道路图合成遍历而非业务蛇形路线；保留独立审查 REJECTED 事实 |

## 单楼层边界

- 五步向导开始前选择一个 `floorId`，整个连续扫描保持不变；
- 不支持楼梯、电梯、自动切层或跨层重定位；
- 同一楼层内可以有坡道、地面起伏等少量竖直位移；
- 二维先验位姿忽略 ARKit 竖直 `y`，原始 ARKit/RTAB-Map 连续数据库仍保留完整三维运动；
- 地图包为每层生成独立预览，HUD 和起点选择只显示本次目标楼层。

## 自动验证证据

当前整改新增/加强的测试包括：

- ARKit 水平坐标与 UI 朝向金标；
- 损坏 JSON/PNG、错误 hash/count/bounds/子集/道路引用/空间索引/验证报告拒绝；
- 大型道路网格附近查询；
- 平移与旋转漂移、XY/yaw 误差、tracking 状态转换；
- 人工校准前后误差和实际道路边 ID；
- 地图包逐字节可复现和逐楼层预览。

完整命令和现场干跑步骤见 `TEST_PLAN.md`。自动测试与真机构建结果应以当前提交的 CI/本地复验输出为准，不以旧审查记录代替。

本次整改提交前复验：

```text
PriorMap unittest: 15 passed
Map Studio unittest: 53 passed
Python py_compile / JavaScript node --check / project.pbxproj plutil: passed
mapcase01 实转与校验: valid，1563 elements，floor 1/2 独立预览，源 SHA-256 不变
500 点回放: 8 lost samples，输出 XY 与 yaw 误差
Xcode iphoneos arm64 Debug build, CODE_SIGNING_ALLOWED=NO: passed
git diff --check: passed
```

## 仍需独立验证

1. 在支持 ARKit/LiDAR 的真实 iPhone 上完成相机权限、文件选择器、地图缓存替换、tracking 中断、结束落盘和 sidecar 干跑。
2. 用具有长直线和转弯的记录轨迹复核旋转漂移与人工校准，不把合成道路遍历当作现场精度证据。
3. 由独立审查者复核整改 diff，重新给出批准或拒绝结论。

## 数据与提交边界

- `map/`、`AGENTS.md`、`doc/.local/`、`.workbuddy-ai/` 和 `.workbuddy/` 不提交；
- 不提交 `.db`、扫描图像、checkpoint、DerivedData 或转换输出；
- 源 XLSX、外部地图包和原始扫描数据库保持只读；
- 转换和 iOS 缓存更新均采用临时目录验证后发布。

## 当前结论

**REMEDIATED — PENDING INDEPENDENT RE-REVIEW**

独立审查提出的一个 HIGH 和五个 MEDIUM 代码问题已逐项整改并增加回归覆盖；正式结论仍由后续独立复审和真实 iPhone 干跑决定。
