# 地图辅助定位阶段一至阶段三测试计划

> 文档状态：**当前有效**。最后核对日期：2026-09-05。

## 2026-09-05 周期强制校准与自动分卷（需求 §14 矩阵，仅覆盖阶段 1）

自动化（已执行并 PASS）：

1. **时间与提醒**：`tools/Qualification/swift-host-tests/main.swift` 的 1799/1800/1801 秒边界（1799 为 warning 且普通采集仍开、1800 立即关门）、Timer 延迟不额外给时间、提醒阶梯 5 min/1 min/30 s 各触发一次且不重复、时钟回拨记为异常且累计值不倒退、重启恢复累计值（恢复 1200 s 后再走 600 s 即到期，绝不会重新获得 30 分钟）。
2. **强制门**：维护门内 `ordinaryNodeWrites / priceTagConfirmation / localizationCorrection` 全为 false，`oneShotAnchorNode` 仍为 true；`finalizingUnit / preparingNextUnit / terminalRecovery / completed` 为全关闭。
3. **状态机**：`scanning` 不能直达 `finalizingUnit`；空 boundary id 不能开启封口；锚点失败回到 gate；可恢复的 unit finalization/next-unit prepare 只能通过带 durable trigger + boundary id 的显式重试边，且普通 admission 始终关闭；`operator_stop / safety_stop` 不允许进入 `preparingNextUnit`；首卷必须从 1 开始，`completeNextUnitPreparation` 的 index 必须为 `current+1`。
4. **安全优先级**：证据/数据库写失败、可用空间 <1 GiB、thermal critical 一律 `terminalRecovery` 且不开新卷；8 GiB 仅告警；安全门优先于时间与字节门。
5. **字节门**：≥3 样本估计增长并预测未来 60 s；`softMaxUnitBytes=nil`（真机基线未冻结）时字节门不激活，不得宣称存在严格字节上限。
6. **恢复幂等**：`finalizingUnit` 重试同 index、pending U0002 的 `preparingNextUnit` 仍重试 U0002、`finalized=false` 直判 terminal、无 checkpoint 目录一律隔离为 orphan、重复输入产生同一 idempotency key 与同一动作；未知 state、缺/未知 trigger、负 elapsed、缺当前 unit/DB/live checkpoint 一律人工复核，不自动续采。
7. **PC 校验**：`tools/SupermarketMapStudio/tests/test_mission_validation.py` **33/33 PASS**——除原有缺卷/乱序/重复/断链/单边/链接/逃逸/运行中/legacy 之外，新增伪 SQLite + 缺 sidecar、foreign mission、`free_mapping`、声明路径逃逸、缺摘要、unverified/deny manifest 与 live checkpoint 并存、boundary 错类型/负 generation/错误 tracking/坏 hash、额外非相邻完整 boundary；全部 `publish_permitted=false`。
8. **原子与不可变提交**：write/flush/commit 失败不留可误认的半成品；不完整 boundary、phantom finalized unit、缺 required sidecar、top-level mission identity 漂移、第二次 manifest 写入全部拒绝；文件 SHA 校验前后复核 inode/size/mtime/link identity，极端字节预测饱和而不 trap。
9. **schema/工程合同**：feature flag 关闭时 engine 不开门、不发提醒、恢复规划不产生 mission 动作；开启后 engine 状态写回 checkpoint 并清除已恢复错误。`ScanLiveCheckpoint` 的 10 个 mission 字段必须参与 synthesized decoding，active duration 写 metadata 前必须清洗；Xcode target membership 审计确保两个周期维护源码真实进入 RTABMapApp Sources。

本轮汇总：Swift host **173 断言 PASS**、mission validator **33/33 PASS**、Map Studio **181/181 PASS**、Qualification **58/58 PASS**。

已执行 unsigned generic iPhoneOS Debug 全量编译/链接，证明修正后的两个周期维护源码进入生产 target；该 dirty Debug bundle 仅为编译证据，`production_eligible=false`。尚未执行（功能未上线，按 §14.2/§14.3 必须补齐后才能声称完成）：clean Release exact-SHA、签名安装/真机运行、iOS HUD/提醒/维护页手测、Dynamic Type/VoiceOver、真机 30 分钟/65 分钟/2 小时、4 单元 3 边界、20 次边界校准、热/低磁盘/强杀/外部存储矩阵、PC 处理编排与回放。

## 2026-09-03 资源门重锚定（取代 768 MiB 绝对门）

本文及更早条目中所有“768 MiB 门”均指已被取代的 tag-evidence host RSS 绝对门：自本日起该绝对门**不再作为流水线失败条件**。规模压力测试（300,000 finalization / 1,728,000 trace / 400,000 tag evidence）继续执行，继续报告真实输入字节、wall/CPU 耗时和峰值 RSS，判定改为：

1. **硬门：真机不闪退/不 OOM**，由 `performance_samples.jsonl`（内存轨迹）+ MetricKit（是否被系统杀）判定；已有一条 39.3 min 真机证据（进程峰值 1551 MB、系统可用最低 4592 MB、无崩溃，见 `IMPLEMENTATION_STATUS.md` 2026-09-03 条目）；
2. **增长预警：与上一发布基线同规模峰值对比，增幅 >20% 必须给出原因说明**，不自动 fail；
3. `localization_constraints.jsonl` 的 768 MiB **文件**上限（解析器防恶意输入）保持不变，与内存门无关；
4. `tools/PriorMap/tests/test_prior_map.py` 中 `test_mobile_scale_evidence_streaming` 的测试断言已同步落地：废除了 `assertLess(..., 768 * 1024 * 1024)` 绝对断言，改为对比 15b339d 基线（747,192,320 字节）超幅 20% 时发出预警，测试判定与本规范完全统一。

外部必测项中“C-1/C-2/C-3 Replay Pareto”相应变为：C-1/C-2 回放拟合（见 `C1_C2_JUDGMENT_WINDOW_DESIGN_2026-09-03.md`）；原 C-3 时长标定废弃，改为 C-3a 地图锚定遮挡分类的现场复核（无时长参数）。

## 2026-08-19 ESL 现场效率与连续性回归

自动化必须证明：非有限 depth-plane residual/normal 被转换为缺失且 JSON 可编码；任何 observation 的 NaN/Infinity 在 writer 前被拒绝；`deferEvidenceUntilUsableMeasurement` 只释放当前 frame slot、保留同一 capture ID 和已接受帧，后续有限 frame 可继续。磁盘写失败、JSONL framing、会话/地图身份和 observation→burst orphan 仍必须进入原有粘性 fail-closed。EAN-13、URL QR 应分类为疑似商品码；山姆 9 位 Code128 `981115951` 仍兼容。源码合同必须证明 App Intent/Shortcut 只调用现有入口，不包含 `MPVolumeView`、`outputVolume` 或第二路 `AVCaptureSession`。

签名真机必须覆盖：Action Button 从前台/后台连续触发 30 次；25/35/45/60 cm、强弱光、反光、倾斜、模糊恢复；商品正面 EAN/QR 与实际 ESL Code128 的提示/确认；连续扫描至少 5 个通道且数据库仍为单一 `segment_0001`；安全注入非有限 measurement frame 后下一帧继续，同时 `tag_observation_numeric_evidence_rejected` 不增加 required writer failure；再注入真实 writer/framing 错误确认仍关闭发布门。传统静音拨片/音量键记录为平台不支持，不使用私有 API。真机矩阵完成前不得登记 Production GO。

## 2026-08-19 人工位置更新 fresh-node 超时回归

自动化必须证明人工位置提交经过完整 Swift/native bridge，并用单个 `ParamEvent` 同时请求 `RGBD/LinearUpdate=0`、`RGBD/AngularUpdate=0`、`Mem/RehearsalSimilarity=1.0`；配置恢复必须来自当前 authoritative mapping profile，不能硬编码旧值。pure admission 正反例覆盖：请求后新 node 且 delta≤1 秒通过；相同/更早 frame、请求时刻前的 node stamp、相同基线 node、未递增 stamp、delta>1 秒、node 0 和非有限值拒绝；无基线时也必须以 request node-time 为下界。成功、超时、取消、系统中断、prior-map unload、finalization 和重新开库必须清除请求作用域，durable append 仍先于 alignment CAS。

签名真机必须在手机静止、正常步行、1 Hz 和自适应 1.5–2 Hz、弱跟踪恢复、前后台/来电中断各场景执行；连续 20 次“确认当前位置/重新选择位置”不应要求晃动手机，核对每次请求到新 node 的延迟、DB node 增量、参数恢复事件、manual v3 node/stamp/timebase/generation、UI 值、alignment 和 PC parser。故障注入要保留 6 秒确实无 detector node 的可恢复超时、审计写失败和 CAS 冲突。主机测试或 unsigned Xcode build 不能把本项登记为真机 PASS。

## 2026-08-15 通道/货架约束增量

自动化必须覆盖：manifest v5 四流空/非空水位、未知字段/重复键/半行/超限、epoch bridge 正反例、component/side/window 交叉引用、两侧法向与 0.5 m/10°/70% 门、非主导与主导动态样本、point+swept-segment 0.4 m 穿架、top1 低 margin 的非阻塞 `LOW_CONFIDENCE`、人工重定位恢复、corridor route 成功转正与任一自洽项失败降级、accepted loop 生成 shelf-face 因子并回溯整圈、以及价签 raw/optimized/shelf-projected 三坐标和采集侧长边投影。epoch bridge 组必须同时证明：同一 native Statistics 事件的 exact Link 被 node/epoch/component 绑定；两组 node-disjoint 且 transform 一致的 global/local-space edge 可形成 v3 bridge；单 edge、重复或反向 pair、共享任一端点、错误 component、冲突 transform、旧 v2 aggregate counter 和多 epoch 链缺任一相邻 bridge 均拒绝；无 bridge transition 仍以空数组追加并保持 final newline/单调水位。结果测试必须分别断言：Debug + `CALIBRATION_PENDING` 在其余真实质量门通过时生成 `COMPLETE/TEST` 和全部最终成果，但 `production_publish_permitted=false`；clean Release + pending calibration 仍不可生产发布；任一低置信、空坐标、穿架、degradation 或 graph failure 在 Debug 中也不得被测试 override 洗白。

当前主机执行结果：PriorMap **369/369（385.868 s）**、Map Studio **143/143（9.539 s）**、Qualification **30/30（13.062 s）**、生成合同 16 文件、native factor-graph/reprocess 增量构建、Python/JavaScript 语法、patch check 和 unsigned generic iphoneos Debug 全量编译/链接 PASS。规模门为 finalization 300,000 条 peak **13,303,808 bytes**，trace 1,728,000 条保留 172,801 / peak **59,179,008 bytes**，tag evidence 400,000 条接受 200,000 / peak **792,821,760 bytes**；tag evidence 仍低于 768 MiB 门，但余量约 12.5 MB。1280×720 真实浏览器检查通过；1024/390 的内置视口覆盖未生效，只能记为 CSS/源码合同覆盖，不能登记为真实视觉 PASS。

签名 iPhone 17 Pro Max 的候选打分/穿架审计 cadence、30 分钟与 2 小时热/内存/电量矩阵、C-1/C-2/C-3 Replay Pareto、Sam WM/LTM A/B、动态顾客/购物车和现场控制点仍是外部必测项；这些未完成前不得把 host/unsigned build 写成 Production GO。

### 2026-08-15 扫描前显示名称合并回归

自动化必须执行真实 `MarketScannerScanName` 核心代码，覆盖路径/控制字符过滤、空白折叠、完全无有效字符、64 字符上限、幂等、用户名称优先和默认名称回退；`PriorMapScanConfiguration` 必须证明无字段的旧编码仍可解码为 nil，命名配置可 Codable round-trip。源码合同还要证明配置页只在相机授权和地图身份完成后把解析名称送入唯一 `MobileScanConfiguration`，host 再次清洗，live checkpoint/final metadata/scan event 使用同一值，历史列表对 metadata 再清洗并保留会话目录副标题。

路径安全负例必须证明 `startNewSessionIfNeeded()`、`SupermarketSession-*`、SQLite、sidecar、snapshot、Result 和发布路径不消费 `scanDisplayName`；命名为空、只有非法字符或历史字段缺失均不得阻断启动、处理或导出。真机需手工覆盖中文/英文/emoji、64/65 字符、特殊字符、切换楼层后的默认 placeholder、键盘清空、连续两次同名扫描、Stop/finalization、历史列表、原始导出和 PC metadata 读取；host/Xcode 通过不能替代这一交互矩阵。

当前合并证据：命名 UX/source **25/25 PASS**、完整 PriorMap **331/331 PASS（376.662 s）**、Qualification **30/30 PASS（12.128 s）**、Map Studio **142/142 PASS（9.671 s）**、生成合同检查、Swift parse、patch check 和 unsigned generic iPhoneOS QualifiedDevice Debug 全量编译/链接 PASS。真机交互矩阵仍为 NOT RUN。

### 2026-08-15 山姆现场前完整链路稳定性回归

冷启动必须覆盖 Settings bundle 缺项、错误类型和 native host 暂不可用；地图入口必须覆盖 off-main prepare/present、Files provider staging 无 base address、包内 floor 消失和取消/rollback。严格证据必须对 recovery reason、last-trigger reason、trigger record reason 的非字符串值、空 complete burst、trace pose 二次读取失败、duplicate observation 和 canonical scalar 类型漂移返回稳定错误，任何路径不得调用显式进程终止原语。ARKit 提交必须故障注入 captured image/depth/confidence lock/base-address 失败和无 raw feature point；有限证据可降级，锁必须精确释放。

Stop 回归必须证明调用顺序为 `beginFinalization/admission close → pause ARSession → pause native mapping → stopCamera → prior-map/localization drain → clock flush → database save → sidecar/metadata commit`。从停止边界后不得再产生没有 required localization sidecar 的 native node；路径解析早期失败必须恢复同一连续扫描且 `triggerNewMap=false`，terminal commit 后 native host 丢失只能记录诊断。空 burst、未知楼层、损坏 recovery JSON 和 unavailable depth 均必须不崩溃。

PC 浏览器恢复必须使用受认证本地会话，覆盖旧 complete localized journal 缺少/损坏 current：详情 GET 返回结构化 409，后续 `/api/about` 仍可访问，Web 显示保留原输入/旧结果并允许四种模式继续切换。当前证据：聚焦 UX/sidecar **43/43**、完整 PriorMap **330/330（382.204 s）**、Qualification **30/30（11.140 s）**、Map Studio **142/142（10.017 s）**、native **7884/0**、unsigned generic iphoneos Debug、clean exact-commit macOS Release/QualifiedDevice Release、Swift parse 和 patch PASS；压力子进程 300,000 finalization peak 13,205,504 bytes、1,728,000 trace retained 172,801 / peak 59,129,856 bytes、400,000 tag evidence accepted 200,000 / peak 746,455,040 bytes。浏览器 1600/1280/980 无横向溢出且四模式保持可操作。已配对 iPhone 17 Pro Max 的签名 Release 构建、签名验证和安装 PASS；冷启动因设备锁屏被系统拒绝，运行与交互仍 NOT RUN。以上仍不替代 LiDAR、Files Provider、热/低磁盘、前后台中断、异常退出和山姆现场路线。

### 2026-08-15 手机性能证据与结果包回归

自动化必须覆盖：5 秒正常 cadence 与保存后的 `finalizing` 样本；CPU 首样本无区间百分比、后续按 `(delta user+system CPU)/(delta uptime)` 计算且允许多核超过 100%；`phys_footprint`、process-available-memory、磁盘、电池/充电、热状态、FPS、RTAB-Map update、节点/数据库/会话目录增长均使用有限非负值或明确 unavailable，禁止 NaN/Infinity 和用 0 冒充不可测量。写侧必须受 250,000 条、256 MiB、64 KiB/row 上限约束，metadata 的 count/last sequence/last timestamp/write-failure/complete 与落盘文件一致；性能写失败只关闭 performance qualification，不得把有限地图结果删除或伪装成定位证据失败。

PC strict parser 必须覆盖 final newline、空行、坏 UTF-8/JSON、NaN、format/version、tracking identity、序号跳号/重复、时间倒退、metadata count/末序号/末时间漂移、symlink/hardlink/超限、分析期间 inode/size/mtime 变化。正常结果要生成 exact raw SHA-256 副本、CSV、summary 和最多 720 点的确定性浏览器序列；25,000+ 行测试证明序列/分位样本有界且重复运行一致。坏日志不得生成可信 CSV/趋势，但安全大小内的 exact bytes 必须以 `.invalid.jsonl` 保留。MetricKit 已投递日志按单文件 8 MiB 上限复制并记录 hash；未投递不得解释为“没有 crash”。

真机资格矩阵至少包括：30 分钟、2 小时连续扫描；nominal/fair/serious 热状态；充电/不充电；低电量；可用内存压力；8 GiB/1 GiB 低磁盘门；前后台/系统中断；正常结束、强杀、watchdog/真实 crash 后重启及 MetricKit 延迟投递。将同一结果包导入 PC，核对原始 JSONL、metadata、CSV、summary、Web 图表和实际时间点一致，并检查性能采样自身未造成可见帧率周期性尖峰。没有上述设备证据时只能声明 host/Xcode 验证，不能声明性能生产资格或整体 GO。

当前合并自动化证据更新为 PriorMap **330/330 PASS（382.204 s）**、Qualification **30/30 PASS（11.140 s）**、Map Studio **142/142 PASS（10.017 s）**，并通过生成合同检查、Swift/Python/JavaScript 语法、patch-format 和 unsigned generic iphoneos Debug 全量编译/链接。浏览器在 1600/1280/980 宽度均无横向溢出；QualifiedDevice Release 必须在 clean exact commit 上重新构建并核对 bundle identity，上述真机矩阵仍全部 NOT RUN。

### 2026-08-14 现场反馈回归

自动化必须证明：人工重定位 picker 不再直接修改 `imageView.transform`，支持真实 zoom/pan；确认前提交最后文本编辑；fresh-node 超时保持弹窗；`appendManualLocalizationEvent` 在 `commitManualPosition` 前完成；写失败不改变 alignment。ARFrame 同帧路径必须把同一 `correctedPose` 传给 native graph、prior-map 和 ESL，rejected frame 不写 location boundary；tracking gap 不得恢复 6 m/360° 门。连续 profile 日志必须报告实际 OptimizeMaxError/MinInliers。MetricKit parser 只向 UI 返回有界摘要；8 MiB 内原始 call tree 保留在导出 JSONL，超限记录必须明确报告原始大小和省略原因。

真机必须新增：20 次连续“重新选择位置”成功率测试；每次覆盖 1×–8× zoom、放大后单指 pan、点击/箭头拖动、X/Y/yaw 最后一键确认、±1/5/15°和四方向；核对 UI 值、manual event、alignment snapshot、PC 解析一致。另执行审计写失败注入、6 秒无 fresh node、tracking loss/recovery、顾客碰撞、刚开始扫描 crash、长扫 crash、kill/relaunch 和 MetricKit 后续交付。没有 `.ips`/payload 时只能记录“未取得诊断”，不能判定无 crash。

### 2026-08-14 通道/货架设计审查 P0/P1-A 回归

P0 node-local tag contract 必须在 Swift 和 Python 两端共同证明：native 单次快照同时返回 exact node ID、map/component ID、stamp、timebase generation 和 `T_opengl_world_from_node`；scene-depth 世界点写成 `point_in_bound_node_frame`；parser 精确复核源数据库 node ID/stamp/map ID 和 verified complete burst；resolver 只执行 `P_final = T_final_node × P_node`。冻结的数值回归至少包含最终 node 位姿 `(100 m, 50 m, 90°)` 与 node-local 点 `(1 m, 0 m)`，期望 `(100 m, 51 m)`，禁止重新出现 `T_final × inverse(T_raw) × prior-map-point`。`raw_map_position` 缺失或损坏不得覆盖 node-local 权威；node-local 点缺失/非法必须清空最终坐标、标记低置信并生成重扫。历史 v1 必须保留条码和 durable identity，但不得输出可发布地图坐标。

P1-A publication invariant 必须分别覆盖 writer、immutable result reader 和 committed-task recovery。coordinate contract v2 只有在 prior-map frame、图质量 PASS、零 degradation、coordinate-frame audit PASS、legacy count=0、`LOW_CONFIDENCE=0`、unpositioned=0、unassociated=0、rescan=0 时才能声明 `COMPLETE/publish_permitted=true`。任一字段被篡改、遗漏或改成不一致计数都必须拒绝或降为 review；coordinate contract v1 可保留为历史 review artifact，但不得继续声明 COMPLETE。

当前已执行证据包括：Stage-3 **126/126 PASS**；非零 gauge/精确 node binding focused **19/19 PASS**；完整 PriorMap discover（含 Swift host 长方法）**329/329 PASS（378.876 s）**。规模子进程保留 300,000 finalization（输入 114,933,372 bytes，wall 8.111 s，CPU 8.076 s，峰值 RSS 13,287,424 bytes）、1,728,000 trace（保留 172,801，wall 0.405 s，CPU 0.407 s，峰值 59,146,240 bytes）和 400,000 tag evidence（输入 282,352,646 bytes，接受 200,000，wall 29.046 s，CPU 28.916 s，峰值 747,192,320 bytes）。v2 evidence 增加字段后 tag 峰值明显高于上一基线，仍低于冻结的 768 MiB 门但余量有限；后续 exact-SHA runner 必须继续报告真实输入字节、耗时和 RSS，不得沿用旧数字。签名真机、LiDAR、Files provider、热/低磁盘、动态顾客/购物车、错误 loop、平行通道多解和现场控制点精度仍未执行。

## 自动测试

### 2026-08-14 跨端稳定性自检

除既有轨迹、价签、sidecar、snapshot、CAS 和发布门合同外，正常生命周期回归必须证明：Core Location 空批次、暂时无 active window scene、历史数据库列表越界/类型不符、文件修改时间不可读、Application Support 状态目录不可创建、价签状态竞态和已提交结果恢复分支均不会调用强制解包、强制转换、`fatalError`、`preconditionFailure` 或 Debug assertion 结束进程。普通低置信度/部分图/多解必须保留有限轨迹、逐秒行和 durable 价签；完整性、身份、水位、CAS、重复 durable 主键、完全无有限轨迹和原子提交损坏继续失败关闭。

当前本机证据：PriorMap discover 329/329（378.876 s；300,000 finalization peak 13,287,424 bytes；1,728,000 trace retained 172,801 / peak 59,146,240 bytes；400,000 tag evidence accepted 200,000 / peak 747,192,320 bytes）、Qualification 30/30、Map Studio 完整 API 131/131、native 7884 checks / 0 failures、macOS Release `rtabmap-reprocess` build、Swift parse、JavaScript/Python syntax 和 `git diff --check`。真实浏览器响应式自动化仍受 localhost 安全策略限制；权限不可得时必须报告为环境阻断，不能绕过浏览器安全限制或把 HTTP 单元测试冒充真实视觉交互。

PC 人工锚点必须确认 HTML 中不存在连续 yaw range slider，并覆盖 X/Y/yaw 数值输入、平移步长、四向移动、离散旋转、四个基准朝向、键盘/Shift、canonical bounds、exact request/audit value 和 CAS。iOS 配置/重定位继续使用同一 canonical SE(2) 离散交互。最终提交后还必须运行 unsigned generic iphoneos Release 并核对 `MarketScannerBuildIdentity.json.app_git_sha == git rev-parse HEAD`；该结果仍不替代签名安装、LiDAR、Files provider、热/低磁盘或现场真值。

### 统一扫描 UX、启动事务和 build identity

生产入口、地图先选后载、导入进度可见性、线程边界、导航、相机权限、启动 receipt/context、取消/回滚、地图包单快照/descriptor freeze、zoom/nudge/discrete heading 和默认/QualifiedDevice Release scheme 使用以下聚焦组：

```bash
python3 -m unittest \
  tools.PriorMap.tests.test_mobile_scan_ux_contract \
  tools.PriorMap.tests.test_yaw_arrow_geometry \
  tools.Qualification.tests.test_market_scanner_build_identity \
  -v
```

朝向回归必须额外证明：`0°/90°/180°/-90°` 分别对应东/北/西/南；ARKit `+X/-Z/-X/+Z` camera forward 分别产生 `0/+π/2/π/-π/2`；首帧锚定后向前移动 1 m 必须沿用户选择的地图方向；配置 marker、人工重选箭头和实时 HUD 均以右向 artwork 加单次 `-yaw` 渲染。无签名构建不能替代真机四方向复测。

2026-08-10 的历史源码结果为 **32/32 PASS**；当前合同继续证明同一 UX/startup 项，并把构建身份要求更新为：Debug 和 Release 都生成 version 5 identity、进入同一完整扫描链路；Debug 可用 `--allow-dirty`，但必须记录实际 source ref、唯一 tracked patch SHA-256 和 `production_eligible=false`；默认 `RTABMapApp` 和 `RTABMapApp-QualifiedDevice` 的 Run 均保持 clean Release。新增合同还要求 setup transition 失败不得继续 commit、finalization 的 state/context 单次持久化、未完成的 `finalizing_scan` 不得直接进入后处理，以及条码失败 alert 去重。

2026-08-10 历史扫描/ESL 布局增量中，`tools.PriorMap.tests.test_mobile_scan_ux_contract` 单组扩展为 **19/19 PASS**。新增断言要求：ESL status/payload 必须绑定 exact scan rect 上下边缘且不能恢复 `centerY` 魔数；历史列表必须显示独立导出按钮并使用 folder document picker；导出必须 finalized/live-checkpoint/hardlink/SHA/local-retention fail closed；snapshot 必须存在 iOS 私有 descriptor-copy fallback、exact stat identity cache 和临时副本清理。这个 19 项数字是该单组当前结果，不替代上面跨三个模块的历史 32/32 证据。

Swift 核心可执行长方法 `IOSCoreContractTests.test_swift_workflow_state_and_se2_projection` 在当前源码上 **1/1 PASS（1212.429 s）**，覆盖 map-library CAS、register/rebuild/freeze/quarantine、异常 symlink 外部目标权限保护、300k finalization、1,728,000 trace、400k tag evidence、MapCase02 和 workflow/SE(2) 合同。现场阻断聚焦组 46/46、较广 PriorMap 拆分组 197/197、Map Studio 109/109 也已通过。拆分执行不等同于单命令完整 discover，这些 host 证据也不能冒充真机交互延迟或现场扫描 PASS。

本轮在同一个 Swift executable 默认路径中增加两类运行时回归：强制走 iOS 私有 snapshot DB 校验副本并确认 `.marketscanner-db-validation-*` 无残留；构造 finalized `SupermarketSession-*/segment_0001` 后连续导出两次，确认源仍存在、源/目标 manifest 相等、两个 receipt 存在且第二次不覆盖第一次。2026-08-10 当前源码的完整长方法结果为 **1/1 PASS（1484.429 s）**；其中 400,000 条 tag evidence 输入 243,952,646 bytes、接受 200,000 条、峰值 RSS 520,077,312 bytes。只做 `swiftc -parse` 或 source-token contract 不算行为验证。

### MapCase02 冻结回归

正式输入 `map/mapcase02/mapcase02.xlsx` 的 SHA-256 必须为 `1ddf428fc4dd6e4e8bd33258d0cbfaab87b809c4dedd6b8baca9e167c14b5e6a`。Swift `--mapcase02-suite <xlsx> <output> <canonical-sha> <swift-package-sha> [legacy-xlsx]` 与 PC converter/schema 必须同时满足 1838/1630/1301/329/0/208 统计、0 active 越界、canonical ID `piaseczno-5ddfac7dc439`、canonical SHA `5ddfac7dc439afc45abdcf800b799c05d53704895b620d161ef08a442c55b2db`、Swift package `c6b6b2c00690998cfa9517374b9385f857cb3ee0efcbe3663f63ee76fee87959`、PC package `41332d093e652ec2de94f0f86b8f15107cd6f67f3b2e5ddec1c0685ab4d7d3be` 和 PC preview `d0c02be63dff3ab002dcf931ce7d0c5149152b78bea139fb1b0a2d86be196a18`。Swift 套件必须继续执行 compile → integrity → content-addressed move → register → listMaps → exact map read，并对重签的旧 uppercase v2 包断言 production 默认拒绝、显式 diagnostic-only 允许；`validation_report.summary.node_count/edge_count` 必须绑定 road graph 且 Swift 输出须由 Python production validator 直接接受；手机预览回归还必须证明 Quartz `minY→0/maxY→height`、UIKit touch `1-v`、`(58.03,-18.13)` 不在障碍物内且保持 0.30 m clearance、已知货架内部点继续拒绝。PC 正式 golden 测试必须直接断言 source/canonical/ID/package/preview SHA。只做自洽 digest 或只验证编译包均不再足够。

真实工作簿回归使用 Swift host `--xlsx-library-smoke <xlsx...>`，输出仅写入 `/private/tmp` 下的临时地图库。2026-08-09 已对 `map 2.xlsx`、TianHong 02402、北京昌平 6599 和 Kohl's 1224 共四张正式工作簿执行，四张均完成严格导入、编译、完整性、安装、注册、列表和 exact ID/SHA 读取。跨端 slug 负例覆盖 `Piaseczno`、`Kohl's 1224`、`İstanbul`、Kelvin sign、中文夹 ASCII 与 200-byte 合法地图名；最终 ID 必须匹配 `^[a-z0-9._-]+$` 且最长 128。

负例覆盖关系别名/外部 target/namespace 伪 authority、缺失/重复/前导零 row 与 cell、非法 shared-string/boolean/公式/超大 cell、100001 元素、错误角色几何、重复 element ID、严格整数 token、距离场预算，以及重签名后 canonical/graph/spatial/distance/shelf 派生工件篡改。任一端接受集合不同即失败。

2026-08-10 本机证据：MapCase02 Swift 正式套件 PASS；四张真实 XLSX 手机地图库 4/4；PC production validator 4/4；当前 Swift 长方法 1/1（1212.429 s）；较广 PriorMap 拆分组 197/197；Map Studio 109/109；unsigned generic iPhoneOS Debug 全量编译/链接 PASS。run `31307753672@8f0e730d…` 的全部非 Apple jobs、完整 macOS host、SwiftPM/Xcode metadata 与 200k RSS `794,099,712 < 805,306,368` bytes 均 PASS，但 iphoneos cold dependency configure 未找到 host `rtabmap-res_tool`，整体仍为 7/8，双平台 clean link skipped。I11 `37e6ed8c4afa00202693cd56919aea78fd4c7af5` 显式绑定该工具，本地全新 prebuild/configure 与独立复审 `P0=0/P1=0` PASS；replacement exact-SHA CI、成对 cold simulator/device link、真机/LiDAR/现场仍待执行，required jobs 全绿前不得冻结。

P0 生产安全不变量（CI 使用相同选择器，任一失败即失败关闭）：

```bash
python3 -m unittest -v \
  tools.SupermarketMapStudio.tests.test_map_studio.MapStudioApiTests.test_review_transition_is_versioned_and_bounded_solver_cannot_publish \
  tools.SupermarketMapStudio.tests.test_map_studio.MapStudioApiTests.test_checkpoint_cleanup_requires_confirmation_and_exact_evidence \
  tools.PriorMap.tests.test_ios_sidecar_health_contract.IOSLocalizationSidecarHealthContractTests.test_atomic_visibility_and_copy_retention_contracts_are_explicit \
  tools.PriorMap.tests.test_ios_sidecar_health_contract.IOSLocalizationSidecarHealthContractTests.test_finalized_metadata_is_bound_to_persisted_evidence_bytes
```

该快速组锁定四项既有行为：bounded solver 禁止发布、checkpoint cleanup 的人工确认与精确 CAS、外部复制不自动删除本地副本、required evidence 异常阻断 finalized metadata。它不能替代下面的全量测试、macOS 上的 Swift 可执行 core 测试、真机矩阵或现场验收。

```bash
python3 -m unittest discover -s tools/PriorMap/tests -v
python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v

python3 -m py_compile \
  tools/PriorMap/*.py \
  tools/Supermarket2DMap/supermarket_2d_map.py \
  tools/SupermarketMapStudio/server.py \
  tools/SupermarketMapStudio/offline_processing.py

xcrun swiftc -parse \
  app/ios/RTABMapApp/SupermarketFinalizationCore.swift \
  app/ios/RTABMapApp/PriorMapLocalizationCore.swift \
  app/ios/RTABMapApp/PriorMapLocalization.swift \
  app/ios/RTABMapApp/SupermarketScanSession.swift \
  app/ios/RTABMapApp/ViewController.swift

node --check tools/SupermarketMapStudio/web/app.js
git diff --check

xcodebuild -quiet -project app/ios/RTABMapApp.xcodeproj \
  -scheme RTABMapApp -configuration Release \
  -sdk iphoneos -destination generic/platform=iOS \
  -derivedDataPath /private/tmp/marketscanner-derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

普通共享 `RTABMapApp` 的默认 Run 仍是 Release；手动 Debug 现在也生成身份并可用于完整 prior-map 扫描、落盘、finalization 和结果回归。Debug dirty 状态不得阻断功能测试，但必须在身份和会话审计中显示；真实性能、签名真机和现场资格仍使用 clean Release。2026-08-10 的旧 Debug“身份被移除”结果只描述历史版本，不能作为当前合同。

本轮真机手测必须补充：删除/停用 Xcode 的 `ViewController.updateState(state:)` 文件断点后冷启动，确认不会再被调试器停在黑色残缺界面；打开 ESL 扫描确认状态文字位于框外且 Dynamic Type/短屏无约束冲突；对截图中的真实 finalized 会话执行手机后处理，确认不再出现 `/dev/fd` 只读打开错误；不处理或故意处理失败后仍可把完整原始扫描导出到 Files/iCloud/外接存储，并在第二次导出时保留第一次目录。大型真实 DB 还要记录私有校验副本的额外空间、耗时、取消/锁屏和低磁盘行为。

2026-08-10 的历史 unsigned generic iPhoneOS Debug 与 tracked-clean exact-HEAD Release 全量编译/链接均已 PASS；当时 Debug 产物没有 `MarketScannerBuildIdentity.json`。当前 version 5 合同要求 Debug/Release 两个产物都包含身份，因此必须重新执行至少一次 Debug 全量构建并检查 `debug/dirty-or-clean/source_ref/source_patch_sha256/production_eligible=false`，以及一次 clean exact-commit Release 构建并检查 `release/clean/empty-patch-digest/production_eligible=true`。无签名构建仍不是签名安装或真机运行资格。

覆盖：

- XLSX `Element Info`、六种 shape；
- 损坏 JSON、未知类型、隐藏元素；
- 损坏 PNG、错误 hash/count/bounds、错误子集、道路引用、空间索引和验证报告的拒绝；
- Swift 对 swapped shelves、tampered bounds、broken road、mixed preview/distance 和 validation=false 的导入拒绝；
- 业务字段保留；
- 坐标轴、厘米/米、90° 旋转矩形、bounds；
- 道路字符串/数字 ID、缺失引用、连通统计；
- 大型结构/道路空间网格的有界查询；
- schema 和逐字节可复现输出；
- 默认及逐楼层 PNG 预览有效；
- PC API 异步导入、检查、artifact allowlist、源 XLSX 不变；
- 自由扫描旧会话兼容和连续单库识别；
- 直接编译运行 iOS 无 UI 核心，以恒等、前后左右和非零原点金标验证 ARKit `x/z` 到地图 `x/y/yaw`、UI 朝向约定、双模式启动门控和 SE(2) 投影；
- 平行通道歧义拒绝、唯一道路软修正上限；
- 平移/旋转 drift（旋转必须改变 XY 误差）、yaw 误差、tracking 状态转换、道路边分配和人工校准前后误差。
- 正方形/近正方形和反转 ring 的稳定货架 `A/B`/offset，柜台所有边 `E##`；
- 密集深度内点、稀疏孔洞和前后景错误多数拒绝，0/100/300/800 ms 与版本滞后的快照门；
- 阶段三源 DB hash 不变、确定性输出、离线漂移降低、错误约束拒绝、人工编辑 undo/redo/分支重放；
- manual localization v3 使用 native 原子 node/timebase/generation 快照；无 node、过期、generation/身份/时间等式错误拒绝；严格 v2 可兼容，legacy v1 拒绝；
- JSONL 必需/可选策略、非法 UTF‑8、NaN/Infinity、format/version、身份、时间、空文件、重复 observation/tag ID；
- staging 失败、陈旧 staging、损坏指针、无效版本不切 current、不可变旧版本和具体 version artifact；
- POSIX/Windows 并发锁、Windows write-through 原子移动、输入 identity、处理中输入变化、旧版本 local-input 隔离和已打开文件字节复核；
- iOS 必需 sidecar 结构化写结果、state watermark 仅在成功后推进、粘性 capture health；可注入 Swift writer 实际覆盖每个必需文件部分失败、metadata 提交前失败、checkpoint 提交后删除失败、成功终态和同字节数复制篡改；
- iOS 原子 writer 对 temp write、flush、rename 分别注入失败，确认旧字节保持且无临时文件泄漏；合同仅承诺原子可见和进程恢复，不把 hosted/模拟测试写成设备断电持久化；
- Foundation finalization effects 执行四种 disposition：只有 `resumeRecording` 恢复 camera/mapping；正常 finalized 关闭会话并允许校验复制；needs-cleanup 关闭且禁止复制；ineligible 关闭并保留 checkpoint；ViewController completion 返回枚举而非 Bool；
- finalized metadata 提交前对真实 sidecar 字节执行 bundle 复核；删除、空文件、非法/半行 JSON、identity/count/state watermark 不符和 symlink 均降级为 `finalized=false`，optional 空文件保持合法；
- finalized checkpoint 手机/PC 显式清理只接受同 tracking identity、有限 Unix 时间且 checkpoint 不晚于 metadata commit；session/segment/metadata/checkpoint/events symlink、Windows reparse、相邻前缀、TOCTOU 替换全部拒绝；PC 必须 `confirmed=true` 并绑定 expected identity/time/双 SHA，冲突和重复请求返回 409；authorized/completed/failed 审计覆盖终态；
- expected version/revision 缺失、两个客户端使用同一基准版本的 CAS 冲突、HTTP 409、服务端 old value/UTC/ID、字段/范围/货架边长/批准前校验、重放失败回滚；
- draft→review 新版本、bounded solver 发布 422 硬阻断、published 指针不产生；
- 自由扫描默认入口和旧会话处理回归。

阶段三快速 E2E：

```bash
python3 -m unittest tools.PriorMap.tests.test_stage3 -v
```

阶段三确定性性能/内存门：

```bash
python3 tools/PriorMap/benchmark_stage3.py \
  --nodes 2000 --max-seconds 15 --max-peak-mib 64
```

该基准只测 `bounded_correction_field` draft fallback，不代表完整 SE(2) 因子图、`rtabmap-reprocess`、地图生成或真实 iPhone matcher 性能。

## P1 相对 SE(2) 因子图

```bash
cmake --build build-pc-release \
  --target rtabmap-prior-map-factor-graph --config Release -j2
python3 -m unittest tools.PriorMap.tests.test_factor_graph_schema -v
```

真实 DB 资格测试必须把 `--database` 指向 `rtabmap-reprocess` 的一次性输出副本，传入真实文件 SHA-256、正确的 `--horizontal-axes xz|xy`，执行前后重新计算 DB SHA，并用 `factor_graph_schema.validate_factor_graph_result()` 复核结果。至少记录 DB version、nodes/factors、factor digest、initial/final objective、iterations、gauge mode、残差 p95 和被拒绝/降权的 factor IDs。扫描 DB 和生成报告均不得进入 Git。

自动负例覆盖断连、缺 endpoint、奇异 information、非有限结果、canonical/digest 篡改、错误 gauge 和不收敛；既有 `SE2TagPropagationTests` 覆盖 ±90°/180°、平移旋转耦合和 yaw wrap。clean runner 的 native helper 构建属于 P2，不得用已有本机构建目录替代。

## 样例地图验收

```bash
out="$(mktemp -d /private/tmp/prior-map.XXXXXX)"
rmdir "$out"
python3 tools/PriorMap/xlsx_to_prior_map.py map/mapcase01/mapcase01.xlsx --output "$out"
python3 tools/PriorMap/validate_prior_map.py "$out"
python3 tools/PriorMap/replay_localization.py "$out" \
  --output /private/tmp/prior-map-replay \
  --floor 1 \
  --translation-drift-per-m 0.01 \
  --rotation-drift-deg-per-m 0.02 \
  --tracking-loss-start 30 \
  --tracking-loss-length 8
```

核对 manifest 元素统计为 1,563、楼层为 1/2，并分别视觉对比每层 `preview_file` 与用户 PNG 的方向、结构和比例。手机干跑只选择其中一个楼层，整个会话不得切层；楼层内部少量竖直移动不应改变二维平面位置。

## iOS 手工干跑

无需超市场景：

1. 功能端到端干跑可直接使用 Debug，包括 dirty tracked tree；确认页面和日志显示正确的 Debug/tree 状态，并完整执行 start/stop/finalization/处理。真实性能或现场资格测试再提交全部 tracked 改动、确认 tree clean，并选择 `RTABMapApp-QualifiedDevice` Release 安装到支持 ARKit/LiDAR 的 iPhone。
2. 从首页大型“新建扫描”进入统一配置页，确认左上角 Close；从“门店地图”选择同一地图进入，确认系统 Back/返回手势。进入、返回和重复切换不得再出现 3–4 秒主线程冻结，并记录 p50/p95。
3. 分别导入手机 XLSX 和 PC 正式 v2 地图包，确认都进入同一地图库和同一配置页；编译/复制期间持续显示阶段、百分比与用时，完成后核对 store ID、map ID、package/canonical SHA、楼层、元素和 warning 摘要。
4. 对“导入已有 PC 地图包”覆盖本机文件、iCloud Drive 和至少一个第三方 FileProvider：点击入口不得退出进程；文件夹 picker 必须以 open-in-place 模式显示；取消、空选择、provider 下载失败和无权限均回到可操作的地图列表。成功选择后核对外部目录不变、私有包完整注册，并可继续进入统一配置和扫描启动事务。
5. 在配置页验证 1×–8× 捏合、平移、双击、点击选点、0.1/0.5/1.0 m 四方向微调，以及东/北/西/南和左右 15° 朝向；不得出现横向 yaw slider。
6. 在首次权限未决定的干净安装上点击开始：授权前不得创建会话；授权后必须重新执行完整入口并成功启动。拒绝权限时恢复交互并提供系统设置入口，不能出现后台幽灵扫描。
7. 选择有效起点开始扫描，确认配置页关闭后直接进入 `.STATE_MAPPING`，无需再点 Record；检查 session-scoped DB、receipt 和 workflow context 均存在且身份一致。随后测试启动页离开/取消、host 失败和持久化故障注入，确认 CameraMobile/ARSession/mapping/clock 全部停止、失败数据库被脱离且没有可继续录制的未提交会话。
8. 在办公室步行，确认 HUD 轨迹连续；遮挡相机后变 weak/lost，但数据库继续增长。人工确认/重新选择位置，检查定位 JSONL。
9. 另从“实验与兼容工具”新建自由扫描，确认旧连续单库和 sidecar 兼容行为不变，且它不再占据主入口。
10. 正常结束，确认 metadata 地图身份、`finalized=true`、capture health 完整、eligibility blockers 为空、无 checkpoint、NFC 不可见。
11. 在测试构建中注入一次必需 sidecar 写失败，确认红色告警持续、停止新的先验地图修正/价签确认、原数据库继续增长、结束后 `finalized=false` 且 checkpoint 保留，PC 明确拒绝；不得在真实扫描目录上用权限破坏方式注入。
12. 单独注入 metadata 已成功但 checkpoint 删除失败，确认数据库关闭、相机/映射不恢复、metadata 保持 `finalized=true`，启动后只显示严格校验的人工清理提示。
13. 对实际业务文件提供者完成复制，核对 `copy_verification.json` 与源/目标复读清单；确认应用默认保留本地副本。分别记录普通完成、应用强退和设备重启后的可读性，不把前两者替代断电测试。

正式超市验收只按 `FIELD_TEST_PLAN.md` 执行；尚未执行时不得声称生产通过。
