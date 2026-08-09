# 地图辅助定位变更记录

> 文档状态：**当前有效**。最后核对日期：2026-08-09。

## 2026-08-09 — MapCase02 标准工作簿格式/几何阻断级收口

- I8 validation run [`31303500822`](https://github.com/mcjiansheng/MarketScanner/actions/runs/31303500822) 的 RSS `793,296,896 < 805,306,368` bytes 且原退出 94 fixture 已通过；随后独立 tombstone source-replacement fixture 的两步 `RENAME_EXCL` 以 91 退出，Apple build 仍未执行，run 为 7/8、未冻结。
- I9 `5c576dc0818f0908ef05ac1333b189aa9743d211` 将该 fixture 改为同 parent/volume `RENAME_SWAP`：durable tombstone 后一次原子交换 source 与 byte-identical clone，原 inode 直接保留在 `tombstone-original-*`。swap 失败仍退出 91；精确边界 50/50、默认 host 与独立复审均 PASS（`P0=0 / P1=0`）。进一步显式绑定交换前后双方 inode/payload bytes 仅登记 TODO。
- replacement exact-SHA run [`31301693439`](https://github.com/mcjiansheng/MarketScanner/actions/runs/31301693439) 的 200k tag-evidence RSS 已以 `790,839,296 < 805,306,368` bytes 通过；随后 Map quarantine delayed-replacement fixture 因固定 15 ms 调度错位 `_exit(94)`，macOS/iOS job 失败且 Apple build 未执行，run 仍为 7/8、未冻结。
- I8 `0a3606ecd4e06086ea95c0ab99d92f4e80fcc2dc` 在 payload/diagnostic descriptor 已 `O_NOFOLLOW` 打开并完成 fstat/expected identity 绑定之后、读取之前提供默认 `nil` 的 host observer；fixture 在该同步点确定性替换，production 仍沿原 FD 读取并执行 post-read path/inode/root sweep。两个场景 20 次重复与默认 host suite PASS，独立复审 `P0=0 / P1=0`；128 MiB fixture 缩小及精确 rejection category 断言仅登记 TODO。
- validation HEAD `770d94b078a0dd94653b9d6b33576890f88f7296` 的 exact-SHA run [`31299358502`](https://github.com/mcjiansheng/MarketScanner/actions/runs/31299358502) 为 7/8：除 macOS/iOS 200k tag-evidence RSS 外全部 required jobs PASS；失败值 `812,892,160` bytes，比 768 MiB 门高 `7,585,792` bytes，因此未创建冻结标签。
- RSS blocker implementation I7 `cbba284ad1b0694f5302ec3abbb9a446d9d3a970` 删除 burst frame dictionary value 中重复 observation ID，并把已严格验证的 view/tracking 有限域压缩为单射 `UInt8` code；observation key lookup、所有数值/身份 exact-match、duplicate/already-consumed 与 remaining-frame fail-closed 合同保持不变。新增全域 round-trip/mismatch/unknown 回归；本地同一 200k 规模为 `629,735,424` bytes，低于门约 167.4 MiB，独立复审 `P0=0 / P1=0`。replacement final exact-SHA 全绿前仍不冻结。
- 正式 XLSX 以 `Basic Info + Element Info` 为权威，`Shelf Info` 仅审计；冻结 top-left anchor/pivot、生产角色集合、active/ignored 统计和 100,000 元素上限。
- Swift/PC 同步关闭 relationship/worksheet alias、External/歧义 target、XML root/namespace 伪 authority、row/cell 引用、shared-string/boolean/公式、单元格大小、严格 JSON 数值与 duplicate element ID 的 fail-open/crash 路径；workbook sheet/relationship 各限制 4096 并使用线性索引。
- prior-map v2 完整性从权威 active elements 重建 canonical identity、road graph、spatial index、distance fields 和 shelves-v2 segment；六字段 bounds、可选 `center_m/yaw_rad` 严格 finite 数值与 stable business identity uniqueness 均 fail closed。距离场在任何分配前执行 20k 单维、8m 单层、16m 包总 cells 上限与 RLE row budget。
- `mapcase02.xlsx` 冻结结果：源 1838、active 1630、shelf 1301、fixed 329、road 0、presentation 208、active 越界 0；canonical `5ddfac…2db`、Swift package `5cc223…72a`、preview `d0c02b…a18` 未漂移。
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
