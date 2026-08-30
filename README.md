# RTAB-Map 大型超市扫描与地图工作台

> 文档状态：**当前有效**。最后一次与源码交叉核对日期：2026-08-19。

本项目是在开源 **RTAB-Map** 基础上进行的业务化改造，面向大型超市、仓储卖场等室内场景，形成从 iPhone Pro 连续采集，到 PC 端离线优化，再到二维地图、彩色俯视图和三维预览的一套本地工作流。

当前源码中的 RTAB-Map 版本为 **0.23.5**。上游项目原始 README 已保存在 [doc/README.md](doc/README.md)，便于查询 RTAB-Map 官方主页、安装说明、ROS 支持和上游 CI 信息。

> 本仓库不是 RTAB-Map 官方发行版。RTAB-Map 的原始著作权和 BSD 许可仍归原作者所有；本仓库在其通用 SLAM 能力之上增加了超市连续采集、离线处理和地图交付功能。

## 项目目标

原始 RTAB-Map 是一个通用的实时外观建图系统，提供视觉/激光里程计、回环检测、位姿图优化、RGB-D 数据库、点云和占据栅格等能力。本项目保留这些基础能力，并针对实际超市作业补充以下闭环：

```text
iPhone Pro RGB-D / LiDAR / IMU / ARKit 采集
  -> 连续写入单个 RTAB-Map SQLite 数据库
  -> 位姿质量门控、在线回环 map→odom 同步、跨帧结构覆盖提示、自适应关键帧、设备安全保护与有界性能时间线
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
| 稳定性与可观测性 | 对 ARKit tracking 恢复和不合理位姿跳变进行质量门控；用跨时间/视角的深度证据抑制单帧行人噪声；按内存、磁盘和热状态降低预览、限制采样或安全结束；约每 5 秒持久化 CPU、内存、磁盘、热、电池、FPS、RTAB-Map 更新时间和数据库增长 |
| PC 优化 | 扩展 `rtabmap-reprocess` 的进度、约束统计和最终求解流程，支持工作台执行自适应离线优化 |
| 地图生成 | 新增单设备、历史多阶段、多设备二维地图脚本，输出占据图、融合地板空缺、自由空间、竖直面与层板证据的货架实例闭合边界、轨迹、GeoJSON 和质量报告；保留旧价签数据兼容解析 |
| 可视化工作台 | 新增仅监听本机的 Web 工作台，统一进行输入检查、处理编排、2D/3D 预览、日志和结果检查 |
| 性能加速 | 提供 Release/OpenMP 配置，以及 Apple Metal 或 NVIDIA CUDA 深度投影 helper；不可用时明确回退 CPU |

Android 目录中的部分 C++ 原生实现也因共享移动渲染和数据库能力而被扩展，但当前完整的超市现场采集交互主要实现在 iOS 应用中。

## 当前采集方案

### 统一的全手机门店扫描主流程

当前发布目标只有一条主链路：首页大型“新建扫描”和右上角菜单的“开始门店扫描”先进入同一个轻量地图选择页。用户可以选择已注册地图，也可以直接导入新地图；只有确认某一张地图后才完整验证并加载该包，再进入楼层、起点和朝向配置。地图可以来自手机现场编译的 `XLSX / CSV / JSON`，也可以来自 PC 已生成并通过 production validator 的正式 v2 地图包，但安装后都进入同一个内容寻址地图库，并复用同一套配置、设备检查和启动事务。选择页完成首屏绘制后会在主线程空闲轮次预先构造一次导入菜单、导入页和文件选择器；这只预热 UIKit/UTType/FileProvider，不读取 provider 文件、不创建 workflow 事务。PC 地图包的文件夹选择固定使用 open-in-place security scope（文件夹不能使用 document-copy 模式），选中后才在后台冻结一次严格快照并复制到 App 私有 staging；原 provider 目录从不成为扫描输入。自由扫描建图与原始数据录制仍保留，但降级到“实验与兼容工具”，不再占据主入口。

正式超市 XLSX 使用 `Basic Info + Element Info`，`Shelf Info` 仅审计。文件尚未选择时不显示 0% 和空进度条；provider 已返回文件并开始安全暂存后，手机编译过程才显示复制、严格解析、身份/元素校验、道路图、逐楼层/逐分辨率距离场、空间索引、预览、manifest、自验证、提交和注册等真实阶段。完成页显示门店 ID、地图 ID、package SHA、canonical SHA、楼层和元素/警告统计，不再只提示“导入成功”。

统一配置页只接收已经明确选择的一张地图，不再包含会触发重复加载的地图 picker。它支持 1×—8× 捏合缩放、单指平移、双击放大/复位和点击选点；起点可用方向键按 0.1 m / 0.5 m / 1.0 m 微调；朝向使用东/北/西/南和左右 15° 微调，不再使用横向滑杆。地图航向统一使用标准 SE(2) 合同：`0° = +X/东/屏幕右`、`90° = +Y/北/屏幕上`，逆时针为正；配置箭头、ARKit 首帧对齐、深度局部坐标、人工重选和扫描 HUD 必须消费同一数值。手机 CoreGraphics 预览、UIKit 触点和 canonical 地图几何共享同一 +Y 合同，预览只在 UIKit 触点转换时执行一次纵向翻转，避免画面白色通道被误映射到货架。地图选择 root 页面有关闭按钮，配置页使用系统返回按钮/手势；离开页面会取消尚未完成的启动事务。

配置页还允许在启动前填写最多 64 个字符的可选“扫描名称”。斜杠、通配符、引号、控制字符等会被过滤，连续空白会折叠；留空或过滤后为空时自动使用 `<门店>-<楼层>-MMdd-HHmm`。该值只作为 `scanDisplayName` 写入扫描配置、`metadata.json` 和 `live_checkpoint.json`，并作为历史扫描列表的显示标题；它不参与会话目录、数据库、sidecar、地图身份、处理任务或发布路径命名。旧会话没有该字段时继续显示原 `SupermarketSession-*` 目录名并保持完全兼容。

开始扫描前先完成 build identity、地图身份和相机权限检查。包校验、localizer 构造、会话目录和 native SQLite 初始化在串行后台队列执行，主线程只承担短暂的 UIKit/ARSession 状态切换。扫描只有在 ARSession、RTAB-Map、sidecar writer、durable receipt 和 workflow context 全部提交后才进入 `scanning`；任一步失败或取消都会停止相机/映射、释放会话身份并脱离失败数据库，不能留下“幽灵扫描”。Debug 与 Release 现在都生成可追踪 build identity，并执行完全相同的扫描、落盘、finalization、处理和结果链路；Debug 允许 tracked tree dirty 并在身份、scan event 和 metadata 中标明测试来源，Release 继续要求 tracked tree clean 并标记为 production eligible。共享 `RTABMapApp` 默认 Run 和 `RTABMapApp-QualifiedDevice` 仍使用 Release，便于进行真实性能和现场资格测试。

当前 build identity 为 version 5：除 HEAD/native/governance/configuration/tree state 外，还保存实际 `source_ref` 与完整 tracked diff SHA-256，因此 dirty Debug 的不同未提交代码也可区分。Debug 在其余图、坐标、价签和完整性门通过时，可使用明确标记的 `CALIBRATION_PENDING` 初值生成与生产链相同的完整地图、表格、价签和不可变 Result；结果标记为 `result_scope=TEST`、`publish_permitted=true`、`production_publish_permitted=false`。这让测试可以拿到最终成果并复核全部效果，同时不把未冻结阈值冒充生产资格。clean Release 只有在标定和全部质量门通过后才可得到 `production_publish_permitted=true`。

已有地图模式的定位和 PC 草稿复核能力保持不变：手机只接受小幅、唯一且连续一致的自动结构修正；PC 先运行 RTAB‑Map 重处理，再运行 native 完整相对 SE(2) 因子图、质量报告、人工复核和价签导出。对于短兼容会话，native helper 缺失、执行失败或结果破坏已验证物理连续性时，仍可回退到不可发布的连续有界修正场并保留 native 审计。长距离会话则额外执行下述 gauge-neutral 自由空间道路恢复；当前质量策略仍是 candidate，且真机/现场资格未完成，因此不能据此宣称生产发布通过。

手机运行时的整图距离场匹配能够保持多个长期 alignment basin；可靠 RTAB‑Map 回环只开启有界宽搜索，不直接注入 pose prior。回环发生时，手机还会把当前位置附近最多 5 个 concrete `shelf_segment_id` 作为 diagnostic top-K 写入扫描日志，多解继续保留。当前 session input manifest v4 已用于绑定扫描期时钟证据；局部货架结构快照、phone↔shelf 相对 SE(2) 和 concrete shelf identity 尚未进入正式定位 sidecar，因此“回环后确认具体货架并持续用该货架校准”的完整闭环必须使用未来 manifest v5，不能用整个距离场匹配或邻域 top-K 冒充货架身份识别。

长距离累计漂移后的手机人工重选位置按“严格绑定的绝对地图锚点”处理，而不是手机物理瞬移。更重要的是，`localization_trace.rawPose` 本身已经经过当时可变的 ARKit→地图 alignment 投影，自动结构校正、人工重定位和坐标 epoch 重置都会改变这个 map gauge。PC 因而先从相邻 `rawPose` 相对运动恢复 gauge-neutral 物理轨迹：自动 correction 后以下一帧相对前一帧 `estimatedPose` 计算增量，人工重定位后的首个 post-reset sample 物理位移记为零；人工锚点只改变整条连续路线在地图中的放置，不制造相邻节点跳变。恢复结果按数据库节点时间戳重采样，保留手机真实相对运动、回头和 U-turn。手机 v3/exact-node/身份与时间证据，以及 PC 从不可变复核轨迹重新验证唯一 exact node/time/floor/coordinate-contract/bounds 的锚点，都是约 3 米平移、20°航向不确定度的可信地图证据；旧 v2、历史 timestamp-only 或无 exact binding 的事件仍受兼容门约束。若 RTAB‑Map 全局图不完整，完整、有限、时间有序的原始轨迹仍可进入明确禁止发布的诊断草稿；原始数据库始终只读。

人工“确认当前位置”或“重新选择位置”提交后，手机会对本次请求临时放开 RTAB-Map 的小位移丢帧与 rehearsal 合并，使静止操作者看到的下一次 detector tick 也能保留为普通图节点；成功、超时、取消、系统中断和结束扫描都会请求恢复扫描 profile。提交仍必须绑定严格晚于点击时刻的新 node stamp、新 node ID（存在基线时）且 node-time 差不超过 1 秒，再按 `manual_localization_events.jsonl` durable-first、alignment CAS 的原顺序提交；不会复用旧节点、注入外部 pose prior，也不要求测试人员晃动手机来制造位移。

长距离轨迹不再先使用通道方向场做整体旋转，也不再逐点吸附最近通道。PC 使用 gauge-neutral 物理移动、严格人工绝对锚点、`road_graph` 连通性以及货架/固定结构多边形的自由空间硬约束，执行全局道路身份序列匹配；有限道路边、真实路口和可达转移只回答“处于哪条通道、何时可以换到相邻通道”，道路中心线不是手机位置观测。最终 X/Y 保留优化手机位姿的局部曲线、横向偏移、停顿、回头和 U-turn；exact 人工锚点的平移残差按物理里程连续传播，自由空间只施加低频最小修正。只有点落入结构或相邻线段穿越货架时，才使用货架边界驱动的最近安全侧、局部刚体平移和经碰撞验证的修正渐变；任何步骤都不得把坐标或 yaw 改写成道路中心/切线。周期性平行通道无法唯一确定、绝对修正过大或少数修正梯度无法在不穿架的条件下继续摊平时，完整 CSV、价签、预览和审计仍保留并标记 `LOW_CONFIDENCE` / `PARTIAL_REVIEW_REQUIRED`，只关闭发布资格。`optimized_map_trajectory.geojson` 显式保存每个节点的 `yaws_rad`；节点级/本地时间秒级 CSV 的 yaw 始终来自优化后的手机位姿。

native 因子图和 corridor/free-space 后处理不再证明不同的轨迹。后处理完成后，PC 对最终导出的严格递增 node ID、X/Y/yaw 清单计算 canonical SHA-256，并使用 native 报告中的同一 canonical factor inventory 重新计算全部相对、闭环、绝对/货架因子残差和加权目标；质量阈值只接受与 release policy 原文 SHA-256 完全一致的文档。localized processing contract v3 在 `processing_manifest.json`、`localization_report.json`、`factor_graph_report.json` 和 `optimized_map_trajectory.geojson` 之间重复绑定最终轨迹 SHA、factor-set SHA 和 authority 结论。任一坐标、yaw、node ID、factor、policy limits 或跨文件绑定不一致都会关闭 publish gate；历史 v2 localized version 继续只读兼容，但不能重新执行发布操作。

地图辅助处理的四个核心业务表直接写入不可变 localized version：`calibrated_positions_by_node.csv`、`calibrated_positions_1s.csv`、`localized_price_tags.json` 和 `localized_price_tags.csv`，并由 `calibrated_deliverables_manifest.json` 对源节点数、导出节点数、源价签数、保留价签数、逐文件字节数和 SHA‑256 做核账。生成核心表与“是否允许自动发布”是两个独立决定：平行通道多解、局部时钟绑定缺口、部分优化图恢复、价签位置/货架关联不完整等普通算法退化会保留完整草稿并关闭 publish gate，不会删除节点、价签或整个版本。无法确定的坐标留空并标记 `UNAVAILABLE` / `LOW_CONFIDENCE`，禁止伪造 `(0,0)`。

session input manifest v4 将 `clock_correlations.jsonl` 与源数据库和其他 sidecar 一起纳入不可变输入身份。correlation 与 node binding 必须严格递增并交叉验证 node stamp、采样 frame time、UTC、IANA 时区和 offset；系统时钟跳变或时区变化会产生新的 `clock_segment_index`。秒级表只在同一时钟段内插值，跨段秒保留为空坐标并写 `position_degradation_code=clock_discontinuity`。若 framing、水位、身份和节点绑定均完整，但局部 binding 交叉验证后不足两条，手机与 PC 仍提交轨迹和价签，并按 correlation 时间边界保留所有秒级行，坐标统一标为 `UNAVAILABLE`；历史无权威时钟证据的 node stamp 也不会再伪装成 UTC。任何路径都不使用 PC 处理时区或跨不连续点制造看似连续的本地时间位置。

### 地图辅助定位的权威顺序

1. 输入地图先通过 canonical source、package SHA、store/map/floor identity、bounds、道路图、货架/固定结构和坐标合同校验。UI 只在 UIKit y-down 边界做一次显示转换；用户看到并提交的 X/Y/yaw 必须与内部 canonical SE(2) 完全相同。
2. ARKit、LiDAR、IMU、RGB-D 与 RTAB-Map 只提供连续相对运动和结构观测。原始 SQLite、trace、clock、manual、burst 与 tag sidecar 全部只读保存；任何离线优化都写新目录，不能把修正反写成原始传感器事实。
3. PC 优先使用完整 `Admin.opt_poses` 整图；若优化图部分覆盖，则以全量连续 VIO 为骨架传播已优化校正；若全局图不可用但原始 `Node.pose` 可证明连续，则只生成不可发布诊断草稿。任何路径都禁止逐节点混合两个 gauge。
4. 起点与初始方向提供首个地图 gauge；严格 exact-node 人工校准提供可信绝对地图锚点。大绝对修正是长距离累计漂移的正常校正量，不能被当作手机瞬移；连续性检查针对相对运动、局部修正梯度、闭环残差和地图可达性。
5. 道路连通性、通道、货架及固定结构自由空间约束把连续轨迹放回原始地图。结构内点、穿越结构和不可达转移不能成为结果；平行货架/通道多解保留候选和低置信度，不通过调权重伪造唯一货架。
6. 最终无条件尝试生成节点级/秒级位置和全量价签业务表，再按统一发布不变量决定 `publish_permitted`：地图坐标框、图质量、pipeline degradation、coordinate-frame audit、legacy 坐标记录、低置信价签、空坐标、未关联货架和重扫任务必须全部通过/清零。正式 concrete shelf-loop factor 尚未完成；在未来 v5 证据合同落地前，当前 top-K 只可用于诊断和人工复核。

当前已有地图模式按**单次扫描、单一楼层**工作：开始前绑定一个楼层，扫描中不自动切层，也不支持跨楼层定位。楼层内部允许坡道、地面起伏等少量竖直位移；二维先验定位忽略 ARKit 高度分量，而原始 ARKit/RTAB-Map 数据仍完整保留三维运动。

已有地图模式提供用户触发的 ESL Barcode Capture Mode，直接复用持续到达的 `ARFrame.capturedImage`，不启动第二路相机。进入该模式不会暂停 `ARSession`、RTAB-Map、连续 SQLite 数据库、节点创建、时钟/位姿记录或先验地图定位；相机画面只由 camera-only `MTKView` 预览覆盖，原扫描链继续在后台运行。ARKit 连续自动对焦被显式保持启用。Vision 使用屏幕固定 scan box 对应的真实 `regionOfInterest`，按最多 10 Hz 且 one-in-flight 执行；主 ROI 无结果时只在同一 worker lane/同一 ARFrame 上追加一次有界扩展 ROI 检测，以覆盖贴近镜头时条码略超框的情况，同时增加 Code39/93、I2of5、ITF14、DataMatrix、Aztec 等成熟码制。每个请求仍有独立的 1 秒 ARFrame deadline。底层使用固定两条 worker lane：超时请求会 best-effort cancel 并隔离旧 lane，fresh request 可在备用 lane 实际开始；两条 lane 都挂起时立即终止 ESL UX，不创建第三条 worker 或无界 backlog，原始扫描链继续。相机预览最多 24 Hz。候选需要连续 2 帧锁定，同一 burst 目标 4 个、最低 3 个独立帧；采集窗口为 4 秒，给近距离重新对焦和短暂 node publication gap 留出时间。

现场触发新增公共 App Shortcut `Scan ESL`；iPhone 15 Pro 及更新机型可在系统“设置 → Action Button → Shortcut”把 Action Button 绑定到该入口。Shortcut 只调用屏幕按钮使用的同一个 `startPriceTagCapture()`，不能绕过扫描、定位、相机或 sidecar 健康门。传统 Ring/Silent 静音拨片和音量键没有稳定、受支持的 App raw-key API，因此项目不监听系统音量、不隐藏 `MPVolumeView`，也不争抢 ARKit 所持相机。扫码初始提示建议与价签保持约 25–45 cm；这能减少触屏抖动并给连续自动对焦留出工作距离，但软件不能突破镜头最短对焦距离。

价签入口使用独立全屏扫码框、识别进度、成功/错误状态、触觉反馈和取消按钮；状态文字和已识别条码分别绑定扫码框的精确上、下边缘并保持 18 pt 间距，不再依赖屏幕中心魔数，因此不会压住扫码框边线。失败时按 ARFrame、定位对齐、扫描状态、地图身份和 required evidence 给出明确弹窗。native node timebase 在首个 RTAB-Map snapshot 前缺失属于暂时未就绪：该 frame 会等待而不写入非有限占位值，避免一次启动窗口同时毒化三份必要定位 sidecar。扫码过程中暂时拿不到 live node snapshot 时，会在同一 1 秒严格时间合同内复用已冻结 exact-ID snapshot 或等待下一帧，不再把它误报成 sidecar 写入失败；真实必需写入失败、身份错误和 burst 绑定失败仍保持粘性 fail-closed。

Vision 识别的是条码码制，不知道条码是否物理印在电子价签上；商品正面的 EAN/UPC 或 URL 型 QR 被快速识别属于正常行为。没有门店级 ESL payload 合同或主数据时，不能仅凭码制自动拒绝，因为现场 ESL 本身可能使用 Code128、EAN 或 QR。当前对典型零售商品码显示风险提示，并在保存前要求操作员明确确认“该码确实印在 ESL 上”；山姆现场常见的 9 位 Code128 继续正常进入采集。

连续扫描没有“三个通道后分段”或强制新建会话的阈值。现场一次失败的实际原因是深度平面退化时内部 residual 使用 `+Infinity`，`JSONEncoder` 无法写入 `tag_observations.jsonl`，随后严格证据健康门才提示结束并开启新扫描。现在不稳定平面将 residual 表示为缺失并降级当前 frame，持久化前再检查全部数值；该 frame 会被跳过并等待下一帧，不会毒化整场连续数据库。真实的磁盘写入、JSONL framing、身份或 observation/burst 绑定损坏仍保持粘性 fail-closed。

价签 observation schema v2 由同一次 native 原子快照冻结 `bound_node_id`、`bound_node_stamp`、`bound_node_map_id` 和 `T_opengl_world_from_node`，把同帧 scene-depth 世界点转换为 `point_in_bound_node_frame`。手机与 PC 后处理只执行一次 `P_final = T_final_node × P_node`，不再把已经位于先验地图框的旧 `raw_map_position` 再与 raw-node inverse 组合，从而关闭非零地图平移/旋转下的重复变换。只有 scene depth 可形成正式 node-local 三维点；二维 `shelf_plane_ray` 不伪造该权威。历史 observation v1 仍保留条码和业务身份，但可发布坐标清空、质量降为低置信并生成 `legacy_tag_coordinate_frame_rescan_required`。完整 burst 若定位、深度或货架关联质量不足，业务记录继续保留；任何低置信、空坐标、未关联或 rescan 都会阻断 `COMPLETE/publish_permitted`。扫描结束会同步驱动 Mobile-Only workflow 的 `scanning → finalizingScan → idle`，可恢复保存失败则回到原扫描，避免下一次配置收到旧的 `scanning` 状态。

### 2026-08-30 第二轮审查与价签识别优化

第二轮审查以仓库内真实现场数据（14 个含价签会话、74 个 burst、233 条观察）做回测，定位到价签链路成功率为 **0%** 的代码级根因并修复。

新增回测与基准工具：

```bash
# 现场数据回测：门级失败归因 + 策略对比
python3 tools/PriorMap/tag_capture_backtest.py \
  --root 扫描结果 --root "PC处理结果/0823-tianhong" --compare

# 动态结构过滤热循环基准（真实地图包）
python3 tools/PriorMap/dynamic_filter_benchmark.py \
  --package /path/to/mapcase03_sam --points 600 --frames 30

# 实时定位诊断：为什么 usable 占比低（门限拟合 + 拒绝原因分布）
python3 tools/PriorMap/localization_trace_diagnostic.py \
  --root 扫描结果 --root "PC处理结果/0823-tianhong"
```

### 实时定位 usable 占比低的根因（2026-08-30 诊断结论）

对 37 个会话、43,995 条 `localization_trace.jsonl` 逐帧记录做统计：

- 手机 `trackingState` **100% 为 normal**、`structureSource` 89.6% 为 `scene_depth`——**问题不在 ARKit，也不在缺深度**。
- 拒绝原因集中在 `insufficient_structure_points`（44.0%）与 `ambiguous_structure_match`（26.8%），
  成功 `trusted_structure_correction` 仅 **0.2%**。
- `matchUniqueness` 中位为 **0**（21/27 个会话如此），门限 0.10 拒绝了 **91.3%** 的帧；
  在线修正安全门 0.35 m 拒绝了 **96.2%** 的帧（实际需要的修正量中位为 2.209 m）。
- **关键反证**：唯一性 = 0 的帧，其 `matchResidualCost` 中位为 0.0014，**低于**唯一性 > 0 的 0.0043。
  即多解帧的残差并不更差——**低残差不代表匹配正确，因此放宽残差门或安全门会引入错误匹配，不是有效修复**。

已修复：结构点门槛 45（`insufficient_structure_points` 占 44.0%）**不筛选质量**——
<45 点帧的 cost 中位 0.00273 反而优于 ≥45 点的 0.00340，各桶 `cost<=0.10` 通过率均 97–99%；
且 45 是硬编码字面量，与命名常量 `minimumSearchPointCount = 30`（搜索门槛）冲突，
导致 30–44 点的帧付了完整搜索却只因点数被丢弃（占 72.5%）。两处已改为引用该常量。
离线估算通过帧数 2,504 → 3,739（+49%）；cost/唯一性/角覆盖/安全门/多帧一致性全部照旧生效。
已尝试但因契约测试拒绝而**回退**：按空间盆地重算唯一性（详见报告 §4.8）。

Xcode Release 全量构建（CI 同款命令）已通过：`BUILD SUCCEEDED`，且构建产物内
`MarketScannerBuildIdentity.json` 经统一合约校验为 `build identity verified`，
`app_git_sha` 精确绑定 exact HEAD，`production_eligible=true`。
（`iphonesimulator` 依赖缺失，模拟器构建未执行；宿主环境禁止 SwiftPM `sandbox-exec`，
需加 `-skipPackageUpdates -scmProvider system`。）

结论：根因是**周期性平行货架造成的几何多解**，属场景几何本质，不是阈值调参问题。
破解方向是引入**非周期信息**（`MapPillar` 柱子、`MapCross` 交叉口、墙角、货架端头的角点/端点显著性图，
以及已绑定货架的 ESL 价签作为绝对锚点）。详见
[`MARKETSCANNER_ROUND2_REMEDIATION_2026-08-30.md`](MARKETSCANNER_ROUND2_REMEDIATION_2026-08-30.md) 第四节。

修复内容：

- **价签采集契约由 2/3/4 帧改为 2/2/3 帧**，采集窗口由 4.0 s 收紧到 2.5 s，最短采集时长 0.30 s 改为 0.20 s。冻结契约测试已同步更新，并新增三道防回退断言（单帧必须拒绝、放宽门必须严于主门且有面积托底、窗口必须封顶）。
- **ROI 门改为分层**：0.80 严格主门保持不变且仍是权威判据；新增"面积托底的第二道门"（归一化面积 ≥0.02 且交叠 ≥0.55）允许大而清晰的条码贴边通过，放宽进入的候选评分乘 0.85，并以 `relaxedROI` 标记供下游按低置信处理。
- **货架 quorum 改为强弱分级**：原 `resolve()` 要求组内全部帧 `!needsReview`，而现场 233/233 观察因深度不可用恒为 `needsReview`，导致分组永远为空。现在弱证据帧可以形成分组，但只有强帧数量达标时才判定 `algorithmCandidateReliable = true`，弱结果仍需人工确认且不自动发布。
- **测量连续失败提前退出**：已攒够最少证据帧且测量连续 3 次不可用时立即结束采集，不再空转到窗口超时。
- **动态结构过滤热循环加包围盒预筛**：原实现对每个深度点遍历全部货架/固定结构多边形的每条边，真实山姆地图（1240 多边形 / 4874 边）实测 753.76 ms/帧，与现场记录的 921 ms 更新尖峰吻合。预筛后为 34.67 ms/帧，**加速 21.7 倍**，结果逐一相等。
- **证据栅格上界改为每次生效**：原先只在每 100 帧触发裁剪，低帧率下可突破 50,000 上限。

回测结果：成功率 **0.0% → 64.9%**（0/74 → 48/74），单次采集均值耗时 **4.00 s → 1.14 s（−71.5%）**，失败空等 **267.8 s → 59.0 s（−78.0%）**。

该 64.9% 是**回测**成功率，表示这批 burst 按新策略能走完采集并形成结果；其中多数仍会因 `needs_review` 判为 `LOW_CONFIDENCE` 而不自动发布（符合"结果保留、发布从严"合同），且真机验证尚未执行。详见 [`MARKETSCANNER_ROUND2_REMEDIATION_2026-08-30.md`](MARKETSCANNER_ROUND2_REMEDIATION_2026-08-30.md)。

### 2026-08-15 山姆现场前端到端稳定性加固

现场候选分支对冷启动、地图导入/选择、扫描事务、ARKit/深度提交、人工重定位、价签 burst、停止封口和 PC 历史恢复做了故障注入审查。App 生产 Swift 源码（不含供应商 `Libraries/`）已清除显式 `fatalError`、`precondition`、`preconditionFailure` 和强制类型转换；损坏或缺失的 Settings 值使用保守默认值并记录诊断，UIKit/FileProvider 调用在错误线程进入时回送主线程，恢复日志、定位 trace、价签 observation/burst 和地图楼层不合法时返回严格错误或降级结果，不终止进程。ARKit 图像、深度与置信度缓冲只有在 lock/base-address 成功时才提交对应证据；缺失深度返回 unavailable，不强制解包。

扫描停止现在先关闭新写入 admission，并在同一线性化边界立即暂停 ARSession、native mapping 和 camera producer，再等待 prior-map/localization writer 排空和保存数据库，避免数据库继续增长而 required sidecar 已停止的终端证据空洞。若封口早期尚不能解析会话路径，会结束 finalization 事务、恢复同一连续轨迹的 camera/mapping 状态并返回扫描界面；已经提交数据库后 native host 暂不可用只写告警，不把成功封口变成闪退。空价签 burst、未知楼层人工重定位、损坏 recovery reason 和无可用 Metal/depth buffer 均有独立回归。

浏览器运行时还发现并修复了真实持久历史中的恢复问题：若旧 localized 任务被标为完成但其 `current` 不可验证，Map Studio 现在返回结构化 409、保留原输入和旧结果目录并继续提供四种处理模式，不再让 GET 请求线程断开并显示模糊的 `Failed to fetch`。合并扫描前命名后的当前主机证据为命名 UX/source 合同 **25/25 PASS**、PriorMap **331/331 PASS（376.662 s）**、Qualification **30/30 PASS（12.128 s）**、Map Studio **142/142 PASS（9.671 s）**、native **7884/0 PASS**、Swift parse/生成合同/patch 检查和 unsigned generic iPhoneOS QualifiedDevice Debug 全量编译/链接 PASS；前序加固提交的 clean exact-commit macOS Release、QualifiedDevice Release、签名构建及安装证据继续有效，但合并提交仍须单独核对 Release bundle identity。1600/1280/980 浏览器宽度均无横向溢出。当前压力回归的 30 万条 finalization、172.8 万条 trace、40 万条 tag evidence 峰值 RSS 分别为 13,139,968、59,113,472、746,192,896 bytes；trace 保留 172,801 条，tag evidence 接受 200,000 条。真机进程存活、命名交互、相机授权、LiDAR 扫描及 start/stop/finalize/export 尚未由本次合并验证；热/低磁盘、Files Provider、异常退出后的 MetricKit 延迟投递和山姆完整路线仍不能由主机或安装结果替代。

通道/货架约束定位现有 P1-B～P2 仍是待资格化实现，不能表述为全部关闭。manifest v5 已绑定 epoch/component、通道状态、货架窗口和闭环证据；2026-08-17 的 sidecar v2 修复进一步让通道评分显式包含距离、结构盆地与道路拓扑，并用过滤后的深度点到货架段残差替代“当前位置附近货架”和普通视觉闭环 inlier 的自证路径。随后加入的 pose-transition v3 从同一 native RTAB-Map Statistics 事件冻结 exact loop edge，并把 node pair、两端 epoch/component、native measurement、epoch-frame bridge estimate 和共识 inlier 逐条写入 append-only transition；只有至少两组 node-disjoint、同 component、与 transition transform 几何一致的 global/local-space edge 才能授权跨 epoch 闭环。单链路、反向/重复 pair、共享端点、错误 component、变换冲突和旧 v2 aggregate counter 全部保持 fail-closed；没有 bridge 的 transition 仍会在 finalization 时如实写为空证据。C-1/C-2/C-3 仍为 `CALIBRATION_PENDING`；publication invariant v3 允许 Debug 在其余真实质量门全部通过时形成 `COMPLETE/TEST` 最终成果，但固定 `production_publish_permitted=false`。PC 正式 current publication 与 clean Release 的生产 scope 仍要求冻结标定，TEST 结果不能被提升为正式生产发布。签名 LiDAR 真机跨 epoch 实测、阈值标定、Sam 现场 A/B、异常退出恢复和动态顾客/购物车仍未完成，整体状态继续为 **NO-GO / NOT PRODUCTION READY**；详见 [`IMPLEMENTATION_STATUS.md`](docs/map-assisted-localization/IMPLEMENTATION_STATUS.md)。

“处理历史扫描”只列出 `finalized=true` 的连续单库会话。手机后处理会先生成 immutable snapshot，并对 SQLite、Node/Link 和图位姿 BLOB 执行严格校验；iOS App sandbox 不再依赖 SQLite 重新打开 `/dev/fd/<n>`，而是从已绑定的 no-follow descriptor 流式复制到 App 私有临时目录进行只读完整性校验，复核源 inode 后立即清理。每个历史会话还提供独立“导出原始扫描”按钮：即使手机后处理失败，也可选择 Files 或外接存储目录，复制完整 `segment_0001`，对源/目标/复制后源执行 SHA-256 manifest 三方一致性检查，写入复制凭证，并始终保留手机中的原始会话；同名目标使用新的 `-Export-*` 目录，绝不覆盖已有导出。

### 2026-08-14 跨端稳定性自检基线

正常生命周期不得通过强制解包、强制类型转换、`fatalError`、`preconditionFailure` 或 Debug assertion 结束进程。当前自检已覆盖 Core Location 空回调、窗口方向暂不可得、历史数据库列表越界/类型不符、数据库修改时间读取失败、Application Support 状态目录不可创建、价签状态竞态和已提交结果恢复分支；这些情况现在分别被忽略、返回可选值、记录诊断或转换为可恢复的类型化错误，不再让扫描/处理进程直接崩溃。真正的数据库、证据 framing、身份、水位、CAS 或原子提交损坏仍保持失败关闭，并保留扫描日志、任务 journal、恢复包或已经提交的不可变结果。

人工地图锚点在 iOS 与 PC 统一为 canonical SE(2)。PC 工作台不再提供容易产生不可控跳变的连续 yaw slider，只保留 X/Y/yaw 数值输入、0.1/0.5/1.0 m 四向微调、±1/±5/±15°旋转、东/北/西/南和键盘操作；界面显示值就是服务端提交值，不进行隐藏坐标或朝向变换。低置信度、部分图、平行通道/货架多解、时钟局部缺口和可恢复的关联不足只降低发布资格，不得删除源节点、durable 价签或整个处理版本。

本轮主机证据包括 PriorMap 全量 329/329（378.876 s）、Qualification 30/30、Map Studio 完整 API 131/131、原生检查 7884/0，以及 macOS Release `rtabmap-reprocess` 构建。规模子进程处理 300,000 finalization（8.111 s，峰值 RSS 13,287,424 bytes）、1,728,000 trace（保留 172,801，0.405 s，峰值 59,146,240 bytes）和 400,000 tag evidence（输入 282,352,646 bytes，接受 200,000，29.046 s，峰值 747,192,320 bytes）；tag 路径仍低于冻结的 768 MiB host 门，但余量有限。真实浏览器响应式自动化仍受浏览器 localhost 安全策略限制；签名真机、LiDAR、Files provider、热/低磁盘和现场非空价签真值仍属于设备/现场验收，不能由上述主机结果替代。

### MapCase02 标准工作簿状态（2026-08-09）

`MAPCASE02 / STANDARD SUPERMARKET XLSX FORMAT PASS`：Swift/PC 对正式工作簿 top-left anchor、production role geometry、canonical v3、package v2、road/spatial/distance/shelf 派生工件与资源上限已完成阻断级收口。冻结统计为源 1838、active 1630、货架 1301、固定结构 329、展示审计 208、active 越界 0；canonical SHA `5ddfac7dc439afc45abdcf800b799c05d53704895b620d161ef08a442c55b2db`。2026-08-09 真机导入暴露编译器保留大写、地图库只接受小写的 `prior_map_id` 合同断层；当前新包统一生成小写且总长不超过 128 的 ID，正式 MapCase02 为 `piaseczno-5ddfac7dc439`，并已补齐 compile → integrity → MobileMapLibrary install/register/list/exact-read 回归。Swift/Python 还共同严格校验 manifest/report 计数、warnings/malformed rows 以及 road graph node/edge 绑定，手机原样生成包必须通过 PC production validator。旧 uppercase v2 开发包在普通 iOS/PC validator、旧向导和离线定位入口均默认拒绝，只能通过显式 diagnostic-only 参数做只读检查，不能参与新的扫描或处理。

这是 2026-08-09 地图格式局部链路的历史结论，不是产品发布结论。完整 PriorMap discover 已在 2026-08-14 当前修复源码上完成 329/329；Apple 双平台 cold clean link、签名 LiDAR 真机、Device Lab、Replay/FAR 和现场验收仍待执行。I10 exact-SHA 的 iphoneos `rtabmap-res_tool` 历史阻断与 I11 修复仅作为演进记录保留，未创建冻结标签。当前整体仍为 **REJECTED / NO-GO / developer smoke only**，J-04 仍为 **BLOCKER / NOT CLOSED**。

每个 frame observation 先写入 `tag_observations.jsonl`，完整 burst 再写入 `tag_observation_bursts.jsonl`，最终确认前必须证明 burst complete，并对 `observation_id / burst_id / frame_id / payload / symbology` 做精确磁盘交叉绑定。只有至少 3 个逐帧通过定位、测量、关联质量门且共同指向同一 `shelfSegmentId + side` 的独立证据，才能打开可提交的货架确认。确认页显示小地图、高亮货架、算法候选和替代侧面；`USER_CONFIRMED` / `USER_OVERRIDDEN` 作为 additive v2 用户证据保存，不能覆盖算法字段，更不能修改 SLAM、轨迹、node pose 或定位约束。

扫描最终化与证据 writer 通过统一 admission gate 线性化：finalization 关闭新 admission 后，会等待此前已登记的 localization/confirmation transaction 完成；已登记 writer 不会被内部二次 finalization 检查误拒。finalization sentinel 之后到达的普通 ARFrame 定位任务和普通 Recovery append 会被拒绝，只有终端 Recovery 与 scan-stop 自有 audit 使用窄范围 `allowDuringFinalization`。ESL audit 冻结 generation 对应的 exact tracking session，只能追加到仍存在的既有 `segment_0001`，不会创建空的后继会话，也不会把旧 capture audit 写入新会话。

PC 输入 manifest v3 在既有 Recovery 证据之外绑定 burst sidecar，v4 再绑定严格扫描期时钟证据。共享 validator 严格验证 v1/v2/v3/v4 整数版本、Recovery binding、role/filename 顺序、大小写不敏感文件名唯一性、source database 安全 basename 及其与 `source_manifest` 的名称一致性；snapshot 与 verified copy 拒绝 source DB hardlink、非空 WAL 和 rollback journal。manifest v3/v4 中只有 localized tag v2 使用 verified complete burst 的 `bound_node_id` 作为唯一节点权威；同一会话中的历史 tag v1 保持 legacy explicit-node/timestamp 兼容，不会被错误强制绑定到 burst。手机和 PC 现在统一采用“结果保留、发布从严”合同：单个 burst/frame、节点绑定、位置字段、货架关联或确认材料不完整，只降级对应价签为 `LOW_CONFIDENCE`，保留条码、可恢复位置和精确原因；必要时额外生成非阻断补扫建议。durable burst 的 `burst_id/frame_id/observation_id` 在整个会话全局唯一，即使某个 burst 后续退化也不能释放并被后续记录复用；若最终价签数组漏写了一个身份明确的 durable burst，PC 会补出一条保留 barcode/symbology/capture ID、坐标与货架为空的 `LOW_CONFIDENCE` 业务记录。普通 PC 地图同时输出全量 `price_tags.json/csv`，无有限坐标的价签不会进入 GeoJSON，也不会被伪造为 `(0,0)`。文件 framing/UTF-8/JSON 不可界定、哈希或水位不一致、重复持久主键、地图/门店/楼层/会话身份串包、数据库损坏、完全没有有限轨迹或无法安全提交结果仍会终止。任何低置信度/部分结果都设置 `publish_permitted=false`，但不再等同于处理失败或价签删除。离线优化与现场选择一致时输出 `NO_CONFLICT` 并保持批准；可靠优化结果冲突时输出 `USER_CONFIRMATION_CONFLICT`，离线证据不可用时输出 `OFFLINE_ASSOCIATION_UNAVAILABLE`，两者都强制人工复核。MapCase02、地图坐标变换和任何 store/map/file-specific scale、offset、rotation 启发式均未在本轮 ESL 增量修改；其后续修复以独立正式规范和提交为准。真实 LiDAR iPhone 的 30 秒性能、强弱光/反光/斜视/多价签矩阵和完整现场验收仍未执行，因此项目判断仍是 **REJECTED / NO-GO / developer smoke only**，J-04 仍为 **BLOCKER / NOT CLOSED**。

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
- 扫描期间约每 5 秒向 `performance_samples.jsonl` 追加一条有界结构化样本，数据库保存完成后再写终止样本。`metadata.json` 记录精确条数、末序号、末时间和写失败水位。性能证据缺失/损坏会关闭“性能资格通过”结论，但不会删除有限轨迹或让安全落盘的原始地图失效。
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
    performance_samples.jsonl       # 约 5 秒一条的手机性能时间线
    metrickit_diagnostics.jsonl      # 系统延迟投递时的 crash/hang/CPU/disk-write 诊断
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
- `performance_samples.jsonl`：严格递增的有界性能时间线，记录进程 CPU 时间/占用率、物理内存、可用内存/磁盘、电池/充电、热状态、FPS、RTAB-Map 更新时间、节点/数据库/会话目录增长。iOS 没有普通应用可用的可靠整机 GPU 利用率公开 API，因此明确写 `gpu_metric_status=not_available_public_ios_api`，绝不从 CPU 或渲染时间伪造 GPU 百分比。
- `metrickit_diagnostics*.jsonl`：MetricKit 延迟投递的 crash、hang、CPU exception 和 disk-write exception 原始诊断；若系统已投递到该会话，PC 结果包会原样保留。
- `tag_observations.jsonl` / `tag_observation_bursts.jsonl`：已有地图模式下的严格 ESL 逐帧与完整 burst 证据；两者必须在最终化和 PC parse-and-hash-once snapshot 中精确交叉绑定。
- `localized_price_tags.json`：用户确认后的价签结果；v2 将 algorithm evidence 与 user-confirmed evidence 分开，现场确认不会回写或覆盖算法/SLAM 事实。

如果会话中仍存在 `live_checkpoint.json`，PC 工作台会把它视为正在写入或异常未完成的数据，拒绝自动重处理。

## PC 端处理

### Supermarket Map Studio

`tools/SupermarketMapStudio/` 是本项目推荐的统一入口。它使用 Python 标准库提供仅绑定 `127.0.0.1` 的本机服务，并在浏览器中完成：

- 连续流式单库、旧版分段会话和多设备会话检查；
- SQLite 完整性、RGB-D/标定、时间戳和节点统计检查；
- 手机端稳定/多视角结构覆盖、地面冲突和自适应节点率摘要检查；
- 手机性能时间线的严格 framing/身份/水位校验，以及 CPU、内存、磁盘增长、热、电池、FPS、RTAB-Map 更新时间的趋势、分位数、峰值和采样缺口分析；
- `rtabmap-reprocess` 离线闭环与全局优化编排；
- 优化前后轨迹覆盖率、步长、旋转、垂直跨度和尺度验证；
- 二维结构图、白底黑色货架闭合边界、彩色 RGB-D 俯视图和 WebGL 三维预览；
- 手机采集日志、PC 处理日志、质量结论与成果文件浏览；
- 最终地图目录内生成 `performance/phone/phone_performance_samples.jsonl`、同名 CSV、`phone_performance_summary.json` 与总清单；坏日志不伪装成统计结果，但在安全大小范围内以 `.invalid.jsonl` 完整保留供取证；
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

`shelf_outline.png` 为保持地图包兼容而沿用旧文件名，内容是白底黑色的货架实例闭合外边界：内部保持白色，不输出零散开放线段，也不会把证据机械拟合成矩形框。生成器对数据库中全部可用 RGB-D 深度帧执行独立的结构证据通道，不再受彩色/3D 预览最多 96/240/384 帧的抽样预算限制；默认只接受至少两个独立帧重复看到的竖直面，以抑制行人、购物车和单帧深度毛刺。若 `Admin.opt_poses` 覆盖完整，整条结果统一使用完整优化 SE(3) 位姿（包括 roll、pitch 与垂直修正）；普通预览若发现优化图仅覆盖部分节点，会整条回退到 `Node.pose`，禁止逐节点混合两个 gauge。prior-map 处理则使用显式的连续 partial-graph recovery 生成完整不可发布草稿，而不是把两种坐标系逐点拼接。人工 stage/device 的 dx、dy、yaw 作为投影后的平面残差继续生效。高度再减去与该帧匹配的相机高度，以保守抵消优化图中仍可能残留的垂直漂移，然后分别提取地面、层板面和竖直面。货架下方通常缺少地面回波，因此会先在内部重建货架占地掩膜，但候选必须能在某一横截方向找到两侧地板或稳定自由空间；实测地面和重复射线清空区域用于保护通道，未知空间或只有单侧证据的区域不会被凭空填满。同一栅格若多帧稳定看到地面、却仅偶尔出现竖直面，还会按地面冲突率再次过滤；窄桥分水岭随后拆开被重影或噪声粘连的相邻实例，最终只提取每个实例的外侧闭合边界。`shelf_outline_evidence.json` 第 6 版除竖直面、地面、层板面、稳定自由空间及独立观测次数外，还记录结构识别实际可用、抽取和成功解码的帧数。Map Studio 可通过“更干净—更完整”滑杆、三档预设或高级门槛即时重算补全距离、通道保护、粘连拆分和轮廓线宽，并显示直接扫描支持率、下载当前 PNG，不必重新执行 PC 优化，也不会覆盖默认成果。旧第 4、5 版证据仍可读取。该结果仍是几何推断：仅凭深度几何不能绝对区分货架与墙体，累计水平位姿漂移造成的重影也无法由轮廓后处理完全消除；缺少两侧地板或结构视角的边缘区域会保守留空。彩色/3D 预览可按内存需要选择快速、详细或最高档，不会再减少货架识别使用的帧数。

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
