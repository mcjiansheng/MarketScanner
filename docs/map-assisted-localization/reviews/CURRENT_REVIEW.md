# RepairV2 W2R 安全闭环当前代码审查

> 文档状态：**当前有效**。最后核对日期：2026-07-28。
> 外部审查输入：`MarketScanner_RepairV2_W2_Review_Followup_Code_Review_and_Agent_Spec_2026-07-28.md`。
> W2R 执行基线：`repair-v2-w2-review-followup@8200b81f76afaf2fae465ad38f2243c711b05e66`。
> 上一轮直接基线：`repair-v2-w2-sidecar-write-health@12715d4fd005dcd46cae015ab31882b732c8e570`。
> 实现分支：`repair-v2-w2r-safety-closeout`。
> 当前代码头：`ed85c38704461429e16321089d9e4e1b05d86753`；本文件之后的文档/CI 证据提交不改变该代码树。

## 当前判定

W2R-A 至 W2R-D 已完成代码、合同、自动测试和当前文档闭环。外部审查提出的 H-01 至 H-04 与 M-01 至 M-05 均已在自动化验证边界内关闭。真实 iPhone、外部文件提供者和断电持久化仍须在 W2R-E 验证；完整相对 SE(2) 因子图仍未实现，因此 RB-01 保持 **BLOCKED BY DESIGN**，第三阶段 published 门不得打开。

| 问题 | 结论 | 实现证据 |
| --- | --- | --- |
| H-01 实际 evidence bundle 未在提交前复核 | **关闭** | metadata 前严格复读 required JSONL 的 UTF-8、末尾换行、逐行 JSON、format/version、identity、数量、末状态和价签数量；缺失、空、截断、身份不符或 symlink 均提交 `finalized=false` 并保留 checkpoint |
| H-02 cleanup no-follow/containment 不完整 | **关闭** | iOS 使用 path-component containment、目录/文件 identity、`openat`/`fstat`/`unlinkat`；PC 拒绝 symlink、junction/reparse，按已验证目录 fd 删除；两端均复核待删字节和摘要 |
| H-03 PC cleanup 缺确认与 CAS | **关闭** | API 强制 `confirmed=true` 及 expected tracking ID、finalized time、metadata SHA-256、checkpoint SHA-256；旧证据和重复请求返回 HTTP 409；Web 先检查、提示并提交同一证据 |
| H-04 原子写入 durability 术语不准确 | **关闭** | 同目录唯一 temp、write、file synchronize、rename；故障注入覆盖 write/flush/rename；合同明确只保证进程级原子可见性，不声称未经真机验证的 directory fsync 或 power-loss durability |
| M-01 completion Bool 语义不足 | **关闭** | completion 改为 `ScanFinalizationDisposition`，effect planner 明确四类终态副作用 |
| M-02 外部复制后过早删除本地副本 | **关闭** | provider copy 关闭后复读目标和源清单，写入 verification receipt；默认保留本地副本，不把 provider 返回等同于断电持久化 |
| M-03 本地删除使用字符串前缀 | **关闭** | 删除与清单统一改用标准化 path components 和严格目录结构校验 |
| M-04 cleanup failure audit 缺失 | **关闭** | authorized、completed、failed 均有审计；审计自身失败显式记录 degraded warning |
| M-05 core 与 UI/session 接线间隙 | **关闭（自动测试边界）** | Foundation 运行测试执行四种 disposition/effect；源码合同验证 ViewController 使用 typed completion 与 effect planner；真实 UIKit/设备行为归 W2R-E |
| RB-01 完整相对 SE(2) 因子图 | **保持阻断** | `tools/PriorMap/offline_localization.py` 相对本 wave 基线无改动；仍为 `bounded_correction_field`，`publish_gate.passed=false` |

## 数据合同与状态机变化

- required localization trace、constraint 和 state JSONL 必须存在且非空；manual event 与 tag observation 仍是允许空文件的 optional evidence。
- `metadata.json` 只有在落盘字节通过 bundle 校验后才可提交 `finalized=true`。验证失败产生确定性 `evidence_bundle_*` blocker、终态 ineligible recovery package，并保留 checkpoint。
- checkpoint cleanup 是独立、显式、证据绑定的恢复操作，不属于普通 inspection/processing；正常 PC 优化继续拒绝任何带 `live_checkpoint.json` 的输入。
- finalization effect planner 的四种结果为：仅 `resumeRecording` 恢复 camera/mapping；正常 finalized 允许外部复制；needs-cleanup 保留 checkpoint 且禁止复制；ineligible 关闭会话、保留 checkpoint，仅允许恢复性外部副本。
- 外部复制收据记录相对文件、字节数和 SHA-256，并声明 `provider_copy_closed_and_reread_no_power_loss_guarantee`；本地唯一副本默认不自动删除。

## 原子提交

| 提交 | 范围 |
| --- | --- |
| `edfd467e2eea80a071cac45d6704d0aa22fce555` | W2R-A 落盘 evidence bundle 校验与负向测试 |
| `8d3438e4d36e7a3643503ecbce7dbb8c3344eba2` | W2R-B iOS/PC cleanup 证据、确认、CAS、UI 与审计 |
| `793d74426b4ac4d96299c64cfc9330d55d5699bd` | W2R-C 原子可见 writer、复制复读/收据和本地保留策略 |
| `5038f353bc09417a436634f9a8462bb44ee5c2a5` | W2R-D typed disposition/effect 集成运行测试 |
| `afca049e526c9a1a72676da1c03517ab36254a3a` | cleanup 目录 fd、`openat`/`unlinkat` 与 inode 竞态收口 |
| `ed85c38704461429e16321089d9e4e1b05d86753` | 关闭 Windows 上 checkpoint 缺失/拒绝时的 metadata fd 泄漏，并增加 closed-fd 回归测试 |

## 本地独立运行证据

以下验证在 2026-07-28、代码头 `ed85c387...` 上实际执行；iOS 源码未在 `afca049e...` 后改变：

| 验证 | 结果 |
| --- | --- |
| `python3 -m unittest discover -s tools/PriorMap/tests -v` | **103 项通过**；包含真实 Swift 可执行 core 测试 |
| `python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v` | **66 项通过**；包含 cleanup 成功、重复/旧证据 409、confirmation、symlink、Windows reparse 和失败打开不泄漏 fd 的负例 |
| Python `py_compile`、Web `node --check` | 通过 |
| native symbol contract | 通过：73 C exports、72 Swift calls、71 RTABMapApp calls |
| RepairV2 Swift `swiftc -parse` | 通过 |
| `xcodebuild -project app/ios/RTABMapApp.xcodeproj -list` | target、Release 配置、scheme 和 SwiftPM 依赖解析通过 |
| 无签名 `Release`、`iphoneos`、`generic/platform=iOS`、`arm64` 全量构建 | 通过；Xcode 26.5（17F42）、Swift 6.3.2；存在上游弃用与预编译 VTK 最低系统版本 warning，无编译/链接错误 |
| `cmake --build build-pc-release --target rtabmap-reprocess --config Release -j2` | 通过（Ninja 无待编译目标；本 wave 未修改 C++） |
| `git diff --check` 与 W2R 基线到代码头的 patch 检查 | 通过 |

本地 iOS 链接使用的关键静态库 SHA-256：

| 文件 | SHA-256 |
| --- | --- |
| `librtabmap_core.a` | `171510f9454dc11f27b7b7e59e02f1354faffd5a199e1aec25c6996696c065b4` |
| `librtabmap_utilite.a` | `80f13d817a8732affdbcd1db07086c0f1e10630cbd9af307a76f234d99902f3d` |
| `libopencv_core.a` | `dc61253e487fa710baab2538388f2ea742f09d876e273b3c2ee46f7e46f440ad` |
| `libpcl_common.a` | `c941d3dc931296ba43f081ee713862aacf7a53e0d915bfff9f5701e68e1a929f` |

## 远端运行证据

代码头 `afca049e...` 的 run [30340428172](https://github.com/mcjiansheng/MarketScanner/actions/runs/30340428172) 已完成：Ubuntu、Native ABI、macOS/iOS source contracts 通过；Windows Map Studio 因 `_cleanup_evidence()` 在第二个文件打开失败时泄漏先打开的 metadata fd 而失败。该 Windows 日志直接形成 `ed85c387...` 修复和 closed-fd 回归测试，不能把此 run 写成全绿。

包含代码头 `ed85c387...` 的文档头 `1bb054394ad7c8585b8e4f6a61f85f089a4542df` 已由 GitHub Actions run [30342577182](https://github.com/mcjiansheng/MarketScanner/actions/runs/30342577182) 验证，结论为 **success**：

| Job | Job ID | 结果与边界 |
| --- | --- | --- |
| Windows imports and Python contracts | `90221303726` | 通过；Python 3.12.10，PriorMap 与 Map Studio 全套测试通过，确认 fd 泄漏修复 |
| Ubuntu Python, API and web contracts | `90221303719` | 通过；Python 3.12.13、Node 22，Python 编译、两套测试、Web syntax 和完整 wave diff 通过 |
| Native ABI source contracts | `90221303746` | 通过；静态 ABI symbol contract 通过，不替代 native 编译 |
| macOS and iOS source contracts | `90221303657` | 通过；Swift parse、Foundation core、Xcode metadata 通过；hosted app build 仍受仓库未保存生成 native dependency bundle 的条件限制 |

四个 job 均产出各自 summary artifact。Actions 对 Node.js 20 action runtime 的弃用提示为上游 action warning，不影响本次测试结论，后续应升级对应官方 action major version。

上一轮代码提交 `2e180e06de1a8db7c90f3342aa08c405c9a430f8` 的 run [30331393098](https://github.com/mcjiansheng/MarketScanner/actions/runs/30331393098) 仍是 W2 基线证据，不覆盖本 wave。

## 未执行与剩余风险

- 未执行支持 LiDAR 的真实 iPhone W2R-E：开始、弱纹理、行人干扰、扫码、结束落盘、checkpoint 恢复和外部 provider 复制仍需设备干跑。
- 未执行断电/进程崩溃/文件提供者掉线矩阵；实现和文档只声明原子可见性、关闭并复读，不声明 power-loss durability。
- hosted CI 不包含本地生成的完整 iOS native 静态库时只能做 Swift/source/Xcode metadata 验证；不能替代上述本机链接和真机验收。
- fresh PC configure 仍受本机 OpenCV 5 与 g2o/Eigen 路径影响；既有 `build-pc-release` 可验证当前 C++ 目标，但构建环境尚未完全可复现。
- 正式超市现场验收未执行；RB-01 未关闭前无论现场结果如何都不得创建有效 published 成果。

## 兼容与回滚

- 自由扫描、连续单库 marker、历史 sidecar optional 文件和 PC 正常 inspection/processing 入口保持兼容；本 wave 只收紧 prior-map finalized/cleanup/复制安全边界。
- 回滚应按上表原子提交逆序进行；不得只回滚 Web confirmation 而保留无 CAS 的删除 API，也不得只回滚 bundle 校验而保留 eligible metadata 文档声明。
- `AGENTS.md`、`doc/.local/`、扫描数据库、构建目录和真实扫描输出不属于提交内容。

历史审查见 [`history/`](history/)，它们只适用于各自声明的旧 SHA。
