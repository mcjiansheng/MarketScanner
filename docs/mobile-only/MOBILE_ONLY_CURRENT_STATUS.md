# Mobile-Only V1 当前状态

> 文档状态：**当前有效**。最后核对日期：2026-08-07（Release Candidate blocker 收口阶段）。

## 总体

当前 RC 分支 `mobile-only-v1-release-candidate-blocker-closeout`，基线 `mobile-only-v1r5-field-qualification-integrity-scale-closeout@81b6dbb216e843d363fd0088f673076add78013f`。post-CI portability implementation 为 `7841c28a37b80334cd14aef7cecaad829d29c8ef`，当前纯治理提交已将 descriptor 的 `implementation_sha` 绑定到该提交；`validation_sha` 仍为 `<EVIDENCE_DOCS_SHA>`。当前发布判断仍为 **REJECTED / NO-GO / developer smoke only**。

新增明确 blocker：J-04 absolute-prior component identity 尚未关闭。最终 DB graph 可以由 node `mapID` 和 links 推导 component，但现行 constraint 写侧没有 atomic bound node/map ID，manual v3 也没有 RTAB-Map map ID；因此 reader 不能事后伪造 same-component 证明。需先完成正式 evidence schema 迁移，再进行 component 资格测试。

## RC 最终治理和 Result 事务加固

- iOS 内嵌 `MarketScannerBuildIdentity` 已升级为 version 3；Python 生成/验证器和 Swift 读取器必须接受完全一致的 exact schema：`format`、`version`、`app_git_sha`、`native_core_sha256`，以及 governance descriptor 的 `wave`、`branch`、`base_branch`、`base_sha`、`implementation_sha`、`validation_sha`。任何缺失、未知或重复字段均 fail closed。
- `wave` / `branch` / `base_branch` 使用统一安全 ASCII 规则 `^[a-z0-9][a-z0-9._-]{0,127}$`；不再要求历史 `mobile-only-v1r4-` 前缀。`base_sha` 只允许 40 位小写十六进制。Python 生成/验证器在 implementation/validation 治理提交产生前只接受各自合同中唯一的明确占位符，但 Swift 运行时会将含任一占位符的 identity 判为 `isUsable == false`；只有两个字段均绑定为 40 位小写 SHA 才能进入 eligible session。当前 implementation 已绑定，但 descriptor 仍含 validation placeholder，不能描述为 final-bound 或 eligible。
- Result 从 `Results/` 下同父目录隐藏 staging 提交：先 fsync 全部文件/清单/receipt，再将整个 staging 冻结为根目录 `0555`、文件 `0444`，验证 exact set/modes 后才 exclusive rename。rename 后再次验证 modes/file set/receipt/manifest/每个 artifact 哈希。rename 前失败时 final path 必须不存在，隐藏 staging 恢复为可清理模式。
- task terminal durability 使用 intent → terminal `task.json` → intent cleanup 两阶段事务。取消、系统中断、资源暂停、`RESCAN_SESSION`、工作流失败具有独立 business outcome；原有四类 outcome 在 4 个 task writer 边界的 16 条故障路径全部返回 typed business+durability error。Route A 两条图路径仍失败或最终无 publish-eligible trajectory node 时，另写 durable read-only `rescan_session_outcome.json`，checkpoint 绑定 task-relative reference + SHA-256，task/UI 使用 `rescan_required` 与 `workflow.rescan_session_required`，不发布 PriceTags、DevicePositions、workbook 或普通 Result；artifact/checkpoint/terminal writer 的 rename 前后边界均有故障注入，重启在 native 重跑前恢复该 artifact。通用 failure terminalization 前先调和 committed immutable Result，再调和 committed immutable RESCAN；已提交业务事实不降级为 `.failed`。重启只清理 task identity、目标状态和 reason 精确一致的 intent，只推进已知非终态，并拒绝 completed、rescan_required、不同终态/理由或 task identity 冲突而不修改 task/intent。若 intent 本身无法建立，代码明确 fail closed，但无法在同一故障存储上承诺不存在任何掉电不确定性。
- `PersistentTaskCoordinator.updateState` 使用显式 `clearError` 区分“保留旧错误”和“清除错误”；`system_interrupted` / `resource_pause` 恢复后进入 snapshot/normal completion/committed-result recovery 时最终 `task.error == nil`。
- RESCAN schema 对 `publish_permitted` / `result_published` 使用 strict Bool，reason 与 graph disposition 交叉绑定，`RESOURCE_REQUIRED`、numeric Bool、EEXIST 不等价 winner、普通 Result 共存或 checkpoint/SHA 冲突均保留现场并 fail closed。
- 上述合同由独立 Qualification Swift host 在真实文件系统上执行，包含 pre-rename failure injection、权限观测、final-path absence、staging recovery/cleanup、terminal 4×4 fault matrix、四类 terminal-intent 冲突拒绝、restart reconciliation 与成功后重开 hash/receipt 验证。这些本地自动化证据不替代 exact-SHA CI、Apple clean build 或真机资格。
- exact-SHA run `31177319567` 在 macOS 14 host E2E 暴露 Foundation `moveItem` 无法发布已冻结 `0555` snapshot staging 的 EACCES。当前 snapshot generation 的 install、backup 和 recovery 已统一使用 `renameatx_np(..., RENAME_EXCL)`，保持 freeze-before-publication、同父目录原子 rename、destination no-replace 与 task-root fsync；完整 `IOSCoreContractTests` targeted rerun 2/2 PASS。
- 同一 run 的 Windows Qualification 暴露大小写不敏感 `Path` equality 会把 `Feature.swift` 与 `feature.swift` 提前视为相同。source membership exact gate 现改用 `os.fspath()` 原始字符串拼写，只有 exact 字符串不同后才进入 `casefold()` mismatch 诊断；Qualification 28/28 和 82-source repository audit 本地 PASS。

## 已交付（IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED）

- Track B1 手机导入：XLSX/CSV/JSON → `MarketScannerPriorMapSource` v1；canonical parity；导入安全（ZIP/公式/CSV/JSON 防御）；错误码冻结。
- Track B2 手机编译器：prior-map package 全产物；距离场 `data_sha256` 与 PC oracle 字节级一致；原子提交 + 生产自检。
- Track C 后处理：session 快照事务；Fast Path 相对 SE(2) 因子图；持久任务状态机。
- Track D 轨迹：时钟相关性记录；1 Hz 最终轨迹（本地时间 + UTC + offset；UNAVAILABLE 区间）。
- Track E 价签：节点/时间绑定、位置传播、burst 融合、货架关联、自动质量门。
- Track F 导出：真 Open XML XLSX 四表流式导出、公式注入/控制字符防护、原子导出。
- UI 接线：MapSourceDocumentPicker（security-scoped staging）、ResultShareController。
- 工程登记：project.pbxproj（31 个新文件四段）、CI swiftc -parse 列表、Swift host 编译列表。
- 修复 P7R6C 遗留缺陷：Swift host 默认模式 guard 从 `arguments.isEmpty` 修正为 `count <= 1`（C1/C2 此前未真正执行）。

## 本轮审查与回归证据

- pre-CI implementation diff 独立只读审查：**COMPLETED / BLOCKERS FOUND AND FIXED**。随后 run `31177319567` 又暴露 macOS snapshot publication 和 Windows path-case 两个 blocker；implementation `7841c28a37b80334cd14aef7cecaad829d29c8ef` 已完成代码路径审查、本地回归及 8-file staged manifest/cached diff 双重只读复核，结论为 **NO ACTIONABLE FINDINGS**；仍需新 exact-SHA 验证。J-04 仍是独立未关闭 blocker。
- PriorMap 166/166、Qualification 28/28、Map Studio 106/106、native 7,878 checks / 0 failures。
- 300,000 条 finalization：peak RSS 12,795,904 bytes；1,728,000 条 trace transition storm：保留 172,801 条，peak RSS 58,769,408 bytes。
- 200,000 burst frames + 200,000 observations 全链路：243,952,646 input/temporary bytes，200,000 accepted observations，融合 1 个 accepted physical tag，884.922 s wall，peak RSS 670,662,656 bytes（约 639.6 MiB，低于 768 MiB host 门）。`StrictJSONLStreamReader` 通过每行 autorelease pool 消除长时 Foundation autorelease 累积，并保留完整 strict validator。
- Map quarantine 真实子进程在 payload rename、diagnostic placement/freeze、publish rename/parent sync 三个窗口分别 `_exit`，新进程从 list/map/rebuild 执行 startup reconciliation；source+published、destination symlink、mode/hash 篡改和 unknown transaction 均 fail closed。

以上是未优化 macOS host developer evidence，不是 target-device scale、thermal、battery 或 Device Lab PASS。

## 未关闭（已有失败 run，禁止写 PASS）

- exact-SHA CI 已运行但未通过：run `31174285439` = FAIL；run `31177319567` = FAIL，后者 6/8 jobs 成功。当前两项 portability 修复尚无新的 exact-SHA required-gate PASS。
- Xcode clean build 与 unsigned arm64 build 在 run `31177319567` 中因前置 macOS host E2E 失败而 skipped，仍未形成 Apple compile-link 证据。
- Replay / 三格式 E2E（Python 驱动 + host 模式化套件已完成基础设施）。
- 真机短路线 / Sam 路线 / Excel-Numbers-WPS 打开验证。
- 新 implementation SHA 已绑定；仍需新 exact-SHA evidence/release review，以及后续 production-drift-free validation 证据和 SHA 绑定。

True sensor Deep（重新解码传感器、重建缺失视觉证据）不属于当前 Mobile V1，也不是“尚未接线”的待执行路线；状态机历史 `deep_*` 名称只表示 Route A 允许的一次 Full existing-graph optimization。

## 决策

本阶段结论：**PRE-CI IMPLEMENTATION HOST-TESTED / POST-CI LOCAL REPAIR TESTED / EXACT-SHA CI EXECUTED AND FAILED**；
NOT APPLE BUILD VERIFIED / NOT DEVICE SMOKE PASS / NOT SAM FIELD PASS / NOT PRODUCTION QUALIFIED。

## V1R5 Apple build gate 收口

RC-B02/RC-B03 的 shipping source membership 与 CI parse 问题已进入代码收口：production Swift 清单从 Xcode target 自动导出，不再维护易漂移的 shell 长列表；新增生产文件按 fileRef/buildFile/group/Sources phase 四段登记。Native dependency 构建改为 `Libraries/iphoneos` 与 `Libraries/iphonesimulator` 两套完全独立的 prefix/cache/manifest，Xcode 通过 `$(PLATFORM_NAME)` 选择 headers、archives 和 framework；manifest 还会核验关键 archive 的 Mach-O platform 2/7，拒绝只看同为 arm64 的错误复用。

共享 SwiftPM `Package.resolved` 固定 Zip 2.1.2 的完整 revision；CI 对 cold resolve、project metadata 和两个 clean build 后的 lock 做字节稳定性检查，任何 Xcode 自动改写都会 fail closed。本机 Xcode `-showBuildSettings` 已分别确认 simulator/device 的完整 header、framework 和静态库输入展开到 `Libraries/iphonesimulator` / `Libraries/iphoneos`，该证据只证明选路，不等同于完成链接。

当前本机只存在历史 device-only `Libraries/` 产物，因此 simulator native cold build 和最终 Debug simulator `clean build` 仍不能由本地历史产物证明，不能写成 PASS。CI 已配置在两个独立 cache miss 时分别执行完整 cold dependency build，然后进行真实 simulator/device compile + link；但 run `31177319567` 在这些步骤之前因 macOS host E2E 失败而终止，所有 Apple dependency/build/identity 步骤均 skipped。其最终状态必须以修复后的新 exact-final-SHA Actions run 为准。

## V1R1 收口（见 MOBILE_ONLY_V1R1_PRODUCT_INTEGRATION.md）

分支 `mobile-only-v1r1-product-integration-closeout` 新增：
真实 App UI 与总协调器（Gate A）、严格导入/canonical v2（Gate B）、
in-process RTAB-Map 图读取 bridge（Gate E）、流式原子 XLSX（Gate J）、
Replay E2E、CI 分支匹配。当前状态与未执行项见 V1R1 文档。

## V1R2 收口（见 MOBILE_ONLY_V1R2_PRODUCT_INTEGRATION.md）

分支 `mobile-only-v1r2-production-pipeline-and-device-readiness-closeout`
（基线 `a9f8c46`）关闭 V1R1 审查 REJECTED 的代码级缺口：
Gate 0 编译/导入死锁修复、Gate A 正式工作流（后台执行/完整
持久化/token 观察者/转换表）、Gate D 真实扫描接线（预览选点 +
`MobileOnlyScanStarting` 真实启动）、共享 native core
`core/MarketScannerFactorGraph`（iOS 与 PC oracle 同源，真实 DB 图
→ 自适应骨架 → g2o robust Fast/一次受控 Deep → §11.5 质量门 →
完整轨迹重建）、Gate L 资源治理。当前状态与未执行项见 V1R2 文档。

## V1R3 收口（见 MOBILE_ONLY_V1R3_EVIDENCE_NATIVE_DEVICE_QUALIFICATION.md）

分支 `mobile-only-v1r3-evidence-integrity-native-correctness-and-device-qualification-closeout`
（基线 `9de2908`）关闭 V1R2 审查 REJECTED 的证据完整性与 native 正确性
缺口：扫描启动事务化 + receipt、yaw 合同与可通行性门、prior-map 全局
约束（LOCAL_FRAME_ONLY fail-closed）、P7R6D 级流式 immutable snapshot、
Swift/C ABI 指针安全 + outcome 校验、严格 BLOB/损坏 fail-closed、
逆信息/SPD/聚合协方差数学修复（可执行测试验证）、可中断优化、
质量门真实性、轨迹 component/uncertainty、result package 原子事务、
时钟侧车记录。当前状态与未执行项见 V1R3 文档。
