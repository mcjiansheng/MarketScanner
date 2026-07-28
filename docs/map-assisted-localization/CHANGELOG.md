# 地图辅助定位变更记录

> 文档状态：**当前有效**。最后核对日期：2026-07-28。

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
