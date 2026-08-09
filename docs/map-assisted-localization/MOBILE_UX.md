# iPhone 统一门店扫描交互

> 文档状态：**当前有效（统一全手机扫描主流程）**。最后核对日期：2026-08-10。

## 主入口与地图库

- 首页大型“新建扫描”和菜单首项“开始门店扫描”直接打开统一配置页，不再先展示自由扫描/已有地图辅助扫描二选一弹窗。
- “门店地图”管理同一个地图库。手机现场编译的 XLSX/CSV/JSON 与 PC 生成的正式 v2 prior-map package 在完成严格验证后都注册到该地图库，并进入同一个配置页、同一个 coordinator 和同一个真实扫描 host。
- 自由扫描建图和原始数据录制保留在“实验与兼容工具”，用于旧流程回归和诊断，不是发布版主要作业入口。NFC 入口继续保持关闭。
- 从首页直接打开的配置页显示“关闭”；从地图库 push 打开的配置页保留系统返回按钮和返回手势。页面离开时会取消 queued/running 启动 operation；已成功进入 scanning 后不会误取消。

## 统一扫描配置

1. **选择地图**：后台读取 registry；若从地图库某条记录进入，则后台完整验证 exact package。不会在主线程逐包解析 JSON/PNG。
2. **选择楼层**：显示所选楼层的独立预览；本次扫描固定绑定该楼层，扫描中不能切层或跨楼层定位。同一楼层内少量坡道/地面起伏不影响二维先验位置。
3. **确认起点**：地图支持 1×—8× pinch zoom、单指平移、双击放大/复位和点击选点。起点可以用上/下/左/右方向键微调，步长可选 0.1 m、0.5 m 或 1.0 m。
4. **确认朝向**：使用东 0°、北 90°、西 180°、南 270°和左/右 15°微调；不再使用横向滑杆。方向箭头按地图坐标系实时更新。
5. **启动门**：完整绑定 registry 与 manifest 的 name、floor count、element count、canonical source SHA、prior-map ID、package SHA 和 store ID。普通 Debug 构建只允许 UI/导入 smoke；正式开始扫描使用 `RTABMapApp-QualifiedDevice` Release Run。
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

匹配分数、唯一性、多候选轨道支持帧数/分差、点数、残差和耗时位于默认折叠的“定位诊断”区域，主 HUD 只显示业务状态、当前通道、最近安全修正和下一步提示。连续 weak/lost 会周期性启用 5 m/30°恢复窗，可靠 RTAB‑Map 闭环也会触发该恢复；候选仍须跨 3—4 帧稳定并与相邻通道拉开分差，每次实际修正不超过 0.35 m/8°，不会静默跨通道跳转。

结构点必须在同一世界 voxel 中连续出现至少 4 个近期帧后才进入匹配；中断后重新计数，避免购物车或行人稍后重访同一位置时累积成静态货架。检测率升档需稳定 8 秒、降档需稳定 12 秒，减少长扫描中的频繁振荡。

“确认当前位置”记录当前估计；“重新选择位置”打开地图选择器，支持点击、拖动红色箭头、双指平移、捏合缩放和旋转朝向，不要求现场输入 X/Y/yaw。两者都写审计日志。

人工确认使用 native 一次性冻结的最近 node ID/stamp、CameraMobile timebase offset 和 generation。短暂无新快照时可使用最近 1 秒内、按当前 frame time 复核仍与 node 相差不超过 1 秒的缓存快照；超过边界仍拒绝，不会伪造 PC 锚点事件。

“扫描价签条码”进入专用 camera-only Capture Mode，持续消费当前 `ARFrame.capturedImage`，支持 QR、EAN‑8/13、Code128、UPC‑E 和 PDF417，不启动第二路相机，也不暂停 ARSession、RTAB-Map、数据库、Clock、Pose、node creation 或 prior-map localization。固定 scan box 会映射成 Vision 的真实 ROI；Vision 最多 8 Hz、one-in-flight，每个 request 有 1 秒 ARFrame deadline，预览最多 24 Hz。Vision worker 固定为两条 lane：超时 lane 被 cancel/quarantine，备用 lane 可继续；两条都挂起时 Barcode UX fail closed，原扫描继续。候选连续 2 帧锁定，同一 capture 目标 4 个、最低 3 个独立 frame，最大窗口 2 秒；达到 deadline 时已有 3 个 durable frame 即进入解析，否则保留原始观测并要求重扫。

深度使用内缩 9×9 ROI，记录样本数、内点数/比例、中值、MAD、平面残差和法向；样本不足、前后景分层、反射/孔洞或平面不稳定时退化为货架射线或待复核，不能因为“有深度”就获得高置信。对齐快照超过 250 ms 降级，超过 600 ms 或版本落后强制 lost/review。只有至少 3 个逐帧可靠证据共同指向同一 `shelfSegmentId + side` 才允许确认；弱帧可以保留作 raw audit，但不能凑足确认 quorum。

逐帧 observation 先落盘，complete burst 后才进入确认页。确认页显示 ESL、算法货架/侧面、迷你地图、高亮货架和替代候选，提供“正确”“错误/选择替代”“重扫”“仅保留观测”。替代选择按 segment + side 精确绑定。`USER_CONFIRMED` / `USER_OVERRIDDEN` 只新增用户证据，不覆盖算法关联，更不修改 SLAM、轨迹或 localization constraint。required evidence 写入失败、prior-map generation 失效或持久化失败时 fail closed，原始 RTAB-Map 数据库仍继续记录。

用户结束扫描时，Capture Mode 会失效 generation 并停止新的普通 Vision/定位工作；finalization 在后台等待此前已登记的 observation、confirmation 和 localization writer 完成，不会因超时提示而跳过 drain。普通 Recovery/audit 不能越过 finalization 边界，只有终端 Recovery 与本次 scan-stop 自有 audit 可以使用窄范围写权限。迟到 callback 只认 capture 开始时冻结的 tracking session；旧会话已 detach 时直接拒绝，不会新建空扫描目录或写入下一次扫描。

定位 trace、constraint、state、观测或已确认价签的必需写入失败时，HUD 持续显示红色“辅助定位证据写入失败”提示；首次失败另显示长 Toast。失败对当前会话是粘性的：立即停止新的先验地图修正、人工校正和价签确认，但原始 RTAB‑Map 数据库继续记录到用户结束。结束后数据库关闭，metadata 保存 `finalized=false`，checkpoint 保留，并可导出完整恢复包；应用不会回到 prior-map 录制。用户应开始新扫描，不要把红色告警会话交给 PC 强行优化。

## 当前限制

- 扫描中地图 HUD 仍以浮层叠加在现有相机/建图界面；本轮统一的是入口、地图库、配置和启动事务，不是对底层 RTAB-Map 渲染页面的整体重写。
- ARKit 显示和记录完整连续，结构辅助计算按 2 Hz 节流，忙时丢弃新任务而不积压。
- 二维 HUD 忽略 ARKit 竖直高度；原始连续数据库仍保留三维运动。
- 当前扫描绑定一个楼层，不支持楼梯、电梯或其他跨楼层过程。
- 预定路线编辑和无条件全图搜索仍属于后续增强；当前只在持续 weak/lost 或可靠闭环后启用有界恢复。
- unsigned iPhoneOS Debug build、聚焦 UX/权限/receipt/地图库合同和完整 Swift host 已通过；真实 `RTABMapApp-QualifiedDevice` 安装后的触控 p50/p95、首次权限、后台/前台、完整扫描和设备热/内存表现仍需真机复测。
- 真实 LiDAR iPhone 的 30 秒性能、照明/反光/斜视/多价签矩阵和完整现场确认尚未执行；低影响增强与明日测试见 [`ESL_CAPTURE_TODO.md`](ESL_CAPTURE_TODO.md) 与 [`MAPCASE02_TODO.md`](MAPCASE02_TODO.md)。当前不得宣称 ESL FIELD CAPTURE UX COMPLETE 或 Production Ready。
