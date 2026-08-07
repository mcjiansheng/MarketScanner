# MarketScanner Mobile-Only V1 Release Candidate 阻断项收口报告

> 文档状态：**当前有效**。最后核对日期：2026-08-07。
> 仓库：`mcjiansheng/MarketScanner`
> 分支：`mobile-only-v1-release-candidate-blocker-closeout`
> 基线：`81b6dbb216e843d363fd0088f673076add78013f`
> 审查输入：`MarketScanner_Mobile_Only_V1R5_Second_Independent_Full_Code_Review_NO_GO.md`
> 实施输入：`MarketScanner_Mobile_Only_V1_Release_Candidate_Blocker_Closeout_Prompt_V2.md`
> 当前发布判断：**REJECTED / NO-GO / developer smoke only**

## 1. 结论和产品边界

本分支已关闭第二次独立审查中的大部分正确性、事务、安全、规模及审计缺口，当前本地主机回归通过。pre-CI implementation diff 的独立只读代码审查已经执行，审查发现的 committed RESCAN 被降级、completed task 残留旧 error、RESCAN strict Bool/reason-disposition/EEXIST 绑定、trace `Int64` 边界崩溃、Map quarantine 崩溃恢复与 canonical integer、以及 200k tag 长时进程 RSS 问题均已修复并加入可执行回归。该结论不是 release PASS；仍有一个明确的代码/合同阻断项：J-04 absolute-prior `same floor/map/component` 不能由现行 evidence schema 证明。关闭它需要先冻结 prior-independent final-link component policy，再完成 node snapshot C ABI、constraint/manual schema、finalization、Graph Reader 和 parser 的 breaking migration。exact-SHA GitHub Actions 已执行两次但均失败：run `31174285439@00018f4bf29a66d42aa94b47e6890cae8408d878` 为 3/8 jobs success；run `31177319567@37accce79201482926b9c3ea3247f649e95b375b` 为 6/8 jobs success。最新 run 的 macOS host E2E 暴露冻结 snapshot 目录经 Foundation `moveItem` 发布时的 EACCES，Windows Qualification 暴露大小写不敏感 `Path` equality 绕过 exact-case membership gate。当前代码已分别改为 `renameatx_np(..., RENAME_EXCL)` 和原始路径字符串 exact-case 比较，并通过本地主机回归；仍需精确 staged/cached diff 复核和新的 exact-SHA required-gate rerun。真实 Apple 双平台 clean compile-link 在 run `31177319567` 中仍因前置 macOS E2E 失败而 skipped，Replay/FAR policy freeze、Device Lab 和 Sam 现场复测也仍未完成。因此本报告不声明 `DEVICE LAB TESTABLE`、`DEVICE LAB PASS`、`SAM FIELD PASS` 或 `PRODUCTION READY`。

Mobile V1 冻结为 Route A：

```text
Fast reduced graph
→ 至多一次 Full existing-graph optimization
→ 仍失败则 RESCAN_SESSION
```

True sensor Deep 不属于 Mobile V1。设备端不会在 Fast/Full 失败后重建缺失视觉图证据，也不得把该能力写成已实现或隐式回退。

## 2. RC-B01…RC-B30 状态

| ID | 本分支状态 | 实现和验证摘要 |
| --- | --- | --- |
| RC-B01 | 代码关闭 | compiler、loader、integrity validator 和测试统一消费 shelves v2；包含物理 `shelf_segment_id`、显式 start/end/axis/normal 和跨文件关系校验 |
| RC-B02 | 代码关闭，待新 exact-SHA 复验 | production Swift 全部登记到 RTABMapApp target；自动 membership checker 当前确认 82 个 Swift 源文件；exact-case gate 使用原始路径字符串，不再被 Windows 大小写不敏感 `Path` equality 绕过 |
| RC-B03 | 代码关闭 | workflow 不再维护易漂移的手写 Swift parse 清单；source membership、SwiftPM lock 和 Apple build gate 分离 |
| RC-B04 | **EXACT-SHA CI EXECUTED / FAIL** | run `31174285439@00018f4` 为 3/8 jobs success，run `31177319567@37accce` 为 6/8 jobs success；后者证明 Linux/Windows native 与 Python 主门可执行，但本轮两项 portability 修复仍需新的精确 governance SHA required-gate 全绿证明 |
| RC-B05 | 代码关闭 | `StrictJSONLStreamReader` 为 64 KiB bounded streaming API；不再返回或保留全量 `ParsedLines`/`String` 数组；每行 caller body 在独立 autorelease pool 内运行，且不再重复执行同一 strict document validator，200k frame + 200k observation 全链路 RSS 回到门限内 |
| RC-B06 | 代码关闭 | clock correlation writer 使用 `O_CREAT|O_EXCL|O_NOFOLLOW` 增量 JSONL，每 64 条 fsync，durable watermark 只在同步成功后推进，final partial batch 同步，parent fsync 失败阻断 |
| RC-B07 | 代码关闭 | finalized metadata v2 严格类型化；读取正式 nested watermark `captureHealth.localizationTraceRecordCount`；metadata 有 1 MiB 上限，缺失/错误字段 fail closed |
| RC-B08 | 代码关闭 | snapshot 对 required file set、DB/WAL/journal/shm、hardlink/symlink、pre/post inventory 和 inode identity 做稳定校验；`scan_events.jsonl` 纳入 immutable snapshot并逐行绑定当前 `trackingSessionId`。当前 metadata 无 scan-event count/last-ID，故不声明 exact cardinality watermark |
| RC-B09 | **REOPENED BY CI / LOCAL FIX TESTED** | generation/manifest/backup 事务合同已实现，但 `37accce` 在 macOS 14 暴露冻结目录 publication EACCES；当前冻结的 `0555` staging、snapshot 和 backup 使用 Darwin `renameatx_np(..., RENAME_EXCL)` 同父目录发布/恢复，保持 no-replace，并已通过本地完整 host targeted rerun；新 exact-SHA PASS 前不得重新标为 closed |
| RC-B10 | 代码关闭 | Objective-C++ Graph Reader 严格验证 SQLite BLOB/NULL/count/byte length/pointer/finite/link；不再为短 BLOB 补零 |
| RC-B11 | 代码关闭 | native mandatory skeleton、factors 和 priors 使用 4096 硬上限；Swift 先解析 disposition 再处理 error，`RESOURCE_REQUIRED` 不降级；成功质量只认严格 `solver.factor_count` |
| RC-B12 | 代码关闭 | burst v2 强制 frame 与 observation exact 一对一、burst 内及全局 ID 唯一、verified complete burst 才可消费 |
| RC-B13 | 代码关闭 | burst summary 从 frame records 重算并与声明值精确核对，不能用伪造 summary 提高质量 |
| RC-B14 | 代码关闭 | typed tag DTO 严格 Bool/Int/finite；optional height 保持 optional；surface normal 必须近似单位长度；跨字段不变量 fail closed |
| RC-B15 | 代码关闭 | tag acceptance 使用 verified burst、`needsReview`、uncertainty、frame count 和正式质量门；缺少完整 burst 时不可 ACCEPTED |
| RC-B16 | 代码关闭 | tag 分桶、聚类、失败分组和 resolver 使用有界索引/哈希路径；200k 观测规模门纳入 host 回归 |
| RC-B17 | 代码关闭 | tag→shelf 绑定保留物理 `shelf_segment_id`，不再以重复 shelf code 覆盖不同货架段 |
| RC-B18 | 代码关闭 | association 正式消费 compiler 的 start/end/longitudinal axis/normal；沿架 offset 不再从 polygon 顺序重新猜测 |
| RC-B19 / J-04 | **部分关闭 / COMPONENT BLOCKER** | floor/identity/schema、一次 NodeIndex、345,600 规模、constraint/manual/recovery 三水位、accepted=false 和 manual nearest/ISO 均已关闭；但现行 constraint 无 atomic bound node/map ID，manual v3 无 RTAB-Map map ID，无法从最终 DB 反证“声明 component 一致”，不得伪报关闭 |
| RC-B20 | 代码关闭 | strict trace 验证 formal state、node timebase identity、统一 monotonic axis、状态关系和 watermark；Swift/PC 共用 fixture 输出稳定 reason parity；有限但无法安全映射到 `Int64` 秒轴的 hostile timestamp 返回 `compaction_axis_out_of_range`，不再触发 runtime trap |
| RC-B21 | 代码关闭 | clock parser 严格检查 reason、DB node binding、timezone offset、jump/rollback 和非单射 UTC；错误报告保留原文件行号 |
| RC-B22 | 代码关闭 | final trajectory 保留精确最后节点、stale trace/floor gate、线性 clock context pointer 和正确 discontinuity timezone；整体保持线性遍历 |
| RC-B23 | 代码关闭 | Result 使用 `Results/.result-staging-<task-sha256>.<result-sha256>/` 同父目录隐藏 staging；全部文件 `0444` 和 staging 根目录 `0555` 在 final path 不存在时完成冻结/验证，然后执行同父目录 `renameatx_np(..., RENAME_EXCL)`；rename 后重读 exact set/modes、receipt、manifest 和逐 artifact bytes/SHA |
| RC-B24 | 代码关闭 | result commit receipt 绑定 task/result/manifest；通用 failure terminalization 前先调和 committed immutable Result 或 committed immutable RESCAN artifact，重启可恢复 commit→completed / rescan-required 窗口，不把已提交业务事实降级为 generic failed，也不重复导出或重跑 native |
| RC-B25 | 代码关闭 | task state transition 严格、cancel 与 interrupt 区分；四类普通失败共用 terminal intent → terminal `task.json` → intent cleanup 事务，4 outcomes × 4 write boundaries 返回 typed business+durability failure；RESCAN artifact/checkpoint/terminal writer 各边界独立覆盖；恢复进入正常阶段或 completed 时使用显式 `clearError` 清除旧 `system_interrupted` / `resource_pause`；durable outputs 使用 namespace-qualified root-relative references |
| RC-B26 | 代码关闭 | mobile prior-map compiler 对 artifact、manifest、目录和 parent 执行强制同步；任一步失败不注册地图 |
| RC-B27 | 代码关闭 | Map Library rebuild 对包做完整验证而非 quick verify；损坏包与 canonical durable immutable `quarantine_diagnostic.json` 经 hidden pending 事务发布；list/map/register/unregister/rebuild 均在 library lock 下执行 startup reconciliation，并用三个真实 `_exit` 崩溃窗口验证 payload rename、diagnostic placement/freeze、publish rename/parent sync 后的新进程恢复；冲突或篡改保留现场并 fail closed |
| RC-B28 | 代码关闭 | XLSX verifier 严格校验 ZIP、workbook relationships、sheet binding、header、formula 和 row count；导入必须提供显式 store ID |
| RC-B29 | **外部门未关闭** | native policy 仍是 candidate；真实 Replay/FAR、Pareto 证据和最终 policy freeze 未执行 |
| RC-B30 | **外部门未关闭** | device/simulator dependency 和 workflow 已修复，但本机缺少完整双平台 native trees；run `31177319567` 在 macOS host E2E 前置步骤失败，后续 SwiftPM/Xcode metadata/simulator/device clean compile-link 全部 skipped，Device Lab 和现场资格未执行 |

结论：除 RC-B19/J-04 的 component identity breaking migration 外，大部分 RC-B01…RC-B03、RC-B05…RC-B28 已完成本地代码闭包；RC-B09 因 exact-SHA macOS 14 CI 暴露的 frozen snapshot publication 移植性问题重新打开，当前修复仅有本地测试证据。RC-B04、RC-B09、RC-B29、RC-B30 还必须分别由远端 exact-SHA CI、真实 Replay/FAR 数据和 Apple/真实设备证据关闭。J-04 与这些门任一未关闭时，整体均保持 `REJECTED / NO-GO`。

## 3. RC-H01…RC-H40 收口摘要

影响正确性、事务、安全、规模或审计的 HIGH 已同步进入代码与测试：

- RC-H01…H08：burst 绑定 prior identity、zero-frame complete 拒绝、tie→`unknown`、bucket 包含 symbology/segment、centroid reassociation 不跨 bucket、second candidate 不受 shelf code 去重污染、完整 sight segment 与 polygon/AABB occlusion、surface normal 单位长度。
- RC-H09…H20：clock 原始行号与 reason 白名单、非单射 UTC、nested watermark、禁止用处理当前时间伪造 finalizedAt、duplicate node fail closed、native prior/trajectory/quality/gauge 严格校验、250 ms resource sampling、真实 peak RSS 和 measurement failure fail closed。
- RC-H21…H31：result/task/map ID 统一安全 basename 和 UTF-8 byte limit；staging exact regular set、hidden file 不跳过、损坏 result quarantine、单一 createdAt、snapshot 目录 immutable、bounded partial writes、metadata size gate、stable source copy、Map Library full verify 和 package version policy。
- RC-H32…H40：resume 明确为 snapshot reuse；durable output root-relative contract；thermal evidence 从 immutable snapshot strict streaming 读取；trace formal state 完整语义；2,000,000 parser hard cap 与 1,728,000 qualification ceiling 分层；统一 store/map identity；SwiftPM exact pin；PC/device strict parser parity；本报告和当前权威文档不再写旧 Route B 或虚假完成状态。

## 4. 本轮本地主机证据

截至本报告最后核对时间，已执行：

| 验证 | 结果 |
| --- | --- |
| `python3 -m unittest discover -s tools/PriorMap/tests -v` | 166 tests，PASS；1059.678 s |
| `IOSCoreContractTests` portability targeted rerun | 2 tests，PASS；1122.825 s；覆盖 immutable snapshot E2E、300k finalization、1,728,000 trace storm、200k frame + 200k observation tag scale |
| `python3 -m unittest discover -s tools/Qualification/tests -v` | 28 tests，PASS |
| `python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v` | 106 tests，PASS |
| `rtabmap-market-scanner-native-tests` | 7,878 checks，0 failures |
| iOS source membership | 82 Swift sources，本地主机 PASS；Windows exact-case regression 已本地修复，待新 exact-SHA 复验 |
| SwiftPM dependency lock | 1 direct package / 1 exact resolved pin，PASS |
| generated mobile evidence contracts | 11 generated/authoritative files，version 1，无漂移 |
| 300k finalization scale | 300,000 records / 114,933,372 input bytes / 114,933,372 temporary bytes；7.877 s wall / 7.871 s CPU；peak RSS 12,795,904 bytes |
| 48 h trace transition storm | 1,728,000 records；保留 172,801 个每秒保守最坏状态 + exact final sample；0 temporary bytes；0.334 s wall / 0.337 s CPU；peak RSS 58,769,408 bytes |
| 200k tag 全链路 | 200,000 burst frames + 200,000 observations，243,952,646 input/temporary bytes；经过 strict parser、resolver、shelf association、fusion 和 quality gate；200,000 accepted observations、1 个 accepted physical tag；884.922 s wall / 880.926 s CPU；peak RSS 670,662,656 bytes（约 639.6 MiB，低于 768 MiB 门） |
| JSONL legacy API residue | `ParsedLines` / `readLines(` 为 0 matches |
| 静态检查 | Python compile、shell syntax、Xcode project plist、workflow YAML、`git diff --check` PASS |

这些是未优化 macOS Swift host / 本地主机自动化证据，不等价于 target-device 60k/200k 性能、simulator/device clean link、热状态、电池、后台、provider、断电或现场精度证据，也不能抵消 run `31174285439` 和 `31177319567` 的远端 FAIL。

## 5. 最终独立只读审查

pre-CI implementation diff 的独立审查覆盖 correctness、transaction、security、scale、audit、docs 和 CI 合同，状态为 **COMPLETED / BLOCKERS FOUND AND FIXED**。修复内容包括：committed RESCAN/Result 的跨目录恢复顺序；RESCAN artifact/checkpoint/task 写边界与 EEXIST race；strict Bool 和 reason/disposition 交叉约束；completed task 的 stale error 清除；Map quarantine 三个真实进程崩溃窗口、destination symlink/source+published 冲突和 canonical integer；trace 超出 `Int64` 秒轴的稳定拒绝；以及 strict JSONL 每行 autorelease pool 解决的 200k 证据 RSS blocker。随后 exact-SHA CI 新发现 macOS snapshot publication 和 Windows path-case 两个 portability blocker；当前修复已完成代码路径只读审查和本地回归，提交前仍需对包含同步文档的精确 staged manifest/cached diff 做最终复核。J-04 与外部资格门保持未关闭，所以这里不得写 release review PASS、Device Lab ready 或 production ready。

## 6. 事务与审计边界

- 原始 session/SQLite 只读；snapshot、task staging、result staging 和最终 result 使用不同命名空间。
- snapshot 拒绝非空 WAL/journal/shm、hardlink、symlink、路径替换和 file-set 变化；成功后文件 `0444`、目录 `0555`。
- Result 只允许从 `Results/.result-staging-<task-sha256>.<result-sha256>/` 同父目录隐藏 staging 提交；exact set、SHA、mode、receipt 和 parent durability 任一失败都不进入 completed。rename 前失败时 final path 不存在，已冻结的隐藏 staging 恢复为 directories `0755` / files `0644` 以便重启清理；rename 后使用 commit receipt 与逐文件 hash 重建并复核提交事实。通用失败路径必须先调和 committed Result，真实提交不得改写为 failed。
- `RESCAN_SESSION` 使用独立不可变 `rescan_session_outcome.json`，artifact、checkpoint 和 terminal task 的 rename 前后四类边界均有故障注入；artifact 已可见时先 stable no-follow 重读、补 task-root parent fsync、复核 exact identity/SHA 与 checkpoint reference，再恢复 `rescan_required`。numeric Bool、错误 reason/disposition、RESOURCE_REQUIRED 冒充 graph failure、EEXIST 不等价 winner 或同时存在普通 Result 均 fail closed。
- cancelled / interrupted / resource_required / workflow_failed 先写 durable `terminal_state_intent.json`，再写 terminal `task.json`，最后清除 intent。task writer 任一注入边界失败均向调用方返回含业务 outcome/code/detail 和 durability phase/detail 的 typed error；重启只在 task identity、目标状态和 reason 精确一致时清理，或把已知非终态推进到 intent 目标，completed、不同终态/理由和 task identity 冲突均保持 task/intent 不变并 fail closed。若底层存储连 intent 都无法 durable 建立，只能 fail closed 并保留存储故障边界，不能宣称具有绝对可靠的磁盘 marker。
- interrupted/resource pause 恢复、fresh/recovered snapshot、正常 completed 和 committed-result recovery 均显式清除旧 task error；`nil` 不再被错误解释成“保留旧错误”。
- iOS 内嵌 build identity 使用 version 3 exact schema，完整消费 governance descriptor 的 wave/branch/base/SHA 字段；当前 RC wave 不再被历史 `mobile-only-v1r4-` 前缀硬编码拒绝。上一 governance HEAD `37accce` 绑定当时 implementation `c78106d`，但 `validation_sha` 仍为 `<EVIDENCE_DOCS_SHA>`；本次 production 修复提交把 descriptor 恢复为精确的 implementation/validation 占位符，待新 implementation commit 已存在后再由纯治理提交绑定。Python 治理阶段只允许这两个精确未绑定占位符，Swift 运行时会对它们 fail closed；最终 implementation/validation 必须均为 40 位小写 SHA 才能使 `isUsable` 成立。
- 损坏或未知 result root entry 移入 `Results/quarantine/quarantine-<uuid>/result_payload`，并写入 immutable `quarantine_diagnostic.json`。
- Map Library 对 invalid immutable package 使用 exclusive quarantine；diagnostic v2 以 strict typed 字段重建 canonical bytes，绑定 transaction/prior-map/source/quarantine/payload-tree/validator identity。library lock 下的 startup reconciliation 能恢复 `.diagnostic.tmp`、`.pending` 与 final quarantine 的合法崩溃状态；source+published 双份、symlink destination、mode/hash 篡改或未知 transaction 保留现场并 fail closed。
- stable import 使用 no-follow、regular、single-link、bounded chunks、pre/post identity、destination `O_EXCL`、data fsync 和 parent fsync。
- 业务身份原值必须 NFC、非空、无首尾空白、无 hidden/path/control 字符，且为单一安全路径组件；store ID 最多 128 UTF-8 bytes，map name 最多 200 UTF-8 bytes。

## 7. Apple 构建和依赖状态

已实现但尚未由新的 exact SHA 远端证明：

- `install_deps.sh --platform iphoneos|iphonesimulator`；
- `Libraries/iphoneos/` 与 `Libraries/iphonesimulator/` 分离；
- `MarketScannerNativeDependencies.xcconfig` 按 `$(PLATFORM_NAME)` 选取依赖；
- simulator/device manifest v2 验证 archive/fat/nested Mach-O、arch 和 `LC_BUILD_VERSION` platform 2/7；
- device/simulator cold cache 与真实 `clean build` workflow gate；
- SwiftPM `Zip` 2.1.2 exact revision `67fa55813b9e7b3b9acee9c0ae501def28746d76`。

当前工作机没有可供完整链接的 `Libraries/iphoneos/` 和 `Libraries/iphonesimulator/` 生产依赖树，因此不能引用历史 archive 或发布目录产物代替。run `31177319567` 的 macOS job 在 platform-independent host E2E 以 EACCES 失败后，cold SwiftPM resolve、Xcode metadata、iphoneos/iphonesimulator dependencies、simulator clean build、unsigned arm64 device build 和 embedded identity 验证均被 skipped；Apple simulator/device clean compile-link 仍为 **NOT RUN / BLOCKED ON SUCCESSFUL PREREQUISITES**。

## 8. 未完成且禁止冒充 PASS 的资格门

| 门 | 当前状态 | 关闭要求 |
| --- | --- | --- |
| J-04 component identity schema/C ABI | **BLOCKER / NOT CLOSED** | 冻结 prior-independent final-link component policy；node snapshot 原子携带 node/map identity；constraint/manual 新 schema；final DB node/map/component exact 重验；旧 schema 不追溯认证；完成 Apple 双平台 compile-link |
| final independent diff review | **PRE-CI REVIEW COMPLETED / POST-CI STAGED REVIEW PENDING** | pre-CI findings 已进入旧 implementation；post-CI 两项 portability 修复已通过代码路径只读审查和本地回归，提交前仍需复核包含同步文档的精确 staged manifest/cached diff。J-04 仍独立保持 BLOCKER，不能把此项写成 release review PASS |
| implementation SHA binding | PENDING REBIND | 旧绑定 `c78106da196ff960b7e1dd78f20cda544023c6ca` 早于本轮两项 portability 修复；implementation commit 中 descriptor 已恢复为精确占位符，新 commit 存在后必须由纯治理提交重新绑定 |
| exact-SHA GitHub Actions | **2 RUNS FAILED / NEW RERUN PENDING** | `31174285439`、`31177319567` 均为 FAIL；修复提交和 governance 绑定后查询只属于新精确 SHA 的全部 required jobs，不可用分支最新状态替代 |
| Apple simulator/device clean link | NOT RUN / BLOCKED | run `31177319567` 中相关步骤因前置 macOS E2E 失败而 skipped；必须在新 exact-SHA run 使用平台正确的冷构建依赖树分别 clean build 并验证 link |
| Replay/FAR/policy freeze | NOT RUN | 真实/合成资格数据、误接受率、精度/性能 Pareto 和冻结 policy |
| Device Lab | NOT RUN | 支持 LiDAR 的真实 iPhone、Route A、tag、弱纹理、后台、热/内存/磁盘、crash/relaunch、result receipt |
| Sam field re-test | NOT RUN | 同路线真实重扫、控制点、价签和独立证据复核 |

在上述资格门全部按对应层级完成前，允许的最高表述仍是：

```text
REJECTED / NO-GO / developer smoke only
```

不得声明：

```text
DEVICE LAB TESTABLE
DEVICE LAB PASS
SAM FIELD PASS
PRODUCTION READY
Replay/FAR PASS
exact-SHA CI PASS
simulator/device clean compile-link PASS
```
