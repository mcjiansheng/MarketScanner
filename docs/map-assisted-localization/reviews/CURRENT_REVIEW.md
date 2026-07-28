# RepairV2 当前代码审查闭环

> 文档状态：**当前有效**。最后核对日期：2026-07-28。
> 外部审查输入：`MarketScanner_RepairV2_W2_Sidecar_Write_Health_Code_Review_and_Agent_Spec_2026-07-28.md`。
> 审查基线：`repair-v2-w2-sidecar-write-health@12715d4fd005dcd46cae015ab31882b732c8e570`。
> 实现分支：`repair-v2-w2-review-followup`。
> 核心代码与测试提交：`a9819ff46a917c3f24969bc81757c5669c9d0fbd`。
> Windows 契约修复提交：`2e180e06de1a8db7c90f3342aa08c405c9a430f8`。

## 当前判定

W2 sidecar write health 的 B-01 已在本分支关闭：finalized metadata 提交后，checkpoint 删除失败进入终态，不再恢复相机或映射。B-02（完整相对 SE(2) 因子图）仍属于 W3，当前发布门保持关闭。

## 已实现的审查整改

- Foundation-only finalization coordinator 和可注入 writer；实际运行 metadata、checkpoint、trace、constraint、state 故障路径。
- 手机与 PC 显式 checkpoint 恢复；仅接受 finalized、同 tracking identity、checkpoint 不晚于 commit 的证据，并保留审计。
- 首个必需写失败后的终端降级：停止新 prior-map 修正、人工校正和价签确认，原始数据库继续录制。
- 外部复制逐文件 SHA-256 和源目录二次清单验证。
- Windows 已打开文件替换测试改为遵循 Windows 共享语义，不把 POSIX 行为当作跨平台契约。
- 候选关联审计声明完整搜索范围；求解器统一为不可发布的 `bounded_correction_field`。
- 旧审查和 Agent Prompt 移至带 SHA/状态的历史归档。

## 证据边界

本文件只记录已由源码、本地自动测试和下述远端 CI 支持的结论。条件式 hosted iOS build 因仓库不包含生成的 native 库而跳过，不能写成远端 iOS 构建成功。本机已完成 native/iOS 链接，但真实 iPhone 和超市现场验收仍未完成。

## 远端运行证据

实现提交 `2e180e06de1a8db7c90f3342aa08c405c9a430f8` 的 GitHub Actions run [30331393098](https://github.com/mcjiansheng/MarketScanner/actions/runs/30331393098) 已完成且结论为 `success`：

| Job | Job ID | 结果与边界 |
| --- | --- | --- |
| Windows imports and Python contracts | `90187126278` | 通过；包含 PriorMap 与 Map Studio 全套测试 |
| Ubuntu Python, API and web contracts | `90187126282` | 通过；包含 Python、Web 和完整分支 patch whitespace 检查 |
| Native ABI source contracts | `90187126288` | 通过；这是源码/ABI 契约验证，不替代 native 构建 |
| macOS and iOS source contracts | `90187126314` | Job 通过；Swift parse、平台无关 finalization core 测试和 Xcode metadata 通过；hosted iOS build 因 native 依赖缺失为 `skipped-missing-native-dependencies` |

## 本地运行证据

以下命令在 2026-07-28 的本分支工作区执行：

| 验证 | 结果 |
| --- | --- |
| `python3 -m unittest discover -s tools/PriorMap/tests -v` | 99 项通过 |
| `python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v` | 62 项通过 |
| Python `py_compile`、Web `node --check`、RepairV2 Swift `swiftc -parse` | 通过 |
| `xcodebuild -project app/ios/RTABMapApp.xcodeproj -list` | 项目、target、scheme 与 SwiftPM 依赖解析通过 |
| 无签名 `Release`、`iphoneos`、`generic/platform=iOS`、`arm64` 全量构建 | `** BUILD SUCCEEDED **`；Xcode 26.5（17F42），Swift、Objective-C++、C++ 与现有 native 静态库完成编译链接 |
| `cmake --build build-pc-release --target rtabmap-reprocess --config Release -j2` | 通过（现有 Release Ninja 构建无待编译目标） |

独立 `/private/tmp` 重新配置 PC 工具时，本机默认 OpenCV 5 缺少 `calib3d`；显式改用 OpenCV 4 后又遇到本机 g2o/Eigen CMake 路径配置问题，因此不把该次 fresh configure 写成成功。既有 `build-pc-release` 目标通过，但本轮没有修改 C++ 源码。

历史审查见 [`history/`](history/)，它们只适用于各自声明的旧 SHA。
