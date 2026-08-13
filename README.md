# RTAB-Map 大型超市扫描与地图工作台

> 文档状态：**当前有效**。最后一次与源码交叉核对日期：2026-08-13。

本项目是在开源 **RTAB-Map** 基础上进行的业务化改造，面向大型超市、仓储卖场等室内场景，形成从 iPhone Pro 连续采集，到 PC 端离线优化，再到二维地图、彩色俯视图和三维预览的一套本地工作流。

当前源码中的 RTAB-Map 版本为 **0.23.5**。上游项目原始 README 已保存在 [doc/README.md](doc/README.md)，便于查询 RTAB-Map 官方主页、安装说明、ROS 支持和上游 CI 信息。

> 本仓库不是 RTAB-Map 官方发行版。RTAB-Map 的原始著作权和 BSD 许可仍归原作者所有；本仓库在其通用 SLAM 能力之上增加了超市连续采集、离线处理和地图交付功能。

## 项目目标

原始 RTAB-Map 是一个通用的实时外观建图系统，提供视觉/激光里程计、回环检测、位姿图优化、RGB-D 数据库、点云和占据栅格等能力。本项目保留这些基础能力，并针对实际超市作业补充以下闭环：

```text
iPhone Pro RGB-D / LiDAR / IMU / ARKit 采集
  -> 连续写入单个 RTAB-Map SQLite 数据库
  -> 位姿质量门控、在线回环 map→odom 同步、跨帧结构覆盖提示、自适应关键帧与设备安全保护
  -> 完整会话导出到 PC
  -> 数据库检查与自适应离线闭环/全局优化
  -> 轨迹安全验证
  -> 2D 占据图、货架/竖直结构轮廓、彩色俯视图、3D 预览与业务图层
  -> 质量报告、来源清单和人工复核
```

设计重点是：手机端优先保证原始数据连续、可靠落盘，计算量较大的闭环补充、全局优化、结构投影和成果整理放到 PC 端完成；原始扫描数据库保持只读，所有处理结果写入新的输出目录。

## 与原始 RTAB-Map 的关系

### 保留的上游能力

- `corelib/`：RTAB-Map 的记忆管理、回环检测、图优化、数据库、传感器数据和地图算法。
- `guilib/`：桌面图形界面与可视化组件。
- `utilite/`：日志、线程、文件和通用工具库。
- `app/`：桌面、Android 和 iOS 应用入口。
- `tools/`：数据库查看、重处理、导出、数据集转换等上游命令行工具。
- `examples/`、`archive/`、`docker/`：示例、研究材料和容器环境。
- CMake 构建体系、ROS 包描述以及原项目的 BSD `LICENSE`。

### 本项目的主要改编

| 范围 | 改编内容 |
| --- | --- |
| iOS 采集 | 增加超市扫描会话、连续流式单库、跨帧结构覆盖顾问、自适应关键帧、中文界面、sidecar 数据和外部目录复制 |
| 移动原生层 | 增加相机原点保持、连续地图模式、有界实时渲染、在线回环 map→odom 同步、数据库操作和 Swift/C++ 桥接能力 |
| 稳定性 | 对 ARKit tracking 恢复和不合理位姿跳变进行质量门控；用跨时间/视角的深度证据抑制单帧行人噪声；按内存、磁盘和热状态降低预览、限制采样或安全结束 |
| PC 优化 | 扩展 `rtabmap-reprocess` 的进度、约束统计和最终求解流程，支持工作台执行自适应离线优化 |
| 地图生成 | 新增单设备、历史多阶段、多设备二维地图脚本，输出占据图、融合地板空缺、自由空间、竖直面与层板证据的货架实例闭合边界、轨迹、GeoJSON 和质量报告；保留旧价签数据兼容解析 |
| 可视化工作台 | 新增仅监听本机的 Web 工作台，统一进行输入检查、处理编排、2D/3D 预览、日志和结果检查 |
| 性能加速 | 提供 Release/OpenMP 配置，以及 Apple Metal 或 NVIDIA CUDA 深度投影 helper；不可用时明确回退 CPU |

Android 目录中的部分 C++ 原生实现也因共享移动渲染和数据库能力而被扩展，但当前完整的超市现场采集交互主要实现在 iOS 应用中。

## 当前采集方案

### 统一的全手机门店扫描主流程

当前发布目标只有一条主链路：首页大型“新建扫描”和右上角菜单的“开始门店扫描”先进入同一个轻量地图选择页。用户可以选择已注册地图，也可以直接导入新地图；只有确认某一张地图后才完整验证并加载该包，再进入楼层、起点和朝向配置。地图可以来自手机现场编译的 `XLSX / CSV / JSON`，也可以来自 PC 已生成并通过 production validator 的正式 v2 地图包，但安装后都进入同一个内容寻址地图库，并复用同一套配置、设备检查和启动事务。选择页完成首屏绘制后会在主线程空闲轮次预先构造一次导入菜单、导入页和系统文件选择器；这只预热 UIKit/UTType/FileProvider，不读取 provider 文件、不创建 workflow 事务，真实暂存和编译仍在用户选择文件后进入原后台队列。自由扫描建图与原始数据录制仍保留，但降级到“实验与兼容工具”，不再占据主入口。

正式超市 XLSX 使用 `Basic Info + Element Info`，`Shelf Info` 仅审计。文件尚未选择时不显示 0% 和空进度条；provider 已返回文件并开始安全暂存后，手机编译过程才显示复制、严格解析、身份/元素校验、道路图、逐楼层/逐分辨率距离场、空间索引、预览、manifest、自验证、提交和注册等真实阶段。完成页显示门店 ID、地图 ID、package SHA、canonical SHA、楼层和元素/警告统计，不再只提示“导入成功”。

统一配置页只接收已经明确选择的一张地图，不再包含会触发重复加载的地图 picker。它支持 1×—8× 捏合缩放、单指平移、双击放大/复位和点击选点；起点可用方向键按 0.1 m / 0.5 m / 1.0 m 微调；朝向使用东/北/西/南和左右 15° 微调，不再使用横向滑杆。地图航向统一使用标准 SE(2) 合同：`0° = +X/东/屏幕右`、`90° = +Y/北/屏幕上`，逆时针为正；配置箭头、ARKit 首帧对齐、深度局部坐标、人工重选和扫描 HUD 必须消费同一数值。手机 CoreGraphics 预览、UIKit 触点和 canonical 地图几何共享同一 +Y 合同，预览只在 UIKit 触点转换时执行一次纵向翻转，避免画面白色通道被误映射到货架。地图选择 root 页面有关闭按钮，配置页使用系统返回按钮/手势；离开页面会取消尚未完成的启动事务。

开始扫描前先完成 build identity、地图身份和相机权限检查。包校验、localizer 构造、会话目录和 native SQLite 初始化在串行后台队列执行，主线程只承担短暂的 UIKit/ARSession 状态切换。扫描只有在 ARSession、RTAB-Map、sidecar writer、durable receipt 和 workflow context 全部提交后才进入 `scanning`；任一步失败或取消都会停止相机/映射、释放会话身份并脱离失败数据库，不能留下“幽灵扫描”。共享 `RTABMapApp` 的默认 Run 已改为严格 Release 身份构建，普通点击 Run 即可进行真机扫描；Test/Analyze 和手动 Debug 配置仍为 Debug 并继续 fail closed。`RTABMapApp-QualifiedDevice` 保留为等价的显式资格入口，二者都不提供 dirty bypass。

已有地图模式的定位和 PC 草稿复核能力保持不变：手机只接受小幅、唯一且连续一致的自动结构修正；PC 先运行 RTAB‑Map 重处理，再运行 native 完整相对 SE(2) 因子图、质量报告、人工复核和价签导出。native helper 缺失、执行失败或结果破坏已验证物理连续性时，回退到不可发布的连续有界修正场并保留 native 审计；当前质量策略仍是 candidate，且真机/现场资格未完成，因此不能据此宣称生产发布通过。

长距离累计漂移后的手机人工重选位置按“严格绑定的绝对地图锚点”处理，而不是手机物理瞬移。只有 v3/exact-node/身份与时间证据完整的事件可跨越大绝对残差参与求解，并按约 3 米人工点击不确定度审计；旧 v2/时间近邻事件和 PC 复核页的普通拖拽锚点仍受 5 米/30°兼容门约束。修正通过完整轨迹的 O(N) 平滑场向前后传播；可信人工锚点造成的大 maximum/P95 绝对修正只做审计并允许进入 current 草稿，质量门改看相邻 correction-field 梯度、相对边和闭环残差。若 RTAB‑Map 全局图不完整，但原始 `Node.pose` 全量有限、时间严格递增且相邻运动连续，PC 可用扫描起点地图位姿生成明确禁止发布的 `raw_continuous_vio_diagnostic_recovery` 草稿；有严格人工锚点时继续记录为更强的人工校准证据。若采集中出现 ARKit/数据库局部坐标系重置，只有至少两条独立、短距离的 RTAB-Map 结构 Link 对同一跨 epoch 刚体变换达成唯一一致时才缝合，并输出 reset 节点、Link、变换和修复前后步长审计；缺少桥接、存在多解或修复后仍不连续时保持硬拒绝。

长距离地图辅助轨迹还会把先验道路图作为软结构证据，而不是逐节点机械吸附到最近通道。长直行段先从地图通道方向场估计需要的整体航向修正，再用包含一阶连续性和二阶曲率项的 O(N) 带状修正场把近似刚体 SE(2) 旋转分布到整段轨迹；这样几十米通道不会因为一阶平滑无法表达线性 x/y 修正而持续斜穿货架。具体通道采用连续序列匹配，联合通道连通性、横向距离、运动方向和相邻修正变化；平行通道身份不明确的样本只记录 `ambiguous_low_confidence` 或保持未匹配，不会被强制拉向某个货架。严格 exact-node 人工锚点仍高于自动通道假设；native 因子图若破坏已经恢复的物理连续性，其报告会保留审计，但复核轨迹回退到连续有界修正场并强制 `PARTIAL_REVIEW_REQUIRED`，不能伪装成可发布结果。

当前已有地图模式按**单次扫描、单一楼层**工作：开始前绑定一个楼层，扫描中不自动切层，也不支持跨楼层定位。楼层内部允许坡道、地面起伏等少量竖直位移；二维先验定位忽略 ARKit 高度分量，而原始 ARKit/RTAB-Map 数据仍完整保留三维运动。

已有地图模式提供用户触发的 ESL Barcode Capture Mode，直接复用持续到达的 `ARFrame.capturedImage`，不启动第二路相机。进入该模式不会暂停 `ARSession`、RTAB-Map、连续 SQLite 数据库、节点创建、时钟/位姿记录或先验地图定位；相机画面只由 camera-only `MTKView` 预览覆盖，原扫描链继续在后台运行。ARKit 连续自动对焦被显式保持启用。Vision 使用屏幕固定 scan box 对应的真实 `regionOfInterest`，按最多 10 Hz 且 one-in-flight 执行；主 ROI 无结果时只在同一 worker lane/同一 ARFrame 上追加一次有界扩展 ROI 检测，以覆盖贴近镜头时条码略超框的情况，同时增加 Code39/93、I2of5、ITF14、DataMatrix、Aztec 等成熟码制。每个请求仍有独立的 1 秒 ARFrame deadline。底层使用固定两条 worker lane：超时请求会 best-effort cancel 并隔离旧 lane，fresh request 可在备用 lane 实际开始；两条 lane 都挂起时立即终止 ESL UX，不创建第三条 worker 或无界 backlog，原始扫描链继续。相机预览最多 24 Hz。候选需要连续 2 帧锁定，同一 burst 目标 4 个、最低 3 个独立帧；采集窗口为 4 秒，给近距离重新对焦和短暂 node publication gap 留出时间。

价签入口使用独立全屏扫码框、识别进度、成功/错误状态、触觉反馈和取消按钮；状态文字和已识别条码分别绑定扫码框的精确上、下边缘并保持 18 pt 间距，不再依赖屏幕中心魔数，因此不会压住扫码框边线。失败时按 ARFrame、定位对齐、扫描状态、地图身份和 required evidence 给出明确弹窗。native node timebase 在首个 RTAB-Map snapshot 前缺失属于暂时未就绪：该 frame 会等待而不写入非有限占位值，避免一次启动窗口同时毒化三份必要定位 sidecar。扫码过程中暂时拿不到 live node snapshot 时，会在同一 1 秒严格时间合同内复用已冻结 exact-ID snapshot 或等待下一帧，不再把它误报成 sidecar 写入失败；真实必需写入失败、身份错误和 burst 绑定失败仍保持粘性 fail-closed。完整 burst 若定位、深度或货架关联质量不足，会直接以低置信度保留并结束本次扫码，无需现场反复扫描；PC 后处理继续执行 `P_final = T_final_node × inverse(T_raw_node) × P_raw`，按 exact `boundNodeID` 和最终优化手机位姿重算位置。只有缺少完整 burst、exact node/原始节点位姿或可解析位置等权威证据时才产生重扫任务。扫描结束会同步驱动 Mobile-Only workflow 的 `scanning → finalizingScan → idle`，可恢复保存失败则回到原扫描，避免下一次配置收到旧的 `scanning` 状态。

“处理历史扫描”只列出 `finalized=true` 的连续单库会话。手机后处理会先生成 immutable snapshot，并对 SQLite、Node/Link 和图位姿 BLOB 执行严格校验；iOS App sandbox 不再依赖 SQLite 重新打开 `/dev/fd/<n>`，而是从已绑定的 no-follow descriptor 流式复制到 App 私有临时目录进行只读完整性校验，复核源 inode 后立即清理。每个历史会话还提供独立“导出原始扫描”按钮：即使手机后处理失败，也可选择 Files 或外接存储目录，复制完整 `segment_0001`，对源/目标/复制后源执行 SHA-256 manifest 三方一致性检查，写入复制凭证，并始终保留手机中的原始会话；同名目标使用新的 `-Export-*` 目录，绝不覆盖已有导出。

### MapCase02 标准工作簿状态（2026-08-09）

`MAPCASE02 / STANDARD SUPERMARKET XLSX FORMAT PASS`：Swift/PC 对正式工作簿 top-left anchor、production role geometry、canonical v3、package v2、road/spatial/distance/shelf 派生工件与资源上限已完成阻断级收口。冻结统计为源 1838、active 1630、货架 1301、固定结构 329、展示审计 208、active 越界 0；canonical SHA `5ddfac7dc439afc45abdcf800b799c05d53704895b620d161ef08a442c55b2db`。2026-08-09 真机导入暴露编译器保留大写、地图库只接受小写的 `prior_map_id` 合同断层；当前新包统一生成小写且总长不超过 128 的 ID，正式 MapCase02 为 `piaseczno-5ddfac7dc439`，并已补齐 compile → integrity → MobileMapLibrary install/register/list/exact-read 回归。Swift/Python 还共同严格校验 manifest/report 计数、warnings/malformed rows 以及 road graph node/edge 绑定，手机原样生成包必须通过 PC production validator。旧 uppercase v2 开发包在普通 iOS/PC validator、旧向导和离线定位入口均默认拒绝，只能通过显式 diagnostic-only 参数做只读检查，不能参与新的扫描或处理。

这是地图格式局部链路结论，不是产品发布结论。当前整体仍为 **REJECTED / NO-GO / developer smoke only**，J-04 为 **BLOCKER / NOT CLOSED**；Apple 双平台 clean link、完整 PriorMap discover、LiDAR 真机、Device Lab、Replay/FAR 和现场验收仍待执行。I10 exact-SHA 已通过完整 macOS host 合同，但在冷构建 iphoneos 依赖时暴露宿主 `rtabmap-res_tool` 未显式绑定；I11 已修复并等待新的 exact-SHA 复验，未创建冻结标签。

每个 frame observation 先写入 `tag_observations.jsonl`，完整 burst 再写入 `tag_observation_bursts.jsonl`，最终确认前必须证明 burst complete，并对 `observation_id / burst_id / frame_id / payload / symbology` 做精确磁盘交叉绑定。只有至少 3 个逐帧通过定位、测量、关联质量门且共同指向同一 `shelfSegmentId + side` 的独立证据，才能打开可提交的货架确认。确认页显示小地图、高亮货架、算法候选和替代侧面；`USER_CONFIRMED` / `USER_OVERRIDDEN` 作为 additive v2 用户证据保存，不能覆盖算法字段，更不能修改 SLAM、轨迹、node pose 或定位约束。

扫描最终化与证据 writer 通过统一 admission gate 线性化：finalization 关闭新 admission 后，会等待此前已登记的 localization/confirmation transaction 完成；已登记 writer 不会被内部二次 finalization 检查误拒。finalization sentinel 之后到达的普通 ARFrame 定位任务和普通 Recovery append 会被拒绝，只有终端 Recovery 与 scan-stop 自有 audit 使用窄范围 `allowDuringFinalization`。ESL audit 冻结 generation 对应的 exact tracking session，只能追加到仍存在的既有 `segment_0001`，不会创建空的后继会话，也不会把旧 capture audit 写入新会话。

PC 输入 manifest v3 在既有 Recovery 证据之外绑定 burst sidecar。共享 validator 严格验证 v1/v2/v3 整数版本、Recovery binding、role/filename 顺序、大小写不敏感文件名唯一性、source database 安全 basename 及其与 `source_manifest` 的名称一致性；snapshot 与 verified copy 拒绝 source DB hardlink、非空 WAL 和 rollback journal。manifest v3 中只有 localized tag v2 使用 verified complete burst 的 `bound_node_id` 作为唯一节点权威；同一会话中的历史 tag v1 保持 legacy explicit-node/timestamp 兼容，不会被错误强制绑定到 burst。手机和 PC 现在统一采用“结果保留、发布从严”合同：单个 burst/frame、节点绑定、位置字段、货架关联或确认材料不完整，只降级对应价签为 `LOW_CONFIDENCE`，保留条码、可恢复位置和精确原因；必要时额外生成非阻断补扫建议。普通 PC 地图同时输出全量 `price_tags.json/csv`，无有限坐标的价签不会进入 GeoJSON，也不会被伪造为 `(0,0)`。文件 framing/UTF-8/JSON 不可界定、哈希或水位不一致、重复持久主键、地图/门店/楼层/会话身份串包、数据库损坏、完全没有有限轨迹或无法安全提交结果仍会终止。任何低置信度/部分结果都设置 `publish_permitted=false`，但不再等同于处理失败或价签删除。离线优化与现场选择一致时输出 `NO_CONFLICT` 并保持批准；可靠优化结果冲突时输出 `USER_CONFIRMATION_CONFLICT`，离线证据不可用时输出 `OFFLINE_ASSOCIATION_UNAVAILABLE`，两者都强制人工复核。MapCase02、地图坐标变换和任何 store/map/file-specific scale、offset、rotation 启发式均未在本轮 ESL 增量修改；其后续修复以独立正式规范和提交为准。真实 LiDAR iPhone 的 30 秒性能、强弱光/反光/斜视/多价签矩阵和完整现场验收仍未执行，因此项目判断仍是 **REJECTED / NO-GO / developer smoke only**，J-04 仍为 **BLOCKER / NOT CLOSED**。

阶段一/二整改和阶段三草稿复核链路已有自动测试；真实 LiDAR iPhone 完整干跑和正式超市现场验收仍是发布前门槛。本文不把模拟指标表述为现场精度或生产批准。完整架构、格式、UI、测试和当前状态见 [docs/map-assisted-localization/](docs/map-assisted-localization/)，双模式操作、复核、备份和失败恢复见 [用户操作手册](docs/map-assisted-localization/USER_GUIDE.md)，本轮 RepairV2 审查闭环见 [当前审查记录](docs/map-assisted-localization/reviews/CURRENT_REVIEW.md)。

### 连续流式单数据库

生产扫描不再通过频繁关闭数据库和创建新分段来控制内存。一次扫描会话持续写入同一个 SQLite 数据库：

- `Mem/STMSize` 和 `Rtabmap/MemoryThr` 限制在线工作图规模；旧节点通过数据库驱动持续写入磁盘。
- 实时渲染节点数有独立上限，释放退出工作图的点云和图形缓冲，避免预览内存无限增长。
- 暂时打开控制中心、锁屏或发生系统中断后，恢复到同一条连续轨迹，不人为创建新子图。
- `segment_0001` 仅为兼容早期 PC 工具保留的目录名，不表示生产模式仍会自动分段。

### NFC 功能暂停

当前项目暂停 NFC 相关功能的使用与开发。原因是 iOS 调起 Core NFC 会中断正在运行的摄像头采集，从而破坏连续扫描；同时，未具备相应认证、entitlement 和 provisioning profile 的 Apple 开发者账号无法在真机上调试 NFC。

因此当前版本隐藏 NFC 菜单和调试入口，不把 NFC 纳入扫描验收流程。`PriceTagNFCReader.swift`、相关数据结构、旧 `price_tags.*` 文件解析和地图兼容代码暂时保留，仅用于历史数据兼容及未来在具备认证条件、且完成摄像头连续性方案后恢复。不得在生产扫描过程中直接重新启用该入口。

### 纯软件误差控制

当前生产配置不依赖 AprilTag、ArUco、landmark 或外部 pose prior。手机端会拒绝把以下帧写入地图图结构：

- ARKit 处于初始化、重定位、不可用或其他不稳定 tracking 状态；
- tracking 刚恢复但尚未达到连续稳定帧数；
- 没有有效 ARKit 视觉特征；
- 相邻可信帧之间出现不符合手持步行设备物理范围的平移或旋转跳变。

发生异常瞬跳时，后续原始位姿会重新基准到最后一个可信连续位姿。手机端接受视觉或 local-space 回环后会在线更新 `map→odom`：实时地图、旧点云和结构覆盖立即使用优化地图坐标，而连续 `odomPose` 仍作为相邻图边输入，避免重复应用修正。只有跨越至少 50 个节点的全局/邻近回环才算累计漂移健康锚点；短回环不会掩盖长距离无可靠回环告警。手机的在线图是有界窗口，完整数据库上的闭环补充、RGB-D 重配准、重力约束、鲁棒核和最终全局优化仍由 PC 完成。

### 碎片化结构覆盖与自适应采样

货架及商品表面天然不规则，小平面也常只有零散 LiDAR 回波，因此手机端不要求一帧内出现完整平面或闭合矩形。扫描时会每 0.6 秒把中/高置信度深度用最新 `map→odom × odomPose` 投影到 0.2 米地图栅格，分别累计地面、低位/高位结构、观测时间和八方向视角；同一高于地面的栅格需要跨时间重复出现才算稳定结构，多方向再次看到后才算多视角覆盖。这样可将不同帧中的碎片保留下来，避免回环前后证据形成两套错位结构，同时让行人、购物车和单帧反射毛刺较难直接变成稳定证据。

结构新颖度高时，`Rtabmap/DetectionRate` 会从保守的 1 Hz 临时提高到 1.5 或 2 Hz，以便在小平面和不规则商品面附近保存更多 RGB-D 节点；证据重复后自动回落。`fair` 热状态最高 1.5 Hz，`serious/critical` 最高 1 Hz。HUD 会显示稳定/多视角结构栅格和覆盖分数，并提示保持货架底部、地面上下文或渐进改变视角。该层只改善采集覆盖和留下可审计证据，不在手机上凭空补货架；最终实例识别仍由 PC 使用完整数据库完成。

### 设备资源与数据安全

- 内存压力只缩小在线工作图和实时预览，不主动切换数据库。
- 设备进入 `fair` 热状态即先降低实时绘制并限制自适应采样；`serious` 时进一步缩小在线窗口。
- 可用空间低于安全线或热状态达到 `critical` 时完成并关闭当前数据库，避免继续写入造成损坏。
- 扫描期间周期写入 `live_checkpoint.json`；只有数据库保存、全部必需 sidecar 写入和最终元数据提交都成功后才删除 checkpoint。已有地图模式的定位证据若有任一必需写入失败，会保留红色告警、`finalized=false`、失败计数和 checkpoint，停止新的先验地图修正/价签确认，但原始 RTAB-Map 数据库仍继续安全记录。
- `metadata.json(finalized=true)` 是不可逆提交点。若其后仅 checkpoint 删除失败，应用进入“已完成、待清理”终态，绝不恢复相机或继续写库；手机启动恢复提示和 Map Studio 显式 API 只会在同一 tracking identity、checkpoint 时间不晚于提交时间时清理，并写审计事件。若 metadata 以 `finalized=false` 成功保存粘性证据失败，会话同样停止并作为不可处理的原始数据库恢复包导出，而不是回到永远无法恢复资格的 prior-map 录制。
- 选择外部保存目录时，应用在数据库关闭后后台复制整个会话，关闭复制句柄后逐文件复读并核对相对路径、字节数和 SHA-256，再确认源目录未变化；输出 `copy_verification.json`，默认保留本地副本。文件提供者完成不等于设备断电持久化，真机 provider 验收前不会自动删除唯一副本。

## 扫描会话数据

一次正常结束的连续扫描大致生成：

```text
SupermarketSession-YYYYMMDD-HHMMSS/
  segment_0001/
    rtabmap_segment_0001.db
    metadata.json
    price_tags.json             # 暂停功能的兼容空文件
    price_tags.csv              # 暂停功能的兼容空文件
    scan_area_cells.json
    structure_coverage_cells.json
    trajectory_samples.json
    trajectory_samples.csv
    scan_events.jsonl
    localization_trace.jsonl          # 仅已有地图辅助扫描
    localization_constraints.jsonl    # 仅已有地图辅助扫描
    localization_events.jsonl         # 仅已有地图辅助扫描
    tag_observations.jsonl             # ESL 原始逐帧证据
    tag_observation_bursts.jsonl       # ESL 完整 burst 证据
    localized_price_tags.json          # 用户确认后的 additive v2 结果
```

主要内容：

- `rtabmap_segment_0001.db`：RGB-D 帧、节点、约束、位姿和 RTAB-Map 管理数据。
- `metadata.json`：扫描模式、完成状态、节点数、面积、存储、设备状态、处理配置、手机在线/可靠回环计数和最终 `map→odom` 修正（仅审计，不作为 PC 外部先验）。
- `price_tags.*`：为旧会话兼容保留；当前扫描不采集 NFC，正常情况下为空。
- `scan_area_cells.json`：移动端轻量覆盖面积估算使用的栅格。
- `structure_coverage_cells.json`：跨帧深度结构证据、时间/视角重复次数和最终覆盖摘要；用于审计采集是否充分，不替代原始 RGB-D 数据库。
- `trajectory_samples.*`：移动端采样轨迹，供检查和兼容流程使用。
- `scan_events.jsonl`：tracking、中断恢复、自适应采样、结构覆盖提示、闭环健康、内存、热状态、磁盘和结束事件的结构化日志。
- `tag_observations.jsonl` / `tag_observation_bursts.jsonl`：已有地图模式下的严格 ESL 逐帧与完整 burst 证据；两者必须在最终化和 PC parse-and-hash-once snapshot 中精确交叉绑定。
- `localized_price_tags.json`：用户确认后的价签结果；v2 将 algorithm evidence 与 user-confirmed evidence 分开，现场确认不会回写或覆盖算法/SLAM 事实。

如果会话中仍存在 `live_checkpoint.json`，PC 工作台会把它视为正在写入或异常未完成的数据，拒绝自动重处理。

## PC 端处理

### Supermarket Map Studio

`tools/SupermarketMapStudio/` 是本项目推荐的统一入口。它使用 Python 标准库提供仅绑定 `127.0.0.1` 的本机服务，并在浏览器中完成：

- 连续流式单库、旧版分段会话和多设备会话检查；
- SQLite 完整性、RGB-D/标定、时间戳和节点统计检查；
- 手机端稳定/多视角结构覆盖、地面冲突和自适应节点率摘要检查；
- `rtabmap-reprocess` 离线闭环与全局优化编排；
- 优化前后轨迹覆盖率、步长、旋转、垂直跨度和尺度验证；
- 二维结构图、白底黑色货架闭合边界、彩色 RGB-D 俯视图和 WebGL 三维预览；
- 手机采集日志、PC 处理日志、质量结论与成果文件浏览；
- 已完成结果发现和相同参数结果复用。
- 对连续单库结果执行人工区域误差修复：框选重复区域、预览 `kUserClosure` 节点约束，确认后在数据库副本上重新全局优化；只有全部人工约束端点仍存在，且平移残差、旋转残差和全图位移均通过安全门，才发布新的 `MapStudio-Merge-*` 版本；原始扫描库和基线结果保持不变。

默认优化流程为：

1. 只复用手机已经接受的邻接边和闭环约束，快速回放完整数据库。
2. 检查长程闭环数量及输入约束保留率。
3. 约束不足时才使用 ORB 特征执行 PC 补环，避免无条件重算所有视觉特征。
4. 节点回放期间使用少量在线迭代，结束后执行一次高质量稀疏全图求解。
5. 在新数据库中验证优化位姿，通过安全门后原子发布；源数据库始终保持只读。

### Supermarket2DMap 脚本

`tools/Supermarket2DMap/` 提供可独立调用的脚本接口：

- `supermarket_2d_map.py`：单会话二维地图包。
- `supermarket_staged_map.py`：兼容历史分段数据的阶段校正。
- `supermarket_multi_device_map.py`：多个设备会话的初始对齐、变换和统一地图包。

这些脚本可从 RTAB-Map 数据库读取优化位姿、RGB-D 深度和标定；也支持额外结构点输入。没有可解析深度时会退化为轨迹和业务图层结果，并在质量报告中说明限制。

### 输出地图包

典型 PC 输出包含：

```text
MapStudio-*/
  preview.png
  occupancy_grid.png
  occupancy_grid.yaml
  shelf_outline.png
  shelf_outline_evidence.json
  preview_3d.json
  preview_frames/
  trajectory.geojson
  price_tags.json               # 全量价签；无位置条目也保留
  price_tags.csv                # 全量价签表格导出
  price_tags.geojson            # 仅包含具有有限地图坐标的价签
  vector_map.geojson
  semantic_layers.json
  quality_report.json
  review_items.json
  source_manifest.json
  rtabmap_optimized/
  offline_processing_report.json
  pc_acceleration_report.json
  merge_edits.json                # 仅人工修复版本
  merge_manifest.json             # 仅人工修复版本
  merge_report.json               # 仅人工修复版本
```

其中 `source_manifest.json` 用于记录输入文件 hash，`quality_report.json` 和 `review_items.json` 用于自动检查及人工复核，`offline_processing_report.json` 记录实际命令、优化路径、耗时、闭环和发布判定。

`shelf_outline.png` 为保持地图包兼容而沿用旧文件名，内容是白底黑色的货架实例闭合外边界：内部保持白色，不输出零散开放线段，也不会把证据机械拟合成矩形框。生成器对数据库中全部可用 RGB-D 深度帧执行独立的结构证据通道，不再受彩色/3D 预览最多 96/240/384 帧的抽样预算限制；默认只接受至少两个独立帧重复看到的竖直面，以抑制行人、购物车和单帧深度毛刺。每帧深度优先直接使用 `Admin.opt_poses` 的完整 SE(3) 位姿投影（包括 roll、pitch 与垂直修正），缺失节点才回退 `Node.pose`；人工 stage/device 的 dx、dy、yaw 作为投影后的平面残差继续生效。高度再减去与该帧匹配的相机高度，以保守抵消优化图中仍可能残留的垂直漂移，然后分别提取地面、层板面和竖直面。货架下方通常缺少地面回波，因此会先在内部重建货架占地掩膜，但候选必须能在某一横截方向找到两侧地板或稳定自由空间；实测地面和重复射线清空区域用于保护通道，未知空间或只有单侧证据的区域不会被凭空填满。同一栅格若多帧稳定看到地面、却仅偶尔出现竖直面，还会按地面冲突率再次过滤；窄桥分水岭随后拆开被重影或噪声粘连的相邻实例，最终只提取每个实例的外侧闭合边界。`shelf_outline_evidence.json` 第 6 版除竖直面、地面、层板面、稳定自由空间及独立观测次数外，还记录结构识别实际可用、抽取和成功解码的帧数。Map Studio 可通过“更干净—更完整”滑杆、三档预设或高级门槛即时重算补全距离、通道保护、粘连拆分和轮廓线宽，并显示直接扫描支持率、下载当前 PNG，不必重新执行 PC 优化，也不会覆盖默认成果。旧第 4、5 版证据仍可读取。该结果仍是几何推断：仅凭深度几何不能绝对区分货架与墙体，累计水平位姿漂移造成的重影也无法由轮廓后处理完全消除；缺少两侧地板或结构视角的边缘区域会保守留空。彩色/3D 预览可按内存需要选择快速、详细或最高档，不会再减少货架识别使用的帧数。

## 快速开始

### 1. 配置 PC 处理环境

macOS Apple Silicon 推荐：

```bash
tools/SupermarketMapStudio/configure_pc_macos.sh
```

脚本会配置 CMake、Ninja、OpenCV 4、PCL、g2o、OpenMP，并构建 Release 版本的 `rtabmap-reprocess`。已有依赖的其他平台也可手动构建：

```bash
cmake -S . -B build -DBUILD_TOOLS=ON
cmake --build build --target rtabmap-reprocess --config Release -j
```

可选 GPU 地图投影：

```bash
# Apple Silicon / Metal
tools/SupermarketMapStudio/configure_gpu_apple_macos.sh

# Linux / WSL / NVIDIA CUDA，需要带 CUDA 模块的 OpenCV 4
OpenCV_DIR=/path/to/opencv-cuda/lib/cmake/opencv4 \
  tools/SupermarketMapStudio/configure_pc_nvidia.sh
```

GPU 主要用于 RGB-D 密集深度投影。RTAB-Map 数据库回放和 g2o 稀疏图优化仍包含 CPU/串行部分；工作台会在报告中记录实际后端和任何回退。

### 2. 启动工作台

macOS / Linux：

```bash
cd tools/SupermarketMapStudio
./start.sh
```

Windows 可运行：

```bat
tools\SupermarketMapStudio\start.bat
```

浏览器将打开 `http://127.0.0.1:8765/`。页面保持打开时会自动续期本机 HttpOnly 会话，长时间操作后文件/文件夹选择器仍可使用；服务重启后请使用启动器自动打开的新页面建立新会话。选择完整的 `SupermarketSession-*`、确认新的输出目录，然后执行单设备处理或多设备合并。

工作台“导入/管理先验地图”页签可把已有货架 Excel 转换为手机/PC 共用地图包；输出到 macOS 外置盘时，系统生成的 `._*` AppleDouble 旁车和 `.DS_Store` 会在 PC/iOS 完整性检查中一致忽略，不会作为地图 JSON 读取。“先验地图会话优化”页签执行 RTAB‑Map 重处理、派生轨迹优化、质量门禁、人工复核和最终导出。测试阶段可启用“测试诊断模式”：冲突手机定位约束由稳健门剔除但继续进入审计，即使累计修正超限也加载不可发布草稿，并显示在线/RTAB‑Map/离线轨迹长度、修正中位/P95/最大值和 weak/lost 时长；该模式不会绕过 review/publish gate。也可直接运行：

```bash
python3 tools/PriorMap/xlsx_to_prior_map.py /path/to/map.xlsx \
  --output /path/to/PriorMap-output
python3 tools/PriorMap/validate_prior_map.py /path/to/PriorMap-output
```

源 XLSX 只读；输出记录源 SHA-256、规范包 SHA-256、楼层、bounds、元素统计、道路连通性、结构/道路空间索引、warning、默认 PNG 和逐楼层确定性 PNG 预览。一个地图包可以保存多个楼层，但一次手机扫描只绑定其中一个楼层。

### 3. 直接生成二维地图

```bash
python3 tools/Supermarket2DMap/supermarket_2d_map.py \
  /path/to/SupermarketSession-YYYYMMDD-HHMMSS \
  --output /path/to/Map2D-output
```

### 4. 运行工作台测试

```bash
python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v
```

### 5. 构建 iOS 应用

使用 Xcode 打开 `app/ios/RTABMapApp.xcodeproj`。完整扫描流程需要支持 ARKit 和 LiDAR 的真机，建议使用 iPhone Pro 系列设备。NFC 当前暂停，不属于构建或验收范围。

若 Xcode 启动后画面只剩黑底和部分旧 RTAB-Map 控件，且 Debug Navigator 显示 `Thread 1: breakpoint` / `ViewController.updateState(state:)`，这是本机文件断点暂停了主线程，不是 App 随机启动失败。删除或停用该断点后点击 Continue；重新安装 App 不能从根本上消除仍启用的 Xcode 断点。

首次构建前必须为目标平台生成独立的 native dependency prefix：

```bash
# 真机 / generic iOS device
bash app/ios/RTABMapApp/install_deps.sh --platform iphoneos

# iOS Simulator（arm64）
bash app/ios/RTABMapApp/install_deps.sh --platform iphonesimulator
```

产物分别位于 `app/ios/RTABMapApp/Libraries/iphoneos/` 和 `app/ios/RTABMapApp/Libraries/iphonesimulator/`。Xcode 使用 `$(PLATFORM_NAME)` 选择对应 headers、archives 和 `vtk.framework`；平铺的旧 `Libraries/include`/`Libraries/lib` 不属于当前 build 输入，也不会被 CI 接受。两个平台首次 cold build 都会重新构建完整 Boost、Eigen、LZ4、FLANN、GTSAM、SuiteSparse、g2o、VTK、PCL、OpenCV、LASzip、libLAS 和 RTAB-Map 依赖，耗时和磁盘占用较大。生成的本地 `Libraries` 目录不会提交到 Git。

## 目录导航

| 路径 | 作用 |
| --- | --- |
| `app/ios/RTABMapApp/` | iOS 采集、会话、状态管理和 Swift/C++ 桥接；NFC 代码仅保留未启用 |
| `app/android/jni/` | 共享移动原生、数据库和渲染能力 |
| `corelib/` | 上游 RTAB-Map 核心 SLAM 与数据库实现 |
| `guilib/` | 上游桌面可视化组件 |
| `tools/Reprocess/` | 本项目扩展后的数据库重处理工具 |
| `tools/Supermarket2DMap/` | 二维、历史阶段和多设备地图生成脚本 |
| `tools/SupermarketMapStudio/` | 本地 Web 工作台、离线处理、GPU helper 和测试 |
| `tools/PriorMap/` | XLSX 先验地图转换、schema、预览、空间索引和定位回放 |
| `docs/map-assisted-localization/` | 可提交的地图辅助定位权威架构、格式、UI、测试和状态文档 |
| `doc/README.md` | 迁移保存的原始 RTAB-Map README |
| `doc/.local/` | 本地开发/交接文档；被 Git 忽略，不属于可提交内容 |

## 质量原则与实现边界

- 输入数据库和 sidecar 不就地修改；重处理和地图生成写入新目录。
- PC 优化使用临时文件、完整性检查和原子发布，失败结果不能覆盖已验证输出。
- 地图辅助成果写入 `localized/versions/vNNNNNN/`；`current.json`/`published.json` 只以原子指针切换。人工编辑必须同时提交 version/revision CAS，冲突返回 HTTP 409。
- 轨迹质量门能发现明显不连续、坏闭环、覆盖不足或异常尺度，但不能在没有实测控制点时证明绝对坐标精度。
- 多设备“共同起点对齐”只是初始值；最终结果需要通过重叠区域、已知距离或人工控制点复核。
- 当前三维成果是由抽样 RGB-D 关键帧重建的彩色表面预览，不是经过全局纹理融合、孔洞修补和封闭处理的交付级 mesh。
- 大型超市正式交付前，应使用闭合路线、已知货架间距或测量控制点做独立验收。

## 文档管理约定

- 根目录 `README.md` 是项目对外入口，应随实现变化同步维护。
- `doc/README.md` 保留上游原始说明，不用于描述本项目新增业务功能。
- Codex 生成的本地分析、交接、调试和阶段性设计文档统一保存在 `doc/.local/`。
- `doc/.local/` 已加入 `.gitignore`；其中内容只作为本机工作资料，不应进入提交或发布包。

## 许可与上游资料

除文件中另有声明的内容外，RTAB-Map 原始代码及 MarketScanner 改编代码均按仓库根目录的 [BSD 3-Clause 许可证](LICENSE) 提供。上游 RTAB-Map 的版权声明保持不变；MarketScanner 改编部分以 `mcjiansheng` 作为公开版权标识。仓库中单独标注许可证的第三方代码和依赖仍遵循各自的许可条款。

使用、分发或二次修改源码时必须保留许可证要求的版权声明、许可条件和免责条款。发布 iOS App、安装包或其他二进制成果时，也应在随附文档或应用内“开源许可/致谢”页面中提供相应声明。许可证管理代码的使用与分发，不决定 GitHub 仓库的协作者或分支写入权限。

- RTAB-Map 官方主页：<https://introlab.github.io/rtabmap/>
- RTAB-Map 上游仓库：<https://github.com/introlab/rtabmap>
- RTAB-Map Wiki：<https://github.com/introlab/rtabmap/wiki>
- 本仓库保存的上游 README：[doc/README.md](doc/README.md)
