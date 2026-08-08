# iPhone 已有地图辅助扫描交互

> 文档状态：**当前有效（阶段二移动端）**。最后核对日期：2026-08-09。

## 新建扫描

“新建扫描”和菜单中的“新建扫描会话”显示两个业务选项：

- **自由扫描建图**：使用原连续 RTAB-Map 单库流程，输出兼容不变。
- **已有地图辅助扫描**：进入先验地图向导。

数据录制高级入口仍固定使用自由扫描，不加载先验地图。

## 五步向导

1. **选择地图**：选择 PC 生成的 `PriorMap-*` 文件夹。应用复制到 Documents/PriorMaps，源包不修改。
2. **选择楼层**：显示所选楼层的独立预览；明确本次扫描固定绑定该楼层，扫描中不能切层或跨楼层定位。同一楼层内少量坡道/地面起伏不影响二维先验位置。
3. **确认起点和朝向**：地图支持点击、双指缩放/平移、选择当前楼层道路锚点，方向滑杆旋转箭头，并显示米制比例说明。
4. **设备检查**：相机、ARKit、LiDAR/深度、磁盘、温度、地图完整性和保存位置。
5. **开始扫描**：说明结构匹配只调整地图对齐、不改变原始数据库，道路只作弱先验，然后启动原连续数据库。

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

- 地图 HUD 以浮层叠加在现有相机/建图界面，尚未替换成完整业务首页。
- ARKit 显示和记录完整连续，结构辅助计算按 2 Hz 节流，忙时丢弃新任务而不积压。
- 二维 HUD 忽略 ARKit 竖直高度；原始连续数据库仍保留三维运动。
- 当前扫描绑定一个楼层，不支持楼梯、电梯或其他跨楼层过程。
- 预定路线编辑和无条件全图搜索仍属于后续增强；当前只在持续 weak/lost 或可靠闭环后启用有界恢复。
- 真实 LiDAR iPhone 的 30 秒性能、照明/反光/斜视/多价签矩阵和完整现场确认尚未执行；低影响增强与明日测试见 [`ESL_CAPTURE_TODO.md`](ESL_CAPTURE_TODO.md)。当前不得宣称 ESL FIELD CAPTURE UX COMPLETE 或 Production Ready。
