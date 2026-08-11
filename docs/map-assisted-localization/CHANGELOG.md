# 地图辅助定位变更记录

> 文档状态：**当前有效**。最后核对日期：2026-08-11。

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
