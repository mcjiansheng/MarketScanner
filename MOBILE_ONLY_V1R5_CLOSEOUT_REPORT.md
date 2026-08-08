# MarketScanner Mobile-Only V1 Release Candidate 阻断项收口报告

> 文档状态：**当前有效**。最后核对日期：2026-08-09。
> 仓库：`mcjiansheng/MarketScanner`
> 分支：`mobile-only-v1-release-candidate-blocker-closeout`
> 基线：`81b6dbb216e843d363fd0088f673076add78013f`
> 审查输入：`MarketScanner_Mobile_Only_V1R5_Second_Independent_Full_Code_Review_NO_GO.md`
> 实施输入：`MarketScanner_Mobile_Only_V1_Release_Candidate_Blocker_Closeout_Prompt_V2.md`
> 当前发布判断：**REJECTED / NO-GO / developer smoke only**

## 1. 结论和产品边界

本分支已关闭第二次独立审查中的大部分正确性、事务、安全、规模及审计缺口，并积累了本地主机 developer-smoke 回归。底层事务加固实现为 `f0ffcec4480ce04ac61f3a8aad2453e5b4b27a35`，ESL 核心 I3 为 `fdcc5c87005a0128e0654eb43b1364898edd8f5d`；当前 implementation I4 为 `ec1fe96fc676c03514e591c40226112cde30fe76`，G4 `17871d839834487c777824c062980f3322521cdb` 已将 descriptor 的 `implementation_sha` 更新到 I4。evidence 文档由后续纯治理提交绑定到 `validation_sha`，当前精确值以 `.github/marketscanner-repair-v2-wave.json` 为唯一事实源。该结论不是 release PASS；J-04 absolute-prior `same floor/map/component` 仍是明确的代码/合同阻断项。exact-SHA GitHub Actions 历史三次运行全部失败，V3 run `31276419986` 又出现 P0 fixture failure；I4 尚未取得远端 exact-SHA PASS。当前实现采用 payload/nested directory 先冻结、root `0755` exclusive rename、inode-bound FD `fchmod(0555)`/`fsync`/path identity 复核的 publication 协议；Snapshot、Result 和 quarantine 的 rename 均不是业务提交点。Apple clean compile-link、Replay/FAR、Device Lab 和 Sam 现场复测仍未完成，因此本报告不声明 `DEVICE LAB TESTABLE`、`DEVICE LAB PASS`、`SAM FIELD PASS` 或 `PRODUCTION READY`。

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
| RC-B02 | 代码关闭，待新 exact-SHA 复验 | production Swift 全部登记到 RTABMapApp target；自动 membership checker 当前确认 83 个 Swift 源文件；exact-case gate 使用原始路径字符串，不再被 Windows 大小写不敏感 `Path` equality 绕过 |
| RC-B03 | 代码关闭 | workflow 不再维护易漂移的手写 Swift parse 清单；source membership、SwiftPM lock 和 Apple build gate 分离 |
| RC-B04 | **EXACT-SHA CI FAILED；NEW RUN REQUIRED** | 历史三次为 3/8、6/8、7/8；V3 run `31276419986` 的 P0 job 又因 legacy fixture 不同步而 FAIL。当前 I4 `ec1fe96` / G4 `17871d8` 已修复并绑定，仍需 E4/V4 exact-HEAD required-gate PASS |
| RC-B05 | 代码关闭 | `StrictJSONLStreamReader` 为 64 KiB bounded streaming API；不再返回或保留全量 `ParsedLines`/`String` 数组；每行 caller body 在独立 autorelease pool 内运行，且不再重复执行同一 strict document validator，200k frame + 200k observation 全链路 RSS 回到门限内 |
| RC-B06 | 代码关闭 | clock correlation writer 使用 `O_CREAT|O_EXCL|O_NOFOLLOW` 增量 JSONL，每 64 条 fsync，durable watermark 只在同步成功后推进，final partial batch 同步，parent fsync 失败阻断 |
| RC-B07 | 代码关闭 | finalized metadata v2 严格类型化；读取正式 nested watermark `captureHealth.localizationTraceRecordCount`；metadata 有 1 MiB 上限，缺失/错误字段 fail closed |
| RC-B08 | 代码关闭 | snapshot 对 required file set、DB/WAL/journal/shm、hardlink/symlink、pre/post inventory 和 inode identity 做稳定校验；`scan_events.jsonl` 纳入 immutable snapshot并逐行绑定当前 `trackingSessionId`。当前 metadata 无 scan-event count/last-ID，故不声明 exact cardinality watermark |
| RC-B09 | **IMPLEMENTATION COMMITTED / EXACT-SHA PENDING** | Snapshot 使用 durable transaction intent 绑定 new/prior generation 的 dev/inode 与 manifest SHA；task-root 与 `input_snapshot.lock` 的 FD/path authority 在获取前后及公开 API 返回前复核。payload/nested directories 先冻结，root 以 `0755` exclusive rename，再由 bound FD 冻结为 `0555`、fsync 并复核 path identity；新 exact-SHA PASS 前不得标为 closed |
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
| RC-B23 | 实现已提交，待 exact-SHA | Result 使用同父目录隐藏 staging、durable publish intent、root-scoped process lock 与最终 root/lock authority validation；exclusive rename 后由同一 bound FD 执行 `0755→0555`、fsync、path/dev/inode 与 generation-wide manifest/receipt/artifact 重验。损坏 Result 的 quarantine 另使用 hidden pending + source move 前 durable v2 diagnostic + dev/inode 绑定 + startup recovery；历史 v1 顶层 symlink quarantine 保持兼容 |
| RC-B24 | 代码关闭 | result commit receipt 绑定 task/result/manifest；通用 failure terminalization 前先调和 committed immutable Result 或 committed immutable RESCAN artifact，重启可恢复 commit→completed / rescan-required 窗口，不把已提交业务事实降级为 generic failed，也不重复导出或重跑 native |
| RC-B25 | 代码关闭 | task state transition 严格、cancel 与 interrupt 区分；四类普通失败共用 terminal intent → terminal `task.json` → intent cleanup 事务，4 outcomes × 4 write boundaries 返回 typed business+durability failure；RESCAN artifact/checkpoint/terminal writer 各边界独立覆盖；恢复进入正常阶段或 completed 时使用显式 `clearError` 清除旧 `system_interrupted` / `resource_pause`；durable outputs 使用 namespace-qualified root-relative references |
| RC-B26 | 代码关闭 | mobile prior-map compiler 对 artifact、manifest、目录和 parent 执行强制同步；任一步失败不注册地图 |
| RC-B27 | 实现已提交，待 exact-SHA | Map Library diagnostic v3、legacy v2 fail-closed、payload dev/inode、FD-relative rollback、所有公开成功路径 root/lock 最终复核及 canonical lowercase UUID 已提交；safe prior-map ID 额外拒绝 `.`/`..`。本轮 focused 真实进程覆盖 root/lock replacement、tombstone rename/unlink、source replacement、pending/embedded diagnostic replacement等关键边界 |
| RC-B28 | 代码关闭 | XLSX verifier 严格校验 ZIP、workbook relationships、sheet binding、header、formula 和 row count；导入必须提供显式 store ID |
| RC-B29 | **外部门未关闭** | native policy 仍是 candidate；真实 Replay/FAR、Pareto 证据和最终 policy freeze 未执行 |
| RC-B30 | **外部门未关闭** | device/simulator dependency 和 workflow 已实现，但本机缺少完整双平台 native trees；最新 run `31180693841` 在 macOS 14 host E2E 前置步骤失败，后续 Apple SwiftPM/Xcode metadata、cold dependencies、simulator/device clean compile-link 与 identity 检查全部 skipped，Device Lab 和现场资格未执行 |

结论：除 RC-B19/J-04 的 component identity breaking migration 外，大部分 RC-B01…RC-B03、RC-B05…RC-B28 已形成代码闭包或当前工作树加固；但 RC-B09/RC-B23 的 macOS directory publication 修复尚无 exact-SHA 远端 PASS。RC-B04、RC-B09、RC-B23、RC-B29、RC-B30 还必须分别由新的精确提交 CI、真实 Replay/FAR 数据和 Apple/真实设备证据关闭。J-04 与这些门任一未关闭时，整体均保持 `REJECTED / NO-GO / developer smoke only`。

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
| `python3 -m unittest discover -s tools/PriorMap/tests -v` | 历史基线 166 tests PASS；当前 implementation I4 的完整套件按时间要求延期到明日，不复用旧 PASS 作为当前提交结论 |
| `IOSCoreContractTests` portability targeted rerun | 2 tests，PASS；1122.825 s；覆盖 immutable snapshot E2E、300k finalization、1,728,000 trace storm、200k frame + 200k observation tag scale |
| `python3 -m unittest discover -s tools/Qualification/tests -v` | 28 tests，PASS；7.663 s；包含 Snapshot/Result acquisition 与最终 process-lock pathname/root replacement |
| `python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v` | 106 tests，PASS |
| Result quarantine focused smoke | PASS；正常隔离、intent durable→source move、source move→freeze、publish rename→freeze、根级 symlink、重启后无 hidden transaction residue |
| Map/Result focused fault smoke | PASS；Map root/lock replacement、tombstone crash/restart、source/pending/diagnostic inode replacement；Result publication destination/source/interrupted replacement与 artifact symlink拒绝 |
| `rtabmap-market-scanner-native-tests` | 7,878 checks，0 failures |
| iOS source membership | 83 Swift sources，当前本地主机 checker PASS；Windows exact-case regression 待新 exact-SHA 复验 |
| SwiftPM dependency lock | 1 direct package / 1 exact resolved pin，PASS |
| generated mobile evidence contracts | 11 generated/authoritative files，version 1，无漂移 |
| 300k finalization scale | 300,000 records / 114,933,372 input bytes / 114,933,372 temporary bytes；7.877 s wall / 7.871 s CPU；peak RSS 12,795,904 bytes |
| 48 h trace transition storm | 1,728,000 records；保留 172,801 个每秒保守最坏状态 + exact final sample；0 temporary bytes；0.334 s wall / 0.337 s CPU；peak RSS 58,769,408 bytes |
| 200k tag 全链路 | 200,000 burst frames + 200,000 observations，243,952,646 input/temporary bytes；经过 strict parser、resolver、shelf association、fusion 和 quality gate；200,000 accepted observations、1 个 accepted physical tag；884.922 s wall / 880.926 s CPU；peak RSS 670,662,656 bytes（约 639.6 MiB，低于 768 MiB 门） |
| JSONL legacy API residue | `ParsedLines` / `readLines(` 为 0 matches |
| 静态检查 | Python compile、shell syntax、Xcode project plist、workflow YAML、`git diff --check` PASS |

这些是未优化 macOS Swift host / 本地主机自动化证据，不等价于完整 PriorMap 当前提交回归、target-device 60k/200k 性能、simulator/device clean link、热状态、电池、后台、provider、断电或现场精度证据，也不能抵消历史失败 run；尤其不能把 I4 描述为 exact-SHA PASS。

## 5. 最终独立只读审查

最终关键生产增量已完成两轮只读审查。第一轮发现 Map `.`/`..` safe identifier、Result quarantine payload-move→diagnostic crash orphan和 Snapshot process-lock pathname binding；均已修复。第二轮发现历史 v1 顶层 symlink quarantine 兼容问题并已修复。最终结论为 `P0=0 / P1=0 / 新的可修 P2=0`。审查同时确认 Result quarantine v2 hidden pending/diagnostic/temp/tombstone/recovery 状态机不会删除唯一 payload，Snapshot/Map/Result 最终 authority validation均 fail closed。该结论仍不是 release review PASS：完整 PriorMap 当前提交套件、exact-SHA、J-04、ACL/file-flags与外部资格门仍未关闭。

## 6. 事务与审计边界

- 原始 session/SQLite 只读；snapshot、task staging、result staging 和最终 result 使用不同命名空间。
- snapshot 拒绝非空 WAL/journal/shm、hardlink、symlink、路径替换和 file-set 变化；payload 文件与嵌套目录冻结后，durable transaction intent 绑定 new/prior generation 的 manifest SHA 和 dev/inode。task-root 与 `input_snapshot.lock` 的 descriptor/path dev/inode、mode、link、size在获取前后及 API 返回前复核。macOS 14 publication 期间 root 必须允许 `0755` rename，rename 后通过仍打开的 FD 冻结到 `0555` 并 fsync；task reference、generation/path identity、parent durability 和 intent cleanup 完成前，rename 不是业务 commit point。
- Result 只允许从 `Results/.result-staging-<task-sha256>.<result-sha256>/` 同父目录隐藏 staging 提交；durable publish intent 绑定 task/result/manifest 与 directory dev/inode，root-scoped cross-process advisory lock 序列化 cleanup、commit、recovery、list 和 read，防止这些受锁操作清理或误读 active publish intent。payload 为 `0444`，root 以 `0755` exclusive rename 后由 bound FD 冻结为 `0555`、fsync 并重验 exact set、receipt、manifest 和逐 artifact SHA。rename 或 final pathname 出现均不是业务提交；只有完整验证、parent durability 和 intent cleanup 后才能调和为 committed。该 lock/lease 不覆盖 active staging 的长期 payload 写入阶段；生产安全依赖 `MobileProcessingPipeline` 单一主 App 串行，`cleanupStaging` 只在 task pipeline 启动且 staging 创建之前调用，并禁止同一 task 跨进程并发构建。
- 共享 publication helper 和目录枚举会以 `O_RDONLY|O_DIRECTORY` 打开 parent/root，因此 app owner 对相关 parent 必须具备 read + write + search 权限，不能只假设 write + search。目标文件系统还必须支持 no-follow directory FD、directory `fsync`、`lockf` advisory locking，以及同卷同父目录的 `renameatx_np(..., RENAME_EXCL)`；这些是当前 macOS/iOS 运行前提，不得泛化为任意文件系统均已资格化。
- `RESCAN_SESSION` 使用独立不可变 `rescan_session_outcome.json`，artifact、checkpoint 和 terminal task 的 rename 前后四类边界均有故障注入；artifact 已可见时先 stable no-follow 重读、补 task-root parent fsync、复核 exact identity/SHA 与 checkpoint reference，再恢复 `rescan_required`。numeric Bool、错误 reason/disposition、RESOURCE_REQUIRED 冒充 graph failure、EEXIST 不等价 winner 或同时存在普通 Result 均 fail closed。
- cancelled / interrupted / resource_required / workflow_failed 先写 durable `terminal_state_intent.json`，再写 terminal `task.json`，最后清除 intent。task writer 任一注入边界失败均向调用方返回含业务 outcome/code/detail 和 durability phase/detail 的 typed error；重启只在 task identity、目标状态和 reason 精确一致时清理，或把已知非终态推进到 intent 目标，completed、不同终态/理由和 task identity 冲突均保持 task/intent 不变并 fail closed。若底层存储连 intent 都无法 durable 建立，只能 fail closed 并保留存储故障边界，不能宣称具有绝对可靠的磁盘 marker。
- interrupted/resource pause 恢复、fresh/recovered snapshot、正常 completed 和 committed-result recovery 均显式清除旧 task error；`nil` 不再被错误解释成“保留旧错误”。
- iOS 内嵌 build identity 使用 version 3 exact schema。当前 implementation I4 `ec1fe96fc676c03514e591c40226112cde30fe76` 已由 G4 `17871d839834487c777824c062980f3322521cdb` 绑定；evidence SHA 由后续纯治理提交写入 descriptor，当前值以 descriptor 为准。两个字段均为 40 位小写 SHA 后运行时 identity 才可 `isUsable`，但这仍不替代 exact-SHA CI。
- 损坏或未知 result root entry 使用 `Results/quarantine/.quarantine-<uuid>.pending/` 隐藏事务；source move 前先持久化 canonical v2 diagnostic，绑定 source/payload/wrapper dev/inode，再冻结并 exclusive publish到 `quarantine-<uuid>/`。startup recovery分类 external/embedded diagnostic、pending/final和tombstone；未知冲突保留证据并使listing整体fail closed。历史 v1 immutable final继续兼容，包括顶层 symlink payload；嵌套 symlink/special/hardlink仍拒绝。
- Map Library 对 invalid immutable package 使用 exclusive quarantine；当前 diagnostic v3 以 strict typed schema 重建 canonical bytes，绑定 transaction/prior-map/source/quarantine/payload-tree/validator identity 和 payload dev/inode。v3 incomplete source rollback 使用 bound FD 做 payload hash、`fchmod/fsync`、最终 path/dev/inode 复核后才删除 durable intent。legacy v2 仅向后兼容完整冻结的 `0555` final；v2 writable final 和 v2 incomplete transaction 不具备 durable payload identity，必须保留现场并 fail closed。
- 当前 immutable 资格合同只覆盖 POSIX type/mode、single-link、symlink/hardlink、dev/inode、hash 和 fsync/rename 边界；尚未对 macOS ACL、BSD `uchg`/`schg` file flags 或相关扩展属性进行 hostile-input/恢复资格测试。不得把 `0444/0555` 宣称为已证明可以清除或覆盖 ACL/flags。
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

当前工作机没有可供完整链接的 `Libraries/iphoneos/` 和 `Libraries/iphonesimulator/` 生产依赖树，因此不能引用历史 archive 或发布目录产物代替。最新 run `31180693841@359e5c2` 的 macOS job 在 platform-independent host E2E 因 `0555` directory-root rename `EACCES` 失败后，cold SwiftPM resolve、Xcode metadata、iphoneos/iphonesimulator dependencies、simulator clean build、unsigned arm64 device build 和 embedded identity 验证均被 skipped；Apple simulator/device clean compile-link 仍为 **NOT RUN / BLOCKED ON SUCCESSFUL PREREQUISITES**。

## 8. 未完成且禁止冒充 PASS 的资格门

| 门 | 当前状态 | 关闭要求 |
| --- | --- | --- |
| J-04 component identity schema/C ABI | **BLOCKER / NOT CLOSED** | 冻结 prior-independent final-link component policy；node snapshot 原子携带 node/map identity；constraint/manual 新 schema；final DB node/map/component exact 重验；旧 schema 不追溯认证；完成 Apple 双平台 compile-link |
| current transaction diff review | **COMPLETED / P0=0 / P1=0** | Snapshot/Map/Result 与 ESL finalization/admission 增量均已独立复审；最新 ESL 复审的 3 个低影响 P2 已登记 TODO，完整 PriorMap 当前提交回归仍延期，不能写 release PASS |
| implementation/validation binding | **I4/G4 BOUND / E4-V4 PENDING** | implementation `ec1fe96fc676c03514e591c40226112cde30fe76`；governance `17871d839834487c777824c062980f3322521cdb`；当前 `validation_sha` 在 E4/V4 后由 descriptor 更新，文档不做自引用 SHA 声明 |
| exact-SHA GitHub Actions | **3 RUNS FAILED / NEW COMMITTED RERUN REQUIRED** | `31174285439`、`31177319567`、`31180693841` 均为 FAIL，最新为 7/8；只能查询未来明确提交 SHA 的全部 required jobs，不可用分支最新状态或当前工作树替代 |
| Apple simulator/device clean link | NOT RUN / BLOCKED | 最新 run `31180693841` 中相关步骤因前置 macOS host E2E 失败而 skipped；必须在新的 committed exact-SHA run 使用平台正确的冷构建依赖树分别 clean build 并验证 link |
| Replay/FAR/policy freeze | NOT RUN | 真实/合成资格数据、误接受率、精度/性能 Pareto 和冻结 policy |
| Device Lab | NOT RUN | 支持 LiDAR 的真实 iPhone、Route A、tag、弱纹理、后台、热/内存/磁盘、crash/relaunch、result receipt |
| Sam field re-test | NOT RUN | 同路线真实重扫、控制点、价签和独立证据复核 |

### 明日详细测试与低影响 TODO（2026-08-09 登记）

- 运行当前 implementation I4 的完整 `python3 -m unittest discover -s tools/PriorMap/tests -v`，不得复用历史 166/166 作为 I4 证据。
- 执行已写但今日未运行的 Map EEXIST、uppercase/noncanonical UUID、`.`/`..` CAS 集成场景。
- 执行 Result artifact hardlink、`0644` clone、hash 后同 inode修改、manifest/receipt post-read replacement、generation final sweep、intent creation/temp/removal/staging replacement完整 Python断言。
- 重跑完整 workflow/E2E 与 finalization、trace、tag、XLSX scale；两个128 MiB delayed replacement场景后续增加精确只测试 hook，消除时序依赖。
- `listResultsLocked()` 根目录创建/枚举失败目前安全地返回空列表，但未写 `lastListingDiagnostics()`/`NSLog`；补显式 `do/catch` 审计诊断。
- 根级非 symlink special file当前留在原位并使 listing fail closed；补 durable conflict diagnostic fixture与策略。
- 恶意同 UID 非协作 namespace writer、macOS ACL、BSD `uchg/schg`、相关扩展属性和第三方 file-provider/非本地文件系统语义继续作为未资格化平台边界。

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

## 9. ESL Barcode Capture / Shelf Confirmation 阻断级补充收口

本补充根据 `MarketScanner_ESL_Barcode_Capture_and_Shelf_Confirmation_Fix_Prompt.md` 实施，保持 MapCase02、地图坐标转换和所有 store/map/file-specific scale、offset、rotation 规则不变。

已关闭的阻断级链路：

- Capture Mode 复用持续到达的 `ARFrame.capturedImage` 和 camera-only `MTKView` 预览；无第二个 `AVCaptureSession`，无 `ARSession.pause()`、`stopCamera()`、`stopMapping()`、`resetTracking()` 或数据库切换。RTAB-Map、连续 SQLite、Clock、Pose、node creation 和 prior-map localization 在后台继续。
- 真实 Vision ROI，8 Hz detection / one-in-flight，24 Hz bounded preview；generation token 覆盖 Vision、evidence、persistence 和 UI completion。
- candidate 连续 2 帧锁定；目标 4 个、最低 3 个独立 frame；2 秒 deadline 时 3 个 durable frame 可解析，no-detection/multiple 不会让 collecting 无限等待。
- confirmation quorum 只统计逐帧可靠且无需 review、共同指向同一 `shelfSegmentId + side` 的证据；“2 弱 + 1 强”不能授权确认。替代候选保留 segment + side 完整 identity。
- frame observation 先 durable append，complete burst 后才允许确认。iOS finalization 与 PC strict reader 对 `observation_id / burst_id / frame_id / payload / symbology` 做 exact binding；v2 localized tag 的 frame set 必须精确等于一个 verified complete burst，tag payload/symbology 必须与该 burst 一致，burst `sequence` 必须为正且在文件内严格递增，但不要求从 1 开始或连续。
- completed capture cache 按真实完成顺序 FIFO 保留，超过 512 个 burst 时不会按 UUID 字典序随机淘汰当前 capture；confirmed durable write 后释放对应 cache。
- additive localized tag v2 分离 algorithm evidence 与 `USER_CONFIRMED` / `USER_OVERRIDDEN`，用户选择不覆盖算法字段，也不修改 SLAM、trajectory、node pose 或 localization constraint。
- PC session input manifest v3 在 Recovery v2 binding 之上纳入 `tag_observation_bursts.jsonl`；builder、parse-and-hash-once snapshot、bundle validator、render/replay 与 localized output store 使用共享合同和同一 exact role order。合同拒绝 Boolean/浮点/字符串版本，强制 v1 legacy 与 v2/v3 bound Recovery 声明、大小写不敏感 filename 唯一、source database 安全 basename 和 source-manifest cross-binding；source DB 在 manifest/snapshot/verified-copy 全链拒绝 hardlink、非空 WAL 与 rollback journal。
- 现场选择与可靠 optimized association 一致时输出 `NO_CONFLICT` 并保持 approved；可靠冲突输出 `USER_CONFIRMATION_CONFLICT`，离线关联不可用输出 `OFFLINE_ASSOCIATION_UNAVAILABLE`，后两者均进入 `REVIEW_REQUIRED` / rescan，且不静默改写现场选择。
- 同步审查关闭 confirmation cancel/clear TOCTOU 与后台 generation data race：coordinator 锁内保存 immutable map/session authority，commit 只能原子 claim 一次；session writer 在同一事务内复核 workflow、required-write health、tracking、map ID/SHA、floor、capture ID 和 exact durable burst。统一 session admission gate 保证 finalization 前已登记的 writer 可以完成且 drain 必须等待它们，内部 writer 不再二次读取 finalization 状态误拒；prior-map queue sentinel 之后的普通 ARFrame/Recovery 路径被双重 generation/finalization gate 拦截，普通 Recovery 使用 `allowDuringFinalization=false`，只有终端 Recovery 使用 true。ESL audit 冻结 generation→tracking identity，只向既有 active session 追加；迟到或未知 generation 不创建空后继 session，也不污染新会话，scan-stop 自有 audit 才取得窄范围 finalization override。PC 三个 transform/binding early-error 分支稳定输出 unavailable audit。

当前验证证据：ESL capture focused Swift host、ESL finalization focused Swift host、ARFrame-only source contract、Stage-3 和 localized output store **104/104**、Python compile、Swift parse、`git diff --check` 均通过。Xcode simulator 构建已实际编译本轮 Swift 文件并 emit `RTABMapApp` module，但 native C++ 最终被 platform-scoped Eigen/PCL/OpenCV headers 缺失阻断（包括 `Eigen/Core`、`pcl/point_cloud.h`、`opencv2/highgui/highgui.hpp`）；完整 BUILD 仍为 FAILED，不能写 simulator clean compile-link PASS。完整长时 host workflow 方法已通过早期 compile/focused 阶段后进入 snapshot crash matrix，但本轮因时间手工中断，不能报告为 PASS。

最终独立复审结论为 `P0=0 / P1=0`。允许延期的 3 个 P2 是 Windows portable basename 尾随点/空格与设备名深化、Debug 非法状态转移 assertion 的 audit 顺序，以及 scan-stop 终端 audit/Recovery 稳定读取可能造成的主线程延迟；均已进入 [`docs/map-assisted-localization/ESL_CAPTURE_TODO.md`](docs/map-assisted-localization/ESL_CAPTURE_TODO.md)。真机 30 秒连续性、Vision p50/p95、CPU/memory/thermal、强弱光/反光/斜视/多价签、EAN13/Code128/QR、系统中断/低空间/thermal 和完整现场矩阵均为 NOT RUN。

该补充不改变 RC 资格结论：

```text
REJECTED / NO-GO / developer smoke only
J-04 = BLOCKER / NOT CLOSED
```

## 10. exact-HEAD P0 fixture 后续收口

V3 `7dd42beac00a2144712503662147e77fee679ffc` 推送后触发 exact-HEAD run [`31276419986`](https://github.com/mcjiansheng/MarketScanner/actions/runs/31276419986)。`Exact SHA and wave bindings` 已通过，但 `P0 production safety invariants` 在业务断言前失败：Map Studio 测试 helper 仍生成旧 v1 session manifest fixture，缺少共享 validator 现在强制的 `recovery_lifecycle_evidence_unbound_legacy`、`session_input_manifest_version`、processing/report Recovery binding 和 `source_database_name` cross-binding。生产 validator 行为正确；失败暴露的是 P0 fixture 与新合同不同步，不能通过放宽 validator 处理。

fixture 已在 I4 `ec1fe96fc676c03514e591c40226112cde30fe76` 修复，G4 `17871d839834487c777824c062980f3322521cdb` 已将 descriptor `implementation_sha` 绑定到 I4。修复后 exact CI 的四个 P0 合同本地 **4/4 PASS**，完整 Map Studio **106/106 PASS**，Python compile 与 `git diff --check` PASS。E4/V4 将绑定本段证据并触发新的 exact-HEAD run；在新 run 全部 required jobs 成功前，run `31276419986` 只能记录为失败证据，不能声明 exact-SHA CI PASS。
