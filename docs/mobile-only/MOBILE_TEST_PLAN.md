# 手机端测试计划（Mobile Test Plan）

> 状态：**当前有效**；统一扫描 UX/startup 聚焦组、MapCase02 正式套件、非超长 PriorMap 分组和完整 Swift host 长方法已执行；完整 discover、QualifiedDevice 真机、设备与现场详细测试仍延期；run `31307753672` 为历史 7/8 FAIL。最后核对：2026-08-10。

> 独立复审状态：`fix/mobile-import-prewarm-esl-deferred-tag@673d8d3a714f8fb6be18acc44ca4dd32589f3e81` 为 **REJECTED / DO NOT MERGE**，发现 Vision ROI 坐标与历史处理同步准入两个 P1。`fix/mobile-import-esl-review-blockers` 包含修复和回归测试，但仍待独立只读复审；不得把本地修复或此前增量的 `P0=0/P1=0` 结论扩展为本增量已通过。

## 自动测试（已实现，Swift host 默认模式 + 模式化套件）

| 组 | 覆盖 | 状态 |
|---|---|---|
| Unified scan UX/startup | 首页/菜单先进入轻量地图选择页、已导入地图/导入新地图、确认后才加载、配置页 immutable selectedMap 且无 picker、导入进度在 staging 后才显示、单一地图库/配置页/Coordinator、后台 package I/O、root Close/push Back、首次相机权限、旧 tmp-db 绕过关闭、receipt/context durable commit、取消/强 rollback、1×–8× zoom、方向键、离散朝向、默认/QualifiedDevice Release scheme | 聚焦合同 **29/29 PASS**；Swift 核心长方法 **1/1 PASS（1233.541 s）**；当前 unsigned iphoneos Debug 全量编译/链接 PASS 且身份 fail closed；提交后默认 `RTABMapApp` unsigned Release 全量编译/链接 PASS，输出 `build identity verified`；独立复审 `P0=0/P1=0`。真机运行与交互 p50/p95 NOT RUN |
| I1-I14 | 三格式导入、canonical parity、公式/ZIP/CSV/JSON 安全 | Swift host + --import-suite |
| C5/C7/C9/C10 | 编译器路网统计、距离场 SHA、package self-load、PC parity | Swift host |
| MapCase02 | 正式 Basic/Element workbook、Shelf audit、top-left、1838→1630 active、role geometry、canonical/package/preview golden；XLSX authority、strict scalar、resource budget 与派生工件重签 mutation | Swift `--mapcase02-suite` + PC converter/schema **PASS**；独立复审 `P0=0/P1=0` |
| P1/P2/P7/P8/P12 | Fast Path 收敛、快照事务、任务状态机；Snapshot/Result durable intent、`0755→rename→bound-FD 0555/fsync`、root/lock descriptor/path最终复核、mismatched removal tombstone 永久 conflict quarantine | I10 完整 Python 外层 Swift host 973.769 s PASS；run `31307753672` 的远端 host 合同与 200k RSS PASS；完整 discover 与新 exact-SHA 待执行 |
| Native/AbsolutePrior contract | 4096/4097、RESOURCE_REQUIRED+error；quality v2 strict typed DTO 的 unknown/duplicate/wrong type/Bool、path/disposition/request identity、graph/factor SHA、runtime ABI、C trajectory/skeleton/publish/factor count mismatch；RunSummary 仅投影已验证 `solver.factor_count`；constraint/manual/recovery exact raw-line watermark、345,600 资格上限、accepted=false 非致命、manual ISO/Unix 与 v2/v3 nearest/second margin | Native executable + Swift host（合并后统一重跑） |
| J-04 component identity | Graph Reader node mapID/link component derivation；constraint/manual 新 schema 的原子 bound node + RTAB-Map map ID；最终 component 重算与错 component 拒绝 | **BLOCKER：写侧 schema 尚无可核验证据，NOT RUN / NOT CLOSED** |
| T1/T3/T4/T6/T7/T12 | 1 Hz 重采样、yaw 最短弧、lost/gap、100k 行 | Swift host |
| G1-G10 | 价签绑定/传播/融合/货架/质量门 | Swift host |
| ESL Capture / confirmation v2 | ARFrame-only camera preview、显式 autofocus、真实 ROI + 同帧一次扩展 ROI、10 Hz/one-in-flight、1 秒 request deadline、bounded two-lane Vision executor、2-frame lock、3 minimum/4 target、4 秒窗口、暂时 exact-node publication gap 延期、逐帧可靠 quorum、`ACCEPTED/LOW_CONFIDENCE/RESCAN_REQUIRED` 三态、durable observation↔burst exact binding、exact-node final-pose 重投影；session admission/drain、ordinary/terminal Recovery 权限、active-only exact-session audit | `673d8d3` 独立复审 **REJECTED**（ROI-local 坐标 P1）；修复分支的 actual request ROI/revision 还原、0.80 gate 与 host/source 回归已通过 mobile UX 22/22、完整 PriorMap 247/247、Qualification 30/30、Map Studio 109/109、Swift parse 和 unsigned generic iphoneos Debug build，仍待独立复审。真机 close-range focus、iOS 15/16/17+ ROI/depth-center、恢复期定位、LiDAR、性能和现场矩阵 NOT RUN |
| X1-X9 | 工作簿结构、四表、公式注入、控制字符、100k | Swift host |
| Scale/stream | 当前源码：300k finalization（14,139,392-byte peak RSS）；60k clock writer；1,728,000 trace transition storm（保留 172,801、59,129,856-byte peak RSS）；200k burst frames + 200k observations 经 parser/resolver/shelf/fusion/quality 全链路（589,463,552-byte peak RSS，低于 768 MiB host 门）；JSONL per-line autorelease pool | Swift host；未优化 macOS developer evidence，不是 target-device PASS |
| Contract/parity | 11 份生成证据合同、scan-event mixed-session fail-closed、strict trace parity、85 shipping Swift source membership与Windows exact-case | Qualification 28/28 PASS；membership/SwiftPM lock/contracts PASS |
| Map quarantine | diagnostic v3、legacy v2 fail-closed、payload dev/inode、FD-relative rollback、root/lock最终复核、canonical UUID和`.`/`..`拒绝 | 关键focused真实进程PASS；EEXIST/UUID/CAS完整Python集成延期 |
| Result/RESCAN transaction | Result publish intent、root lock最终验证、artifact generation sweep；Result quarantine hidden pending + source move前durable v2 diagnostic + startup recovery + v1顶层symlink兼容；RESCAN既有事务 | Qualification与quarantine/publication focused PASS；完整artifact/intent replacement矩阵延期 |
| Publication platform contract | parent/root 以 `O_RDONLY|O_DIRECTORY` 打开，app owner 必须具备 read + write + search；no-follow directory FD、directory `fsync`、`lockf`、同卷同父目录 `renameatx_np(..., RENAME_EXCL)` 均为必要能力 | 当前 macOS/iOS 运行前提；不满足这些能力的文件系统不在已资格范围 |
| P7R2-P7R6C 回归 | 既有三端套件 | 全量 unittest |

## 未关闭（未写 PASS；逐项注明已运行/未运行）

- 2026-08-10 已完成统一 UX/startup 聚焦合同 29/29；本轮导入预热/近距离 ESL/低置信度保留 focused 21/21、当前源码完整 Swift host 长方法 1/1（1266.338 s）和 unsigned iphoneos Debug 全量编译/链接 PASS；四张真实 XLSX 手机地图库与 PC validator 4/4、PriorMap 非超长分组 217 项、Map Studio 109/109 与 I10/远端 host/RSS 证据仍有效。完整 discover 仍未登记 PASS；host evidence 不是 Replay/FAR、默认/QualifiedDevice Release 真机或现场 PASS。
- 三格式 canonical/编译语义 parity 已自动覆盖；真实业务大图 Replay/FAR 仍 NOT RUN。
- E2E-3 真机短路线（5~10 分钟扫描、10 个价签、手机处理、手机导出）。
- E2E-4 Sam 路线（100+ truth tags、现场控制点）。
- Excel / Numbers / WPS 打开验证。
- 资源门：peak RSS、处理时长、thermal、磁盘、电量、中断/崩溃恢复。macOS ACL、BSD `uchg`/`schg` file flags 和相关扩展属性仍未资格化；POSIX `0444/0555` 不能冒充这些边界的 PASS。
- exact-final-SHA GitHub Actions：最新 `31307753672@8f0e730d92773eea2ab58f56742d901ac02eead4` 为 7/8；七个非 Apple required jobs与 Apple job 内的 host/SwiftPM/Xcode metadata 均 PASS，iphoneos cold dependency configure 缺宿主 `rtabmap-res_tool` 显式绑定。I11/G11 已修复，等待新的全量 rerun。
- run `31307753672` 已证明 P0、exact binding、ABI、Ubuntu/Windows native clean build、Python contracts 与 macOS host/RSS PASS；本轮 Map Studio 109/109、既有 PriorMap 非超长 217 项、正式 PC golden/canonical ID/strict manifest-report 相关 Python 52/52、MapCase02 正式套件和四张真实 XLSX library smoke PASS。新 exact-HEAD 全绿前仍不得声明 exact-SHA PASS。
- Apple simulator/device 两套 cold native dependencies + 两次真实 clean compile/link：`31307753672` 的 iphoneos 依赖构建到 RTAB-Map configure 后失败，后续 simulator/device 步骤 skipped。I11 本地 iOS configure PASS；当前 unsigned Debug 和默认 `RTABMapApp` Release device build均 PASS，Release 日志确认严格身份，但仍不能替代 simulator/device 双平台 cold clean link或真机安装。
- I5 Result recovery、前序 I6 ESL、MapCase02、I10 fixtures、I11 cold-build、统一 UX/startup 和地图库安全复审的历史局部结论仍分别保留；它们不覆盖 `673d8d3`。该增量当前独立结论仍是两个 P1、**REJECTED / DO NOT MERGE**；修复分支待独立复审。完整 discover、新 exact-SHA、Apple/设备/现场与 J-04 仍未关闭，最终判断保持 **REJECTED / NO-GO / developer smoke only**。

## 明日详细执行队列

1. 完成 `python3 -m unittest discover -s tools/PriorMap/tests -v`；不得把已通过的 217 项、完整单个长方法或远端 host contract 冒充全 discover。
2. 保留 XLSX 100k、Replay/FAR 与真实业务数据矩阵；workflow/finalization/trace/tag 主长路径已在 I5 执行。
3. Map EEXIST、uppercase/noncanonical UUID、`.`/`..` CAS集成。
4. Result hardlink/`0644` clone/post-hash mutation、manifest/receipt post-read、root final sweep、intent creation/temp/removal/staging replacement。
5. 将两个128 MiB delayed replacement改为精确fault hook测试。
6. 修复`listResultsLocked()` root枚举错误的审计诊断；为根级非symlink special file设计durable conflict evidence。
7. 按 [`../map-assisted-localization/ESL_CAPTURE_TODO.md`](../map-assisted-localization/ESL_CAPTURE_TODO.md) 执行 LiDAR 真机 30 秒连续性、Vision p50/p95/CPU/memory/thermal、照明/反光/斜视/多价签、confirmation conflict 和 manifest v3 矩阵。
8. 补齐 `Libraries/iphonesimulator` / `Libraries/iphoneos` platform dependencies 并完成两次 clean compile-link；当前缺失的 Eigen/PCL/OpenCV headers 只可记录为 build blocker。
9. 在真机测量 scan-stop finalization-owned audit/terminal Recovery stable-read 的 UI latency；当前源码长时 PriorMap host workflow 已完成，不能替代该真机 UI 测量。
10. 在真机重新导入 `map 2.xlsx`，确认显示 ID `piaseczno-5ddfac7dc439` 且地图出现在地图库；继续执行 [`../map-assisted-localization/MAPCASE02_TODO.md`](../map-assisted-localization/MAPCASE02_TODO.md) 的低影响 parity/UI/preview/visual baseline 与真机 MapCase02 矩阵。host `--xlsx-library-smoke` 四张真实地图 PASS 不能替代该真机复测。
11. 深化 Windows portable basename 尾随点/空格和设备名拒绝，并评估 Debug illegal-transition assertion 前后的 audit 持久化顺序。
12. 用默认 `RTABMapApp` Release（并可用 `RTABMapApp-QualifiedDevice` 交叉确认）在干净安装上执行：新建扫描先选图、导入新图、确认后单次加载、文件选择前隐藏进度、首次权限、zoom/nudge/heading、开始/取消/返回、真实连续扫描和停止；记录入口、返回、地图加载和启动事务的主线程 stall 与 p50/p95，不能用 Debug 或 host wall time替代。
13. 在真机手工复现“成功导入地图后停留 `.mapReady` → 打开处理历史扫描 → 选择 finalized 会话”，确认同步拒绝后 Close、下拉 dismiss 和 table 立即恢复；再从 `.idle` 验证正常处理的完成、失败和取消都恢复 busy。
14. 使用 iOS 15/16/17+ 或等价 Device Lab 覆盖主 ROI、expanded ROI、近距离、大条码、ROI 边缘和多条码，并保存已知像素中心 observation，核对最终 native sensor/depth sample center；host 几何测试不能替代真机 Vision revision 合同。
