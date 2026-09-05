# iPhone 统一门店扫描交互

> 文档状态：**当前有效（统一全手机扫描主流程）**。最后核对日期：2026-08-19。

## 主入口与地图库

- 首页大型“新建扫描”和菜单首项“开始门店扫描”先打开轻量地图选择页，不再自动验证并加载 registry 第一张地图。用户可选择已注册地图或直接点击“导入新地图”；确认后才加载 exact package 并进入配置页。
- “门店地图”和扫描选择页使用同一个地图库。手机现场编译的 XLSX/CSV/JSON 与 PC 生成的正式 v2 prior-map package 在完成严格验证后都注册到该地图库，并进入同一个配置页、同一个 coordinator 和同一个真实扫描 host。
- “导入已有 PC 地图包”使用文件夹 open-in-place picker 和 security-scoped URL；不把 `.folder` 交给不受所有 FileProvider 支持的 document-copy 模式。选择动作会先释放未显示的预热文件 picker，等 action sheet 完成本轮 dismissal 后再展示文件夹 picker，避免两个 provider presentation 重叠。选中后仍在后台完成单快照验证、App 私有 staging、复验和原子注册，外部目录只读且不直接参与扫描。
- 自由扫描建图和原始数据录制保留在“实验与兼容工具”，用于旧流程回归和诊断，不是发布版主要作业入口。NFC 入口继续保持关闭。
- 地图选择页作为 modal root 显示“关闭”；配置页总是由选择页 push，保留系统返回按钮和返回手势。需要换图时先返回选择页，不在配置页内触发另一张地图的完整加载。页面离开时会取消 queued/running 启动 operation；已成功进入 scanning 后不会误取消。

## 统一扫描配置

1. **选择地图**：选择页后台只读轻量 registry，并提供导入入口；点击一条记录后才后台完整验证 exact package。配置页以 immutable initializer 绑定这一张地图，不包含地图 picker，也不会在主线程逐包解析 JSON/PNG。
2. **选择楼层**：显示所选楼层的独立预览；本次扫描固定绑定该楼层，扫描中不能切层或跨楼层定位。同一楼层内少量坡道/地面起伏不影响二维先验位置。
3. **确认起点**：地图支持 1×—8× pinch zoom、单指平移、双击放大/复位和点击选点。起点可以用上/下/左/右方向键微调，步长可选 0.1 m、0.5 m 或 1.0 m。
4. **确认朝向**：使用东 0°、北 90°、西 180°、南 270°和左/右 15°微调；不再使用横向滑杆。方向箭头按地图坐标系实时更新。
5. **启动门**：完整绑定 registry 与 manifest 的 name、floor count、element count、canonical source SHA、prior-map ID、package SHA 和 store ID。Debug 与 Release 都生成严格、可追踪身份并进入同一完整扫描链路；Debug clean/dirty 均可做端到端测试，配置页只展示其测试来源而不禁用开始按钮。默认 `RTABMapApp` Run 与 `RTABMapApp-QualifiedDevice` 仍使用 clean Release，供性能和现场资格验证。
6. **相机权限**：`.authorized` 才允许 workflow begin/commit；首次 `.notDetermined` 先请求权限，授权后重新走整个正式入口，拒绝/受限则恢复交互并提供“打开设置”。host 不允许旧 `startCamera()` permission callback 在 workflow 失败后自行启动。
7. **开始扫描**：localizer、会话目录、连续 SQLite 数据库和 sidecar probe 在 workflow 串行后台队列准备；主线程只安装 UI/localizer、启动 ARSession/CameraMobile 并切换 mapping。ARSession、RTAB-Map、sidecar、receipt 和 workflow context 全部 durable commit 后才进入 `.scanning`。

扫描启动 receipt 使用 `O_EXCL | O_NOFOLLOW` 创建并执行文件/目录 fsync；workflow context v3 绑定 session、segment、source database、地图/store、receipt path/SHA 和 scanning checkpoint。任何持久化失败、用户返回或启动取消都会调用强 rollback：停止 mapping/camera/clock writer、清 localizer/evidence、让 native core 脱离失败数据库、释放 session identity 并回到 idle。旧 `Documents/rtabmap.tmp.db` 的异步恢复提示不会介入 canonical Mobile-Only 启动事务。

阶段一提供道路节点锚点作为快捷起点。外部预定路线文件导入是可选增强项；当前回放工具只会基于道路图生成确定性的合成遍历路线，不把它表述为业务蛇形路线。

## 扫描 HUD

已有地图模式显示 2D 先验图、最近最多 2,000 个轨迹点、当前方向、已确认/待复核价签层、可选路线层、当前通道和业务状态：

- 定位稳定
- 定位可用
- 定位较弱
- 定位已丢失

状态较弱/丢失时不停止数据库记录。没有唯一道路候选时提示继续走向交叉口、柱子或端头，不跨通道硬跳。

匹配分数、唯一性、多候选轨道支持帧数/分差、点数、残差和耗时位于默认折叠的“定位诊断”区域，主 HUD 只显示业务状态、当前通道、最近安全修正和下一步提示。连续 weak/lost 会周期性启用 5 m/30°恢复窗，可靠 RTAB‑Map 闭环也会触发该恢复；候选仍须跨 3—4 帧稳定并与相邻通道拉开分差，每次实际结构修正平移不超过 0.25 m、旋转不超过 8°，不会静默跨通道跳转。

结构点必须在同一世界 voxel 中连续出现至少 4 个近期帧后才进入匹配；中断后重新计数，避免购物车或行人稍后重访同一位置时累积成静态货架。检测率升档需稳定 8 秒、降档需稳定 12 秒，减少长扫描中的频繁振荡。

“确认当前位置”记录当前估计；“重新选择位置”打开地图选择器，支持点击、拖动红色箭头、双指平移、捏合缩放和旋转朝向，不要求现场输入 X/Y/yaw。两者都写审计日志。

人工确认提交后显示原选择器并等待 durable 结果，不要求测试人员移动或晃动手机。host 会为本次请求临时关闭 RTAB-Map 的小位移节点淘汰与 rehearsal 合并，让下一 detector tick 在静止场景也可保留；一旦取得候选、超时、取消、系统中断或扫描结束就请求恢复原扫描参数，不长期提高节点率。

人工确认使用 native 原子冻结的 node ID/stamp、CameraMobile timebase offset 和 generation。候选 frame 与 node stamp 必须严格晚于提交时刻；已有基线时还要求不同 node ID 和递增 stamp，且按当前 frame time 复核 node-time 差不超过 1 秒。旧节点、请求前已排队的帧和超出时间合同的快照仍拒绝；成功前必须先 durable append manual JSONL，再执行 alignment CAS，不会伪造 PC 锚点事件。

“扫描价签条码”进入专用 camera-only Capture Mode，持续消费当前 `ARFrame.capturedImage`，不启动第二路相机，也不暂停 ARSession、RTAB-Map、数据库、Clock、Pose、node creation 或 prior-map localization；ARKit continuous autofocus 显式保持启用。固定 scan box 会映射成 Vision 的真实 ROI；状态文字固定在该框上边缘外 18 pt，条码文字固定在下边缘外 18 pt，边框、文字布局和 Vision ROI 共用同一个 `normalizedScanRect`，不再用 `centerY` 偏移。Vision 最多 10 Hz、one-in-flight；主 ROI 无结果时在同一 worker/ARFrame 上只追加一次有界扩展 ROI，支持 QR、EAN‑8/13、Code128、Code39/93、I2of5、ITF14、UPC‑E、PDF417、DataMatrix、Aztec（iOS 15+ 另含 Codabar）。每个 request 有 1 秒 ARFrame deadline，预览最多 24 Hz。Vision worker 固定为两条 lane：超时 lane 被 cancel/quarantine，备用 lane 可继续；两条都挂起时 Barcode UX fail closed，原扫描继续。候选连续 2 帧锁定，同一 capture 目标 4 个、最低 3 个独立 frame，最大窗口 4 秒。

扫码初始提示建议与价签保持约 25–45 cm，让 ARKit continuous autofocus 有合理工作距离；模糊或退化深度只跳过当前 frame。iPhone 15 Pro 及更新机型可在“设置 → Action Button → Shortcut”绑定 MarketScanner 的 `Scan ESL` App Shortcut；它回到前台后走与屏幕按钮相同的完整准入。传统 Ring/Silent 拨片和音量键不可作为受支持的 App 原始按键，应用不监听系统音量变化、不嵌入隐藏音量控件，也不另外打开 `AVCaptureSession`。

Vision 识别“条码”，不识别“这个条码印在商品包装还是 ESL 上”。因此商品正面的 EAN/UPC 和 URL QR 很快成功是正常检测结果。当前把典型零售码标为“疑似商品码”，操作员只有在确认该码确实印在 ESL 上时才能保存；Code128 继续允许，因为山姆现场 ESL 自身就是 Code128。若要求完全自动区分，必须另提供门店级 ESL payload/主数据合同。

条码已锁定但 live node snapshot 暂时不可用时，只释放当前 evidence slot，并在同一严格 1 秒 node-timebase 合同内复用已冻结 exact-ID snapshot 或等待后续 frame；不得把它升级为 required-write failure，也不得启用 nearest-node/timestamp fallback。完整 durable burst 若仅因 recovering/weak、深度、node uncertainty、位置离散或货架歧义不足以自动确认，会直接保留为 `LOW_CONFIDENCE`，现场提示无需立即重扫；scene-depth observation v2 使用同一次 snapshot 保存 exact node-local point，PC 按 `P_final=T_final_node×P_node` 重投影并把结果写入 PriceTags 待复核。只有 burst/身份/图质量/exact node/node-local point/可解析位置等权威证据缺失，或输入仍是 legacy v1 coordinate frame 时才进入 `RESCAN_REQUIRED`。

深度使用内缩 9×9 ROI，记录样本数、内点数/比例、中值、MAD、平面残差和法向；样本不足、前后景分层、反射/孔洞或平面不稳定时退化为货架射线或待复核，不能因为“有深度”就获得高置信。对齐快照超过 250 ms 降级，超过 600 ms 或版本落后强制 lost/review。只有至少 3 个逐帧可靠证据共同指向同一 `shelfSegmentId + side` 才允许确认；弱帧可以保留作 raw audit，但不能凑足确认 quorum。

平面无法形成稳定法向量时 `plane_residual_m` 必须为缺失而不是 NaN/Infinity；observation 在 JSONL 写入前再次检查所有浮点证据。该类单帧数值退化只等待下一帧，不把整场扫描标成写入失败。应用没有“三个通道后新建扫描”的规则，整个楼层仍写同一个 `segment_0001` 连续数据库；只有真正的 required sidecar 写入/framing/身份/绑定失败才提示结束并创建新扫描。

逐帧 observation 先落盘，complete burst 后才进入确认页。确认页显示 ESL、算法货架/侧面、迷你地图、高亮货架和替代候选，提供“正确”“错误/选择替代”“重扫”“仅保留观测”。替代选择按 segment + side 精确绑定。`USER_CONFIRMED` / `USER_OVERRIDDEN` 只新增用户证据，不覆盖算法关联，更不修改 SLAM、轨迹或 localization constraint。required evidence 写入失败、prior-map generation 失效或持久化失败时 fail closed，原始 RTAB-Map 数据库仍继续记录。

用户结束扫描时，Capture Mode 会失效 generation 并停止新的普通 Vision/定位工作；finalization 在后台等待此前已登记的 observation、confirmation 和 localization writer 完成，不会因超时提示而跳过 drain。普通 Recovery/audit 不能越过 finalization 边界，只有终端 Recovery 与本次 scan-stop 自有 audit 可以使用窄范围写权限。迟到 callback 只认 capture 开始时冻结的 tracking session；旧会话已 detach 时直接拒绝，不会新建空扫描目录或写入下一次扫描。

定位 trace、constraint、state、观测或已确认价签的必需写入失败时，HUD 持续显示红色“辅助定位证据写入失败”提示；首次失败另显示长 Toast。失败对当前会话是粘性的：立即停止新的先验地图修正、人工校正和价签确认，但原始 RTAB‑Map 数据库继续记录到用户结束。结束后数据库关闭，metadata 保存 `finalized=false`，checkpoint 保留，并可导出完整恢复包；应用不会回到 prior-map 录制。用户应开始新扫描，不要把红色告警会话交给 PC 强行优化。

## 历史扫描处理与原始导出

- “处理历史扫描”只发现 `metadata.finalized == true`、`scanMode == continuous_streaming` 且存在 exact `segment_0001/rtabmap_segment_0001.db` 的会话；点按行进入手机后处理，行尾的导出图标独立执行原始数据导出，两条操作互不依赖。
- snapshot 的 WAL/journal、hardlink、文件身份、SHA、SQLite `quick_check`、Node/Link 和 graph BLOB 门保持失败关闭。macOS host 可用 `/dev/fd/<n>` 复核已绑定 descriptor；iOS SQLite VFS 若明确无法只读打开该路径，则从同一 descriptor 流式复制到 App 私有 `0700/0400` 临时目录校验，前后复核 source dev/inode/mode/link/size/mtime/ctime，完成或失败都删除临时副本。其他 SQLite/graph integrity 错误不会触发兼容回退。
- 原始导出要求 exact 单一 `segment_0001`、finalized、连续单库、tracking identity 一致、无 `live_checkpoint.json`，且数据库为普通单链接文件。复制前、目标复制后和源复制后重新计算完整 SHA-256 manifest；三者一致后写 `copy_verification.json` 与 `copy_package_manifest.json`。手机源始终保留，目标重名时创建 `-Export-yyyyMMdd-HHmmss[-N]`，失败仅清理本次未完成目标。
- 导出按钮在复制期间禁用页面关闭、再次处理和再次导出，并显示校验、复制、SHA 复核和凭证写入进度。选择 Files/iCloud/外接存储目录时使用 security-scoped access，结束后释放。

## 周期强制校准与自动分卷（尚未上线）

需求基线见 [`PERIODIC_MANUAL_CALIBRATION_AND_AUTO_ROLLOVER_REQUIREMENTS_2026-09-04.md`](PERIODIC_MANUAL_CALIBRATION_AND_AUTO_ROLLOVER_REQUIREMENTS_2026-09-04.md)。目标交互（**当前代码中没有实现，不要对测试员或现场这样描述现状**）：

- 常驻 HUD 显示“第 N 个文件 · 已采集 mm:ss”“距校准并存盘 mm:ss”、当前文件大小与状态（采集中/即将维护/请原地校准/正在存盘/正在创建新文件/可继续）；文字、颜色、图标共同表达，支持 Dynamic Type 与 VoiceOver，价签 overlay 不遮挡倒计时。
- 剩余 5 分钟/1 分钟/30 秒各提醒一次；到点即关闭普通采集 admission（宽限 0 秒），全屏维护页不可通过点击背景、返回手势或“稍后”关闭。
- 维护页三步：确认当前位置（复用现有 X/Y/yaw 选择器）→ 自动保存第 N 个文件（等待稳定节点 → 写入校准审计 → 保存数据库 → 封口证据 → 校验完成）→ 创建第 N+1 个文件。允许的操作只有“确认位置并存盘”“重新选择位置”“重试”“结束本次任务并安全存盘”。
- 语义红线：`live_checkpoint.json` 只是运行状态摘要，**不是已存盘**；“已存盘”只在该 unit 满足 `metadata.finalized=true`、checkpoint 已清理、数据库脱离且本地文件仍在之后显示；“正在后台复制”不能替代本地已存盘。

阶段 1 已落地的只是 Foundation-only 决策核心（`PeriodicScanMaintenanceCore.swift`/`PeriodicScanMaintenanceStore.swift`）与新增的可选 mission 字段，`featureEnabled` 默认 false；HUD、提醒、维护页、自动封口、新卷启动和 Mobile-Only 工作流状态扩展均未完成。

## 当前限制

- 扫描中地图 HUD 仍以浮层叠加在现有相机/建图界面；本轮统一的是入口、地图库、配置和启动事务，不是对底层 RTAB-Map 渲染页面的整体重写。
- 大型门店的 30 分钟强制校准、自动封口与新文件启动尚未接线，扫描期间仍只有一个连续数据库，文件大小不会自动受限。
- ARKit 显示和记录完整连续，结构辅助计算按 2 Hz 节流，忙时丢弃新任务而不积压。
- 二维 HUD 忽略 ARKit 竖直高度；原始连续数据库仍保留三维运动。
- 当前扫描绑定一个楼层，不支持楼梯、电梯或其他跨楼层过程。
- 预定路线编辑和无条件全图搜索仍属于后续增强；当前只在持续 weak/lost 或可靠闭环后启用有界恢复。
- 2026-08-10 的历史 unsigned iPhoneOS Debug/Release 编译证据仍保留，但当时“Debug 身份被移除”的行为已由 2026-08-17 version 5 合同取代。当前 Debug/Release 都必须输出 `build identity verified`，身份绑定实际 source ref 和 tracked patch digest；Debug 可进入完整扫描、处理并生成 `COMPLETE/TEST` 最终成果。默认 Release Run 或 `RTABMapApp-QualifiedDevice` 安装后的触控 p50/p95、首次权限、后台/前台、完整扫描和设备热/内存表现仍需真机复测。
- Xcode Debug Navigator 若显示主线程停在 `ViewController.updateState(state:)` 的文件断点，App 会表现为黑底、网格或残缺旧控件；删除/停用断点并 Continue 即可。该现象是调试器暂停，不属于 App 状态机恢复路径。
- 真实 LiDAR iPhone 的 30 秒性能、照明/反光/斜视/多价签矩阵和完整现场确认尚未执行；低影响增强与明日测试见 [`ESL_CAPTURE_TODO.md`](ESL_CAPTURE_TODO.md) 与 [`MAPCASE02_TODO.md`](MAPCASE02_TODO.md)。当前不得宣称 ESL FIELD CAPTURE UX COMPLETE 或 Production Ready。
