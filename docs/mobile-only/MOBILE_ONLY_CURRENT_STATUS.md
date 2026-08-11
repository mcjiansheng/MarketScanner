# Mobile-Only V1 当前状态

> 文档状态：**当前有效**。最后核对日期：2026-08-11（起点朝向合同修复阶段）。

## 总体

当前核心基线已推进到 `core-mobile-v1@9a93fbd0ee52944eae5aebedf59ec6a08dedc934`。真机历史处理事务错误的工作分支为 `fix/mobile-snapshot-transaction-stable-read`，不使用 `codex/` 前缀。此前被审增量 `fix/mobile-import-prewarm-esl-deferred-tag@673d8d3a714f8fb6be18acc44ca4dd32589f3e81`、修复分支 `fix/mobile-import-esl-review-blockers` 及其独立复审状态保留为历史证据；它们已合入上述核心基线，但不能把局部结论扩展为整体发布通过。I10 final SHA `8f0e730d92773eea2ab58f56742d901ac02eead4` 的 exact-SHA run `31307753672` 为 7/8：P0、SHA/wave、ABI、Ubuntu/Windows native、Python/API/Web 与完整 macOS host 合同均 PASS，200k tag-evidence RSS 为 `794,099,712 < 805,306,368` bytes；唯一失败是 cold-cache iphoneos RTAB-Map 配置没有找到已生成在 `rtabmap/prebuild/bin/` 的宿主 `rtabmap-res_tool`，因此 simulator/device clean link 被跳过。I11 `37e6ed8c4afa00202693cd56919aea78fd4c7af5` 已在交叉编译前验证该宿主工具并通过 `RTABMAP_RES_TOOL` 显式绑定，G11 `7eef33e` 已绑定 implementation SHA；新的 exact-SHA 8/8 前不冻结，当前发布判断仍为 **REJECTED / NO-GO / developer smoke only**。

## 2026-08-11 起点朝向与实际扫描方向修复

- 真机截图确认配置页“东 0°”箭头向右，但扫描 HUD 初始三角向上。根因是 Mobile-Only V1R3 已冻结 `yaw 0 = map +X`，而 Stage One ARKit 水平位姿和两个扫描/重选箭头仍保留旧的 `yaw 0 = map +Y`；因此既有 90° 显示偏移，也会把首帧后的前进轨迹投影到错误地图方向。
- 当前工作分支为 `fix/mobile-start-heading-alignment`，基于包含历史处理稳定读取修复的 `546866a9081938a4c3ba7fa3be8a9d7abc27b383`，不使用 `codex/` 前缀。ARKit camera forward 现在以 map-space `(forwardX, -forwardZ)` 计算标准 `atan2(y, x)`；深度 matcher local frame 同步改为 `+X` 前向。
- 配置 marker、人工位姿选择器和实时 HUD 共享 `PriorMapHeadingUI`：未旋转 artwork 向右，UIKit 仅执行一次 `-yaw`。快速四方向/首帧/前进一步/源码合同 13/13 PASS，移动 UX/方向/sidecar 聚焦组 54/54 PASS，修改 Swift parse 与 `git diff --check` PASS。
- 完整 Swift host 1/1 PASS（1398.238 s）：300,000 条 finalization 峰值 RSS 13,320,192 bytes、1,728,000 条 trace 峰值 59,228,160 bytes、400,000 条 tag evidence 峰值 533,495,808 bytes；unsigned generic iPhoneOS Debug clean build 已完成全量编译/链接。提交后 Release identity build 与真机东/北/西/南复测仍待执行；在真机复测前不得声明 real-device PASS 或整体 GO。

## 2026-08-10 真机历史处理 committed-file 稳定读取修复

- 在 `core-mobile-v1@9a93fbd0ee52944eae5aebedf59ec6a08dedc934` 真机处理历史扫描时复现 `稳定复制失败：committed transaction file changed before open`。该错误发生在已提交 snapshot/task/intent 权威文件的稳定读取阶段，早于 SQLite 图读取、Fast/Full 优化和扫描质量门；因此它不是“空白场景置信度不足”本身导致。过于简单的扫描仍可能在事务成功后得到正常的 `RESCAN_SESSION`，但不应在这里失败。
- 根因是提交后的 `0444` 单链接文件经原子 rename 发布后，iOS/APFS 的 pathname `fstatat` 与随后 descriptor `fstat` 可能短暂观察到同一 dev/inode/mode/link/size/mtime、但 descriptor 侧 `ctime` 已向前稳定。旧实现把任何 `ctime` 差异都视为替换或写入，误报 `changed before open`。
- 修复只接受这一窄边界：dev/inode/mode/link/size/mtime 必须完全相同，`ctime` 只能向前；随后立即重新 `fstatat`，pathname 必须完整等于已打开 descriptor。读取后仍严格复核 descriptor/path 的 dev/inode/mode/link/size/mtime/ctime 和实际字节数。inode 替换、普通同尺寸写入造成的 mtime 变化、hardlink、symlink、可写 authority、打开后的 `ctime` 变化和读中 pathname 替换均继续 fail closed。
- workflow 现在把底层 `SessionSnapshotTransaction.SessionError` 保留为 typed `workflow.snapshot_failed`；处理页直接显示该本地化错误，不再生成 `处理失败：处理失败：…`。错误诊断增加内部 basename 与 `inode/mtime/ctime` 等变化字段，便于真机继续定位。
- 当前证据：mobile UX/source + sidecar health **41/41 PASS**，Qualification **30/30 PASS**，修改 Swift parse 与 `git diff --check` PASS；完整 Swift host **1/1 PASS（1270.619 s）**，其中 300,000 条 finalization 峰值 RSS 13,221,888 bytes、1,728,000 条 trace 峰值 59,179,008 bytes、400,000 条 tag evidence 峰值 553,189,376 bytes，新增 `--snapshot-stable-read-focused` 已实际编译运行。unsigned generic iphoneos Debug 全量编译/链接 `BUILD SUCCEEDED` 且正式 build identity 按合同省略；本修复提交的 unsigned generic iphoneos Release 全量编译/链接 `BUILD SUCCEEDED`，日志包含 `build identity verified`，包内 `app_git_sha` 已核对为构建时 exact HEAD。修复版真机重试仍待完成；在完成前不得写“真机已修复通过”或整体 GO。

## 2026-08-10 独立复审 P1 修复状态

- Vision 条码 observation 统一通过 platform-neutral normalizer 转换成 oriented full-image normalized coordinates：revision 1 原样验证，revision 2+ 使用产生 observation 的实际 request ROI 做仿射还原；主 ROI 和 expanded fallback 不再共享错误坐标解释。非法 revision、非有限、负/空尺寸和实质越界证据 fail closed，仅允许 `1e-6` 的边界浮点修正。
- 还原后的 full-image 框才进入 operator ROI 选择、去重、`nativeSensorBounds`、深度采样和射线几何；expanded ROI 只扩大检测窗口，不扩大业务可选范围。字段策略的 ROI 交集门已从未经真机论证的 `0.55` 恢复为 `0.80`。
- 历史处理 `beginProcessing` 返回 typed `Result<String, MobileOnlyWorkflowError>`；duplicate、非法状态和 task 目录创建失败均同步返回且不重复发送 observer failure。UI 在同一主线程调用栈清除 `processing` 并恢复 Close、interactive dismissal 和 table；accepted operation 的异步完成/失败/取消仍通过 observer exactly once 结束 UI busy。
- `.mapReady -> .snapshotting` 状态表没有放宽；`.finalizingScan` 的内部生命周期边仍保留，但单独的历史处理准入策略拒绝活动 finalization。快速重复调用使用准入 owner，拒绝第二次调用时不会清除第一条已接受任务的 busy 所有权。
- 当前修复源码验证：mobile UX/source **22/22 PASS**；完整 PriorMap discover **247/247 PASS（1262.239 s）**，400,000 条 tag evidence 峰值 RSS `574,849,024` bytes；Qualification **30/30 PASS**；Map Studio **109/109 PASS**；修改 Swift 文件 parse 与 `git diff --check` PASS；unsigned generic iphoneos Debug 全量编译/链接 `BUILD SUCCEEDED`，并按合同明确省略正式 build identity；修复代码提交 `8b8cbf4d9c8325986cde43c95391141473f2d336` 的 unsigned generic iphoneos Release 全量编译/链接 `BUILD SUCCEEDED`，日志包含 `build identity verified`，包内 `app_git_sha` 与该提交精确一致。
- 上述内容是修复实现状态，不是独立复审 PASS。签名真机 iOS 15/16/17+ ROI 矩阵、已知像素/depth center 采集、`.mapReady` 手工复现、LiDAR/thermal/现场资格和独立复审仍为 NOT RUN。

## 2026-08-10 地图导入预热、近距离 ESL 与低置信度保留

- 地图库首屏绘制后在主线程空闲轮次预加载一次导入 action sheet、导入页、XLSX `UTType` 和 document-picker view；不改变 workflow、不访问 provider 文件，真实暂存/编译继续在后台。
- ARKit autofocus 显式启用；Vision 最多 10 Hz，主 ROI 无结果时只在同一 worker/ARFrame 上追加一次有界扩展 ROI，capture 窗口由 2 秒延长到 4 秒并扩充成熟条码类型。固定两条 worker、one-in-flight 和 1 秒 request deadline 不变。
- live exact-node snapshot 短暂缺失只延期当前 evidence slot；只允许继续使用 live snapshot 或仍满足 1 秒合同的 frozen exact-ID snapshot，不恢复 nearest-time fallback。真实 sidecar、identity 与 burst 失败继续 sticky fail-closed。
- 最终价签质量为 `ACCEPTED / LOW_CONFIDENCE / RESCAN_REQUIRED`。完整 burst、exact node/raw pose 和至少 3 帧可重算位置仍完整但定位/测量/关联不足时保留 `LOW_CONFIDENCE`，按最终 node pose 重投影且不自动生成 RescanTask；同一 burst 的多货架歧义合并为一条低置信度结果。缺失权威证据仍要求重扫，低置信度绝不计为 ACCEPTED。
- 当前源码 focused UX/source **21/21 PASS**、全部修改 Swift `swiftc -parse` PASS、generated evidence contracts 11 文件无漂移、中文字符串与 Python 语法 PASS、unsigned generic iphoneos Debug 全量编译/链接 PASS。完整 Swift host 长方法 **1/1 PASS（1266.338 s）**：300,000 条 finalization 峰值 RSS 14,139,392 bytes；1,728,000 条 trace 保留 172,801 条、峰值 59,129,856 bytes；400,000 条 tag evidence 接受 200,000 条、峰值 589,463,552 bytes。上述仍不是签名真机、LiDAR、近距离聚焦、恢复期定位、Files/FileProvider 首开、热状态或现场 PASS。

## 2026-08-10 历史扫描处理、原始导出与 ESL 布局修复

- iOS snapshot DB 复核不再把 `/dev/fd/<descriptor>` 当作唯一 SQLite 入口。保留完整 descriptor/path stat identity、hardlink/WAL/journal/SHA/SQLite/graph 安全门；仅当 SQLite 明确无法只读打开 `/dev/fd` 时，从已绑定 descriptor 流式复制到 App 私有临时目录校验，前后复核源身份并在所有路径清理副本。进程内只缓存 exact dev/inode/mode/nlink/size/nanosecond mtime/ctime 已通过语义校验的不可变文件。
- 历史扫描列表每行新增独立原始导出按钮，不要求后处理成功。导出严格要求 finalized continuous-streaming、单一 exact `segment_0001`、tracking identity、无 checkpoint、安全数据库；完整复制后执行三方 SHA manifest 复核并写两份 receipt，保留手机源且不覆盖已有目标。
- ESL 状态/条码文字分别绑定扫码框精确上/下边缘外 18 pt，边框、布局和 Vision ROI 共用同一 normalized rect，修复文字压线。
- 构建后黑色残缺界面已确认为 Xcode 本地文件断点暂停 `ViewController.updateState(state:)`；断点已删除。这项修复不产生产品源码差异，真机 smoke 需确认 Xcode 不再在该位置暂停。
- 新增源码合同当前 **19/19 PASS**，UX + sidecar 快速组 **37/37 PASS**，修改 Swift 文件 `swiftc -parse` PASS。包含私有 DB copy 清理与连续两次历史导出的完整 Swift host 长方法 **1/1 PASS（1484.429 s）**；400,000 条 tag evidence 峰值 RSS 520,077,312 bytes。最终 unsigned generic iPhoneOS Debug 与 tracked-clean exact-HEAD Release 全量编译/链接 PASS；Debug App 不含正式 build identity，Release bundle `app_git_sha` 与构建提交精确一致。真机 Files provider/大型真实 DB 仍按测试计划继续收口，无签名 build 不能替代现场资格。

## 2026-08-10 现场扫描 blocker 修复

- 首帧 native node timebase 未就绪不再写入 `.nan`；定位 frame 会等待有限 offset，并以限频 audit 记录等待。严格 JSONL writer 和 sticky fail-closed 规则保持不变，因此不会再由暂时未就绪同时毒化 trace/constraint/state。
- coordinator 现在绑定真实扫描最终化生命周期；结束失败可恢复同一扫描，terminal close 回到 idle 并清除 receipt/session。已有扫描/结束事务存在时，新的 setup 不再继续 commit。
- “扫描价签条码”继续使用全屏 camera-only ARFrame overlay；入口失败显示明确 alert，required evidence 失败会指示结束扫描并保留 recovery package，成功 overlay 置顶且无障碍模态。
- 手机预览移除重复 Y 翻转，地图画面、点击/微调位置和 canonical 障碍物几何保持一致；新的 MapCase02 Swift package SHA 为 `c6b6b2c00690998cfa9517374b9385f857cb3ee0efcbe3663f63ee76fee87959`，canonical 与 PC golden 不变。

## 2026-08-10 扫描 UX 与启动事务阻断级收口

- 首页“新建扫描”和菜单“开始门店扫描”现在先进入轻量地图选择页；用户可选择已注册地图或导入新地图，明确选择后才完整校验并加载该包。配置页只接收一张 immutable `selectedMap`，不再包含会导致每次切换都重复等待的地图 picker。手机编译地图与正式 PC v2 package 仍使用同一个地图库、配置页、coordinator 和真实扫描 host；自由扫描/原始录制降级到“实验与兼容工具”。
- 地图编译显示实际阶段和完整结果；文件尚未选择时隐藏 0%、空进度条和计时，provider 返回文件并进入安全暂存后才显示。配置页支持 1×—8× zoom、pan、双击复位、方向键 0.1/0.5/1.0 m 微调，以及四方向和 ±15°朝向，不再使用 yaw slider。root/push 导航分别使用 Close 与系统 Back；返回会取消启动。
- 主线程卡顿根因已关闭：地图库普通列表只读轻量 registry，完整 package I/O、PNG/JSON、localizer、会话和 native database preparation 在后台串行执行。主线程只处理短 UIKit/ARSession 事务。
- 首次相机权限在 workflow commit 前完成；旧 tmp DB recovery continuation 不参与 canonical Mobile-Only；host/receipt/context/cancel 任一步失败都会强 rollback。start receipt 使用 `O_EXCL|O_NOFOLLOW`、完整写循环、file/dir fsync 和 SHA；workflow context v3 绑定 session/segment/database/map/store/receipt/checkpoint。
- 地图库安全复审关闭 registry/manifest 身份不完整、rebuild 无上限预读和 pathname chmod 跟随符号链接三个 P1。完整 package load 绑定 name/floor/element/canonical/map/package；rebuild 使用同一有界 snapshot；freeze 使用 root FD、`fstatat/openat(O_NOFOLLOW)` 和 `fchmod(fd)`。
- 当前源码的 UX/geometry/build identity 自动测试 32/32 PASS；现场阻断聚焦（UX、sidecar health、Y 轴、文档治理）46/46 PASS；`IOSCoreContractTests.test_swift_workflow_state_and_se2_projection` 1/1 PASS（1212.429 s，含 300k finalization、1,728,000 trace、400k tag evidence 和 MapCase02/地图库链路）；较广 PriorMap 197/197、Map Studio 109/109、ESL ARFrame-only 1/1 PASS。当前修改的 unsigned generic iPhoneOS Debug 全量编译/链接 PASS，并明确验证 Debug 身份仍被移除。共享 `RTABMapApp` 默认 Release Run 的严格身份构建必须在提交后、tracked tree 干净状态执行并验证 bundle SHA；`RTABMapApp-QualifiedDevice` 继续保持等价 Release 合同。真机安装和实际点击开始扫描仍待执行，不能用无签名 build 代替。

新增明确 blocker：J-04 absolute-prior component identity 尚未关闭。最终 DB graph 可以由 node `mapID` 和 links 推导 component，但现行 constraint 写侧没有 atomic bound node/map ID，manual v3 也没有 RTAB-Map map ID；因此 reader 不能事后伪造 same-component 证明。需先完成正式 evidence schema 迁移，再进行 component 资格测试。

## RC 最终治理和 Result 事务加固

- iOS 内嵌 `MarketScannerBuildIdentity` 已升级为 version 3；Python 生成/验证器和 Swift 读取器必须接受完全一致的 exact schema：`format`、`version`、`app_git_sha`、`native_core_sha256`，以及 governance descriptor 的 `wave`、`branch`、`base_branch`、`base_sha`、`implementation_sha`、`validation_sha`。任何缺失、未知或重复字段均 fail closed。
- `wave` / `branch` / `base_branch` 使用统一安全 ASCII 规则；implementation与evidence分别通过纯治理后继提交绑定，当前值以descriptor为准。Swift运行时只有implementation/validation均为40位小写SHA时才允许`isUsable`；即使完成绑定，也必须另有exact-SHA CI和资格证据。
- Result 从 `Results/` 下同父目录隐藏 staging 提交：先 fsync 全部文件/清单/receipt，把 payload 文件冻结为 `0444`，root 保持 `0755`。durable publish intent 绑定 task/result/manifest 与 directory dev/inode；root-scoped cross-process advisory lock 覆盖 cleanup、commit、recovery、list 和 read，阻止这些受锁操作清理或误读 active publisher 的 intent。exclusive rename 后，通过仍打开的 inode-bound FD 执行 `0755→0555`、directory fsync、destination path/dev/inode 复核，再验证 exact set、receipt、manifest 和每个 artifact 哈希。rename 或 final pathname 出现均不是业务提交点；intent 清理前只允许按 exact identity 恢复。该 lock/lease 不覆盖 active staging 的长期写入阶段；生产依赖 `MobileProcessingPipeline` 单一主 App 串行，`cleanupStaging` 仅在 task pipeline 启动且 staging 创建前调用，同一 task 禁止跨进程并发构建。
- Snapshot 的 task-root 与 `input_snapshot.lock`、Result 的 Results root 与 `.result-library.lock`、Map 的 Maps root 与 `.map-library.lock` 均绑定 descriptor/path dev/inode，并在公开成功返回前最终复核；pathname replacement不会继续返回成功。
- Result quarantine 使用 hidden pending + source move前 durable canonical v2 diagnostic，绑定 source/payload/wrapper dev/inode，并在启动时恢复 external/embedded diagnostic、pending/final与removal tombstone。未知/冲突状态保留并使listing整体fail closed；历史 v1 immutable wrapper保持兼容，包括顶层symlink payload，嵌套symlink/special/hardlink仍拒绝。
- publication helper 与目录枚举使用 `O_RDONLY|O_DIRECTORY` 打开 parent/root；因此 app owner 对相关 parent 的前提权限是 read + write + search，而不只是 write + search。当前运行平台还必须提供 no-follow directory FD、directory `fsync`、`lockf` 和同卷同父目录 `renameatx_np(..., RENAME_EXCL)`；未满足这些能力的文件系统不在当前资格声明内。
- task terminal durability 使用 intent → terminal `task.json` → intent cleanup 两阶段事务。取消、系统中断、资源暂停、`RESCAN_SESSION`、工作流失败具有独立 business outcome；原有四类 outcome 在 4 个 task writer 边界的 16 条故障路径全部返回 typed business+durability error。Route A 两条图路径仍失败或最终无 publish-eligible trajectory node 时，另写 durable read-only `rescan_session_outcome.json`，checkpoint 绑定 task-relative reference + SHA-256，task/UI 使用 `rescan_required` 与 `workflow.rescan_session_required`，不发布 PriceTags、DevicePositions、workbook 或普通 Result；artifact/checkpoint/terminal writer 的 rename 前后边界均有故障注入，重启在 native 重跑前恢复该 artifact。通用 failure terminalization 前先调和 committed immutable Result，再调和 committed immutable RESCAN；已提交业务事实不降级为 `.failed`。重启只清理 task identity、目标状态和 reason 精确一致的 intent，只推进已知非终态，并拒绝 completed、rescan_required、不同终态/理由或 task identity 冲突而不修改 task/intent。若 intent 本身无法建立，代码明确 fail closed，但无法在同一故障存储上承诺不存在任何掉电不确定性。
- `PersistentTaskCoordinator.updateState` 使用显式 `clearError` 区分“保留旧错误”和“清除错误”；`system_interrupted` / `resource_pause` 恢复后进入 snapshot/normal completion/committed-result recovery 时最终 `task.error == nil`。
- RESCAN schema 对 `publish_permitted` / `result_published` 使用 strict Bool，reason 与 graph disposition 交叉绑定，`RESOURCE_REQUIRED`、numeric Bool、EEXIST 不等价 winner、普通 Result 共存或 checkpoint/SHA 冲突均保留现场并 fail closed。
- 上述合同由独立 Qualification Swift host 在真实文件系统上执行，包含 pre-rename failure injection、权限观测、final-path absence、staging recovery/cleanup、terminal 4×4 fault matrix、四类 terminal-intent 冲突拒绝、restart reconciliation 与成功后重开 hash/receipt 验证。这些本地自动化证据不替代 exact-SHA CI、Apple clean build 或真机资格。
- exact-SHA run `31177319567` 首先暴露 frozen snapshot publication EACCES；后续事务、RSS 与 host fixture 阻断均已逐项收口。最新 `31307753672@8f0e730d…` 已通过完整 macOS host 与 RSS 门，但在 iphoneos cold dependency 配置缺失宿主 resource tool 绑定处失败；I11 已显式绑定，仍需新的 exact-SHA PASS。
- Windows exact-case membership已使用原始路径字符串，当前 repository audit确认85个 shipping Swift source。当前 Qualification全量28/28 PASS。

## 已交付（IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED）

- Track B1 手机导入：XLSX/CSV/JSON → `MarketScannerPriorMapSource` v1；canonical parity；导入安全（ZIP/公式/CSV/JSON 防御）；错误码冻结。
- Track B2 手机编译器：prior-map package 全产物；距离场 `data_sha256` 与 PC oracle 字节级一致；原子提交 + 生产自检。
- Track C 后处理：session 快照事务；Fast Path 相对 SE(2) 因子图；持久任务状态机。
- Track D 轨迹：时钟相关性记录；1 Hz 最终轨迹（本地时间 + UTC + offset；UNAVAILABLE 区间）。
- Track E 价签：节点/时间绑定、位置传播、burst 融合、货架关联、`ACCEPTED / LOW_CONFIDENCE / RESCAN_REQUIRED` 自动质量门。
- Track F 导出：真 Open XML XLSX 四表流式导出、公式注入/控制字符防护、原子导出。
- UI 接线：MapSourceDocumentPicker（security-scoped staging）、ResultShareController。
- 工程登记：project.pbxproj（31 个新文件四段）、CI swiftc -parse 列表、Swift host 编译列表。
- 修复 P7R6C 遗留缺陷：Swift host 默认模式 guard 从 `arguments.isEmpty` 修正为 `count <= 1`（C1/C2 此前未真正执行）。

## ESL Barcode Capture / Shelf Confirmation 阻断级收口

- iOS Capture Mode 只叠加 camera-only `MTKView` 预览、Vision 和 durable evidence；直接使用持续到达的 `ARFrame.capturedImage`，没有第二个 `AVCaptureSession`，没有暂停 ARSession、RTAB-Map、连续 SQLite、Clock、Pose、node creation 或 prior-map localization。
- 当前 Vision 使用固定 scan box 的真实 ROI与同帧一次有界扩展 ROI，最多 10 Hz、one-in-flight；每个请求有独立 1 秒 ARFrame deadline，预览最多 24 Hz。固定两条 worker lane；超时 lane 被 best-effort cancel/quarantine，fresh request 可在备用 lane 实际开始，两条 lane 都挂起时仅结束 ESL UX，不创建第三 worker，原扫描继续。candidate 需连续 2 帧锁定，同一 capture 目标 4 个、最低 3 个独立帧，最大 4 秒；下方其余 I6 条目为前序证据合同，当前参数以上述新增小节为准。
- confirmation gate 只统计逐帧 `algorithmCandidateReliable=true` 且 `needsReview=false`、共同指向同一 `shelfSegmentId + side` 的独立证据；弱帧只保留 raw audit，不能凑足 3-frame reliable quorum。替代候选按 segment + side 精确绑定。
- `tag_observations.jsonl` 与 `tag_observation_bursts.jsonl` 在最终化和 PC 上逐项核对 `observation_id / burst_id / frame_id / payload / symbology`；localized tag v2 的 frame set 必须精确等于一个 verified complete burst。capture cache 使用完成顺序 FIFO，超过 512 个 burst 时不会随机淘汰刚完成、正在确认的 capture。
- iOS finalization 还要求 localized v2 tag 的 payload/symbology 与该 verified burst 完全一致；burst sequence 必须为正且严格递增，但不要求从 1 开始或连续。duplicate/decreasing sequence 使用稳定 blocker fail closed。
- additive v2 将 algorithm evidence 与 `USER_CONFIRMED` / `USER_OVERRIDDEN` 用户证据分开；用户确认不能覆盖算法事实，也不修改 SLAM、trajectory、node pose 或 localization constraint。
- PC session input manifest v3 在 v2 Recovery binding 之上绑定 burst sidecar；只有 localized tag v2 使用 verified complete burst `bound_node_id` 作为唯一节点权威，同一会话历史 tag v1 保持 legacy explicit-node/timestamp 路径。可靠 optimized association 与现场选择一致时为 `NO_CONFLICT` / approved；冲突为 `USER_CONFIRMATION_CONFLICT`，离线证据不可用为 `OFFLINE_ASSOCIATION_UNAVAILABLE`，后两者强制 review/rescan。
- confirmation 提交由 coordinator 锁内 immutable map/session authority 与单次 claim 线性化；session writer 在同一 localization/capture 事务内复核 workflow、required-write health、tracking、map ID/SHA、floor、capture ID 和 verified burst。统一 session admission gate 在 finalization 前登记 transaction/reservation，finalization 关闭新 admission 后等待已登记 writer，inner writer 不再二次误拒。prior-map sentinel 后普通 ARFrame/Recovery 由入队/执行双重 gate 拦截，ordinary/terminal Recovery 的 `allowDuringFinalization` 已分离。capture generation 冻结 exact tracking identity，active-only audit 不创建 session；迟到旧 generation 不污染新 scan，scan-stop 自有 audit 仅使用窄范围 override。
- PC pose/raw-position early-error 统一生成 unavailable audit。共享 manifest validator 强制 strict integer version、v1/v2/v3 Recovery binding、case-insensitive filename uniqueness、source database 安全 basename与 source-manifest cross-binding；manifest/snapshot/verified-copy 全链拒绝 source DB hardlink、非空 WAL/journal。
- I6 frozen-worktree 验证已覆盖 ESL capture/finalization、ARFrame-only source contract **1/1**、Stage-3 **82/82**、localized output store **28/28**、session snapshot **10/10**，合计 **120/120 PASS**，以及 Python compile、Swift parse 和 diff check。I5 长时 Swift host workflow 的历史证据为 **1/1（943.159 s）PASS**，I6 未重新完整运行。Xcode simulator 本机已生成当前 App Swift module，但 native C++ 在 `Eigen/Core` 缺失处失败；这不是本机 clean build PASS。
- MapCase02、坐标转换和 store/map/file-specific scale/offset/rotation 未在 ESL 增量中修改；后续修复按独立正式规范执行。真机 30 秒连续性、Vision p50/p95、CPU/memory/thermal、光照/反光/斜视/多价签和现场矩阵见 [`../map-assisted-localization/ESL_CAPTURE_TODO.md`](../map-assisted-localization/ESL_CAPTURE_TODO.md)，均为 NOT RUN。

## 本轮审查与回归证据

### MapCase02 标准工作簿冻结候选

- `MAPCASE02 / STANDARD SUPERMARKET XLSX FORMAT PASS`：正式 `Basic Info + Element Info`、Shelf audit-only、top-left anchor、production roles、canonical v3/package v2 和派生工件 exact binding 已在 Swift/PC 同步关闭阻断项。
- 冻结统计为源 1838、active 1630、shelf 1301、fixed 329、road 0、presentation 208、active 越界 0；canonical ID `piaseczno-5ddfac7dc439`、canonical `5ddfac7dc439afc45abdcf800b799c05d53704895b620d161ef08a442c55b2db`、Swift package `c6b6b2c00690998cfa9517374b9385f857cb3ee0efcbe3663f63ee76fee87959`、PC package `41332d093e652ec2de94f0f86b8f15107cd6f67f3b2e5ddec1c0685ab4d7d3be`、PC preview `d0c02be63dff3ab002dcf931ce7d0c5149152b78bea139fb1b0a2d86be196a18`，均由 executable exact assertion 绑定。真机暴露的大写 ID 安装断层和手机预览重复 Y 翻转均已关闭；Swift validation report 现绑定 road graph node/edge 计数并通过 Python production validator；Swift/Python 对 manifest/report count、warnings/malformed rows 执行相同 strict integer/array 检查；四张真实 XLSX 均通过 Swift 地图库完整 smoke；旧 uppercase v2 在 production iOS/PC 入口默认拒绝，只保留显式 diagnostic-only 只读检查。
- 独立 MapCase02 复审发现的 P1 已全部修复，最终为 `P0=0 / P1=0`；P2 与延期资格项见 [`../map-assisted-localization/MAPCASE02_TODO.md`](../map-assisted-localization/MAPCASE02_TODO.md)。该局部 PASS 不关闭 J-04、Apple、Device Lab、现场或 exact-SHA 门。

- 最终关键生产增量完成两轮只读审查，发现的 Map `.`/`..`、Result quarantine crash orphan、Snapshot process-lock binding和历史v1顶层symlink兼容均已修复；该事务增量最终 `P0=0 / P1=0 / 新的可修P2=0`。I6 ESL 最终独立复审关闭 callback/evidence timeout 误取消 fresh request 和 manifest v3 误强制历史 tag v1 使用 burst authority两个 P1，复审为 `P0=0 / P1=0`；scanner 级可注入 hung-worker 集成测试及其他低影响项已登记 [`../map-assisted-localization/ESL_CAPTURE_TODO.md`](../map-assisted-localization/ESL_CAPTURE_TODO.md)。这不是 release review PASS，J-04 仍是独立未关闭 blocker。
- 当前 MapCase02 后证据：PriorMap 非超长分组 217 项 PASS、Map Studio 109/109 PASS、MapCase02 Swift/PC 正式套件 PASS；85-source membership、SwiftPM exact pin、contract drift、pbxproj、Swift/Python compile和diff-check PASS。I10 完整外层 Swift host 长方法与 run `31307753672` 远端 host contract 已 PASS，但仍不登记完整 discover PASS。
- 300,000 条 finalization：peak RSS 12,795,904 bytes；1,728,000 条 trace transition storm：保留 172,801 条，peak RSS 58,769,408 bytes。
- 200,000 burst frames + 200,000 observations 全链路：243,952,646 input/temporary bytes，200,000 accepted observations，融合 1 个 accepted physical tag，884.922 s wall，peak RSS 670,662,656 bytes（约 639.6 MiB，低于 768 MiB host 门）。`StrictJSONLStreamReader` 通过每行 autorelease pool 消除长时 Foundation autorelease 累积，并保留完整 strict validator。
- Map quarantine 当前 diagnostic v3 以 strict canonical bytes 绑定 transaction/prior-map/source/quarantine/payload-tree 和 payload dev/inode；真实子进程覆盖 source thaw、payload/diagnostic/publish 的七个 durable `_exit` 窗口，并验证 source replacement 在 intent 删除前被拒绝。legacy v2 仅兼容完整冻结的 `0555` final；v2 writable `0755` final 和 v2 incomplete source transaction 均保留现场并 fail closed。
- 当前 immutable 资格证据覆盖 POSIX type/mode、single-link、symlink/hardlink、dev/inode、hash、rename/fsync 和崩溃窗口；尚未资格化 macOS ACL、BSD `uchg`/`schg` file flags 或相关扩展属性，不能声称 `0444/0555` 已消除这些额外权限/标志影响。

以上是未优化 macOS host developer evidence，不是 target-device scale、thermal、battery 或 Device Lab PASS。

## 未关闭（已有失败 run，禁止写 PASS）

- exact-SHA CI 尚未全绿；最新 `31307753672@8f0e730d92773eea2ab58f56742d901ac02eead4` 为 7/8，完整 macOS host 合同和 200k RSS 已 PASS，iphoneos cold dependency configure 因 `RTABMAP_RES_TOOL` 未绑定 FAIL。I11/G11 已修复，等待新 run。
- `31307753672` 的 SwiftPM cold resolve、Xcode metadata 与 platform-independent host contract 已 PASS；iphoneos cold build 到 RTAB-Map configure 才失败，iphonesimulator、两端依赖验证和 simulator/device clean compile-link 被 skipped，仍未形成 Apple compile-link 证据。
- Replay / 三格式 E2E（Python 驱动 + host 模式化套件已完成基础设施）。
- 真机短路线 / Sam 路线 / Excel-Numbers-WPS 打开验证。
- 当前 implementation/governance 已绑定为 I11 `37e6ed8c4afa00202693cd56919aea78fd4c7af5` / G11 `7eef33e`；validation SHA 以 descriptor 为准，仍需新的 exact-SHA evidence 和 production-drift-free 复核。

## 明日 TODO（按 2026-08-09 时间收口决定延期）

- 完整 `python3 -m unittest discover -s tools/PriorMap/tests -v`；I10 完整外层 Swift host 长方法与远端 host 合同已通过，但不能冒充整个 discover PASS。
- 按 [`../map-assisted-localization/MAPCASE02_TODO.md`](../map-assisted-localization/MAPCASE02_TODO.md) 执行低影响 parity/UI/visual baseline 与真机 MapCase02 矩阵。
- 已写但未运行的 Map EEXIST、uppercase/noncanonical UUID、`.`/`..` CAS和 Result artifact/manifest/receipt/final-sweep/intent replacement完整集成断言。
- 两个128 MiB delayed replacement场景增加精确测试hook，消除时序依赖。
- `listResultsLocked()` root创建/枚举失败补持久可见的listing diagnostic与`NSLog`，不再静默等价于空库。
- 根级非symlink special file补 durable conflict diagnostic策略。
- 同UID非协作writer、ACL、BSD flags、xattr和第三方文件系统语义继续保持未资格化。
- 执行 [`../map-assisted-localization/ESL_CAPTURE_TODO.md`](../map-assisted-localization/ESL_CAPTURE_TODO.md) 中的 LiDAR 真机、性能、视觉条件、确认冲突和 manifest v3 全矩阵；补齐 platform-scoped Eigen/native dependencies 后完成 simulator/device clean compile-link。

True sensor Deep（重新解码传感器、重建缺失视觉证据）不属于当前 Mobile V1，也不是“尚未接线”的待执行路线；状态机历史 `deep_*` 名称只表示 Route A 允许的一次 Full existing-graph optimization。

## 决策

本阶段结论：**WORKTREE DEVELOPER-SMOKE REVIEWED / EXACT-SHA CI EXECUTED 3× AND FAILED / J-04 BLOCKER OPEN**；
NOT APPLE BUILD VERIFIED / NOT DEVICE SMOKE PASS / NOT SAM FIELD PASS / NOT PRODUCTION QUALIFIED。

## V1R5 Apple build gate 收口

RC-B02/RC-B03 的 shipping source membership 与 CI parse 问题已进入代码收口：production Swift 清单从 Xcode target 自动导出，不再维护易漂移的 shell 长列表；新增生产文件按 fileRef/buildFile/group/Sources phase 四段登记。Native dependency 构建改为 `Libraries/iphoneos` 与 `Libraries/iphonesimulator` 两套完全独立的 prefix/cache/manifest，Xcode 通过 `$(PLATFORM_NAME)` 选择 headers、archives 和 framework；manifest 还会核验关键 archive 的 Mach-O platform 2/7，拒绝只看同为 arm64 的错误复用。

共享 SwiftPM `Package.resolved` 固定 Zip 2.1.2 的完整 revision；CI 对 cold resolve、project metadata 和两个 clean build 后的 lock 做字节稳定性检查，任何 Xcode 自动改写都会 fail closed。本机 Xcode `-showBuildSettings` 已分别确认 simulator/device 的完整 header、framework 和静态库输入展开到 `Libraries/iphonesimulator` / `Libraries/iphoneos`，该证据只证明选路，不等同于完成链接。

当前本机有足以完成 iphoneos fresh configure 的历史依赖前缀，但没有本轮 clean、成对验证的 device+simulator trees，因此不能写 link PASS。CI 已配置在两个独立 cache miss 时分别执行完整 cold dependency build，再进行真实 simulator/device compile + link；run `31307753672` 已到 iphoneos RTAB-Map configure，因 host resource tool 搜索失败而停止。I11 本地已关闭该 configure 错误，最终状态仍必须以新的 committed exact-final-SHA Actions run 为准。

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
