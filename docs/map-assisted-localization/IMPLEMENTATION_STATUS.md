# 地图辅助定位实现状态

> 文档状态：**当前有效**。最后核对日期：2026-08-10。

当前全手机发布目标已收敛为一条生产流程：首页大型入口和菜单入口先进入轻量地图选择页；用户可选择已注册地图或直接导入新地图，只有明确选定后才进入统一扫描配置页并完整校验/加载该包。手机编译 XLSX/CSV/JSON 与 PC 正式 v2 地图包都安装到同一个 `MobileMapLibrary`，再复用同一个楼层/起点/朝向页面、Coordinator 和真实扫描 host。配置页以 required initializer 接收 immutable `selectedMap`，不再持有地图 picker 或自行列举/自动加载第一张地图。旧向导不再从生产 UI 可达，自由扫描和原始数据录制只保留在“实验与兼容工具”。地图库普通进入使用轻量 registry，完整包读取、provider snapshot/copy、localizer 构造、会话目录和 native SQLite 初始化均在后台队列；主线程只保留短 UIKit/ARSession 事务。MapCase02 单次完整包校验约 9.36 秒的证据解释了原 3–9 秒冻结，当前实现不再在进入/返回路径同步重复该工作。

统一配置页已实现 1×–8× zoom、pan、双击缩放、点击选点、0.1/0.5/1.0 m 方向键微调、四个基准朝向和左右 15° 微调，并删除 yaw slider。root modal 显示 Close，library push 使用系统 Back/手势；页面离开会取消启动。地图编译 UI 显示可观测的解析、距离场、空间索引、预览、完整性、自验证、fsync、提交和注册阶段，完成摘要包含 store/map/package/canonical identity、楼层、元素与 warning 统计；选择文件之前不会显示 0%、空进度条或导入计时，进入安全暂存后才显示真实进度。

扫描启动现在是 background preparation + short main commit + durable receipt/context transaction。首次相机权限必须先完成；canonical Mobile-Only 使用 session-scoped streaming DB 并跳过旧 tmp-db 异步恢复；receipt 使用安全 ASCII tracking ID、`O_EXCL|O_NOFOLLOW`、完整写与文件/目录 fsync，workflow context v3 绑定 session/segment/database/map/store/receipt SHA。host 失败、持久化失败、状态提交失败或用户取消都会执行强 rollback，停止相机、映射和时钟，清理 prior-map 状态，打开私有 scratch DB 使 native core 脱离失败 streaming DB，并释放未提交会话。正常生产动作进入 `.STATE_MAPPING`，不再依赖隐藏的第二次 Record 操作。

当前现场阻断修复分支为 `codex/fix-mobile-field-scan-blockers`，基于已验证并推送的地图选择/默认 Release 基线 `559353edd699abf995c04b3daf83f2ba60ebff17`；未修改核心分支 `core-mobile-v1@36f606c1fa05e92210f0189c804dadd1b09721a1`。上一轮 UX/startup 和地图库安全专项复审均为 `P0=0 / P1=0`。本轮新增 node-timebase admission、扫描 finalization 生命周期与崩溃恢复门、条码入口反馈和预览坐标修复；当前源码已通过 UX/geometry/build-identity 32/32、现场阻断聚焦 46/46、ESL ARFrame-only 1/1、较广 PriorMap 197/197、Map Studio 109/109、Swift 核心长方法 1/1（1212.429 s）、四张真实 XLSX 手机地图库 4/4、PC production validator 4/4，以及 unsigned generic iPhoneOS Debug 全量编译/链接。Debug 日志明确确认正式 build identity 被移除；当前提交的严格 Release identity build 必须在 tracked tree 干净后执行，不能提前登记。新的真机安装与现场点击仍必须重新执行，不能沿用上一轮设备结论或用 host/Xcode 构建冒充。

本轮证据链根因是 `ViewController.updatePriorMapLocalization()` 在首个 native node-time snapshot 尚未产生时把 offset 替换为 `.nan`，严格 writer 因而同时把 trace/constraint/state 标成永久 required-write failure；该状态又让价签入口被拒，最终只能关闭为不可处理 recovery package。当前缺失/非有限 timebase 被视为 transient not-ready 并跳过 frame，不放宽任何 sidecar schema。扫描结束时 coordinator 同步进入 `finalizingScan`，可恢复失败返回 `scanning`，terminal close 清除 receipt/session；新的 setup 事务在状态迁移失败时不再继续 commit。全屏价签 overlay 保持 ARFrame-only，但入口失败改为明确 alert，成功进入后置顶并设为 accessibility modal。

MapCase02 标准超市 XLSX 局部链路已完成阻断级收口：Swift/PC 正式导入、canonical v3、package v2、角色几何、派生空间工件和资源预算一致。2026-08-09 真机导入补充发现生成层保留大写、MobileMapLibrary 仅接受小写的安装合同断层；当前 canonical ID 为 `piaseczno-5ddfac7dc439`，Swift package 为 `c6b6b2c00690998cfa9517374b9385f857cb3ee0efcbe3663f63ee76fee87959`，并已把安装、注册、列表和 exact read 纳入正式套件。2026-08-10 真机起点误判进一步定位为 Swift 预览 PNG 重复翻转 Y；当前 Quartz 渲染、UIKit touch 和 canonical obstacle geometry 已统一，MapCase02 报告点 `(58.03,-18.13)` 保持 0.30 m clearance 可用，已知货架内部点继续拒绝。冻结 golden 为源 1838、active 1630、shelf 1301、fixed 329、presentation 208，canonical `5ddfac7dc439afc45abdcf800b799c05d53704895b620d161ef08a442c55b2db`。最终增量还关闭了 legacy uppercase v2 从通用 validator 泄漏到旧 iOS 向导和 PC 离线定位的 P1，以及 Swift validation report 缺 road graph node/edge 计数、导致手机包被 PC production validator 拒绝的跨端 P1：production 默认严格拒绝 legacy uppercase；Swift/Python 现在共同校验 report 与 graph，Python 外层直接复核 Swift 包。因此允许表述 `MAPCASE02 / STANDARD SUPERMARKET XLSX FORMAT PASS`，但不得扩大到整机/现场或 Production Ready。

本轮真实样本证据：`map 2.xlsx` 与正式 MapCase02 source SHA 完全相同；另对 TianHong 02402、北京昌平 6599、Kohl's 1224 执行 PC converter/schema 和 Swift `--xlsx-library-smoke`，四张均通过。新增 slug 合同同时关闭大写、Unicode lowercase parity 和 200-byte 合法地图名超过 128 字符的同类安装风险。lowercase-ID 修复初版完整 Python 外层 Swift host 1/1 PASS（1020.058 s）；随后加入的 frozen SHA、diagnostic-only validator 与 manifest/report strict-count 收口已通过重编译 Swift host 的 Map Library CAS、MapCase02 正式套件、四图 smoke、Python 52/52、Map Studio 109/109 和 iphoneos Debug 无签名 build。该证据仍不替代 exact-SHA CI、真机或现场资格。

除 RC-B19/J-04 component identity 外，第二次独立全量审查的 RC-B01…RC-B03、RC-B05…RC-B28 已完成代码和本地主机自动化闭包；J-04 仍需冻结 prior-independent final-link component policy，并完成 node snapshot C ABI 与 constraint/manual evidence schema 的 breaking migration。RC-B04 exact-SHA CI、RC-B29 Replay/FAR policy freeze、RC-B30 Device Lab 也仍未关闭。当前现场修复以拆分方式执行较广 PriorMap 197/197 与 Swift 核心长方法 1/1，并补充 Map Studio 109/109、MapCase02 Swift/PC 正式套件和历史 I10/I11 证据；这不是一次单命令完整 `discover`，也仍不替代 LiDAR、热/内存/后台/provider 或现场精度证据。

MapCase02 validation HEAD `770d94b078a0dd94653b9d6b33576890f88f7296` 的 exact-SHA run `31299358502` 为 7/8；唯一失败是 macOS/iOS 200k tag-evidence RSS `812,892,160` bytes 超过 768 MiB 门。I7 `cbba284ad1b0694f5302ec3abbb9a446d9d3a970` 已用 compact、单射的 view/tracking code 消除 burst index 中重复 String 保留，且保持 observation key、逐字段 exact binding、duplicate 与 unconsumed fail-closed；本地同一规模峰值为 `629,735,424` bytes，默认 host 峰值 `493,338,624` bytes，独立复审 `P0=0 / P1=0`。这些结果仍是本地证据；replacement final exact-SHA 全 required jobs PASS 前不创建冻结标签。

replacement run `31301693439@a61920b995d8c95d10e5353bfd593a21a941c1c9` 已证明 RSS 在 runner 上为 `790,839,296 < 805,306,368` bytes，但后续 Map quarantine fixture 的固定 15 ms delayed mutation 因调度错位 `_exit(94)`，整体仍为 7/8 且未进入 Apple build。I8 `0a3606ecd4e06086ea95c0ab99d92f4e80fcc2dc` / G8 `fc495be` 改为 descriptor no-follow open + identity bind 后、read 前的默认 `nil` host 同步点；production post-read path/inode/root 校验不变。两场景 20 次重复、默认 host 和独立复审均通过（`P0=0 / P1=0`），仍需新的 final exact-SHA required run。

I8 validation run `31303500822@9478aa5981c664abb98760e24aaba2a4ec537e12` 的 RSS 与退出 94 修复均通过，但更靠后的 tombstone source-replacement fixture 两步 `RENAME_EXCL` 以 91 退出，整体仍为 7/8。I9 `5c576dc0818f0908ef05ac1333b189aa9743d211` / G9 `ba6104c` 用同卷 `RENAME_SWAP` 原子交换 source 与 clone，原 inode 保留在审计路径；精确边界 50/50、默认 host 与独立复审 `P0=0 / P1=0`。仍需新的 final exact-SHA required run，Apple build 尚未被前述 runs 执行。

I9 validation run `31305157950@b22bd8878fcf001b38cca275b8eddcc6e48974e8` 的 runner RSS `792,576,000` bytes 与 I8/I9 fixture 均通过，但后续 mode-restore replacement 两步 rename 未完成时被通用退出码 19 掩盖，Python 在预期 replacement `0755` 处观察到原 source `0555`；整体仍为 7/8，Apple build 未执行。I10 `2b111d351173b80575d37229ad55c13b42d8c3f9` / G10 `f7cad97` 把 mode-restore、map-root、pending-root、embedded-diagnostic 替换改为原子 `RENAME_SWAP`，增加 mode/inode/payload 方向证明，并让 map-root swap failure 专用退出 95。最终源码 204 次聚焦执行、默认 host（peak RSS `493,305,856`）、完整 Python 外层长方法（tag peak RSS `688,111,616`）和独立复审均通过，结论 `P0=0 / P1=0`；仍须新的 exact-SHA required run。

I10 validation run `31307753672@8f0e730d92773eea2ab58f56742d901ac02eead4` 的七个非 Apple jobs 全部 PASS；Apple job 的完整 host contract、SwiftPM cold resolve、Xcode metadata 与 200k RSS `794,099,712 < 805,306,368` bytes 也 PASS。唯一失败是 iphoneos cold dependency 的 RTAB-Map configure 无法自动发现已生成在 `rtabmap/prebuild/bin/` 的 host `rtabmap-res_tool`，后续 simulator/device clean link skipped。I11 `37e6ed8c4afa00202693cd56919aea78fd4c7af5` / G11 `7eef33e` 先验证工具可执行，再显式传入 `RTABMAP_RES_TOOL`；全新 host prebuild、全新 iOS CMake configure、22/22 focused、Map Studio 109/109 与独立审查 `P0=0/P1=0` PASS。新 exact-SHA 8/8 前仍不冻结。

当前 RC 独立只读 diff review 已完成，状态为 **COMPLETED / BLOCKERS FOUND AND FIXED IN CURRENT DIFF**。本轮新增修复 committed RESCAN/Result 跨文件事务恢复、stale completed task error、RESCAN strict Bool/reason-disposition/EEXIST、Map quarantine 三个真实 `_exit` 崩溃窗口和 canonical integer、trace 超出 `Int64` 秒轴拒绝，以及 strict JSONL 每行 autorelease pool。规模证据包括 1,728,000 条 transition-storm trace 保留 172,801 条、300,000 条 finalization peak RSS 12,795,904 bytes、I7 的 200,000 burst frames + 200,000 observations 全链路 peak RSS 629,735,424 bytes。以上均是未优化 macOS host developer evidence，不构成 target-device scale PASS。

Mobile V1 产品路线固定为 Route A：Fast reduced graph 后至多一次 Full existing-graph optimization，仍失败即 `RESCAN_SESSION`。True sensor Deep 不属于 V1。当前状态保持 **REJECTED / NO-GO / developer smoke only**，不得声明 `DEVICE LAB TESTABLE`、`DEVICE LAB PASS`、`SAM FIELD PASS` 或 `PRODUCTION READY`。

2026-08-09 的 ESL blocker-closeout 核心 implementation I3 为 `fdcc5c87005a0128e0654eb43b1364898edd8f5d`。V3 exact-HEAD run `31276419986` 随后暴露 P0 Map Studio v1 manifest fixture 未同步新 Recovery/version/source-name 合同；fixture 修复进入 I4/G4。V4 run `31276999280@8ba2f697a8213a1bcd4bf6fb7197d155cb09b865` 为 7/8，唯一失败是 macOS/iOS host contract 的 §18 timer 固定等待抖动。Result recovery I5 `4d78d4646c01fe50bc0ac07eb2266879a24348db` / G5 `d2eb9e2cb9b349179c410205d8eb9f44c2c30188` 关闭 timer/worker 抖动和 tombstone authority-laundering P1。当前 ESL follow-up I6 `396097ea474be2e1155098cd709d1edfa9064a83` 已由 G6 `f65dbb0a3d0337ca926f4142489555d409089939` 绑定：加入独立 1 秒 Vision request deadline、固定两 lane executor、hung-lane quarantine/capacity fuse、cancel/append 线性化、tracking/prior-map hard-loss gate，并保证 manifest v3 中仅 localized tag v2 使用 verified burst exact-node authority，历史 tag v1 保持 legacy 路径。

当前 I6 可执行证据包括 ESL capture/finalization focused、ARFrame-only source contract **1/1**、Stage-3 **82/82**、localized-output-store **28/28**、session snapshot **10/10**，合计 **120/120 PASS**，以及 Python syntax、Swift parse 和补丁格式检查；最终冻结工作区的准确计数与审查结论以 [`reviews/CURRENT_REVIEW.md`](reviews/CURRENT_REVIEW.md) 和 `MOBILE_ONLY_V1R5_CLOSEOUT_REPORT.md` 为准。真实 LiDAR、Vision 性能和现场矩阵仍在 [`ESL_CAPTURE_TODO.md`](ESL_CAPTURE_TODO.md)。I5 Result recovery、I6 ESL follow-up、MapCase02、I7 RSS、I8 quarantine-race、I9 tombstone-swap、I10 atomic-fixture 与 I11 cold-build follow-up 最终独立复审均为 `P0=0 / P1=0`；低影响项已登记 TODO。run `31307753672` 为 7/8 FAIL，I11/G11 后仍需 committed replacement exact-HEAD run。上述 host 证据不关闭 Apple clean build、Device Lab、Sam field、exact-SHA CI 或 J-04，整体判定不变。

2026-08-02 的 Sam 真实扫描暴露了数据库位姿与 iOS prior-map 坐标契约不一致、reciprocal loop 被过严判为矛盾边、在线定位长期歧义和交互困难。现场证据、指标、根因、代码整改和同一优化数据库的只读回归结果见 [`SAM_SCAN_REPORT_2026-08-02.md`](SAM_SCAN_REPORT_2026-08-02.md)。修复后完整因子图已覆盖 4,442 个节点并收敛，测试草稿可查看；修复后的 iPhone 真机重扫和现场控制点验收仍未执行，不能据此标记生产通过。

P7R2 后续审查确认在线 hypothesis 的旧“修正变换”实际是 body-local translation，设备转弯时不保持不变。代码提交 `0a2a3ec50a851d52f96120a8f3d1669a7797e34e` 已改为显式全局 `T_map_from_arkit`，按候选地图位姿与原始 ARKit 水平位姿求逆组合、在地图坐标平滑，并由该变换重建安全修正目标；旧局部数学和未接线 temporal gate 已删除。该结论目前为 **IMPLEMENTED / AUTOMATED TESTED**，最终 exact-SHA CI 与 Sam 真机重扫待执行。

P7R3 代码提交 `0e2ce5133c8fb261fc1756111a5173c71d15b380` 已关闭 Recovery 生命周期缺口：新 episode 清空历史 local tracks、4 帧 trust 只用当前 episode 新证据、support 饱和为 120、40 次有效 matcher attempt 与 30 秒 wall-clock 双上限、repeated trigger 不重置 ID/support/budget/deadline，且 converged/timed-out/cancelled/manual-reset 统一清除 wide-search tracks。有效 attempt 只在 matcher 至少取得 30 个 effective points 后增加，ambiguous/mismatch 算一次实际搜索，nil/limited/no-depth/undersized observation 不计。P7R2 全局变换、5 m/30°总门与 0.35 m/8°单步门未改变。Windows 源码合同与 Python 回归通过；Swift host、iOS full build、exact-SHA CI 和真机仍待执行。

## 生产化总状态

当前发布判定是 **NO-GO / NOT PRODUCTION READY**。`repair-v2-w2r-safety-closeout@cf1b62c949f3574e1804808537e38c8ff643549c` 是生产化冻结基线；P0 在专用 CI job 中锁定 bounded solver 禁止发布、cleanup 确认与精确 CAS、复制后本地副本保留、required evidence 失败时 finalization fail closed 四项不变量，不修改业务算法。

P1 已实现并在真实 DB 上只读验证完整相对 SE(2) 因子图、canonical factor digest、严格 Python 二次校验和 fail-closed publish capability；设计见 [`FACTOR_GRAPH_DESIGN.md`](FACTOR_GRAPH_DESIGN.md)。P2 已加入 PC release presets、依赖 capability 门、source-bound `--version`、release/iOS dependency manifests，以及不允许依赖缺失静默 skip 的 hosted build 流程；本机 macOS 空目录构建与累计 SHA 的 hosted Ubuntu/Windows native clean build、Windows 全套回归、iOS cold-cache dependency manifest/cache 和 unsigned arm64 full App link 均已通过，见 [`REPRODUCIBLE_BUILD.md`](REPRODUCIBLE_BUILD.md)。P3 已完成 Map Studio 持久 journal、重启中断判定、子进程取消、运行日志留存和浏览器任务重连，见 [`PERSISTENT_JOBS.md`](PERSISTENT_JOBS.md)。P4 代码和主机压力测试已完成流式 finalization、descriptor-bound 读取、schema/大小门、copy receipt 隐私和 durability hook；真机 smoke 仍归 P5，见 [`IOS_FINALIZATION_HARDENING.md`](IOS_FINALIZATION_HARDENING.md)。

P5/P6 的真实执行尚未发生；仓库已提供失败关闭的设备/现场 evidence collector。P7R1 将 Field Plan/Evidence 升级到 v3：禁止自由 trajectory metrics，改由 immutable localized version 自动生成 typed trajectory evidence；每个 Device App SHA 精确绑定 release SHA，控制点 CSV 使用单次 descriptor-bound 读取。最终 evidence 以 `MarketScannerQualificationSourceBundle`、`MarketScannerTrajectorySourceBundle` 和 `MarketScannerFieldRunInputBundle` 三个 v1 合同自包含 exact plan/release/policy、trajectory source artifacts、控制点 CSV 和 Device Evidence bytes；Field v3 bounded stable-read 上限为 128 MiB，inspect/发布会重新派生指标、阈值和身份，摘要篡改并重算 SHA 仍失败。完整矩阵、真实设备身份、App/native/prior/session/package hash、冻结阈值、至少 3 次扫描与独立标签控制点缺一项即 FAIL，见 [`FIELD_TEST_PLAN.md`](FIELD_TEST_PLAN.md) 和 [`tools/Qualification/README.md`](../../tools/Qualification/README.md)。这只属于 **IMPLEMENTED / AUTOMATED TESTED**，不构成 **REAL DEVICE PASS / FIELD PASS**。

P7 已实现 loopback-only server、每次启动随机且不落盘的 token、POST token/Origin 门、CSP、安全 About/恢复信息、bounded 诊断包、启动 selfcheck、macOS/Windows launcher 和 hash-bound operator archive。P7R1 进一步让 development runtime 无条件禁止 publish，production 在事务前重新 selfcheck并只接受安装包内、与 package manifest 精确绑定的 release identity，忽略外部 release override；accepted Field Evidence exact bytes 进入 published manifest v4；package release/quality JSON 与 package 文件 hash 在主 descriptor 保持打开时使用前后 path descriptor 身份绑定，Windows 强制 binary read，About 使用真实 runtime mode，见 [`RELEASE_OPERATIONS.md`](RELEASE_OPERATIONS.md)。这些属于 **IMPLEMENTED / AUTOMATED TESTED**；只有最终精确 SHA 的全矩阵 run 才可标 **CI VERIFIED**。干净 Windows/macOS 安装、升级、卸载 smoke 尚未执行，不能视为 **HUMAN REVIEWED / PRODUCTION QUALIFIED**。

## 阶段一

| 能力 | 状态 | 代码/证据 |
| --- | --- | --- |
| XLSX 六类元素解析 | 已实现 | `tools/PriorMap/xlsx_reader.py`、转换测试、用户样例实转 |
| 唯一坐标/几何模块 | 已实现 | `coordinate_system.py`、90° golden 测试 |
| 版本化地图包、SHA-256、schema | 已实现 | 全文件解析、跨文件一致性、损坏包负向测试 |
| 道路图和有界空间索引 | 已实现 | road graph + 5 m structure/road grid，大索引查询测试 |
| dependency-free PNG 预览 | 已实现 | 默认兼容图 + 每层独立预览、PNG 解码校验 |
| PC 导入、进度、统计、warning、缩放预览 | 已实现 | Map Studio API/Web 和 API 测试 |
| iOS 双模式入口 | 已实现 | 新建按钮与菜单入口；自由模式默认流程不变 |
| iOS 五步向导 | 已实现 | 地图、楼层、起点/方向、设备检查、开始 |
| iOS 道路锚点快捷起点 | 已实现 | 起点步骤可从当前楼层道路节点选择锚点 |
| prior-map 仍写连续 RTAB-Map DB | 已实现 | 复用 `newScan`/`streamingDatabaseURL` |
| T_map_from_arkit、Recovery episode 与 2D HUD | P7R3 已实现，macOS/真机待验证 | P7R2 全局 `T_map_from_arkit` 保持；Recovery 需 4 个 episode-fresh observations，40 valid attempts/30 s，重复 trigger 不重置，所有 exit 清 track；5 m/30°总门、0.35 m/8°单步门与 corrected HUD 保持 |
| 单楼层定位边界 | 已实现 | 开始前绑定一层；无跨层切换；忽略二维高度但保留原始 3D |
| 道路软约束、歧义拒绝 | 已实现 | 2 Hz、有界道路索引、in-flight 丢帧门控、0.15 gain、0.25 m cap、Top-3 |
| 人工确认和审计 | 已实现 | manual v3 JSONL；native 原子 node/timebase/generation 快照；无一致 node 证据即拒绝 |
| synthetic/trajectory replay | 已实现 | 平移/旋转 drift、XY/yaw 误差、tracking loss、道路分配 |
| 旧会话和自由扫描兼容 | 已实现 | storage/workflow 分字段、PC regression |
| 完整业务首页五入口 | 部分实现 | 现有首页/菜单保留；新建扫描双模式已完成，独立“先验地图”首页入口尚未拆出 |
| 预定路线导入 | 未实现 | 可选增强项；当前只有道路图合成遍历和回放 |
| iOS 核心契约测试 | 已实现 | ARKit 前后左右/非零原点金标、模式门控、SE(2) 投影和 CameraMobile epoch node timebase 静态/PC 回归 |

## 阶段二

| 能力 | 状态 | 代码/证据 |
| --- | --- | --- |
| 线程、状态、距离场与失败策略 | 已实现 | `STAGE_2_DESIGN.md`、`PriorMapScanMatcher.swift`、in-flight gate |
| 多分辨率确定性距离场 | 已实现 | 0.40/0.20/0.10 m、2 m 截断、RLE、逐层 SHA-256、schema 负向测试 |
| 深度结构提取和扫描匹配 | 已实现 | scene depth、4 帧近期 world-voxel 静态证据、600 点上限、粗中细 Top‑5 多盆地、平行通道跨帧消歧、周期结构保守拒绝 |
| 状态和置信度滞回 | 已实现 | initializing/stable/usable/weak/lost/manualCorrection；连续可信和 stale 门限集中管理 |
| Vision QR/条形码识别 | 已实现 | 用户触发；复用 `ARFrame.capturedImage`；捕获时对齐快照与版本；四方向 ROI；QR/EAN/Code128/UPCE/PDF417 |
| 标签三维测量与结构关联 | 已实现 | 同帧 depth；楼面法向/残差/时序置信度；货架/柜台；跨结构遮挡；侧面、offset、高度和歧义门控 |
| 阶段二 sidecar 和移动 UI | 已实现 | constraint/state/tag observation JSONL、localized tags JSON、结构指标 HUD、确认 UI 和必需证据写失败的持久红色告警 |
| PC 会话检查 | 已实现 | `/api/session/inspect` 有界汇总约束、状态、观测、最终价签和 malformed 计数 |
| 阶段二回放与指标 | 已实现 | iOS 同款校正门控/gain/锚点/状态；周期结构、动态干扰、错误初始位姿、tracking 恢复、yaw/通道/跳变和 matcher p50/p95 |
| 结束并发与提交一致性 | 已实现（自动测试） | finalization 先失效 generation 并有界 drain；metadata 提交前复核实际 required evidence 文件、严格 JSONL/身份/数量/state 水位；失败写 `finalized=false`，成功提交后即为终态；checkpoint 删除失败绝不恢复写库 |
| Sidecar 故障与终端恢复 | 已实现（自动测试） | Foundation-only 可注入 writer 运行时覆盖 trace/constraint/state 部分失败、metadata 失败、checkpoint 删除失败；首个必需写失败后停止新修正/价签确认但保留原始 DB；手机/PC 清理使用 no-follow、文件身份复核、单 segment/path-component containment、失败审计；PC 要求 confirmed 与 expected evidence CAS，冲突返回 409 |
| Finalization 副作用接线 | 已实现（Foundation 集成测试） | completion 使用 `ScanFinalizationDisposition`；effect planner 覆盖恢复、正常终态、待清理终态和 ineligible recovery，只有提交前失败恢复 camera/mapping，needs-cleanup 禁止外部复制 |
| 原子可见 sidecar 写入 | 已实现（自动测试） | 同目录唯一 temp→write→synchronize→rename；write/flush/rename 故障保留旧字节；明确不承诺未经真机验证的 power-loss durability |
| 外部复制完整性 | 已实现（自动测试），provider 待真机 | 关闭句柄后复读目标，逐文件相对路径、字节数、SHA-256，并复核源目录未变化；生成 copy receipt，默认保留本地唯一副本 |

2026-07-25 综合审查整改：地图包新增全文件清单并由 iOS 做摘要/跨文件校验；货架面语义对正方形/环方向稳定，柜台支持全部边；价签改为密集 ROI 深度证据和快照时效门；拒绝候选不再预热校正门；HUD 增加有界轨迹/价签层并折叠诊断；finalization 不再在主线程等待。

## 阶段三

| 能力 | 状态 | 代码/证据 |
| --- | --- | --- |
| RTAB-Map 重处理前置和源库只读 | 已实现 | `run_localized_map` 强制 `rtabmap-reprocess`；前后 SHA‑256 一致 |
| 先验地图派生修正 | 已修复并完成 Sam 只读回归 | 精确 `ios_prior` 契约；reciprocal canonical 折叠；native RTAB-Map/g2o 完整相对 SE(2) 因子图 4,442 节点收敛，最大修正 2.9638 m；仍是诊断 draft |
| 在线/道路/人工约束与拒绝审计 | 已实现 | 在线结构约束、道路区域/方向低权重软约束、accepted/rejected residual、禁用约束、人工锚点 |
| 通道切换审计 | 已实现 | 最终轨迹几何投影输出进入/离开时间、候选 margin、方向、weak/lost overlap、人工 assignment 和可能静默切换 |
| 标签离线重算和结构关联 | 已实现（保守门控） | observation→真实 node/frame time 绑定、raw 位置 SE(2) 传播、独立次候选/遮挡/侧面/边长校验；失败进入 review 或阻断 current |
| Sidecar 输入契约 | 已实现 | 每类 required/optional、format/version、严格 UTF‑8/JSON、身份/时间/业务 schema/大小/唯一 ID；legacy manual 仅审计；tag/observation 内容交叉验证；损坏 fail closed |
| 节点覆盖审计 | 已实现 | 只读查询 source/optimized SQLite Node，和导出 node ID 三方比较缺失、额外、重复、非单调 stamp 与首尾时间；metadata 仅交叉检查 |
| 导出隐私与本机恢复 | 已实现 | version 内 `session_input_manifest.json`/input identity 绑定全部输入字节；绝对路径按 identity 隔离在不导出的 `localized/local_inputs/`，重放前验证 version、身份和当前输入 hash |
| 不可变成果事务 | 已实现 | POSIX/Windows 跨进程锁内 staging→完整文件/hash 校验→`versions/vNNNNNN`→单指针提交；Windows write-through move、版本/指针 durability 故障注入；读取与已打开 fd 复核 hash；损坏状态拒绝降级 |
| 质量报告和状态机 | 已实现（仍受现场发布门约束） | draft/review/published/revoked 事务框架和门禁；完整相对 SE(2) helper 报告通过严格能力校验后才允许进入发布判断 |
| 人工编辑重放/撤销/重做 | 已实现 | manual_edits v4 与 input identity、强制 version/revision CAS、HTTP 409、服务端 old value/UTC/ID、字段/范围/地图校验、undo/redo audit |
| PC 非专业向导 | 已实现 | 地图+会话选择、一键处理、三轨迹/价签联动画布、状态/货架筛选；轨迹锚点可直接点选/拖动并自动生成 node/time/JSON |
| 确定性 E2E fixture | 已实现 | 源库不变、漂移降低、错误约束拒绝、事务/输入变更故障、双线程客户端同基准 CAS 冲突、409、发布硬门、严格 sidecar/capture-health 负例 |
| 正式现场验收 | 未执行 | 只完成 `FIELD_TEST_PLAN.md`；不能用模拟或构建替代 |

操作流程、弱/丢失定位、人工复核、备份和失败恢复见 `USER_GUIDE.md`。

## P3 持久任务

| 能力 | 状态 | 代码/证据 |
| --- | --- | --- |
| 原子任务 journal | 已实现 | `StudioState` 的 versioned JSON、文件和目录同步、有限时间戳/路径/状态校验 |
| 浏览器刷新恢复 | 已实现 | `GET /api/jobs` 恢复最近活动或完成任务 |
| 服务重启判定 | 已实现 | 活动态 fail closed 转换为 `interrupted`，不猜测继续、不发布 staging |
| 操作者取消 | 已实现 | 持久取消意图；原生子进程 terminate→有界 wait→kill；partial 清理 |
| 原生运行日志 | 已实现 | fast/discovery 独立日志、严格文件名和任务归属下载 |
| 损坏 journal/保留策略 | 已实现 | health 报告 startup error；不按不可信路径清理；默认保留 200 个终态任务 |
| 自动回归 | P7R3 Windows 可执行部分通过 | 源码/sidecar 合同 15/15；PriorMap Python 20/20，Swift host 1 项因无 xcrun 按预期延期；Swift executable 已新增 R1—R12（fresh support、stale A/new B、valid budget、repeat、exit cleanup、5 m/30°、score formula），必须由 macOS CI 实际执行。完整 Windows 套件的 symlink/CMake 环境项与 exact-SHA CI 单独记录，不替代人工验收 |

## 尚未完成的发布门槛

- P2 自动化 clean-build 出口已由累计 SHA 的 Ubuntu/Windows native build 与 hosted iOS cold-cache full link关闭；P7 的干净 Windows/macOS 安装、升级和卸载 smoke 仍未执行；
- 支持 LiDAR 的真实 iPhone 上完成完整开始、弱纹理、行人干扰、扫码、结束落盘和外部复制干跑；
- 已按 2026-07-28 外部静态审查关闭 W2 B-01 与 W2R H-01 至 H-04/M-01 至 M-05；远端多平台 CI run `30342577182` 已绑定准确提交并通过，独立人工复核仍待执行；
- 正式超市场景验收；
- 对更多真实 DB 固化相对边 residual 工程阈值，并由 clean CI 构建 helper；P1 单样本通过不替代现场 acceptance；
- 修复后的 iPhone 真机重扫，确认多候选恢复、动态购物车过滤、热状态与自适应检测率在 Sam 场景中的实际效果。
- P7R3 最终治理 HEAD 的七组 exact-SHA CI 与独立只读代码审查。

自动测试和模拟回放不替代以上现场与独立审查。

## 兼容说明

实施 Prompt 建议把业务模式直接写入 `scanMode`，但当前生产协议用 `scanMode=continuous_streaming` 判定单库安全处理。阶段一因此新增 `workflowMode` 承载 `free_mapping/prior_map_localized`，保留原 storage marker。这是为了满足“不破坏自由扫描和旧 PC 流程”的更高优先级约束。

# P7R4 Recovery confidence closeout update

P7R4 production implementation `981ff4e208f74c8d4dd451d32df88233089e3201`, based on cloud P7R3 `998c175e40562fffd85fe45579a358c485a65b30`, is **IMPLEMENTED / focused AUTOMATED TESTED**. It closes intermediate-step confidence promotion, timeout/final-step ambiguity, strict post-match deadline enforcement, automatic Recovery cooldown, episode-bound completion diagnostics, matcher search disposition, post-Recovery Local trust, automatic tag-confirm safety, and exposes the real localizer anchor/frame-disposition/completion-binding boundaries to production-shared integration tests. The shared update reducer produces correction, confidence, constraint, Recovery action, next phase, and diagnostics for both production `update(frame:)` and T5/T6/T8/T12. P7R2 global alignment and P7R3 episode freshness/budget/cleanup invariants remain unchanged.

Swift host execution, Xcode/UIKit/ARKit, LiDAR, exact-final-SHA seven-group CI, independent review, and Sam field re-test are not yet complete and must not be reported as PASS. Current release status remains **NO-GO / NOT PRODUCTION READY**; the maximum pre-field decision after CI and independent review is `READY FOR HUMAN SAM RE-TEST`.

# P7R5 Recovery terminal closeout update

P7R5, based on P7R4 HEAD `e2b1cf4142b5a3bc353909af77158199bbf09e5f` (implementation `981ff4e208f74c8d4dd451d32df88233089e3201`), is **IMPLEMENTED / focused AUTOMATED TESTED** on branch `repair-v2-p7r5-recovery-terminal-closeout`; its exact implementation SHA is bound in `.github/marketscanner-repair-v2-wave.json`. It closes F-01 (the automatic cooldown is now reconciled against the terminal outcome: convergence and manual reset clear stale cooldown, timeouts extend it regardless of trigger source, cancellations follow their explicit reason), F-02 (every terminal Recovery completion, including scan-stop and map-unload cancellations, is persisted as `MarketScannerRecoveryLifecycleEvent` v1 evidence in `localization_recovery_events.jsonl` before localizer teardown; append failures fail closed and make the session processing-ineligible), F-03 (pending-completion elapsed time is bound to the completion finish time through one shared diagnostics reducer), and F-04 (repeated triggers retain a bounded source summary: automatic/reliable-loop counters, last reason/uptime, and at most eight trigger records). P7R2 global alignment, P7R3 episode budget/freshness, and P7R4 confidence/provisional/deadline invariants remain unchanged.

# P7R6 Recovery evidence integrity closeout update

P7R6, based on P7R5 governance HEAD `970d03fbf18f8c9274f6dfb7ee0b8a79ee193c3f` (P7R5 implementation bound in `.github/marketscanner-repair-v2-wave.json`), is **IMPLEMENTED / focused AUTOMATED TESTED / INTEGRATION TESTED** on branch `repair-v2-p7r6-recovery-evidence-integrity-closeout`; its exact P7R6 implementation SHA is bound in the same governance descriptor. It closes R6-01 (capture health now carries the exact recovery expected-count watermark; the watermark advances exactly once per confirmed durable append, finalization validates the exact count and the last episode/finish uptime, and a missing file or a rebuilt empty file while the watermark is positive stays a hard blocker), R6-02 (the PC input manifest version 2 binds `localization_recovery_events.jsonl` into the canonical bundle SHA; legacy sessions keep version 1 and are explicitly marked `recovery_lifecycle_evidence_unbound_legacy`), R6-03 (the lifecycle schema is validated strictly on device and on the PC reader, with version 2 adding `deadline_uptime`, `maximum_valid_attempts`, and bounded `trigger_records`), R6-04/R6-05 (the Foundation-only `RecoveryLifecyclePersistenceCoordinator` persists terminal evidence through peek/ack with structured results, idempotence strategy A, and retryable failures), and R6-06 (exact-SHA governance binding). Executable teardown-to-finalization transactions (W1-W11 watermark integrity, I1-I15 persistence transactions, P1-P8 input manifest identities) run in the Swift host and the PC test suite. The localized report now exposes `recovery_summary` and a `recovery_gate` whose blockers enter both the review and publish gates. P7R2 global alignment, P7R3 episode budget/freshness, P7R4 confidence/provisional/deadline, and P7R5 cooldown/cancellation/elapsed invariants remain unchanged. Exact-final-SHA seven-group CI, a clean Apple build, the independent review, and the Sam field re-test are still NOT RUN and must not be reported as PASS; the release judgment remains **NO-GO / NOT PRODUCTION READY**.

# P7R6A Recovery persisted parser closeout update

P7R6A, based on P7R6 governance HEAD `4bce394bdfb7f6c7c2373f314814a3e3260356fe` (P7R6 implementation `a315ff6e5c0ca639f12c639aaf81be6738195e2f`), is **IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED** on branch `repair-v2-p7r6a-recovery-persisted-parser-closeout`; its exact implementation SHA is bound in `.github/marketscanner-repair-v2-wave.json`. It closes the residual parser-contract split found by the P7R6 review: (A) the persistence coordinator no longer decodes persisted records with a plain `JSONDecoder`; it validates the complete stable-read snapshot through the new shared strict parser (`RecoveryLifecycleEvidenceParser.swift`) before any append or acknowledgement, exactly the parser finalization now delegates to; (B) a complete JSON tail without its final newline is rejected by both sides (`missingFinalNewline`) so no completion can be acknowledged and later rejected by finalization; (C) historical v1 records are genuinely readable by the coordinator without fabricating `deadline_uptime`, `maximum_valid_attempts`, or `trigger_records`, mixed v1/v2 files validate, and a v1/v2 same-episode pair is a version conflict instead of an idempotent merge; (D) `attemptedEpisodeIds` reports only episodes the transaction actually entered — pre-transaction failures report an empty list and never disguise a read/parse failure as an attempt on episode 1; (E) governance and CI rebinding is executed on the final P7R6A HEAD. Executable evidence: the P-A1..P-A20 Swift host tests (v1/v2 mix, version/bytes/order conflicts, missing-final-newline/blank/partial/unknown/duplicate/order/finish/identity rejections, exact idempotence, attempted-ID precision, watermark edge cases, stable-read swap/truncate/symlink/hard-link fail-closed) plus the shared Swift/PC fixture alignment asserting identical categories on both readers. P7R2 global alignment, P7R3 episode budget/freshness, P7R4 confidence/provisional/deadline, P7R5 cooldown/cancellation/elapsed, and P7R6 watermark/input-manifest-v2/schema invariants remain unchanged. Exact-final-SHA seven-group CI on the P7R6A HEAD, the clean Apple build, the independent read-only review, and the human Sam re-test remain NOT RUN / PENDING and must not be reported as PASS; the release judgment stays **NO-GO / NOT PRODUCTION READY**, and `REAL DEVICE PASS` / `SAM FIELD PASS` / `PRODUCTION READY` remain forbidden until LiDAR real-device and on-site Sam testing complete.

# P7R6B Strict JSON and pending-queue closeout update

P7R6B, based on P7R6A governance HEAD `f4524d958913e927a33a7295f45ccf7b3a98d42a` (P7R6A implementation `01a42a40e9671c709c4e0f9e1f85839a48dd4a83`), is **IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED** on branch `repair-v2-p7r6b-strict-json-pending-queue-closeout`; its exact implementation SHA is bound in `.github/marketscanner-repair-v2-wave.json`. It closes the four open findings of the P7R6A review without regressing P7R2/P7R3/P7R4/P7R5/P7R6/P7R6A contracts:

- B1 Strict booleans: all formal evidence schemas now read JSON booleans through `StrictJSONScalar.boolean`, a CoreFoundation `CFBooleanGetTypeID` check, so a numeric 0/1 is rejected exactly like the PC reader's `isinstance(value, bool)` rejects it (`episode_automatic`, `completion_frame_step_applied`, trigger `automatic`, constraint `accepted`, tag `needs_review`/`user_confirmed`, prior-map `visible`/`valid`). Shared fixtures `numeric_episode_automatic.jsonl`, `numeric_completion_step.jsonl`, `numeric_trigger_automatic.jsonl` are rejected on both readers.
- B2 Duplicate JSON keys: `StrictJSONKeyUniquenessValidator` scans the raw UTF-8 bytes before `JSONSerialization` (iterative, bounded depth/tokens, escape- and surrogate-aware), and the Python reader passes an `object_pairs_hook` to `json.loads` on every formal JSON/JSONL read. Top-level, nested and escaped-equivalent duplicate keys (`{"episode_id":1,"\u0065pisode_id":2}`) are all rejected; stable categories `duplicate_json_key` (Swift/PC/shared fixtures), `existing_evidence_duplicate_json_key` (coordinator), and the `evidence_bundle_*_duplicate_json_key` finalization blocker.
- B3 Pending queue: the coordinator no longer sorts the pending queue. It validates positive unique episode IDs in strictly increasing order plus finite, non-decreasing finish uptimes before any snapshot read/append/ack; violations report `attemptedEpisodeIds=[]`, `persistedEpisodeIds=[]`, the first offending episode, and `pending_episode_duplicate` / `pending_episode_order_invalid` / `pending_finish_order_invalid` with zero writes. Effective persisted state advances inside the transaction so the coordinator can never write a duplicate episode even under a future source-contract regression.
- B4 Unified limits: `RecoveryLifecycleEvidenceLimits` (16 MiB file / 1 MiB record / 100,000 records / 8 trigger records / depth 32) is referenced by the parser, the finalization validator, the session stable-read snapshot and the PC reader (`RECOVERY_MAXIMUM_*`); the PC reader checks file size before reading and enforces the nesting depth per line. Exact-limit boundary tests cover file bytes, record bytes and depth on both sides.

Executable evidence: P-B1..P-B15 Swift host tests (SB1-SB6 strict scalars, DK1-DK3 duplicate keys, PQ1-PQ7 pending-queue order/uniqueness/idempotence, unified limit boundaries), the three numeric and three duplicate-key shared fixtures under `tools/PriorMap/tests/fixtures/recovery_lifecycle/`, and the expanded Swift/PC fixture-alignment assertion. The pending-queue reversal behavior of the old P7R6 test was updated to the fail-closed contract (reversed queue is rejected, never sorted). Exact-final-SHA seven-group CI on the P7R6B HEAD, the clean Apple build, the independent read-only review, and the human Sam re-test remain NOT RUN / PENDING and must not be reported as PASS; the release judgment stays **NO-GO / NOT PRODUCTION READY**, and `REAL DEVICE PASS` / `SAM FIELD PASS` / `PRODUCTION READY` remain forbidden until LiDAR real-device and on-site Sam testing complete.

# P7R6C Stable-input snapshot and total JSON validator closeout update

P7R6C, based on the P7R6B governance HEAD `fd3fb4a84bd8da3770a81d455c2cc428f7479567` (P7R6B implementation `fd3fb4a84bd8da3770a81d455c2cc428f7479567`), is **IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED** on branch `repair-v2-p7r6c-stable-input-total-json-closeout`; its exact implementation SHA is bound in `.github/marketscanner-repair-v2-wave.json`. It closes the six findings of the P7R6B review without regressing P7R2/P7R3/P7R4/P7R5/P7R6/P7R6A/P7R6B contracts:

- C1 Total JSON validator: `StrictJSONKeyUniquenessValidator` is now a total function over arbitrary `Data` — a strict RFC 3629 UTF-8 pass rejects overlong encodings, UTF-8-encoded surrogates, scalars above U+10FFFF, invalid/truncated continuations; the structural scan uses `withUnsafeBytes` (no whole-file copy), decodes `\uXXXX` escapes with explicit high/low-surrogate pairing and never force-unwraps (the empty-stack `stack.last!` trap found by the U1/U10 fuzz was removed). Errors carry byte offsets; the 10,000-iteration deterministic fuzz (U10/TJ9) proves return-or-throw only.
- C2 Byte-derived progress bound: the fixed 1,000,000-token cap that wrongly rejected large legal tag catalogs is gone. The scanner now enforces `maximumIterations = data.count * 4 + 1024` (a bug detector, provably above any legal document), `StrictJSONDocumentLimits` derives limits from `maximumBytes`, and the 16 MiB whole-array tag file is scanned and parsed without copying the `Data`. L1/L2/L3 (10k/30k/50k-equivalent fitting counts), L4 (16 MiB+1 size-limit rejection), L5/L6 (last-tag duplicate key and numeric boolean still detected at the tail) pass; the duplicate-key scan plus JSONSerialization of the largest fitting catalog stays under the CI wall-clock and memory budget.
- C3 Prior-map package snapshot: `PriorMapPackageSnapshotReader` reads every authoritative artifact exactly once through the descriptor-bound `SafeSessionPath.readRegularFile` (no-follow, regular file, `st_nlink == 1`, size bounded, pre/post identity), hashes and strictly parses the same bytes, and freezes package limits (2 MiB manifest / 64 MiB JSON / 64 MiB preview / 512 MiB total / 128 artifacts). `PriorMapPackageIntegrity.validate(snapshot:)` and `PriorMapPackage.load` consume only the snapshot, so the returned package SHA can never describe bytes the loader never parsed. Integrity suite cases cover same-size self-consistent replacement, symlink, hardlink, truncation, file-set change, preview/floor-preview swap and manifest/elements/report duplicate keys (M1-M12).
- C4 PC finalized-session snapshot: `read_finalized_session_input_snapshot` reads metadata, the source database, all six JSONL sidecars and `localized_price_tags.json` exactly once through descriptor-stable reads; the manifest identities are derived from those same bytes, so `session_input_bundle_sha256` always describes what localization parsed. `process_localized_session`/`_render_localized_version` consume the snapshot (no path re-opens), SQLite only opens a descriptor-verified immutable copy of the source database (Plan A), and the before/after manifest re-verifications remain as tamper gates. S1-S12 snapshot tests cover metadata/hash consistency, sidecar symlink/hardlink/truncate, tags/recovery swap, source-DB verified-copy mutation, and bundle recomputation.
- C5 Prior-map strict schema: the shared `strict_json` helpers (strict UTF-8, NaN rejection, `object_pairs_hook` duplicate rejection, iterative nesting depth) back `prior_map_schema.load_json` and every offline reader; the iOS integrity validator reads integers/numbers/booleans/geometry/bounds through `StrictJSONScalar`. N1-N9 reject fractional versions, boolean counts/bytes/visibility, boolean coordinates/bounds and duplicate/escaped-equivalent keys; N10 keeps the Swift/PC parity through the shared fixtures.
- C6 Exact-SHA CI: the CI `swiftc -parse` list, the Swift host compile list and the Xcode project register the two new Swift files; the platform-independent contract job runs the Swift host and C4 snapshot suites.

Executable evidence: C1/C2 U1-U10/TJ9/TJ10 and L1-L6 Swift host tests, the C3 integrity-suite cases, the C4 S1-S12 PC snapshot tests, the C5 N1-N9 strict-schema tests, plus the shared Swift/PC fixture alignment. The seven-group exact-final-SHA CI on the P7R6C HEAD, the clean Apple build, the independent read-only review, and the human Sam re-test remain NOT RUN / PENDING and must not be reported as PASS; the release judgment stays **NO-GO / NOT PRODUCTION READY**, and `REAL DEVICE PASS` / `SAM FIELD PASS` / `PRODUCTION READY` remain forbidden until LiDAR real-device and on-site Sam testing complete.

# Mobile-Only V1 end-to-end implementation status

Based on the P7R6C governance HEAD `04cdfe9a4c533908d1eb175ba84e3e39d2ca2654`, the
`mobile-only-v1-end-to-end-integration` branch implements the Mobile-Only V1
track: on-device map import (XLSX/CSV/JSON), on-device prior-map compilation,
session snapshot transaction + Fast Path SE(2) factor graph, 1 Hz final
trajectory with local time, tag finalization and the four-sheet XLSX workbook.

Status words per module: IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED (Swift
host suites I/C/P/T/G/X plus the three-format `--import-suite`); NOT CI
VERIFIED, NOT DEVICE SMOKE PASS, NOT SAM FIELD PASS, NOT PRODUCTION QUALIFIED.
True sensor Deep (sensor decode/reprocessing that reconstructs missing visual evidence) is outside Mobile V1 and is not a pending V1 implementation route. The compatible `deep_*` state names refer only to the single Full existing-graph optimization allowed by Route A. Full details are in `docs/mobile-only/`.
