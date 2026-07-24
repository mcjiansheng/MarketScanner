# 阶段一实现自审记录

> 文档状态：**当前有效**。最后核对日期：2026-07-24。
> 审查性质：实现会话内的只读 Pass A 与修复复验，不冒充独立 Review Agent。合并前仍建议由另一会话按测试审查 Prompt 复核。

## 范围与环境

- 基线：`b390b98`；
- 分支：`feature/prior-map-localization`；
- 平台：macOS arm64，Xcode 真机 SDK，无代码签名构建；
- 用户样例：`map/mapcase01/mapcase01.xlsx`，仅只读使用并由根 `.gitignore` 排除；
- 范围：先验地图转换、道路图/空间索引、Map Studio 导入、iOS 双模式与五步向导、阶段一道路软约束、sidecar、回放和文档；
- 排除：阶段二 LiDAR/视觉扫描匹配、条码和价签测量，阶段三 PC 复核发布。

## 需求覆盖矩阵

| 审查项 | 结论 | 证据 |
| --- | --- | --- |
| 六类元素、损坏 JSON、未知/隐藏元素 | 通过 | `tools/PriorMap/tests/test_prior_map.py` |
| 唯一 cm→m/轴向/旋转实现 | 通过 | `coordinate_system.py`、关键坐标测试、样例预览 |
| 旋转 polygon、bounds、SHA-256、可复现 | 通过 | 转换测试；样例 hash `0cf694…4906` |
| 道路 ID 归一、连通统计、5 m 有界索引 | 通过 | road graph/spatial index 数值测试 |
| PC 导入、进度、统计、warning、artifact 安全 | 通过 | Map Studio API 测试与 artifact allowlist |
| 自由扫描旧流程 | 通过 | 默认 `free_mapping`；storage `scanMode=continuous_streaming` 不变；53 项回归通过 |
| iOS 双模式与五步向导 | 通过（构建/代码） | arm64 iphoneos 完整构建；地图/楼层/锚点/起点方向/设备检查 |
| SE(2) 投影和模式门控 | 通过 | 自动编译运行 `PriorMapLocalizationCore.swift` |
| 道路软约束与跨通道安全 | 通过 | Top-3、歧义拒绝、0.15 gain、0.25 m 上限测试 |
| weak/lost 保留原始扫描 | 通过（代码/回放） | 定位队列不控制 RTAB-Map 记录；tracking loss 回放 |
| 人工校准审计 | 通过（代码） | `manual_localization_events.jsonl` 和 scan event |
| 原始数据库不可变 | 通过 | 新功能不打开/重写 PC 输入 DB；手机沿用原连续写入职责 |
| 文档真实性 | 通过 | `IMPLEMENTATION_STATUS.md` 明确阶段二/三与可选增强未实现 |

## 测试证据

```text
PriorMap unittest: 10 passed
Map Studio unittest: 53 passed
Python py_compile: passed
JavaScript node --check: passed
Swift parse: passed
Xcode iphoneos arm64 Debug build, CODE_SIGNING_ALLOWED=NO: passed
project.pbxproj plutil: passed
git diff --check: passed
```

样例实转结果：

```text
elements=1563
floors=1,2
road nodes=281
road edges=333
connected components=3
malformed rows=0
package validation=valid
```

带平移/旋转漂移、随机噪声和 8 帧 tracking loss 的 500 点回放成功生成误差、道路分配、状态统计和 CSV trace。阶段一道路约束仅修正横向小误差，不承诺消除长距离 ARKit 纵向漂移。

## 问题分级与处置

### BLOCKER / HIGH

无未解决项。

审查中发现导入地图包原先直接使用 manifest ID 组成缓存目录，恶意 ID 可能造成路径边界风险。已改为校验 64 位十六进制来源摘要，并只用摘要前缀组成缓存目录；修复后真机构建通过。

### MEDIUM

1. 尚未在真实支持 LiDAR 的 iPhone 上完成向导、ARKit 中断、结束落盘的办公室干跑。自动构建与数值测试不能替代相机权限、文件选择器和生命周期实测。
2. 当前 App 复用上游首页并提供双模式入口，尚未重构为完整五入口业务首页；不影响阶段一采集链路，但属于后续 UX 收敛。

### LOW

1. 外部预定路线文件导入尚未实现；当前可选锚点和道路图 synthetic 蛇形路线已覆盖阶段一定位/回放接口。
2. 仓库真机静态库不能链接 Simulator；arm64 iphoneos 构建成功。这是现有依赖产物边界，应在后续依赖升级时处理。

## 数据安全与 Git

- `map/` 被根 `.gitignore` 排除；
- `.workbuddy-ai/`、`.workbuddy/` 属于用户现有未跟踪文件，不纳入阶段一；
- 未生成或提交 `.db`、扫描图像、checkpoint、DerivedData 或转换输出；
- 样例转换与回放输出位于 `/private/tmp`；
- Map Studio 输出要求不存在或为空目录，转换采用同父目录临时目录后原子 rename；
- iOS 只复制已选择的地图包到应用 `Documents/PriorMaps`，不修改外部源包。

## 结论

**APPROVED WITH CONDITIONS**

代码、格式、回放、PC 回归和 arm64 真机构建满足阶段一软件验收。合并或开始阶段二前，条件是：

1. 在支持 ARKit/LiDAR 的 iPhone 完成 `FIELD_TEST_PLAN.md` 中的阶段一办公室干跑；
2. 使用独立会话复核本记录和最终提交范围，尤其检查 UI 生命周期与 sidecar 实际落盘。
