# 地图辅助定位变更记录

> 文档状态：**当前有效**。最后核对日期：2026-08-30。

## 2026-08-31 — PC 路径端到端验证、时钟重复绑定修复、L3→L4 断崖修复

**PC 处理路径端到端验证（此前完全未验证）**：新增 `tools/PriorMap/verify_pc_pipeline.py`。
实测会话 `103343`（2,284 节点 / 994 MB，132.5 s，产出 25 个文件）：数据库校验 ok；
`rtabmap-reprocess` 成功，优化位姿 **190 → 2,284（覆盖率 8.3% → 100%）**；
native 因子图 `solver=rtabmap_g2o_slam2d`、`full_factor_graph=true`、**`converged=true`**；
产物含 `calibrated_positions_by_node.csv`、`_1s.csv`、`localized_price_tags.{json,csv,geojson}`、
`optimized_map_trajectory.geojson` 等。**修正首轮判断**：native helper 一直存在且可用，
历史 28 份结果退化为 `bounded_correction_field` 是**调用未传 `factor_graph_binary`**，非能力缺失。
结果仍不可发布（`maximum_correction_m=35.6`、质量策略仍 `candidate`），根因仍在手机端 usable 0.2%。

**时钟节点重复绑定修复（阻断性）**：`process_localized_session` 首步即抛
`Invalid or duplicate clock node binding`。取证为同一 `node_id`+同一 `node_stamp` 被写入两次
（手机复用冻结 exact-ID snapshot 所致）。**影响 14/36 会话（38.9%）、共 80 条**，
这些会话此前完全无法被 PC 处理（含山姆现场两个最严重会话 2.16%/0.95%）。
修复：区分**冗余重复**（同 id+同 stamp，身份可界定）与**身份冲突**（stamp 不同）。
冗余重复保留以维持 metadata 水位、豁免 stamp 严格递增、记降级码
`clock_node_binding_redundant_duplicate_retained` 保持可见；真冲突仍 fatal。
既有测试 `test_clock_v4_integrity_failures_and_cross_check_degradation` 的重复用例改为真冲突场景，
冗余语义由新增 `test_clock_binding_redundancy.py` 覆盖（4 例）。

**L3→L4 断崖修复**：`PriorMapCorrectionSafety` 由固定 0.35 m 改为随 `supportFrames` 分级
（0-2 帧 0.35 m/8°；3-4 → 1.0 m；5-9 → 2.0 m；≥10 → 2.5 m，航向 15°）。
依据：支持帧越多残差越低、所需修正越小（3.36 m → 1.39 m 单调下降），
而现场修正量中位 2.209 m 被 0.35 m 门拒绝 96.2%。单步上限 0.25 m 不变（多步渐进而非跳变）。
离线估算 trusted 帧数 **162 → 1,818（约 11×）**。

**异常路径审查**：修掉三处 `Int(floor(...))` trap（Swift 中 NaN/Infinity 转 Int 会崩溃而非截断）——
`PriorMapLocalization.nearbySegments`（每帧）、`PriorMapDepthSampler` 体素化、
`ShelfFreeSpaceAuditor.audit`；另加 `filter()` 位姿级守卫。新增源码扫描测试强制热路径文件中
每处网格转换附近有 `.isFinite` 守卫（该扫描编写时即抓出 `audit()` 未防护的一处）。
其他：饱和递增防溢出、早退要求正阈值+最少 1 条证据、`isWithinGate`/`isMapSupported` 拒非有限输入。

**价签 2 帧 quorum 已于 2026-08-31 获产品侧确认**。

## 2026-08-30 — 第二轮审查与价签识别优化（ESL 采集效率）

动机：现场反馈"价签识别困难、依赖多帧定位导致耗时过长"。以仓库内真实现场数据
（14 会话 / 74 burst / 233 观察）回测，确认端到端成功率为 **0%**，失败集中在三道门。

- **采集契约 2/3/4 → 2/2/3 帧**，窗口 4.0 s → 2.5 s，最短时长 0.30 s → 0.20 s。
  冻结契约测试同步更新，新增三道防回退断言（单帧必拒、放宽门必严于主门且有面积
  托底、窗口必封顶）。**这是产品契约变更，已于 2026-08-31 获产品侧确认接受 2 帧 quorum。**
- **ROI 门分层**：0.80 主门保持权威；新增面积托底第二道门（面积 ≥0.02 且交叠
  ≥0.55）。放宽候选评分 ×0.85 并标记 `relaxedROI`。
- **quorum 强弱分级**（`PriceTagCaptureCore.resolve`）：弱证据帧可成组，仅强帧达
  标才判 `algorithmCandidateReliable=true`；弱结果仍需人工确认、不自动发布。
- **测量连续失败早退**：已攒够最少帧且连续 3 次测量不可用即 resolve，不等超时。
- **动态过滤包围盒预筛**（首轮遗漏）：原每点遍历全部多边形各边，真实山姆地图
  实测 753.76 ms/帧；预筛后 34.67 ms/帧（**21.7×**），命中点逐一相等。
- **证据栅格上界每次生效**（首轮遗漏）：原每 100 帧才检查，低帧率可突破 50,000。

**实时定位 usable 占比低的根因诊断**（37 会话 / 43,995 条 `localization_trace.jsonl`）：
- `trackingState` 100% 为 normal、`structureSource` 89.6% 为 `scene_depth`
  → **问题不在 ARKit，也不在缺深度**（推翻此前假设）。
- 拒绝原因集中在 `insufficient_structure_points`（44.0%）与 `ambiguous_structure_match`（26.8%），
  成功 `trusted_structure_correction` 仅 0.2%。
- `matchUniqueness` 中位为 **0**（21/27 会话），门限 0.10 拒绝 **91.3%** 帧；
  在线安全门 0.35 m 拒绝 **96.2%** 帧（实际所需修正量中位 2.209 m）。
- **关键反证**：唯一性 = 0 的帧残差中位 0.0014 **低于** 唯一性 > 0 的 0.0043
  → 低残差不代表匹配正确，**放宽残差门或安全门是错误方向**。
- 结论：根因为**周期性平行货架几何多解**，属场景几何本质；破解需引入非周期信息
  （`MapPillar`/`MapCross`/墙角/货架端头的角点显著性图，及已绑定货架的 ESL 价签作绝对锚点）。
  本轮未实施该算法改动（需真机验证收益与风险）。

**结构点门槛 45 修复**（`insufficient_structure_points` 占 44.0%，头号拒绝原因）：
该门槛**不筛选质量**——按点数分桶后，<45 点帧的 cost 中位 0.00273 **优于** ≥45 点的 0.00340，
各桶 `cost<=0.10` 通过率均在 97–99%（真正区分质量的是 cost 而非点数）。且 45 是硬编码字面量，
与命名常量 `minimumSearchPointCount = 30`（搜索门槛）冲突，导致 30–44 点的帧付了完整搜索却被只因点数丢弃
（占全部帧 72.5%）。**两处均改为引用 `PriorMapScanMatcher.minimumSearchPointCount`**，
接受门槛与搜索门槛对齐、消除魔数副本；cost/唯一性/角覆盖/安全门/多帧一致性全部照旧生效。
离线估算通过帧数 2,504 → **3,739（+49%）**。防回退：Swift 契约断言 + 新增
`tools/PriorMap/tests/test_ios_source_contracts.py`（扫描禁止硬编码点数字面量）。

**唯一性度量塌陷：已定位、已尝试、**已回退**。** `match()` 用 `fine` 阶段（0.2 m 半径、0.1 m 步长）
的邻近采样计算 `uniqueness`，比值数学上趋近 0（实测候选间距 p50 = 0.200 m），即"搜索与自己达成一致"被
记成"歧义"。改为空间盆地口径后，离线估算唯一性通过率 19.2% → 50.4%、39.1% 的歧义判定属误判；
但契约测试 `periodic equal-cost structure basins must fail closed` 拒绝（周期结构间距 0.6 m）。
深挖确认：`fine` 候选永远是局部采样，**无法从中区分真单盆地与周期结构**。
**已回退该改动**，保留离线分析（诊断工具"盆地唯一性分析"段，明确标注为估算而非生产行为）。
安全修复需改用 coarse/medium 阶段的全局盆地，属架构改动，留待下一轮配套真机验证。

新增 `tools/PriorMap/tag_capture_backtest.py`（回测，支持 `--json` 归档）、
`tools/PriorMap/dynamic_filter_benchmark.py`（基准）、
`tools/PriorMap/localization_trace_diagnostic.py`（定位诊断，含门限拟合表）、
`tools/PriorMap/tests/test_tag_capture_backtest.py`（15 例）、
`tools/PriorMap/tests/test_localization_trace_diagnostic.py`（17 例，含盆地唯一性语义测试）、
`tools/PriorMap/tests/test_ios_source_contracts.py`（5 例，源码级防魔数回退）。

回测：成功率 **0.0% → 64.9%**，均值耗时 **4.00 s → 1.14 s（−71.5%）**，
失败空等 **267.8 s → 59.0 s（−78.0%）**。
验证：`IOSCoreContractTests` 6/6（含 Swift host 全量编译）、CI 同款 87 文件 `swiftc -parse` PASS、
tag evidence 峰值 RSS 687 MB → 549 MB。

**Xcode Release 全量构建已通过**（CI `ios-source-contracts` 同款命令）：
`BUILD SUCCEEDED`；`Package.resolved` 构建前后字节一致；构建产物内
`MarketScannerBuildIdentity.json` 经 `market_scanner_build_identity.py verify` 校验为
`build identity verified`，`app_git_sha` 精确绑定本轮 exact HEAD、
`production_eligible=true`、`working_tree_state=clean`。
（`iphonesimulator` 依赖缺失，模拟器构建未执行；宿主环境禁止 SwiftPM `sandbox-exec`，
需加 `-skipPackageUpdates -scmProvider system`，属环境限制非代码问题。）
**回测非真机**；真机端到端、Xcode Release Archive、现场标定仍未执行，整体继续
**NO-GO / NOT PRODUCTION READY**。详见根目录
`MARKETSCANNER_ROUND2_REMEDIATION_2026-08-30.md`。

## 2026-08-24 — 先验地图会话捆绑（V1R6）

- 新增 `PriorMapSessionBundler`：扫描 finalize 时把地图库中与扫描绑定精确一致的
  已安装包写入 `<session>/prior_map/` 并写 `<session>/prior_map_receipt.json`
  （MarketScannerPriorMapBundleReceipt v1）；捆绑失败按 required 证据
  fail-closed（`prior_map_bundle_failed` / `prior_map_binding_missing` 进入
  processingBlockers）。动机：0823 批次因 PC 侧缺少与手机会话匹配的包版本
  （手机 `02402-6bfaef41d384` vs 本地 `02402-d4eb3e633cc2`）无法执行结构校正。
- 导出 `exportFinalizedCapture` 自动携带捆绑包并逐文件复核；历史会话导出时尽力
  从地图库补捆；`copy_verification.json` 新增 `priorMapBundled / priorMapId /
  priorMapPackageSha256`；metadata 新增可选 `priorMapBundled`。
- PC Map Studio：inspect 上报 `bundled_prior_map`（与 metadata 精确比对身份）；
  localized 任务未指定地图时自动选用身份匹配的捆绑包；web 自动填充路径。
- 手机本地后处理：地图库缺失时经 `restoreInstalledPackage` 从捆绑包恢复注册
  （复用 unregister 保留的只读字节、重新校验后 re-register），避免与 PC 相同
  的“缺少地图包”阻断。
- 详细设计见 `PRIOR_MAP_SESSION_BUNDLE_V1R6_2026-08-24.md`。验证：Swift host
  `--prior-map-bundle-focused`（捆绑/幂等/注销恢复/篡改拒绝/canonical 失配拒绝/
  未知 SHA 拒绝）PASS；PriorMap 370/370、Map Studio 148/148、Qualification
  32/32、unsigned generic iPhoneOS Debug BUILD SUCCEEDED。签名 LiDAR 真机
  finalize/导出与 PC localized 端到端仍未执行，整体保持 **NO-GO / NOT
  PRODUCTION READY**。

## 2026-08-19 — PC 地图包文件夹导入防崩溃

- 修复“导入已有 PC 地图包”点击后可能由 FileProvider/DocumentPicker 直接终止的问题：文件夹选择不再使用 `asCopy: true` 的 document-import 模式，改为受支持的 open-in-place security scope；地图包仍只读，选中后由后台单快照验证并写入 App 私有 staging。
- 在展示文件夹 picker 前释放未展示的 XLSX/CSV/JSON 预热 picker，并延迟到 action sheet 完成本轮 dismissal 后展示；同时加入主线程、可见 window、无重叠 presentation 和单实例门，无法展示时返回可恢复提示，不再把 UIKit 异常路径暴露给操作者。
- 安装器不再同时持有 provider 原始包和 App staging 包的两份完整 Data/JSON 快照；来源快照完成验证与 exact-byte copy 后先释放，再复验私有副本，降低合法大包在导入时因瞬时双倍内存被 iOS jetsam 的风险。
- Swift host 新增正式 v2 package 的 source → snapshot → private staging → revalidation → immutable register → exact ID/SHA read 回归；源码合同固定 `.folder + asCopy: false`、security scope 和单一地图库入口。该主机/Xcode 证据不能代替 Files/iCloud/第三方 provider 真机矩阵。

## 2026-08-19 — ESL 现场触发、商品码提示与连续扫描修复

- 新增 `Scan ESL` App Intent/App Shortcut。iPhone 15 Pro 及更新机型可把 Action Button 配置为该 Shortcut；它打开 App 后只转发到现有 `startPriceTagCapture()`，不创建第二路相机，也不绕过扫描/定位/sidecar 门。传统静音拨片和音量键没有受支持的 raw-key API，明确不采用系统音量劫持。
- 保持 ARKit continuous autofocus，扫码框提示约 25–45 cm 工作距离。软件不能控制 ARKit 相机同时又另行锁定 `AVCaptureDevice`，也不能突破镜头最短对焦距离。
- Vision 能高效识别商品正面的 EAN/UPC/QR 属正常现象。EAN/UPC/ITF 与 URL 型 QR 现在显示“疑似商品码”，确认页要求操作员明确证明该码印在 ESL 上；Code128 不按长度/前缀静默拒绝，因为山姆现场 9 位 ESL 也使用 Code128。完全自动区分仍需要门店级 payload 合同、ESL 主数据或服务端校验。
- 关闭连续扫描现场故障：退化 depth plane 过去把 `+Infinity` 作为 residual 传入 observation，导致 `JSONEncoder` 写 `tag_observations.jsonl` 失败并把当前会话标成 required-evidence failure。现在非有限 residual/normal 变为缺失、持久化前执行有限数预检，单帧退化只释放 evidence slot 并等待后续 frame；真正的磁盘/framing/身份/burst 故障仍 fail closed。源码没有“三个通道”切库限制，生产仍是 `continuous_streaming` 单库。
- 完整审查继续收紧 frame-local 防崩溃边界：depth/confidence pixel buffer 必须成功加锁、具有预期像素格式/尺寸/行跨度和有效 base address 才读取，并只解锁已经成功锁定的 buffer；ROI、depth count/ratio、unit normal、node timebase 和 v2 node-local 合同也在 writer 前复核。异常帧只等待下一帧，不越界读取、不写入 PC 严格解析必然拒绝的记录。
- 已加入 Swift host/source 回归和中文本地化；当前 PriorMap **370/370 PASS（373.417 s）**，并通过 Swift parse、localization plist 校验、patch check 和 unsigned generic iphoneos QualifiedDevice Debug 全量编译/链接，AppIntents metadata 与中英文 Shortcut 训练成功。Action Button、25–45 cm 对焦矩阵与连续三个以上通道仍需签名 LiDAR 真机验证，整体保持 **NO-GO / NOT PRODUCTION READY**。

## 2026-08-19 — 人工位置更新的请求后节点保留

- 修复“位置更新等待 stable RTAB-Map node 超时”：RTAB-Map 的 0.05 m/0.05 rad 小位移门和 rehearsal 会在操作者按提示保持静止时淘汰 detector frame，旧 UI 因而可能在 6 秒内永远等不到 fresh retained node。
- 新增 Swift/C/native 请求作用域桥。提交人工位置时暂设 `RGBD/LinearUpdate=0`、`RGBD/AngularUpdate=0`、`Mem/RehearsalSimilarity=1.0`，让下一 detector tick 保留为普通图节点；成功、超时、取消、系统中断和扫描 teardown 请求恢复 authoritative mapping profile，重新开库也清除残留请求状态。
- exact-node 安全合同没有放宽：候选 frame/node stamp 必须严格晚于请求，存在基线时 node ID 必须变化且 stamp 必须递增，node-time delta 仍≤1 秒；manual JSONL durable append 仍先于 alignment CAS。实现不复用旧节点、不注入外部 pose prior，也不要求操作者移动手机。
- 新增 pure policy 与源码桥合同正反例；签名 LiDAR 真机连续 20 次重定位仍待执行，因此整体状态不从 **NO-GO / NOT PRODUCTION READY** 提升。

## 2026-08-15 — 扫描前显示名称合并

- 将 `feature/scan-display-name@389b8b0` 合并到山姆现场加固分支。地图配置页新增可选扫描名称；用户输入经过控制字符/路径特殊字符过滤、空白折叠和 64 字符上限，空值自动回退 `<store>-<floor>-MMdd-HHmm`，名称问题永不阻断扫描启动。
- `scanDisplayName` 作为可选、向后兼容字段进入 `PriorMapScanConfiguration`、live checkpoint 和最终 metadata；扫描事件记录相同解析值。历史扫描列表优先显示再次清洗后的名称，同时保留 canonical `SupermarketSession-*` 目录名作为副标题。名称不参与目录、数据库、sidecar、地图身份、结果 ID 或发布路径。
- 命名规则移入 platform-neutral core 并加入 Swift host 运行时测试，覆盖清洗、空值、长度、幂等、默认值、用户值优先及旧/新配置 Codable；移动 UX 合同覆盖 UI→host→checkpoint/metadata→历史列表全链路和“不得成为路径 authority”。
- 合并回归通过命名 UX/source **25/25**、完整 PriorMap **331/331（376.662 s）**、Qualification **30/30（12.128 s）**、Map Studio **142/142（9.671 s）**、生成合同检查、Swift parse、patch check 和 unsigned generic iPhoneOS QualifiedDevice Debug 全量编译/链接。当前压力峰值为 finalization 13,139,968 bytes、trace 59,113,472 bytes、tag evidence 746,192,896 bytes。真机命名交互、Stop/finalization/export 和 PC metadata 人工核对仍为 NOT RUN。

## 2026-08-15 — 山姆现场前端到端稳定性加固

- 冷启动 Settings 读取不再强制解包；缺失或损坏值使用保守 fallback 并写诊断。生产 Swift 源码（排除供应商 `Libraries/`）清除显式 `fatalError`、`precondition`、`preconditionFailure` 和 `as!`，程序化 UIKit coder、地图导入主线程边界、worker 数量错误、人工定位提交失败和 workflow rollback 都改为可恢复路径。
- recovery lifecycle、strict trace、tag observation/burst 和 canonical JSON 边界移除强制转换/解包。空 complete burst 写入 sticky required-evidence failure；unknown floor 人工重定位不改变扫描；ARKit captured/depth/confidence buffer lock 或 base address 失败时只丢弃对应 frame/证据，深度聚类不足返回 unavailable。
- finalization 改为先关闭写入 admission并停止 ARSession/native mapping/camera producer，再 drain prior-map/localization transaction、flush clock、保存数据库和封口 sidecar，避免 producer 在 writer 关闭后继续创建节点。路径解析早期失败会结束 finalization 并恢复同一连续扫描；封口提交后 native host 缺失只记录警告并释放 session。
- Map Studio 对“历史任务 complete 但 localized current 不可验证”返回 `completed_job_artifacts_unavailable` 结构化 409。Web 恢复逻辑保留原输入/旧结果、禁用打开输出并保持工作台可用，不再因未捕获 `LocalizedStoreError` 断开请求。
- 当前证据：PriorMap **330/330（382.204 s）**、Qualification **30/30（11.140 s）**、Map Studio **142/142（10.017 s）**、native **7884/0**、unsigned generic iphoneos Debug、clean exact-commit macOS Release/QualifiedDevice Release、Swift parse、JavaScript/Python syntax 与 patch check PASS；`rtabmap-reprocess --version` 和 App bundle identity 精确绑定同一候选提交。规模回归处理 300,000 条 finalization（峰值 13,205,504 bytes）、1,728,000 条 trace（保留 172,801，峰值 59,129,856 bytes）和 400,000 条 tag evidence（接受 200,000，峰值 746,455,040 bytes）。浏览器受认证启动、四模式切换和 1600/1280/980 响应式检查 PASS。已配对 iPhone 17 Pro Max 完成 Apple Development 签名 Release 构建、签名验证和安装；冷启动因设备锁屏被系统拒绝，因此运行、相机、LiDAR、start/stop/finalize/export、Files Provider、热/低磁盘/内存压力、异常退出和山姆路线仍未资格化，整体保持 **NO-GO / NOT PRODUCTION READY**。

## 2026-08-15 — 手机性能时间线、不可变结果证据与 PC 趋势分析

- iOS 连续扫描新增有界 `performance_samples.jsonl`：正常扫描约每 5 秒记录一次，数据库保存完成后再记录一条 `scan_state=finalizing` 终止样本。样本使用连续 sequence、严格递增 Unix 时间和 exact tracking-session identity，覆盖进程 CPU 时间与区间占用率、`phys_footprint`、进程可用内存、磁盘、电池/充电、thermal、FPS、RTAB-Map update time、节点数以及数据库/会话目录增长。CPU 百分比按相邻样本的进程 CPU 时间差除以 uptime 差计算，多核时可超过 100%。
- 写侧统一受 250,000 条、256 MiB 文件和 64 KiB 单行上限约束；`metadata.json` 提交文件名、采样间隔、精确条数、末序号、末时间、写失败数和 complete 水位。性能日志属于 observability，不是 pose、constraint、tag 或 publication authority；缺失、写失败或损坏关闭 `performance_qualified`，但不删除已安全落盘的有限地图、轨迹或价签。
- Mobile-Only snapshot 将性能日志作为 `observabilitySidecarPairs` 冻结并绑定 exact bytes/SHA，不把它加入定位权威 sidecar。手机不可变 Result 在证据存在时生成 `phone_performance_samples.jsonl`、`phone_performance_summary.json`，并把样本数与 complete 状态写入 result manifest 和质量报告。
- Supermarket Map Studio 新增流式严格解析与最终地图包 `performance/`：验证 regular/single-link/no-follow、前后 inode/size/mtime、final newline、无空行、UTF-8/JSON、有限数字、format/version、identity、连续序号、严格时间和 metadata 水位；有效证据生成 exact raw、CSV、统计摘要、确定性有界趋势序列与性能 manifest。坏日志不生成可信趋势，但在安全大小范围内以 `.invalid.jsonl` 原样保留并记录 SHA-256。多设备结果按 `device_01`、`device_02` 分目录。
- 已投递的有界 MetricKit crash/hang 诊断随性能目录复制并绑定 hash；没有 MetricKit 文件只表示当前结果包没有已投递 payload，不能解释为“没有闪退”。普通 iOS 应用没有可靠公开的整机 GPU 利用率 API，因此样本明确写 `gpu_metric_status=not_available_public_ios_api`，不从 CPU、FPS 或 Metal helper 状态伪造 GPU 百分比。
- 本增量不等于真机性能资格。30 分钟/2 小时连续扫描、热/电量/低磁盘/内存压力、前后台、强杀/watchdog/crash 后 MetricKit 延迟投递、采样 fsync 对帧率的周期性影响和签名 LiDAR 现场矩阵仍须执行；整体继续为 **NO-GO / NOT PRODUCTION READY**。

## 2026-08-14 — 价签 node-local 坐标合同 v2 与统一发布不变量

- 关闭设计审查 P0：native node snapshot 在 camera/RTAB-Map 同一锁域内新增 node map/component ID 和 `T_opengl_world_from_node`；scene-depth 价签点在手机写入时转换为 exact bound-node local 3D，observation v2 持久化 `bound_node_id/stamp/map_id`、`coordinate_frame=RTABMAP_BOUND_NODE_LOCAL`、`point_in_bound_node_frame` 和独立 `measurement_height_m`。
- Swift/Python strict parser 复核 verified complete burst、exact node ID/stamp/map ID 和 node-local 坐标范围；手机与 PC resolver 统一为 `P_final = T_final_node × P_node`。二维 `shelf_plane_ray` 不伪造 node-local 点。历史 v1 的 prior-map `raw_map_position` 不再参与坐标传播，条码/业务身份继续保留，坐标清空并标记 `legacy_tag_coordinate_frame_rescan_required`。
- 关闭设计审查 P1-A：手机 result coordinate contract 升级为 v2，先统计 degradation、legacy frame、`LOW_CONFIDENCE`、unpositioned、unassociated 和 rescan，再决定 `COMPLETE/publish_permitted`；immutable result reader 与 committed-task recovery 重复检查同一不变量。旧 coordinate contract v1 仍可作为 review artifact 保留，但不能再声明 COMPLETE。
- 新增非零 `(100 m, 50 m, 90°)` gauge、v1/v2 混合、raw display position 缺失/损坏、node-local 点缺失/非法、exact map ID/stamp、结果 manifest 篡改和源数据库只读回归。Stage-3 当前 126/126 通过；完整 PriorMap discover 329/329（378.876 s）通过。规模子进程为 300,000 finalization peak 13,287,424 bytes、1,728,000 trace retained 172,801 / peak 59,146,240 bytes、400,000 tag evidence accepted 200,000 / peak 747,192,320 bytes；tag 峰值仍低于冻结 768 MiB 门但余量有限，必须在 exact-SHA runner 继续监控。
- 本次不包含正式 pose epoch/component sidecar、corridor/shelf/side tracker、人体扫掠体自由空间约束、PC 混合因子图、concrete shelf-loop/manifest v5、动态物体/地图失配或现场控制点资格。整体继续为 **NO-GO / NOT PRODUCTION READY**；范围与剩余项见 [`AISLE_SHELF_CONSTRAINED_LOCALIZATION_REMEDIATION_2026-08-14.md`](AISLE_SHELF_CONSTRAINED_LOCALIZATION_REMEDIATION_2026-08-14.md)。

## 2026-08-14 — 现场反馈复核：人工重定位原子提交、统一位姿 authority 与崩溃诊断

- iOS 人工重定位改为真正的 UIScrollView zoom/pan/双击和箭头聚焦；确认前同步最后一次 X/Y/yaw 编辑，弹窗保持到 fresh accepted node、manual JSONL durable append 和 alignment CAS commit 全部成功。写失败或 fresh-node 超时不改变 live alignment、不关闭弹窗、不丢用户输入。
- RTAB-Map、prior-map localizer/depth、ESL depth/ray 和 location-bearing sensor boundary 统一消费同一 software-stabilized transform；被拒 raw frame只计 tracking health。tracking 恢复坐标 epoch 会重基准并拒绝边界帧，普通 callback gap 不再放宽到 6 m/360°。
- 连续扫描 profile 的 `OptimizeMaxError=2.0`、`Vis/MinInliers=40` 成为可审计实际 authority；没有 Sam 真值 A/B 前未采用审查报告中的 4.0/0.18–0.20/30 建议。
- 新增 MetricKit crash/hang 持久诊断和 Map Studio 有界摘要解析。单个原始 payload 在 8 MiB 合同内完整保留；超限时保留计数、原始大小和明确省略原因，不能突破文件上限。现场 4 次 crash 因缺少 `.ips`/符号化堆栈仍不能宣称根因关闭；冷启动跨 ARKit epoch 续采、WM 恢复、正式 shelf-loop/manifest v5 等后续项登记于 [`TESTER_FEEDBACK_TODO_2026-08-14.md`](TESTER_FEEDBACK_TODO_2026-08-14.md)。

## 2026-08-14 — 正常生命周期防崩溃与人工锚点交互收口

- iOS 正常生命周期不再使用进程级强制终止：Core Location 空批次只写 `gps_empty_update_ignored` 并继续；暂时没有 active `UIWindowScene` 时朝向返回 `nil`；历史数据库 scroller 对索引和 `DatabaseView` 类型做可选检查；数据库文件日期与 Application Support 状态目录失败均进入可恢复分支；价签非法状态迁移只记录诊断；后处理不变量异常改为类型化 checkpoint/map 错误。完整性/身份损坏仍失败关闭，但普通 UIKit、Files、定位回调和算法竞态不能导致闪退。
- PC 人工地图锚点移除连续 yaw range slider，保留 canonical X/Y/yaw 数值、0.1/0.5/1.0 m 四向微调、±1/±5/±15°旋转、东/北/西/南和键盘/Shift 加速；显示值、请求值和审计值完全一致，服务端继续复核 exact node/time/floor/bounds/yaw。iOS 既有离散微调合同不变。
- 源码和成果合同再次确认：存在有限轨迹时，普通图质量、weak/lost、平行通道或货架多解、时钟局部缺口、深度/位置离散度和关联不足只生成 `PARTIAL_REVIEW_REQUIRED` / `LOCAL_FRAME_ONLY` / `LOW_CONFIDENCE`；节点、逐秒行、barcode、主候选货架和 durable identity 必须保留。只有数据库/JSONL framing、身份、水位、CAS、重复 durable 主键、完全无有限轨迹或原子成果提交损坏可以阻断。
- 该正常生命周期增量当时的主机证据为 PriorMap 322/322（363.760 s）、Qualification 30/30、Map Studio 完整 API 130/130、native 7884 checks / 0 failures、macOS Release `rtabmap-reprocess` build/launch、Swift parse、JavaScript/Python syntax 和 patch-format PASS。长规模测试处理 300,000 条 finalization（峰值 14,254,080 bytes）、1,728,000 条 trace（保留 172,801，峰值 59,146,240 bytes）和 400,000 条 tag evidence（接受 200,000，峰值 449,871,872 bytes）；当前整分支证据已由本页顶部 node-local v2 条目更新。真实浏览器响应式自动化受 localhost 安全策略限制；签名真机、LiDAR、Files provider、热/低磁盘和现场非空价签真值仍待执行，不能声明 Production GO。

## 2026-08-14 — 废弃道路中心线重参数化，保留通道内真实轨迹几何

- 废弃 `bounded_free_space_road_hmm_v1` 的“选中道路序列后按物理累计里程在中心线上重新采样”行为。旧实现只保留累计路程，会把用户在通道内的横向位置、局部曲线、停顿和回头压成规则道路折线；TianHong 旧包的 road width 又全部为 0，历史 0.2 m 伪宽度进一步放大了错误。
- 新 `bounded_free_space_road_hmm_v2` 将 `road_graph` 限定为 corridor identity、有限边范围、真实 junction、连通性和可达转移证据。道路边的有限纵向范围参与 HMM 评分，但不会把自由空间中的手机点拖向道路端点；道路中心线和切线均不再写入最终 X/Y/yaw。未知或零道路宽度不再伪造，横向自由空间从货架/固定结构多边形确定性派生。
- 最终轨迹使用 `local_geometry_preserving_corridor_envelope_v2`：保留优化手机位姿的局部几何；exact 人工锚点残差按 gauge-neutral 物理里程连续传播；交替投影只产生最小低频自由空间修正。结构内孤立点按同一通道侧退出并用前后修正场消除错误侧选择；穿架线段使用货架驱动的局部刚体平移，同轮建议先合并再应用，禁止多个相邻穿架段向同一节点顺序累加；最终修正尖刺/平台切换只有在整个候选窗口的点和线段均不碰撞、且局部最大步长不增加时才平滑。
- `MarketScannerCorridorRouteMatchAudit` 升级为 version 2，以 `geometry_preservation` 取代历史 `reparameterization`。审计显式保存 `centerline_snap_applied=false`、道路/手机几何角色、有限包络投影、anchor translation field、point escape continuity、shelf-driven rigid segment repair、collision-safe spike/gradient repair、中心线横向偏移和最终距离尺度。历史 version 1 继续只读兼容。
- 复用既有只读 optimized DB 和同一 TianHong prior-map package 实测：`162937` 保留 3663 个节点与 3806 行秒级表，结构内点/穿架段/拓扑断裂为 `0/0/0`，最大输出/物理步长为 `1.091/1.070 m`，轨迹/物理里程为 `476.929/470.892 m`；`181158` 保留 1054 个节点与 1132 行秒级表，三项同为 `0/0/0`，最大输出/物理步长为 `0.848/0.952 m`，轨迹/物理里程为 `179.779/181.127 m`。两份结果都保留完整 CSV/PNG，但因绝对修正、弱定位时长和少数无法安全摊平的修正梯度继续标记 `PARTIAL_REVIEW_REQUIRED`、禁止发布；这不是处理失败，也不证明现场绝对坐标真值。
- 该轨迹修复基线曾通过 PriorMap 321/321、Map Studio 130/130、Qualification 30/30；本页上方跨端稳定性增量给出当前源码的更新证据。新增/强化用例覆盖通道内横向移动、U-turn、有限道路端点/真实路口、exact 人工锚点连续传播、货架驱动穿架修复和自由空间修正梯度。

## 2026-08-14 — 不可变时间线/价签成果、时钟分段与 durable burst 核账

- localized result 升级为 version manifest v5：`calibrated_positions_by_node.csv`、`calibrated_positions_1s.csv`、`localized_price_tags.json`、`localized_price_tags.csv` 和 `calibrated_deliverables_manifest.json` 成为不可变版本内的核心业务工件。正式发布版本为 v6。外部导出脚本验证并复制核心 CSV，只额外生成路线 PNG，不能重新解释或提升结果资格。
- PC 和手机统一“成果生成”与“允许自动发布”两个决定。部分优化图、低覆盖率、weak/lost、道路/货架多解、距离尺度偏差、时钟局部缺口和价签关联不足会完整保留节点、秒级行、条码、审计和低置信度原因；未知坐标为空并标 `UNAVAILABLE` / `LOW_CONFIDENCE`，禁止伪造 `(0,0)`。数据库/证据 framing 损坏、身份串包、hash/watermark/CAS 不一致、重复 durable 主键、完全无有限轨迹和原子提交失败仍保持阻断。
- session input manifest v4 正式绑定 `clock_correlations.jsonl`。PC 与 iOS 现在共同验证 correlation UTC 严格递增、node binding 的 frame/node stamp 2 秒合同、UTC 映射和 timezone/offset context。节点/秒级表增加 `clock_segment_index`；系统时钟跳变或时区变化切段，秒级导出不跨段插值，跨段行保留为空坐标并写 `clock_discontinuity`。局部 binding 交叉验证后不足两条时改为 `clock_mapping_insufficient_after_cross_check` 退化：轨迹与价签继续提交，correlation 覆盖的所有秒级行保留为 `UNAVAILABLE`；历史 node stamp 不再伪装成 UTC。
- durable tag burst 的 `burst_id/frame_id/observation_id` 在读取原始身份后立即进入会话级全局唯一库存，burst 后续退化也不能释放 ID；tolerant final-tag reader 同时拒绝重复非空 `capture_id`。若身份明确的 durable burst 没有出现在 final tag 文件，PC 补 exactly one 保留 barcode/symbology/capture ID、位置/货架为空的 `LOW_CONFIDENCE` 记录，并要求 `tag_source_record_count == tag_retained_count`。
- 自动回归通过 PriorMap 314/314、Map Studio 130/130、Qualification 30/30。Swift host 长规模仍覆盖 300,000 finalization、1,728,000 trace 和 400,000 tag evidence；新增 durable ID 库存的本轮峰值为 699,891,712 bytes，未突破 768 MiB host 门。签名真机、LiDAR、现场非空价签和 exact-final-SHA 资格仍未执行。
- 复用既有只读优化数据库重新生成 TianHong 两份真实会话：`162937` 保留 3663/3663 节点、3806 行秒级表（1501 行位置不可用）；`181158` 保留 1054/1054 节点、1132 行秒级表（486 行位置不可用）。两份 `current` 都通过 version/file/hash 校验，源 DB、optimized DB、prior-map package SHA 与上轮一致，源地图包未修改；样本输入确实没有价签，因此 0/0 核账是输入事实，不能替代现场非空价签验证。

## 2026-08-14 — TianHong 旧地图兼容、人工校准和结构连续性收口

- TianHong 旧 v2 包的 `elements.json`/权威 XLSX 完整，但旧编译器过滤了隐藏 `MapCross`，又没有从 510 个有效 road-point `crossCodes` 恢复拓扑，导致 `road_graph` 只有 511 个孤立节点、0 条边，并连带触发 `road_graph_source_binding` / `spatial_source_binding`。Map Studio 现在仅在错误集合严格属于这组已知派生绑定问题时，将源包只读复制到结果目录并确定性重建 `road_graph/spatial_index/validation_report/package_manifest`；其他身份、schema、hash 或完整性错误仍终止。源包、权威 canonical SHA 和 prior-map ID 不修改。
- `run_localized_map()` 与人工编辑重放统一采用“结果保留、发布从严”：低置信度或非完整性质量项不再抛通用“处理失败”；新不可变版本、轨迹、价签和审计完整保留，`current`/review/publish 指针是否推进继续由更严格门禁决定。真正的输入身份、数据库、JSON framing、水位、CAS 或原子提交错误仍失败。
- PC Web 人工锚点和 iOS 人工重定位统一 canonical SE(2)：`0°=+X/东/屏幕右`、`90°=+Y/北/屏幕上`、逆时针为正。PC exact-node/floor/time/contract-bound `set_anchor` 与手机 v3 exact-node 事件都作为约 3 m / 20°不确定度的可信绝对地图 gauge 证据；历史 timestamp-only 编辑继续走兼容门。Web 与手机均提供 X/Y/yaw 数值、0.1/0.5/1.0 m 微调、东南西北和 ±1/±5/±15°旋转；Web 同时处理 Shift 后浏览器产生的 `{`/`}` 键值，数值字段在 change/blur 统一提交并按 canonical bounds 钳制。服务端从不可变轨迹复核 node/time/floor/bounds/yaw，界面数值就是提交数值，不存在隐藏二次坐标转换。
- 结构窗口连续性不再用“相邻 correction 总量 ≤ 3 m”拒绝长距离累计漂移。权威诊断改为单位 gauge-neutral 物理行进距离的平移/航向 correction gradient，总变化量只保留审计；短距离大跳变仍因高梯度拒绝。真实 `181158` 在原 12 候选预算下最大总校正仍为 4.080 m，但梯度仅 0.176 m/m 和 1.242°/m，因此连续性通过；`162937` 连续性也通过，但平行货架序列仍多解，继续保留 top-K 和低置信度，绝不伪造唯一货架。
- 手机可靠 RTAB-Map 回环现在会在开始有界 recovery 时，把当前估计位置附近最多 5 个 concrete `shelf_segment_id` 写入 `scan_events.jsonl`，多解显式标记 `ambiguous_top_k_retained`。该事件仅为诊断和后续结构消歧入口，尚未绑定局部结构快照、phone↔shelf SE(2) 或正式 localization input manifest，不能注入绝对因子，也不能据此宣称“具体货架闭环”已完成。
- 两份真实 TianHong 会话已生成完整不可发布草稿：`162937` 保留 3663/3663 节点和 3806 条逐秒坐标，`181158` 保留 1054/1054 节点和 1132 条逐秒坐标；均有节点级/秒级 CSV 与两张路线 PNG，没有节点删除、结构内点、穿越结构线段或道路拓扑断裂。两份会话都没有价签观测，空价签不是失败。签名真机、LiDAR、现场货架 identity 真值和 exact-final-SHA 资格仍未执行。

## 2026-08-14 — Gauge-neutral 自由空间道路路线恢复

- 修复长距离 `localization_trace.rawPose` 的坐标语义错误：该字段已经经过当时可变的 ARKit→地图 alignment 投影，自动结构 correction、人工重定位和坐标 epoch 重置属于 map gauge 变化，不是手机物理位移。PC 新增 gauge-neutral 恢复：普通帧累计相邻相对 SE(2)，自动 correction 后从前一 `estimatedPose` 续算，人工重定位后的首个 post-reset sample 物理位移记为零，再按数据库节点时间戳重采样。
- 长会话不再先运行通道方向场整体旋转，也不再逐点吸附最近通道。新增 `bounded_free_space_road_hmm_v1`，联合 gauge-neutral 相对运动、严格 exact-node 人工绝对锚点、`road_graph` 连通性和货架/固定结构多边形；不可达转移、结构内节点和穿越结构的线段均拒绝。选中的完整道路访问序列按物理累计距离分段参数化，保留回头、U-turn 和围绕货架的绕行。
- 平行通道身份多解通过 `ambiguity_intervals` 和 `corridor_identity_confidence=low` 保留；路线长度与物理里程任一锚点分段偏差超过 5% 时，输出继续生成但 `distance_scale_confidence=low`，review/publish gate 加入 `corridor_route_distance_scale_above_5pct`。低置信度不再等同于处理失败，也不得伪装成唯一正确通道。
- `optimized_map_trajectory.geojson` 的三个轨迹层新增逐节点 `yaws_rad`。独立校准轨迹导出生成节点级 CSV、本地时间秒级 CSV、先验地图预览和时间标记预览；`yaw_source=optimized_phone_pose`，明确禁止用运动路线切线替代真实手机朝向。
- 真实 `SupermarketSession-20260811-103343`（2284 nodes）验证：输入 map-gauge 最大跳变 6.570 m，恢复后 trace 最大物理步长 0.514 m，节点级最大物理步长 0.850 m；最终自由空间路线货架/固定结构内点 0、穿越结构线段 0、道路拓扑断裂 0，最大路线相邻步长 0.951 m。物理里程 820.029 m、路线里程 891.910 m，三个锚点分段尺度为 1.1188 / 1.0612 / 1.1054，因此结果正确保留为 `PARTIAL_REVIEW_REQUIRED`、`publish_permitted=false`，不能宣称生产发布 GO 或通道身份已经唯一确定。
- 最终源码回归为 PriorMap 291/291、Map Studio 120/120，Python 语法和补丁格式通过；原始约 995 MB 数据库 SHA-256、inode、大小和 mtime 均未变化。真机/LiDAR/现场闭合路线与测量控制点验收仍待执行。

## 2026-08-13 — 完整 raw VIO 草稿与坐标系重置缝合

- `rtabmap-reprocess` 图不完整时，只要原始 `Node.pose` 全量有限、时间严格递增且能证明连续，即保留为不可发布的 `raw_continuous_vio_diagnostic_recovery` 草稿；无人工事件时由 `initialMapPose` 提供低置信度 gauge，不再把完整有限轨迹整体丢弃。
- 对 ARKit/数据库局部坐标 epoch 重置引起的绝对跳变，新增只读多 Link 一致恢复：至少两条独立、短距离的 type 1/2/3 Link 必须推导出唯一一致的刚体变换，缝合后重新通过 3 m/120°连续性门。无桥接、多解、非有限位姿或真实大跳变仍 fail closed。
- 诊断报告记录 reset 节点、时间间隙、候选与一致 Link、选择的边界桥、应用变换、修复前后步长和全轨迹指标；该路径不生成来自坏 `Admin.opt_poses` 的点云/地图，始终禁止发布。

## 2026-08-12 — 长距离漂移人工绝对锚点与连续轨迹恢复

- 将严格 `MarketScannerManualLocalizationEvent v3` 的人工重选位置定义为绝对地图 gauge 证据，而不是手机物理瞬移。只有 exact-node、tracking/map/floor identity、递增 alignment version、node stamp/time delta 和 atomic snapshot generation 全部通过时才设置 `trusted_absolute=true`；该日版本的旧 v2 时间绑定和 PC `set_anchor` 仍受 5 m/30° `unverified_manual_anchor_safety_gate`。PC exact-node 锚点随后已由 2026-08-14 条目升级为同等级可信绝对证据。
- 可信人工锚点使用约 3 m 平移、20°航向不确定度，不再按大累计漂移残差做 Huber 降权。bounded fallback 从固定 120 轮松弛改为 O(N) Thomas 三对角精确求解，使修正沿完整连接轨迹前后连续传播，避免在锚点处形成未收敛尖峰。
- `maximum/P95 correction` 在可信人工锚点存在时改为 gauge 审计，不再单独阻断 current draft/review；新增相邻 correction-field 平移/航向梯度门。native 因子图只有在 runner 明确证明选中可信人工锚点时才允许大 pose update，普通自动 absolute prior 不能借用该权限；相对边、闭环、连通性和目标函数门保持不变。
- `rtabmap-reprocess` 图不完整时新增 `raw_continuous_vio_manual_anchor_recovery`：仅在原始 `Node.pose` 全量有限、时间严格递增、相邻步长/旋转安全，且严格解析后至少有一个可信人工锚点时生成 diagnostic-only 草稿；不从不完整 `Admin.opt_poses` 渲染 2D/3D 成果、强制禁止发布、原始数据库只读。无人工证据的 `093330` 坏图继续拒绝。
- 自适应 ORB discovery 若生成不安全图，不再覆盖已验证 fast pass。真实 `103343`（2284 nodes、2 个严格人工锚点）恢复后最大绝对修正约 6.17 m，相邻 correction 平移梯度约 0.057 m、航向梯度约 0.294°；仍因会话 weak/lost 和 rejected constraints 阻断发布。真实 `093330` 无人工事件，恢复按预期拒绝；两份原始 DB 前后 SHA-256 均未变化。
- 自动测试新增长轨迹 35 m 漂移连续传播、可信/非可信人工权限分离、gauge-aware 因子图质量门、工作台恢复编排和 discovery fast-pass 保留。该修复不是生产发布 GO；真机/LiDAR/现场长距离矩阵和 exact-final-SHA 资格仍待执行。

## 2026-08-11 — 手机历史处理长哈希稳定性与 PC 跨编译器地图身份

- 手机 immutable snapshot artifact 哈希增加有界两遍稳定读取：只在同 dev/inode/mode/nlink/size/mtime、`ctime` 单次向前且 descriptor/path 最终一致时丢弃首遍并完整重哈希；持续 `ctime`、内容/mtime、inode、mode、link、size 变化继续 fail closed。
- `metadata.json` 改为同一次 descriptor-stable 读取同时 strict parse 与 SHA，消除 eligibility 的第二次打开窗口；SQLite 只读校验和 generation final sweep 对一次性 `ctime` 稳定必须重新完整哈希并匹配 committed manifest。
- 新手机会话写 `priorMapCanonicalSourceSha256`。PC localized processing 支持 exact source SHA、exact PC package SHA、full canonical SHA，并为缺字段的历史 Swift 手机包提供 exact map/store/floor + canonical-ID-prefix 的显式兼容绑定；报告保留全部身份和 warning。
- 真实 `扫描结果/0811` 的 13 个 finalized 会话通过 PC input snapshot/identity gate；5.9 MB、36 MB、约 995 MB 三档真实会话完成手机 snapshot host 验证和 PC 完整处理。未 finalized 且带 live checkpoint 的会话继续拒绝；大样本后续由正常质量门拒绝发布，而不是哈希/数据库错误。

## 2026-08-11 — 起点朝向、ARKit 首帧对齐与扫描 HUD 统一

- 真机截图复现：配置页选择“东 0°”时 marker 向右，但进入扫描后 HUD 三角向上；继续向前会按旧的 `yaw 0 = +Y` 解释初始轨迹，属于实际定位与显示共同存在的固定 90° 合同断层，而不是单纯图标问题。
- `PriorMapStageOneMath.arkitHorizontalPose` 改为对 map-space camera forward `(forwardX, -forwardZ)` 使用标准 `atan2(y, x)`；因此 `0 = +X/东`、`+π/2 = +Y/北`。深度点局部坐标的视场角同步改为从 local `+X` 计量，避免 matcher observation 再保留旧的 +Y 基轴。
- 配置 marker、旧人工位姿选择器和扫描实时 HUD 统一使用 `PriorMapHeadingUI`：未旋转箭头全部向右，UIKit 只执行一次 `-yaw` 的 y-down 手性转换，不再额外带 90° 偏置。
- 新增四个 ARKit camera-forward 金标、四个起点方向的首帧/前进一步投影金标，以及 setup → configuration → initial map pose → live HUD 源码合同。当前快速方向组 13/13 PASS，移动 UX/方向/sidecar 聚焦组 54/54 PASS，修改 Swift parse 和 `git diff --check` PASS；完整 Swift host 1/1 PASS（1398.238 s，400,000 条 tag evidence 峰值 RSS 533,495,808 bytes），unsigned generic iPhoneOS Debug clean build 编译/链接 PASS。提交后 Release identity build 与真机四方向复测仍为后续门。

## 2026-08-10 — 真机历史处理 committed-file pre-open `ctime` 稳定化

- 在 `core-mobile-v1@9a93fbd0ee52944eae5aebedf59ec6a08dedc934` 真机复现历史处理失败：`稳定复制失败：committed transaction file changed before open`。失败发生在 snapshot/task/intent 的 committed authority 稳定读取，尚未进入数据库图优化或扫描质量判定；简单/空白扫描应在事务通过后按证据得到 Result 或 `RESCAN_SESSION`，不应由该错误中止。
- `SessionSnapshotTransaction` 对原子发布后 pathname/descriptor 可能出现的 pre-open `ctime`-only forward stabilization 增加窄兼容：dev/inode/mode/link/size/mtime 必须完全一致，并立即重新将 pathname 严格绑定到已打开 descriptor。读取后的完整 identity 与字节数门保持不变；inode replacement、mtime/content change、hardlink、symlink、writable authority、post-open metadata change 和 pathname replacement 仍 fail closed。
- 新增确定性 fault points 与 Swift focused 回归，覆盖允许的 pre-open `ctime`-only 情况及七类必须拒绝的 mutation/authority 情况。workflow 将底层 snapshot error 映射为 `workflow.snapshot_failed`，处理页去除双重“处理失败”前缀，并在底层错误中报告 basename 和差异字段。
- 当前证据为 mobile UX/source + sidecar health **41/41 PASS**、Qualification **30/30 PASS**、Swift parse 与 patch-format PASS；完整 Swift host **1/1 PASS（1270.619 s）**，新增 focused 模式已实际执行，400,000 条 tag evidence 峰值 RSS 553,189,376 bytes；unsigned generic iphoneos Debug 与 Release 均全量编译/链接 `BUILD SUCCEEDED`，Release 日志包含 `build identity verified`，包内 `app_git_sha` 已核对为构建时 exact HEAD。修复版真机复测仍待完成，不能据此声明 real-device PASS 或整体 GO。

## 2026-08-10 — 地图导入预热、近距离 ESL 识别与低置信度保留

- 地图选择页首屏完成后，在主线程空闲轮次预热一次导入 action sheet、`MobileMapImportViewController`、XLSX `UTType` 和 `UIDocumentPickerViewController`。点击“导入新地图”与“导入 XLSX / CSV / JSON”不再承担这些一次性初始化；预热不触发 workflow transition、不访问 provider 文件，真实安全暂存和编译仍走原后台队列。
- Barcode Capture 显式保持 ARKit autofocus，Vision 上限从 8 Hz 提升到 10 Hz，主 ROI 无结果时在同一 worker lane/ARFrame 上只执行一次扩展 ROI；加入 Code39/93、I2of5、ITF14、DataMatrix、Aztec 和 iOS 15+ Codabar。worker 仍固定两条、one-in-flight、1 秒 request deadline，不创建第二相机或 backlog。
- exact node snapshot 的短暂 publication gap 不再伪装成 required sidecar write failure：当前 evidence frame 被延期，capture 保持锁定，并且只允许 live snapshot 或仍满足 1 秒 node-timebase 合同的已冻结 exact-ID snapshot。真实写入、身份和 burst 失败继续 sticky fail-closed。
- 完整 verified burst 若仅定位/测量/关联质量不足，手机直接提示低置信度已保存并结束本次扫码；处理时继续按 exact `boundNodeID` 和最终优化 node pose 重投影，输出 `LOW_CONFIDENCE` PriceTag 而不自动创建 RescanTask。缺少完整 burst、身份/图质量、exact node/raw pose 或可解析位置仍为 `RESCAN_REQUIRED`，没有放宽 ACCEPTED 合同。

## 2026-08-10 — 历史扫描校验/导出、ESL 布局与 Xcode 启动假故障修复

- 修复真机“处理历史扫描”在 snapshot 复核阶段报 `cannot open snapshot DB read-only`。根因是 iOS App sandbox 不保证 SQLite VFS 能通过 `/dev/fd/<descriptor>` 重新打开已绑定文件；当前保留 no-follow descriptor、完整 stat identity、WAL/journal、SHA、`quick_check`、Node/Link 和 graph BLOB 安全门，并在且仅在 `/dev/fd` 明确只读打开失败时，从已绑定 descriptor 流式复制到 App 私有 `0700/0400` 临时目录完成正常 immutable URI 校验。源身份在复制/校验前后精确复核，临时文件在所有退出路径清理；其他数据库完整性错误仍直接失败，不被 fallback 吞掉。
- “处理历史扫描”列表新增独立“导出原始扫描”按钮。导出不依赖手机后处理成功，要求 finalized continuous-streaming、exact 单一 `segment_0001`、tracking identity 一致、无 live checkpoint、数据库非 symlink/hardlink；复制完整 capture 后执行源/目标/复制后源 SHA-256 manifest 三方复核，写复制验证凭证，手机原始数据始终保留，同名目标绝不覆盖。
- ESL 全屏扫码层的状态文字和条码文字改为绑定真实扫码框的上、下边缘，并分别保留 18 pt 间距；边框、布局 guide 与 Vision ROI 继续使用同一个 normalized scan rect，关闭截图中的文字压线问题。
- 构建后偶发的黑色残缺画面确认是 Xcode 文件断点 `ViewController.updateState(state:)` 暂停主线程，而非 App 随机初始化失败；本地断点已删除。文档加入辨识和恢复步骤，避免通过反复重启误判。
- 本轮新增的源码合同为 `test_mobile_scan_ux_contract` **19/19 PASS**，UX + sidecar 快速组 **37/37 PASS**，修改 Swift 文件均通过 `swiftc -parse`。包含私有 DB 校验副本清理与连续两次历史导出的完整 Swift host 长方法 **1/1 PASS（1484.429 s）**；400,000 条 tag evidence 输入为 243,952,646 bytes、接受 200,000 条、峰值 RSS 520,077,312 bytes。最终 unsigned generic iPhoneOS Debug 与 tracked-clean exact-HEAD Release 均完成全量编译/链接；Debug App 不含正式 build identity，Release bundle 的 `app_git_sha` 与构建提交精确一致。无签名 generic build 不替代真机 Files provider、大型真实 DB、LiDAR 或现场验证。

## 2026-08-10 — 现场扫描证据、价签入口、结束事务与起点预览修复

- 修复先验地图扫描刚启动时 native node timebase 尚未建立却向严格 sidecar writer 传入 `.nan` 的问题。当前 frame 在 offset 缺失或非有限时直接等待，最多每 2 秒记录一次 `prior_map_update_waiting_for_node_timebase`；只有拿到有限 native offset 后才执行定位和写入 `localization_trace/constraints/events`，不会再把一次短暂未就绪升级为整场粘性证据失败。
- Mobile-Only coordinator 现在显式执行 `scanning → finalizingScan → idle`，可恢复结束失败则回到同一 `scanning`；terminal close 清除 session/database/receipt 绑定。`beginScanSetup` 返回 Bool，配置页在已有扫描正在进行或结束时停止 commit 并恢复 UI，关闭 `scan commit requires configuringScan, got scanning` 的重复事务路径。
- “扫描价签条码”继续复用已有的 ARFrame-only 全屏相机扫码层，不创建第二个 camera session。入口失败不再只显示易遗漏 toast，而是按 required-evidence、alignment、ARFrame、mapping state 和 prior-map identity 显示明确阻断原因；成功进入后 overlay 强制置顶并设为 accessibility modal，保留扫码框、识别进度、成功反馈和取消按钮。
- 修复手机 `MobilePreviewRenderer` 在 Quartz bitmap 上重复翻转 Y 的问题。Quartz 投影现在保持 canonical +Y，UIKit touch 继续只做一次 `1-v`，因此画面、起点 marker 和障碍物验证同向。MapCase02 报告点 `(58.03,-18.13)` 不在结构内且 clearance ≥ 0.30 m，已知货架内部点仍拒绝；Swift package golden 更新为 `c6b6b2c00690998cfa9517374b9385f857cb3ee0efcbe3663f63ee76fee87959`，canonical/PC package/PC preview 不变。
- finalization 的 state/checkpoint/context 现在合并为一次持久化；应用若在 `finalizing_scan` 且 metadata 尚未提交时中断，恢复入口不会把未完成会话直接送进后处理。当前验证为 UX/geometry/build identity 32/32、现场阻断聚焦 46/46、Swift 长方法 1/1（1212.429 s）、较广 PriorMap 197/197、Map Studio 109/109、四张真实 XLSX 4/4 和 unsigned generic iPhoneOS Debug `BUILD SUCCEEDED`；严格 Release identity build 留到提交后 clean tracked tree 执行。

## 2026-08-10 — 地图先选后载、导入初始状态与默认真机 Run 修复

- 首页“新建扫描”和菜单“开始门店扫描”不再直接构造配置页并自动加载 registry 第一张地图，而是先打开 `MobileMapLibraryViewController(purpose: .selectForScan)`。选择页只读轻量 registry，提供明确的“导入新地图”按钮；用户点击某条记录后才创建 `MobileScanSetupViewController(selectedMap:)` 并完整验证/加载该 exact package。
- 配置页的地图参数改为 immutable required initializer，删除内部地图 picker、registry reload 和切换回调。因此起点配置过程中不能因滑动 picker 反复触发大包验证；需要换图时使用系统 Back 返回轻量选择页。
- 导入页初始隐藏百分比、进度条和计时。点击“选择文件并导入”只打开系统 picker；收到文件并进入 `stagingMapSource` 后才显示进度 UI，取消 picker 时继续保持隐藏。
- 共享 `RTABMapApp` scheme 的默认 Launch/Run 从 Debug 改为 Release，普通 Xcode Run 会执行严格 build-identity 生成/验证并可进入扫描。Test/Analyze 和手动 Debug 构建仍为 Debug，仍删除身份文件并 fail closed；没有放宽 `MobileBuildIdentity.isUsable`，也没有加入 `--allow-dirty`。`RTABMapApp-QualifiedDevice` 继续保留。
- 聚焦 UX/yaw/build-identity 合同扩展为 29 项，新增先选后载、配置页无 picker、导入进度延迟显示和默认 Run Release 回归。
- 当前修改已通过 unsigned generic iPhoneOS Debug 全量编译/链接，且日志确认 Debug 身份被移除；提交后默认 `RTABMapApp` Release 全量编译/链接也通过，日志包含 `build identity verified` 和 `BUILD SUCCEEDED`。这仍不替代真机安装、相机/LiDAR 或现场扫描验证。

## 2026-08-10 — 全手机扫描统一 UX 与启动事务阻断级收口

- 首页大型“新建扫描”和菜单“开始门店扫描”统一进入同一套全手机流程；本日后续的“地图先选后载”修复将其入口调整为先打开轻量选择页，再以选定地图创建同一个 `MobileScanSetupViewController`。“门店地图”统一管理手机编译的 XLSX/CSV/JSON 和 PC production-validator 通过的 v2 prior-map package。两种来源最终复用同一个 `MobileMapLibrary`、配置页、`MobileOnlyWorkflowCoordinator` 和 `ViewController.startMobileOnlyScan()`，旧 `PriorMapWizardViewController` 不再从生产入口可达。自由扫描和原始数据录制降级到“实验与兼容工具”。
- 卡顿根因是 UI 线程进入/返回时逐包执行完整 manifest/JSON/PNG/距离场校验，并在开始扫描时重复构造 package/localizer、创建会话和打开 native SQLite；MapCase02 单次完整包校验的本机 host 证据约为 9.36 秒。普通地图库进入现在只读轻量 registry，完整刷新、provider 复制/fsync、精确 package 加载、localizer 构造、会话/数据库准备均转入后台串行队列；主线程只执行短 UIKit、ARSession、CameraMobile 和状态切换事务。
- 统一配置页支持 1×–8× 捏合缩放、单指平移、双击放大/复位、点击选点、0.1/0.5/1.0 m 方向键微调，以及东/北/西/南和左右 15° 离散朝向；删除横向 yaw slider。首页直达时显示 Close，从地图库 push 时保留系统 Back/返回手势，离开页面会取消 queued/running 启动。
- 手机地图编译页面在 provider 返回文件并进入安全暂存后，显示严格解析、身份/元素校验、道路图、逐楼层/逐分辨率距离场、空间索引、工件写入、逐楼层预览、验证报告、manifest、production self-validation、fsync、不可变提交和 registry 注册等真实阶段，并持续显示百分比和用时；文件选择前保持隐藏。完成页显示 store ID、prior-map ID、package/canonical SHA、楼层、源/有效/忽略元素和 warning 统计。
- 新增共享 `RTABMapApp-QualifiedDevice` scheme：Run/Launch 使用 Release，Test/Analyze 使用 Debug，Profile/Archive 使用 Release；手动 Debug 继续故意不携带 build identity 并 fail closed。本日后续修复也把普通 `RTABMapApp` 的默认 Run/Launch 改为 Release，使两者都可从已提交且 tracked tree 干净的版本生成严格身份；不允许 `--allow-dirty` 或放宽 `MobileBuildIdentity.isUsable`。
- 扫描启动改为可回滚 durable transaction：相机权限在 workflow commit 前完成；session-scoped streaming DB 跳过旧 `Documents/rtabmap.tmp.db` 异步 recovery continuation；host 启动成功后以 `O_EXCL|O_NOFOLLOW`、完整写、文件/目录 fsync 持久化 receipt，再以 workflow context v3 绑定 session、segment、database、map/store 和 receipt SHA。任一步失败或取消都会停止 CameraMobile/ARSession/mapping/clock、清 prior-map state、让 native core 脱离失败数据库并释放未提交会话，不能留下无 receipt 的“幽灵扫描”。
- 地图库复审关闭 registry/manifest 全身份绑定、rebuild 单快照、正式 package descriptor/no-follow freeze 和异常 symlink 外部目标权限四组 P1。最终专项复审为 `P0=0 / P1=0`；本日后续新增两项 UI/build-identity 合同后，聚焦 UX/build-identity/yaw 合同为 29/29 PASS；Swift 核心长方法 1/1 PASS（1233.541 s），四张真实 XLSX 手机地图库链路 4/4 PASS，PC production validator 4/4 PASS，此前 unsigned iphoneos Debug build PASS。真机重新安装、干净 Release 设备运行、完整 discover、exact-final-SHA、Device Lab、LiDAR/现场矩阵仍未关闭，整体保持 **REJECTED / NO-GO / developer smoke only**。

- 修复真机 XLSX 地图导入的 `不安全的地图标识` 阻断：Swift/PC 新生成 `prior_map_id` 统一为先过滤原始 ASCII、再 ASCII lowercase、slug 最长 115、最终 ID 最长 128；同时拒绝 APFS 上旧 uppercase 目录与新 lowercase ID 的 case-fold 别名。旧 uppercase v2 包只保留只读 integrity 兼容，不自动改写 exact ID/SHA。
- `map 2.xlsx` 与正式 MapCase02 source SHA 完全相同；修复后 MapCase02 ID 为 `piaseczno-5ddfac7dc439`、Swift package `c6b6b2c00690998cfa9517374b9385f857cb3ee0efcbe3663f63ee76fee87959`、PC package `41332d093e652ec2de94f0f86b8f15107cd6f67f3b2e5ddec1c0685ab4d7d3be`。2026-08-10 修复手机 CoreGraphics 预览的重复 Y 翻转，使预览、选点和 canonical 障碍物几何同向；该修复只改变 Swift preview/package digest。Swift validation report 新增并强校验 road graph `node_count`/`edge_count`；Swift/Python 同步严格拒绝 v1/v2 manifest/report 计数中的 bool/integral-float、非数组 warnings/malformed rows，legacy v1 的 element statistics 与 visible/hidden 也重新派生，Python 外层测试直接以 production validator 验证 Swift 包。新增 `--xlsx-library-smoke`，MapCase02、TianHong、北京昌平与 Kohl's 四张真实地图全部通过 compile/integrity/install/register/list/exact-read。
- Swift 正式套件和 Python MapCase02 回归现在直接绑定 source/canonical/Swift package/PC package/PC preview frozen SHA，消除“编译结果只与自身 digest 比较”的假绿。旧 uppercase v2 仅在显式 diagnostic-only 模式保留只读完整性结果；普通 iOS/PC validator、旧向导和离线定位默认拒绝。

- I10 exact-SHA run [`31307753672`](https://github.com/mcjiansheng/MarketScanner/actions/runs/31307753672) 在 `8f0e730d92773eea2ab58f56742d901ac02eead4` 为 7/8：七个非 Apple required jobs、完整 macOS host、SwiftPM cold resolve、Xcode metadata 与 200k tag-evidence RSS `794,099,712 < 805,306,368` bytes 均 PASS；唯一失败是 iphoneos cold dependency 的 RTAB-Map configure 无法自动发现位于 `rtabmap/prebuild/bin/` 的宿主 `rtabmap-res_tool`，所以 simulator/device clean link skipped，未冻结。
- I11 `37e6ed8c4afa00202693cd56919aea78fd4c7af5` / G11 `7eef33e` 在 host prebuild 后验证 resource tool 可执行，并通过 `RTABMAP_RES_TOOL` 显式绑定给 iOS cross-compile；全新 host tool build、全新 iphoneos CMake configure、focused 22/22、Map Studio 109/109、静态合同与独立复审均 PASS（`P0=0 / P1=0`）。Release 优化标注与工具执行 smoke 作为 P2 记录；新的 final exact-SHA 8/8 前不冻结。

## 2026-08-09 — MapCase02 标准工作簿格式/几何阻断级收口

- I9 validation run [`31305157950`](https://github.com/mcjiansheng/MarketScanner/actions/runs/31305157950) 在 `b22bd8878fcf001b38cca275b8eddcc6e48974e8` 再次为 7/8：RSS `792,576,000 < 805,306,368` bytes，I8/I9 边界均已通过；随后 mode-restore replacement 用例得到实际 `0555` 而非期望 replacement `0755`，说明两步 `RENAME_EXCL` fixture 没有完成替换却被通用退出码 19 掩盖，Apple build 仍未执行。
- I10 `2b111d351173b80575d37229ad55c13b42d8c3f9` / G10 `f7cad97` 将 mode-restore、map-root、pending-root 和 embedded-diagnostic 的测试替换统一为同卷 `RENAME_SWAP`，并绑定 source/displaced mode、inode 与 payload；map-root swap 失败使用专用退出码 95，不能假冒生产拒绝。最终源码 204 次聚焦执行、完整 Python 外层长方法 1/1（973.769 s，tag peak RSS `688,111,616` bytes）、默认 host 和两轮独立复审均 PASS（`P0=0 / P1=0`）。新的 final exact-SHA 全绿前仍不冻结。
- I8 validation run [`31303500822`](https://github.com/mcjiansheng/MarketScanner/actions/runs/31303500822) 的 RSS `793,296,896 < 805,306,368` bytes 且原退出 94 fixture 已通过；随后独立 tombstone source-replacement fixture 的两步 `RENAME_EXCL` 以 91 退出，Apple build 仍未执行，run 为 7/8、未冻结。
- I9 `5c576dc0818f0908ef05ac1333b189aa9743d211` 将该 fixture 改为同 parent/volume `RENAME_SWAP`：durable tombstone 后一次原子交换 source 与 byte-identical clone，原 inode 直接保留在 `tombstone-original-*`。swap 失败仍退出 91；精确边界 50/50、默认 host 与独立复审均 PASS（`P0=0 / P1=0`）。进一步显式绑定交换前后双方 inode/payload bytes 仅登记 TODO。
- replacement exact-SHA run [`31301693439`](https://github.com/mcjiansheng/MarketScanner/actions/runs/31301693439) 的 200k tag-evidence RSS 已以 `790,839,296 < 805,306,368` bytes 通过；随后 Map quarantine delayed-replacement fixture 因固定 15 ms 调度错位 `_exit(94)`，macOS/iOS job 失败且 Apple build 未执行，run 仍为 7/8、未冻结。
- I8 `0a3606ecd4e06086ea95c0ab99d92f4e80fcc2dc` 在 payload/diagnostic descriptor 已 `O_NOFOLLOW` 打开并完成 fstat/expected identity 绑定之后、读取之前提供默认 `nil` 的 host observer；fixture 在该同步点确定性替换，production 仍沿原 FD 读取并执行 post-read path/inode/root sweep。两个场景 20 次重复与默认 host suite PASS，独立复审 `P0=0 / P1=0`；128 MiB fixture 缩小及精确 rejection category 断言仅登记 TODO。
- validation HEAD `770d94b078a0dd94653b9d6b33576890f88f7296` 的 exact-SHA run [`31299358502`](https://github.com/mcjiansheng/MarketScanner/actions/runs/31299358502) 为 7/8：除 macOS/iOS 200k tag-evidence RSS 外全部 required jobs PASS；失败值 `812,892,160` bytes，比 768 MiB 门高 `7,585,792` bytes，因此未创建冻结标签。
- RSS blocker implementation I7 `cbba284ad1b0694f5302ec3abbb9a446d9d3a970` 删除 burst frame dictionary value 中重复 observation ID，并把已严格验证的 view/tracking 有限域压缩为单射 `UInt8` code；observation key lookup、所有数值/身份 exact-match、duplicate/already-consumed 与 remaining-frame fail-closed 合同保持不变。新增全域 round-trip/mismatch/unknown 回归；本地同一 200k 规模为 `629,735,424` bytes，低于门约 167.4 MiB，独立复审 `P0=0 / P1=0`。replacement final exact-SHA 全绿前仍不冻结。
- 正式 XLSX 以 `Basic Info + Element Info` 为权威，`Shelf Info` 仅审计；冻结 top-left anchor/pivot、生产角色集合、active/ignored 统计和 100,000 元素上限。
- Swift/PC 同步关闭 relationship/worksheet alias、External/歧义 target、XML root/namespace 伪 authority、row/cell 引用、shared-string/boolean/公式、单元格大小、严格 JSON 数值与 duplicate element ID 的 fail-open/crash 路径；workbook sheet/relationship 各限制 4096 并使用线性索引。
- prior-map v2 完整性从权威 active elements 重建 canonical identity、road graph、spatial index、distance fields 和 shelves-v2 segment；六字段 bounds、可选 `center_m/yaw_rad` 严格 finite 数值与 stable business identity uniqueness 均 fail closed。距离场在任何分配前执行 20k 单维、8m 单层、16m 包总 cells 上限与 RLE row budget。
- `mapcase02.xlsx` 冻结结果：源 1838、active 1630、shelf 1301、fixed 329、road 0、presentation 208、active 越界 0；canonical `5ddfac…2db` 与 PC preview `d0c02b…a18` 未漂移；canonical lowercase ID 与跨端 validation report 修复使 Swift package 更新为 `8d3564…b1b84`，PC package 为 `41332d…d3be`。
- 最终独立只读复审为 `P0=0 / P1=0`；低影响 parity/UX/visual/scale 项登记在 [`MAPCASE02_TODO.md`](MAPCASE02_TODO.md)。整体仍为 **REJECTED / NO-GO / developer smoke only**，J-04 仍为 **BLOCKER / NOT CLOSED**。

## 2026-08-09 — ESL Barcode Capture / Shelf Confirmation 阻断级收口

- 核心 implementation I3：`fdcc5c87005a0128e0654eb43b1364898edd8f5d`；G3：`2a0a808554b9183cd76420b01135d5f6cdf7d38d`；证据 E3：`744cbb386403dbb548f4c27bf8988e85fa8c2c7e`；V3：`7dd42beac00a2144712503662147e77fee679ffc`。V3 exact-HEAD run `31276419986` 的 P0 job 暴露 Map Studio v1 manifest fixture 未同步新 Recovery/version/source-name 合同；生产 validator 未放宽。fixture 修复为 I4 `ec1fe96fc676c03514e591c40226112cde30fe76`，G4 `17871d839834487c777824c062980f3322521cdb` 已重新绑定 implementation；P0 四项与 Map Studio 106/106 本地 PASS，E4/V4 随后触发 run `31276999280`。
- V4 exact-HEAD run `31276999280@8ba2f697a8213a1bcd4bf6fb7197d155cb09b865` 为 7/8：P0、SHA/wave、ABI、Ubuntu/Windows native clean build、Ubuntu/Windows Python 均 PASS，macOS/iOS host contract 因固定 350 ms 等待未观察到 utility-queue §18 thermal sample 而 FAIL。I5 `4d78d4646c01fe50bc0ac07eb2266879a24348db` / G5 `d2eb9e2cb9b349179c410205d8eb9f44c2c30188` 改为真实 timer 的 2 秒有界 liveness 轮询，并让 crash-worker 不再重复整套 E2E；完整长 host 方法进一步发现并关闭 Result removal tombstone replacement 可在后续恢复中重新取得 canonical authority 的 P1，mismatch 现在永久进入 `.result-publish-intent-conflict-*`。本地长方法 943.159 s PASS，第二轮独立复审为 `P0=0 / P1=0`；其 E5/V5 后继已完成，当前 exact-HEAD 资格由后续 I6/G6/E6/V6 链继续承接。
- ESL follow-up implementation I6 `396097ea474be2e1155098cd709d1edfa9064a83` 由 G6 `f65dbb0a3d0337ca926f4142489555d409089939` 绑定。独立复审先发现固定串行 Vision worker 可被一个 hung `perform()` 永久占用，以及 aiming/candidate 缺单请求 deadline；实现加入 1 秒 request deadline、两 lane bounded executor、`VNRequest.cancel()`、quarantine 和 capacity fuse。最终复审又发现并关闭 callback/evidence timeout generation-only restart 误取消 fresh B，以及 manifest v3 误强制 legacy tag v1 使用 burst authority两个 P1；最终结论 `P0=0 / P1=0`。
- 旧 one-shot Barcode action 改为 ARFrame-only Capture Mode：camera-only Metal preview、真实四方向 Vision ROI、8 Hz one-in-flight、2-frame candidate lock、3-frame minimum/4-frame target 和 2 秒 minimum fallback；不创建第二相机，不暂停 ARSession、RTAB-Map、连续数据库、Clock、Pose、node creation 或 prior-map localization。
- 货架确认改为 dedicated sheet + 局部小地图；只有 3 个独立可靠 frame 对同一 `shelfSegmentId + side` 达成 quorum 才能确认。替代货架选择绑定精确 segment+side，算法证据与 `USER_CONFIRMED/USER_OVERRIDDEN` 用户证据 additive 分离，绝不反写定位数学。
- 新增 strict `tag_observation_bursts.jsonl`、localized tag v2 与 session input manifest v3；iOS finalization 和 PC 对 observation/burst/frame/payload/symbology 做双向 exact binding，localized v2 tag 还必须匹配 verified burst 的 exact observation set、payload 和 symbology。burst sequence 必须为正且严格递增，duplicate/decreasing 以稳定 blocker fail closed；durable orphan 立即造成 sticky required-write failure。
- confirmation persistence 使用锁保护的 immutable map/session authority、单次 commit claim 和同一 session writer 事务内的 workflow/tracking/map/floor/capture/burst 身份复核，关闭 cancel/clear 与后台持久化之间的 TOCTOU/data-race。共享 session admission gate 关闭 finalization 后的新 writer 并等待 pre-admitted writer；inner writer 不再二次误拒。prior-map sentinel 后普通 ARFrame/Recovery 被双重 gate 拦截，ordinary/terminal Recovery 的 `allowDuringFinalization` 权限已分离。
- ESL audit 冻结 generation→tracking identity，并通过 active-only append API 只写既有 `segment_0001`；迟到/未知 generation 不回退到新 session，普通 audit 在 finalization 后拒绝，scan-stop 自有 audit 只获得窄范围 override，关闭空 successor session 与跨会话污染。
- PC 对一致、冲突和不可用证据分别输出 `NO_CONFLICT`、`USER_CONFIRMATION_CONFLICT`、`OFFLINE_ASSOCIATION_UNAVAILABLE`；所有 early-error 分支保留用户选择并稳定进入 review/rescan。共享 manifest validator 强制严格 integer/version/Recovery binding、case-insensitive filename uniqueness、source basename/source-manifest cross-binding；source DB hardlink、非空 WAL/journal 在 manifest/snapshot/verified-copy 全链拒绝。
- 聚焦验证为 ESL capture/finalization Swift host PASS、ARFrame-only source contract 1/1 PASS、Stage-3 82/82、localized-output-store 28/28、session snapshot 10/10，合计 120/120 PASS。I5 的历史长方法 `IOSCoreContractTests.test_swift_workflow_state_and_se2_projection` 为 943.159 s PASS；当前 I6 未重新完整运行该长方法。Xcode 已编译当前 App Swift module，但本机完整 simulator build 仍在 native C++ `Eigen/Core` 缺失处 FAIL；不能写本机 clean build PASS。
- 非阻断 UI/性能增强和真机/现场矩阵登记在 [`ESL_CAPTURE_TODO.md`](ESL_CAPTURE_TODO.md)。MapCase02 与坐标转换未修改。整体仍为 **REJECTED / NO-GO / developer smoke only**，J-04 仍是 **BLOCKER / NOT CLOSED**；Apple clean link、LiDAR 真机、Device Lab、Sam field 和 exact-SHA CI 均未据此宣称通过。

## 2026-08-02 — P7R2 Sam 全局对齐修复

- 在线多候选 tracker 改为跟踪固定的 `T_map_from_arkit = T_candidate_map × inverse(T_arkit)`，修复手机转弯时 body-local translation 旋转并错误拆分 hypothesis 的问题。
- 平滑后的全局变换用于重新投影当前 ARKit 位姿；局部/恢复安全门和单步限幅集中到纯函数合同。可靠闭环只开启恢复窗口，人工确认清空 tracker，原始 ARKit/RTAB-Map 数据不改写。
- 删除旧 `PriorMapCorrectionMath` 和未接线 `PriorMapTemporalCorrectionGate`；trace v1 增加可选全局对齐、track、cost、reason 和 tracker 耗时字段。
- Swift executable 新增 T1—T11、蛇形转弯、相邻通道、遮挡与恢复边界回归；最终 exact-SHA CI、修复版 Sam 真机重扫和人工控制点验收仍待执行。

## 2026-08-02 — 外置盘先验地图导入兼容

- PC 地图包清单生成与验证、iOS 地图包完整性验证统一忽略 macOS 外置盘生成的 `._*` AppleDouble 旁车和 `.DS_Store`；其余非清单普通文件仍保持 fail closed，避免二进制 Finder 元数据被误读为 UTF-8 JSON。

## 2026-07-28 — RepairV2 W2 审查闭环

- W2R 提交前复核真实 required evidence bundle；丢失、空、半行、链接、身份/数量/state 水位不符都提交为 `finalized=false/invalid`，不再创建空 required 文件掩盖丢失。
- checkpoint cleanup 增加 no-follow、regular-file/文件身份、path-component containment、expected evidence CAS、HTTP 409 和 authorized/completed/failed 审计；Map Studio 必须检查后显式确认。
- sidecar 原子 writer 改为同目录 temp/write/synchronize/rename 并覆盖三阶段故障；合同明确只保证原子可见和进程恢复，不宣称未验证的断电持久化。外部复制生成验证 receipt 并默认保留本地副本。
- finalization completion 从 Bool 改为明确 disposition，Foundation effect planner 与 ViewController 共用四种副作用合同，防止 terminal/ineligible 被调用者误当成普通成功。
- 将 `metadata.json(finalized=true)` 明确为不可逆提交点：metadata 写入失败仍属提交前，可恢复录制；提交后 checkpoint 删除失败进入 `finalizedNeedsCleanup` 终态，关闭数据库且绝不恢复相机/映射。
- 新增 Foundation-only `SupermarketFinalizationCore.swift` 和可注入 writer 运行时测试，实际执行 metadata/checkpoint/trace/constraint/state 故障与部分成功路径，不再只依赖源码字符串契约。
- 手机启动时只对 finalized、同 tracking identity 且 checkpoint 时间不晚于提交时间的会话提供人工清理；Map Studio 增加同等严格、默认不自动调用的显式恢复 API，并在删除前写授权审计。
- 首个必需定位证据写失败后停止新的先验地图修正、人工校正和价签最终确认，结束前持续保留原始 RTAB-Map 录制；用户结束时保存 `finalized=false` 恢复包并进入终态，不会回到永远无法恢复资格的 prior-map 录制。
- 外部复制验证升级为逐文件相对路径、大小和 SHA-256，复制后再次复核源目录，检测同大小内容变化后保留本地副本。
- 价签关联审计明确完整搜索范围；`auto_confirmed` 必须同时记录范围内候选搜索完成。求解器统一描述为 component-wise `bounded_correction_field`，不再称 banded SE(2) optimizer。
- 旧根目录审查/Agent Prompt 移入历史归档并声明基线；当前审查入口改为 `reviews/CURRENT_REVIEW.md`。

## 2026-07-27 — RepairV2 安全闭环

- 价签 observation 严格绑定真实 node/frame time 和地图身份；缺失/歧义证据不再回退 node 0，PC 使用 raw map position 做 SE(2) 传播。
- 人工重定位事件升级为 v3，分离 wall clock 与 ARFrame time；native 在同一锁域原子冻结 node ID/stamp、timebase offset 和 generation。缺少、过期或不一致快照会拒绝事件，不再使用 nullable node 或 frame timestamp fallback；PC 仍兼容严格 v2 输入并拒绝 legacy v1。
- 定位 trace/constraint/state/manual 写入改为 throwing I/O 和结构化结果；失败计数粘性进入 `captureHealth`，HUD 持续红色告警。`metadata.json` 最后写入，证据不完整时保留 checkpoint、写 `finalized=false`/eligibility blockers，PC fail closed。
- 本地化输出改为 POSIX/Windows 跨进程锁保护的 staging、不可变 version、逐次复核的文件 hash 清单和单提交点 current/published 原子指针；输入身份由 `session_input_manifest.json` 绑定，绝对路径按 identity 隔离到 `localized/local_inputs/`。发布/撤销只推进 published，失败、篡改或无效诊断版本不会覆盖旧 current。
- `manual_edits.json` 升级 v4；强制 version/revision CAS、HTTP 409、服务端 old value/UTC/UUID、字段/范围/物理关联校验和 undo/redo audit。
- 为五类 JSONL 和最终价签定义严格输入契约，拒绝非法 UTF‑8、非有限数字、错误身份/版本/时间、业务字段缺失、超限和重复 ID；legacy 人工事件仅审计并阻断 review，最终价签与 observation 交叉核对商品、码制和原始位置。
- 节点覆盖改为 source/optimized SQLite Node 与导出轨迹三方审计；当前求解器降级命名为 `bounded_correction_field`，新增残差诊断、局部平移/yaw 形变和 review/publish blockers；完整相对 SE(2) 因子图与现场验收完成前硬阻断 published。
- 修正 `ARFrame.timestamp` 与 `CameraMobile` epoch `Node.stamp` 的基准差，并将 offset 改为原子读写；trace/constraint/state/tag/manual 均保存可复算的 raw/node timebase/offset。
- 增加 Linux/macOS/Windows MarketScanner CI、Windows durable move、版本/指针 fsync 故障注入、双线程客户端同基准 CAS 冲突、409、发布门、native ABI 与 generic iOS arm64 构建回归。正式真机/现场验收仍未执行。

## 2026-07-25 — 综合审查整改与阶段三

- 地图包新增规范 `package_manifest.json`，PC/iOS 校验逐文件 SHA‑256、长度、格式/版本、文件集合及楼层/bounds/子集/道路/索引/验证报告关系。
- 道路点按完整折线弧长排序；货架 `A/B` 和 offset 对方形、旋转起点/反转 ring 保持稳定，柜台使用全部 `E##` 边。
- 价签深度改为内缩密集 ROI，输出样本/内点/中值/MAD/平面残差/法向；歧义层和证据不足降级。快照加入 250/600 ms 与版本门。
- 结构几何/安全拒绝立即重置时序校正门；扫描结束的 queue drain 移到后台。
- HUD 增加有界近期轨迹、价签/路线层，业务信息与折叠诊断分离；丢失超局部窗口明确要求人工重定位。
- 新增阶段三 `offline_localization.py`：RTAB‑Map 重处理之后运行鲁棒带状 SE(2) 派生修正、近道路区域/方向低权重软约束、约束拒绝、价签重关联、质量门禁与确定性导出。
- Map Studio 新增“先验地图会话优化”、人工锚点/禁用约束/区间通道/价签编辑与批准，以及 hash 保护的 undo/redo 重放。
- 复核区新增先验结构、在线/RTAB‑Map/离线轨迹和价签联动画布，以及状态/货架筛选和问题带入编辑。
- 质量报告新增 weak/lost 持续时长与区间；人工价签编辑在自动重关联之后重放，防止重新处理静默覆盖人工结果。
- 新增 `USER_GUIDE.md`，覆盖手机/PC 双模式、弱/丢失定位、价签复核、备份和失败恢复。
- 正式 LiDAR 超市现场验收和本轮独立复审仍未执行，不把自动测试表述为生产批准。

## 2026-07-24 — 阶段二

- 根据综合代码审查改为全搜索窗多盆地传播和真实次佳唯一性；缺少第二候选时保守拒绝，新增周期结构负例。
- 时序门控改为比较 `best ⊖ raw` 校正变换；Python 回放同步实现两帧门控、gain、锚点更新、状态迟滞和 tracking 恢复。
- 解码固定结构；货架/柜台可关联，柱体和全部结构参与最近遮挡判断，被其他结构挡住时不预选远端结构。
- Vision 使用捕获时对齐快照/版本和四方向 ROI；楼面估计加入法向、残差、内点率和时序稳定性。
- finalization 开始即失效并有界 drain 定位任务；定位写入校验 tracking session/finalizing 且不再隐式创建会话。
- 地图包新增三层确定性结构距离场、RLE、逐层 SHA‑256 和 PC/iOS 完整性校验。
- iOS 新增有界跨帧深度结构提取、粗中细 Top‑K 距离场匹配、状态滞回与小幅地图锚点修正。
- 新增用户触发的 ARFrame Vision 条码识别、同帧深度/MAD 测量、货架射线回退和货架侧面/offset/高度关联。
- 新增 constraint/state/tag observation/localized tag sidecar；weak/lost 不自动确认，最终价签由用户确认。
- HUD 显示结构匹配证据、耗时和扫码入口；PC inspect 提供有界审计汇总。
- 新增动态干扰/错误初始化回放、货架关联边界测试和性能基线。
- NFC 继续保持暂停；自由扫描和连续单库格式不变。

## 2026-07-24 — 阶段一

- 根据独立代码审查修正 ARKit 水平坐标/yaw 与地图/UI 约定，并增加方向金标测试。
- 校验器扩展为全 JSON/PNG 解析和跨文件一致性校验，补充损坏包负向测试。
- 道路边加入空间索引，iOS 使用附近候选并增加 in-flight 丢帧门控。
- iOS 地图缓存改为临时校验后原子替换；设备检查不再把未启动的 ARKit tracking 写成成功。
- 回放的旋转漂移现在同时影响 XY 轨迹并输出 yaw 误差。
- 明确一次扫描只绑定一个楼层；楼层内少量竖直位移忽略于二维先验定位、保留于原始三维数据；新增逐楼层预览。
- 新增 dependency-free XLSX 先验地图转换、校验和 PNG 渲染。
- 定义 version 1 地图包、统一米制 SE(2)、道路图和空间索引。
- Map Studio 新增先验地图异步导入、校验、统计和缩放预览。
- iOS 新增自由扫描/已有地图辅助扫描双模式和五步向导。
- 新增 ARKit 初始投影、道路软约束、候选/置信状态 HUD 和人工确认审计。
- 新增 localization trace、manual event 和 metadata/checkpoint 字段。
- 新增 synthetic/trajectory replay 及阶段一测试。
- 保留 `scanMode=continuous_streaming`，新增 `workflowMode`，确保旧连续单库流程兼容。
- NFC 仍保持暂停；未加入 LiDAR 自动匹配或价签扫码。
