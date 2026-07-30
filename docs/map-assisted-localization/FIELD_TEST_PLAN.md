# 正式现场测试计划

> 文档状态：**当前有效的正式验收预案，尚未执行**。最后核对日期：2026-07-30。

阶段一/二整改、阶段三自动测试和独立复审通过前，不安排正式超市场景，避免用现场时间替代可重复测试。本仓库没有可用的真实超市、真值控制点或 LiDAR iPhone，本次开发不生成虚构现场结果。

正式测试前置条件：

- 阶段一 review 通过；
- 阶段二实时匹配、置信度、Vision 扫码和价签测量 review 通过；
- 办公室回放、热状态、磁盘和中断恢复干跑通过；
- 必需 localization sidecar 故障注入已验证持续告警、原数据库继续记录、`finalized=false`、checkpoint 保留和 PC fail-closed；
- 先验地图版本、现场楼层和入口控制点核对完成。
- 完整相对 SE(2) 因子图及其数值门完成；当前 `bounded_correction_field` 只能用于 draft/review pilot，不能作为正式 published 验收对象。

阶段三现场记录至少包括：

- 设备型号、iOS、地图 SHA-256、应用 commit；
- 起点/方向控制点；
- 预先定义的现场遍历路线、交叉口、柱子和重复平行通道；
- 单次测试固定一个楼层，不经过楼梯或电梯；另记录同层坡道/地面起伏造成的少量竖直位移；
- tracking 中断和人工恢复；
- 已知货架位置与测量控制点；
- 标签位置真值、手机位置和估计标签位置；
- 原始数据库 hash、全部 sidecar、capture health/processing eligibility、input identity、PC 参数、current version/revision、review/publish blockers 和结果 hash；
- 自由扫描对照组。

验收至少布置 20 个有人工真值的标签，覆盖重复货架、长直通道、转弯、一次 tracking 中断和一次人工重定位。最终报告必须列出定位/标签误差分布、失败样本、数据库与结果 hash；通过标准由现场负责人和独立审查者在执行前冻结。

阶段一禁止用“办公室预览看起来正确”替代现场绝对精度结论。

## 不可变证据与执行工具

真实设备按 [`DEVICE_QUALIFICATION_CHECKLIST.md`](DEVICE_QUALIFICATION_CHECKLIST.md) 执行，并使用 [`tools/Qualification/qualification.py`](../../tools/Qualification/qualification.py) 收集。设备矩阵必须完整覆盖正常长扫、弱纹理、动态遮挡、扫码、人工纠偏、stop/finalization、provider copy、kill/relaunch、provider failure、low disk、thermal serious 和 checkpoint cleanup；缺一项即 FAIL。工具自动绑定 App Git SHA/build ID、native 静态库 hash、prior-map ID/SHA、session identity、全部 session 文件 hash、复制 package identity 和人工日志 hash。

办公室与真实卖场的阈值和因子图质量策略必须在 run 的执行时间之前冻结并绑定 release manifest SHA。Device/Field Evidence v2 同时绑定 raw session bundle、raw DB、tracking session、prior map、release 和 quality policy identity。每个场地至少 3 次独立扫描，每次至少 20 个独立真值标签；工具计算平面/高度误差，并要求 node inventory、full factor graph、弱/丢失期间自动确认、拓扑和货架关联重复性全部通过。输出文件不得覆盖，失败 scan 也必须保留。

本次代码工作只完成执行器和自动验证合同；仓库仍没有真实 LiDAR iPhone、办公室/卖场测量或人工签名，所以 P5/P6 状态保持 **NOT EXECUTED / NO-GO**。
