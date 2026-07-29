# MarketScanner RepairV2 生产就绪当前代码审查

> 文档状态：**当前有效**。最后核对日期：2026-07-28。
> 外部审查输入：`MarketScanner_RepairV2_W2R_Production_Readiness_Code_Review_and_Final_Product_Agent_Spec_2026-07-28.md`。
> 审查基线：`repair-v2-w2r-safety-closeout@cf1b62c949f3574e1804808537e38c8ff643549c`。
> 代码基线：`ed85c38704461429e16321089d9e4e1b05d86753`；其后的提交只更新 W2R 文档和远端证据。
> 当前 wave：`P7-release-packaging-security`；实施分支：`repair-v2-p7-release-security`。
> P0 已验证头：`011ce479b74d10cb43106dda6ea757fb1ee2fa73`；本文件之后的证据提交不改变 P0 CI/测试树。

## 当前判定

当前结论为 **NO-GO / NOT PRODUCTION READY**。W2R 的 evidence bundle、checkpoint cleanup、原子可见写入、复制后本地保留及 typed finalization disposition 已有自动化保护；这些能力是生产化工作的安全起点，不代表最终产品验收完成。

P0 只冻结安全基线，不改变业务算法。CI 必须单独运行并报告以下不可退化契约：

1. `bounded_correction_field` 不能生成有效 `published` 成果；
2. finalized checkpoint cleanup 必须由操作者显式确认，并绑定 tracking identity、finalized time、metadata SHA-256 和 checkpoint SHA-256 的精确 CAS 证据；
3. 外部 provider 复制即使校验成功，也不得自动删除手机本地采集副本；
4. required localization evidence 缺失、为空、损坏或身份/数量/水位不一致时，metadata 必须 fail closed 为 `finalized=false`。

## 发布阻断项

| ID | 状态 | 关闭条件 |
| --- | --- | --- |
| RB-01 | **代码已关闭，待扩大资格样本** | native helper 已读取 RTAB-Map 相对/闭环 Link transform 和 information，严格验证并接入发布能力；已用 2,315-node 真实 DB 只读运行。clean runner 和更多真实样本随 P2/P5/P6 继续验证 |
| RB-02 | **部分关闭** | macOS PC 空目录 release preset 已实际链接；Ubuntu hosted clean build、iOS cold-cache dependency build/full link 和 manifest 已进入 fail-closed CI，仍需远端成功；Windows native clean build仍缺成功证据 |
| RB-03 | **阻断** | 在支持 LiDAR 的真实 iPhone 完成规定的开始、弱纹理、动态干扰、扫码、结束、恢复和复制矩阵 |
| RB-04 | **阻断** | 按 `FIELD_TEST_PLAN.md` 完成正式超市场景验收并保存不可伪造的原始证据 |
| RB-05 | **代码与自动测试已关闭** | 原子 journal、重启 `interrupted` 判定、浏览器重连、实际子进程取消、日志留存和损坏 journal fail-closed 已实现；安装包/断电矩阵仍由后续 wave 验证 |

生产化附加项 H-01 至 H-07（流式 finalization validator、包与保留语义、Windows handle 删除边界、崩溃/断电/provider 矩阵、性能上限、打包/selfcheck、本地 HTTP token/origin）仍应按各自 wave 实现和复核，不能在 P0 中标记关闭。

## Wave 顺序与边界

| Wave | 目标 | P0 时点状态 |
| --- | --- | --- |
| P0 | 冻结 W2R 安全基线和 CI 不变量 | 本地与远端验证通过 |
| P1 | 完整相对 SE(2) 因子图与发布门 | 已实现并完成本机真实 DB 只读验证；P1 GitHub Actions run `30360809785` 五个 job 全部成功；native clean build 属 P2 |
| P2 | 干净、可复现的 PC/iOS 构建 | 已实现本机 macOS clean build、presets、manifest 和 fail-closed hosted CI 合同；远端/Windows 结果继续核验 |
| P3 | Map Studio 持久任务和重启恢复 | 已实现并通过工作台测试目录 82 项回归；独立运行时进程强杀后由新进程恢复为 `interrupted`，服务重启不猜测续跑，不按不可信 journal 路径清理 |
| P4 | iOS finalization、保留和 provider hardening | 代码与主机压力测试已完成：100k×3 streaming、15,040,512-byte peak RSS、descriptor identity、copy v2 隐私和未执行 durability hook；真机 smoke 未执行，不声称 power-loss durability |
| P5 | 真实设备矩阵 | evidence collector 与完整场景门已实现；真实 LiDAR iPhone 未执行，因此仍为 NO-GO |
| P6 | 正式现场验收 | 已实现 release/阈值预冻结、3-run、20 控制点和重复性验证；办公室/卖场未执行，因此仍为 NO-GO |
| P7 | 安装包、升级/卸载和 selfcheck | token/Origin/CSP、About/recovery、诊断导出、selfcheck、平台 launcher 与 hash-bound ZIP 已实现；`283c2b6` 同机 macOS build/package/extract/version smoke 通过，干净 macOS/Windows smoke 未执行 |
| P8 | 独立代码、证据和发布复核 | 未执行 |

P1 至 P4 可以在 P0 通过后组织，但每一 wave 必须使用独立分支、明确基线、原子提交和单独验证；不得把多个大型 wave 合并成一次不可审查的改动。P5/P6 的证据必须来自真实设备和现场，缺失时如实保持未执行。

## P0 已核验基线

在创建 P0 分支前，对 `cf1b62c...` 实际执行：

| 验证 | 结果 |
| --- | --- |
| PriorMap 单元测试 | 103 项通过 |
| Map Studio 单元测试 | 66 项通过 |
| Python 编译、Web JavaScript syntax、native symbol contract | 通过；73 C exports、72 Swift calls、71 RTABMapApp calls |
| Stage 3 确定性基准 | 2,000 节点、20 约束通过；3.456 秒、Python 峰值 0.563 MiB，低于现有 15 秒/64 MiB 门限 |
| W2R 远端多平台 CI | GitHub Actions run `30342577182` 四个既有 job 通过 |

上述基准只证明冻结点没有已知自动化回归。它不关闭 RB-01 至 RB-05，也不证明真机、断电、外部 provider 或现场条件。

P0 变更后的本地验证结果：生产安全快速契约 4 项、PriorMap 103 项、Map Studio 66 项、文档治理 3 项全部通过；workflow YAML、Python 编译、Web JavaScript、native symbol contract、Swift parse 和 `git diff --check` 通过；无签名 Release arm64 iOS app 完成编译与链接；既有 `build-pc-release` 的 `rtabmap-reprocess` 目标通过。第一笔原子提交为 `612ea6b`（CI、wave 基线与治理契约）。这些结果仍不替代干净环境构建、真机或现场证据。

P0 已验证头的 GitHub Actions run [30355893697](https://github.com/mcjiansheng/MarketScanner/actions/runs/30355893697) 结论为 **success**：

| Job | Job ID | 结果与边界 |
| --- | --- | --- |
| P0 production safety invariants | `90263893473` | 四项失败关闭契约通过 |
| Windows imports and Python contracts | `90263893525` | Windows 导入、PriorMap 和 Map Studio 全套测试通过 |
| Ubuntu Python, API and web contracts | `90263893540` | Python 编译、两套全量测试、Web syntax 和完整 P0 wave diff 通过 |
| Native ABI source contracts | `90263893478` | 静态 native/Swift 接口契约通过，不替代 translation-unit 构建 |
| macOS and iOS source contracts | `90263893712` | Swift parse、Swift 可执行 core、Xcode metadata 通过；hosted runner 缺少 Git 未保存的 native dependency bundle，因此条件式 app build 按合同跳过 |

Actions 对 `actions/checkout@v4`、`actions/setup-python@v5` 和 `actions/upload-artifact@v4` 的 Node.js 20 runtime 弃用提示仍存在；这是待后续独立处理的 CI 维护项，不影响本 run 的断言结论。

## 兼容、数据和回滚约束

- 自由扫描和 prior-map 扫描继续写连续单 SQLite 数据库；`scanMode=continuous_streaming` 的存储语义不变。
- 原始扫描数据库只读，PC 处理写入新目录；带 `live_checkpoint.json` 的输入继续拒绝自动处理。
- NFC 入口保持关闭，旧 `price_tags.*` 仅用于兼容历史输入。
- `AGENTS.md`、`doc/.local/`、扫描数据库、构建目录、真实扫描数据和输出地图不得提交。
- P0 仅添加 CI/文档保护，可按其原子提交整体回滚；不得只删除某一失败保护后仍声称安全基线有效。

P0 已完成冻结、自动化验证和证据同步；它只允许开始组织后续独立 wave，不改变当前产品 **NO-GO** 判定。
