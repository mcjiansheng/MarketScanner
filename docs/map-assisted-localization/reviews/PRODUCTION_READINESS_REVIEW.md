# MarketScanner RepairV2 生产就绪当前代码审查

> 文档状态：**当前有效**。最后核对日期：2026-08-09。
> 当前增量审查输入：`MarketScanner_Mobile_Only_V1R5_Second_Independent_Full_Code_Review_NO_GO.md` 和 `MarketScanner_Mobile_Only_V1_Release_Candidate_Blocker_Closeout_Prompt_V2.md`；完整入口见 [`CURRENT_REVIEW.md`](CURRENT_REVIEW.md)。
> 当前 RC 基线：`mobile-only-v1r5-field-qualification-integrity-scale-closeout@81b6dbb216e843d363fd0088f673076add78013f`。
> 当前 wave：`mobile-only-v1-release-candidate-blocker-closeout`；实施分支同名。
> 历史 P7R1/P0 审查证据保留在下文，不代表当前 RC 的 exact-SHA CI 或 Apple/设备资格已经执行。

## 当前判定

当前结论为 **NO-GO / NOT PRODUCTION READY**。W2R 的 evidence bundle、checkpoint cleanup、原子可见写入、复制后本地保留及 typed finalization disposition 已有自动化保护；这些能力是生产化工作的安全起点，不代表最终产品验收完成。

MapCase02 正式工作簿/几何增量已完成独立 P0/P1 审查并修复全部发现，最终 `P0=0 / P1=0`；允许局部表述 `MAPCASE02 / STANDARD SUPERMARKET XLSX FORMAT PASS`。本机 MapCase02 Swift/PC golden、PriorMap 非超长分组 217 项和 Map Studio 108/108 均 PASS。完整长方法后半段、Apple clean link、exact-SHA、Replay/FAR、真机和现场仍未完成，因此本节不提升生产资格。

当前 Mobile-Only RC 除 RC-B19/J-04 component identity 外，已完成 RC-B01…RC-B03、RC-B05…RC-B28 的本轮代码与本地主机自动化闭包，并同步处理影响正确性、事务、安全、规模和审计的 RC-H01…RC-H40。J-04 仍需冻结 prior-independent final-link component policy，并完成 node snapshot C ABI 与 constraint/manual evidence schema 的 breaking migration；现有记录不得追溯伪证 same-component。RC-B04 exact-SHA CI、RC-B29 Replay/FAR policy freeze、RC-B30 Apple clean build/Device Lab 也仍未关闭。Route A 固定为 Fast reduced graph → 至多一次 Full existing-graph optimization → `RESCAN_SESSION`；True sensor Deep 不属于 V1。当前最高允许表述是 **REJECTED / NO-GO / developer smoke only**。

当前 RC diff 的独立只读代码审查已执行，状态为 **COMPLETED / BLOCKERS FOUND AND FIXED IN CURRENT DIFF**。ESL 核心 implementation I3 与 fixture I4/G4 历史绑定保持可追溯；I5 Result recovery、I6 ESL follow-up 和 MapCase02 最终复审均为 `P0=0 / P1=0`。当前 MapCase02 worktree 证据为 PriorMap 非超长 217 项、Map Studio 108/108 和 Swift/PC 正式套件 PASS；长方法通过 300k finalization 与 1,728,000 trace 后按时间停在 `tag-evidence-scale`。V4 exact-HEAD 仍是 7/8 失败证据，新 committed exact-HEAD 尚未形成 PASS。该审查不关闭 J-04，也不替代 exact-SHA、Apple、Replay/FAR 或设备/现场资格。

P7R1 增量已实现 production-only publish、publish 前即时 production selfcheck、package-bound release identity、Device App SHA 与 release SHA 精确绑定、从 immutable version 自动生成且可由 self-contained source bundle 重新派生的 typed trajectory evidence、Field Evidence v3、descriptor-bound JSON/CSV 读取、exact plan/release/policy/CSV/Device Evidence publication package、published manifest v4 自包含 evidence、package stable-read 和真实 About runtime mode。上述只能标记 **IMPLEMENTED / AUTOMATED TESTED**；最终精确 SHA 全矩阵成功后才是 **CI VERIFIED / READY FOR HUMAN QUALIFICATION**。真实 P5/P6/P7/P8 未执行，禁止标记 **HUMAN REVIEWED / REAL DEVICE PASS / FIELD PASS / PRODUCTION QUALIFIED**。

P0 只冻结安全基线，不改变业务算法。CI 必须单独运行并报告以下不可退化契约：

1. `bounded_correction_field` 不能生成有效 `published` 成果；
2. finalized checkpoint cleanup 必须由操作者显式确认，并绑定 tracking identity、finalized time、metadata SHA-256 和 checkpoint SHA-256 的精确 CAS 证据；
3. 外部 provider 复制即使校验成功，也不得自动删除手机本地采集副本；
4. required localization evidence 缺失、为空、损坏或身份/数量/水位不一致时，metadata 必须 fail closed 为 `finalized=false`。

## 发布阻断项

| ID | 状态 | 关闭条件 |
| --- | --- | --- |
| RB-01 | **代码已关闭，待扩大资格样本** | native helper 已读取 RTAB-Map 相对/闭环 Link transform 和 information，严格验证并接入发布能力；已用 2,315-node 真实 DB 只读运行。clean runner 和更多真实样本随 P2/P5/P6 继续验证 |
| RB-02 | **代码与 clean CI 已关闭** | macOS 本机 PC 空目录构建及累计 SHA 的 Ubuntu/Windows hosted native clean build、source-bound version、release manifest、iOS cold-cache dependency manifest 和 unsigned arm64 full App link 均已通过；干净终端安装/升级/卸载 smoke 仍属于 P7 操作验收，不能由 build Job 代替 |
| RB-03 | **阻断** | 在支持 LiDAR 的真实 iPhone 完成规定的开始、弱纹理、动态干扰、扫码、结束、恢复和复制矩阵 |
| RB-04 | **阻断** | 按 `FIELD_TEST_PLAN.md` 完成正式超市场景验收并保存 hash-bound 原始证据包；V1 由操作者 attestation 与独立 reviewer 复核，不宣称自校验 SHA 是数字签名 |
| RB-05 | **代码与自动测试已关闭** | 原子 journal、重启 `interrupted` 判定、浏览器重连、实际子进程取消、日志留存和损坏 journal fail-closed 已实现；安装包/断电矩阵仍由后续 wave 验证 |

生产化附加项 H-01/H-02/H-05/H-06/H-07 已完成代码和自动测试；H-03 已有 POSIX descriptor-bound 与 Windows reparse/handle 防护；H-04 的真机断电、崩溃和 provider 掉线矩阵仍须由 P5 执行。代码关闭不等价于真实设备或运营安装验收。

## Wave 顺序与边界

| Wave | 目标 | P0 时点状态 |
| --- | --- | --- |
| P0 | 冻结 W2R 安全基线和 CI 不变量 | 本地与远端验证通过 |
| P1 | 完整相对 SE(2) 因子图与发布门 | 已实现并完成本机真实 DB 只读验证；P1 GitHub Actions run `30360809785` 五个 job 全部成功；native clean build 属 P2 |
| P2 | 干净、可复现的 PC/iOS 构建 | 自动化出口已关闭：macOS 本机 clean build、Ubuntu/Windows hosted native clean build、Windows Python、iOS cold-cache manifest/cache 与 unsigned arm64 full App link 全部通过；干净终端安装 smoke 归 P7 |
| P3 | Map Studio 持久任务和重启恢复 | 已实现并通过工作台测试目录 86 项回归；独立运行时进程强杀后由新进程恢复为 `interrupted`，服务重启不猜测续跑，不按不可信 journal 路径清理 |
| P4 | iOS finalization、保留和 provider hardening | 代码与主机压力测试已完成：100k trace/constraint/state streaming 使用独立 finalization 进程并通过固定 peak RSS `<256 MiB` 门、descriptor identity、strict immutable snapshot thermal evidence、copy v2 隐私和未执行 durability hook；真机 smoke 未执行，不声称 power-loss durability |
| P5 | 真实设备矩阵 | Device Evidence v2 与 App/release exact SHA 门已实现；真实 LiDAR iPhone 未执行，因此仍为 NO-GO |
| P6 | 正式现场验收 | Field v3、可重新派生的 immutable trajectory/source evidence、exact CSV/Device bytes、3-run、20 控制点和重复性验证已实现；办公室/卖场未执行，因此仍为 NO-GO |
| P7 | 安装包、升级/卸载和 selfcheck | production-only publish、即时 selfcheck、package-bound release、evidence 自包含、真实 About mode、package stable-read 已实现；既有同机 smoke 不替代干净 macOS/Windows 安装/升级/卸载测试 |
| P8 | 独立代码、证据和发布复核 | 当前 RC code diff 独立只读审查已执行且 findings 已修复；exact-SHA 证据与最终发布复核仍未执行，因此 P8 整体未关闭 |

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

## 当前累计 SHA 的最终 clean CI

GitHub Actions run [30470632088](https://github.com/mcjiansheng/MarketScanner/actions/runs/30470632088) 精确绑定代码 SHA `8b3d06e0807752f515ca9ab6704152891338abde`，七个 Job 全部 **success**：

| Job | Job ID | 结果与证据边界 |
| --- | --- | --- |
| Windows clean native release build | `90639620341` | 哈希固定的 RTAB-Map Windows 依赖、fresh preset configure、两个 `.exe`、源码 SHA、release manifest 和 artifact 均通过 |
| Windows imports and Python contracts | `90639620404` | PriorMap、Qualification、Map Studio 和 Windows 敏感模块回归通过 |
| Native ABI source contracts | `90639620410` | native/Swift ABI 与 factor helper 源码合同通过 |
| Ubuntu clean native release build | `90639620411` | 空目录构建两个 native 工具，source-bound version、manifest 和 artifact 通过 |
| Ubuntu Python, API and web contracts | `90639620420` | Python、API、Web、全量测试和完整 branch diff 通过 |
| P0 production safety invariants | `90639620423` | 四项失败关闭安全不变量通过 |
| macOS and iOS source contracts | `90639620443` | cold-cache 全依赖构建、逐文件 dependency manifest、验证后 cache 保存及 unsigned generic arm64 App 完整编译/链接通过 |

此前 run `30462392903` 已成功构建并验证 cold dependencies，但 full App link 暴露 SuiteSparse/CHOLMOD BLAS/LAPACK 符号未绑定；`8b3d06e...` 显式链接系统 `Accelerate.framework`，并固定 VTK iOS deployment target。该修复先在本机 Xcode 26.5 完成 unsigned arm64 Release full link，再由上述 hosted run 独立通过。失败 run 只作为缺陷发现证据，不冒充成功。

## 兼容、数据和回滚约束

- 自由扫描和 prior-map 扫描继续写连续单 SQLite 数据库；`scanMode=continuous_streaming` 的存储语义不变。
- 原始扫描数据库只读，PC 处理写入新目录；带 `live_checkpoint.json` 的输入继续拒绝自动处理。
- NFC 入口保持关闭，旧 `price_tags.*` 仅用于兼容历史输入。
- `AGENTS.md`、`doc/.local/`、扫描数据库、构建目录、真实扫描数据和输出地图不得提交。
- P0 仅添加 CI/文档保护，可按其原子提交整体回滚；不得只删除某一失败保护后仍声称安全基线有效。

P0 已完成冻结、自动化验证和证据同步；它只允许开始组织后续独立 wave，不改变当前产品 **NO-GO** 判定。
