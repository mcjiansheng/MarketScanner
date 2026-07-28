# MarketScanner 真实设备与现场资格证据工具

> 文档状态：**当前有效**。最后核对日期：2026-07-28。

该工具只收集和复核真实执行产生的证据，不运行或模拟 iPhone/卖场测试，也不允许把模板标记成通过。设备计划必须显式声明 `executionStatus=executed_on_real_device`；现场计划必须声明 `executionStatus=executed_with_independent_ground_truth`。声明由实际操作者负责，工具随后独立散列输入并执行失败关闭检查。

设备矩阵必须覆盖 `normal_long_scan`、`weak_texture`、`dynamic_occlusion`、`tag_scan`、`manual_correction`、`stop_finalization`、`provider_copy`、`kill_relaunch`、`provider_failure`、`low_disk`、`thermal_serious`、`checkpoint_cleanup`。每个场景具有固定的 `operatorAssertions` 集合（例如 weak/lost 不硬吸附、metadata commit 后不恢复写入、provider 失败后本地副本保留、cleanup 精确 CAS 和审计），不能用一个无关的 true 断言代替。每个 run 记录真实设备环境、App SHA/build ID、native 静态库、prior-map 包、session、外部复制包及日志。正常 session 必须 finalized、无 live checkpoint、required sidecar 完整且 eligibility blockers 为空；异常 session 必须明确 fail closed。

```bash
python3 tools/Qualification/qualification.py device \
  --plan /path/to/executed_device_plan.json \
  --output /path/to/new/device_evidence.json
```

现场计划必须在执行时间之前冻结 release manifest 与全部阈值，记录 `siteType`、独立测量方法和独立测量人员，至少包含 3 次独立扫描。每次提供 PASS 且自校验 hash 正确的 device evidence、PC 轨迹报告和至少 20 个独立控制点的 CSV；三者的实际文件大小/SHA 都写入输出，trajectory 的 source session SHA 必须匹配 device evidence 文件。CSV 列为 `tag_id,truth_x_m,truth_y_m,truth_height_m,estimated_x_m,estimated_y_m,estimated_height_m`。工具计算标签平面/高度误差，检查 node coverage、correction、relative residual、weak/lost、图连通/收敛、inventory、用户确认保护和跨 run 拓扑/货架关联重复性。

```bash
python3 tools/Qualification/qualification.py field \
  --plan /path/to/executed_field_plan.json \
  --output /path/to/new/field_acceptance.json
```

输出使用排他创建：同一路径已存在时拒绝覆盖。文件内容在发布前刷新到存储；POSIX 平台随后刷新父目录，Windows 因不支持目录句柄 `fsync` 而保留系统可提供的文件刷新与排他硬链接发布语义。PASS 仍不替代独立审查；原始 session、失败 run、控制点和所有输出必须连同 evidence 一起保留。
