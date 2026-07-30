# 相对 SE(2) 因子图设计与验证合同

> 文档状态：**当前有效**。最后核对日期：2026-07-30。

## 生产路径

`rtabmap-prior-map-factor-graph` 以只读方式打开 `rtabmap-reprocess` 生成的 `optimized.db`，读取完整 Node inventory、`Admin.opt_ids/opt_poses`（缺失时回退 odometry poses）以及 RTAB-Map `Link`。它只接受 neighbor、merged neighbor、global/local/user/virtual closure；pose prior、landmark、gravity 和其他 Link 类型不会静默混入相对图，而是记录到拒绝审计。

手机默认使用 `xz` 水平面。Node pose、Link measurement 和 6×6 information 必须使用同一投影合同：先把 Link 的 native endpoint 组合出来，再分别投影起点/终点并求相对 SE(2)；information 通过该投影的数值 Jacobian 从 6D covariance 边缘化为 3×3，再检查有限、对称和正定。禁止把 native x/y 分量直接当作业务平面，也禁止用全局 `dx/dy` 代替局部 Link measurement。

求解器固定使用 RTAB-Map `Optimizer::kTypeG2O`、`slam2d=true`、robust kernel、100 iterations 和 `epsilon=1e-6`。纯相对图固定最小 node 作为 gauge；存在经 Python 硬门验证的绝对先验时，由绝对先验定义地图 frame，RTAB-Map 解除固定根。失败、断连、缺 endpoint、奇异/非有限 information、节点 inventory 变化、objective 上升或结果不收敛均 fail closed。

## 跨进程合同

Python 仅通过版本化 TSV 传递绝对先验，并对 native JSON 做第二次验证：

- `input_identity_id` 和 optimized DB SHA-256 必须与当前不可变输入一致；
- source/optimized DB 在执行前后 SHA-256 不变；
- 输出 node IDs 与离线轨迹完全一致；
- 每个 factor 的字段必须重新序列化为 canonical line，排序后的字节生成 `factor_set_sha256`；
- factor endpoint、相对图连通性、3×3 information、gauge、finite、convergence 和 objective 全部复核；
- native helper 缺失或失败时，仅允许 `bounded_correction_field` 作为 `draft_fallback`，并写 `native_factor_graph_helper_unavailable` 或 `native_factor_graph_failed` blocker。

绝对先验 TSV v2 分别传递米制 `translation_sigma_m` 和弧度制 `yaw_sigma_rad`；读取 v1 scalar weight 时显式按 `sigma=1/sqrt(weight)` 迁移。unordered endpoint/type 相同的 reciprocal Link 先转换为同一方向并变换 covariance/information；一致项折叠计数，measurement 或 information 冲突立即失败。原先误导性的 `downweighted_factor_ids` 已替换为逐 loop 的 `loop_factor_residuals` 和由策略阈值派生的 `high_residual_loop_factor_ids`。

`FactorGraphQualityPolicy` v1 将 solver convergence、graph integrity 与 product quality 分离，检查 relative/loop translation+yaw 的 p95/max、loop 高残差比例、最大 pose update、relative factor coverage 和 objective improvement。policy SHA 写入 factor report、release manifest 和现场证据。仓库内策略当前状态为 `candidate`，因此 `graph_quality_passed/published_capable` 必为 false；只有真实 P5/P6 分布经人工/P8 审核后将同一版本化策略明确冻结，生产发布门才可能通过。

完整求解结果写入不可变版本的 `factor_graph_report.json`。`localization_report.solver.factor_set_sha256` 必须与它一致；store 层还复核 input identity 和 optimized DB hash。只有完整 native graph、图完整性和冻结质量策略全部通过时，report 的 publish capability 才可通过。Field Qualification v3 不接受客户端声明 `factorGraphQualityPassed=true` 的自由 JSON，而是从 exact version manifest 绑定的 `factor_graph_report.json` 自动生成 `MarketScannerTrajectoryQualificationEvidence` v1。正式 `published` 状态还必须在 production runtime 的即时 selfcheck 通过后，由 store 写锁内复读 Field Evidence v3，并把 exact bytes 纳入 published manifest v4。

## 已执行验证

2026-07-28 在本机已有 Release RTAB-Map build 上完成 helper 编译，并对一份不进入 Git 的真实 optimized DB 只读运行：DB 版本 0.23.5，2,315 nodes，2,538 relative factors；objective 从 151,343.9712 降到 130,679.5373，30 iterations，严格 Python schema 通过。执行前后 DB SHA-256 均为 `20da4fc9bd2a2de30ab1fce48c813902aa30cdd1a86d3fb5c1c40ad04718432b`。

该结果证明真实 DB loader、坐标投影、information 投影和 native optimizer 在该样本可运行，不替代 clean-runner 构建、更多真实 DB 统计、真机或现场验收。自动测试覆盖 canonical/determinism、90° measurement、断连、缺 endpoint、奇异 information、非有限数、digest 篡改、gauge、收敛门和既有 full SE(2) tag propagation。
