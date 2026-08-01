# MarketScanner 真实设备与现场资格证据工具

> 文档状态：**当前有效**。最后核对日期：2026-07-30。

该工具只收集和复核真实执行产生的证据，不运行或模拟 iPhone/卖场测试，也不允许把模板标记成通过。设备计划必须显式声明 `executionStatus=executed_on_real_device`；现场计划必须声明 `executionStatus=executed_with_independent_ground_truth`。声明由实际操作者负责，工具随后独立散列输入并执行失败关闭检查。

设备矩阵必须覆盖 `normal_long_scan`、`weak_texture`、`dynamic_occlusion`、`tag_scan`、`manual_correction`、`stop_finalization`、`provider_copy`、`kill_relaunch`、`provider_failure`、`low_disk`、`thermal_serious`、`checkpoint_cleanup`。每个场景具有固定的 `operatorAssertions` 集合（例如 weak/lost 不硬吸附、metadata commit 后不恢复写入、provider 失败后本地副本保留、cleanup 精确 CAS 和审计），不能用一个无关的 true 断言代替。每个 run 记录真实设备环境、App SHA/build ID、native 静态库、prior-map 包、session、外部复制包及日志。正常 session 必须 finalized、无 live checkpoint、required sidecar 完整且 eligibility blockers 为空；异常 session 必须明确 fail closed。

```bash
python3 tools/Qualification/qualification.py device \
  --plan /path/to/executed_device_plan.json \
  --output /path/to/new/device_evidence.json
```

现场计划 v3 必须在执行时间之前冻结 release manifest、`FactorGraphQualityPolicy` 与全部阈值，并记录 `siteId/siteType`、prior map ID/SHA、独立测量方法和独立测量人员，至少包含 3 次独立扫描。每个 run 提供 `localizedOutput`、`localizedVersionId` 和操作者选择时记录的 `localizedVersionManifestSha256`；自由格式 `trajectoryMetrics` 被明确拒绝。collector 通过 `LocalizedVersionStore` verified-read 从不可变 `version_manifest.json`、`source_manifest.json`、`localization_report.json`、`factor_graph_report.json`、`localized_price_tags.json` 和轨迹 artifact 自动生成 `MarketScannerTrajectoryQualificationEvidence` v1，并把 exact manifest/artifact bytes 放入 `MarketScannerTrajectorySourceBundle`；检查与发布时重新派生全部指标，客户端不能通过修改数值/flag 后重算自哈希声明通过。

Device Evidence v2 由 collector 对实际 session tree 和数据库计算 `rawSessionBundleSha256/rawDatabaseSha256` 并读取 `trackingSessionId`，不信任 plan 提供的 session identity。每个 run 的 `deviceEvidence.app.gitSha` 必须精确等于 release manifest 的 `git_sha`；V1 产品合同使用同仓库同 SHA，不允许静默接受不同 PC/iOS SHA。Field Evidence v3 明确输出 `releaseGitSha/deviceAppGitSha/deviceAppBuildId`。三次 distinctness 使用 bundle SHA + tracking session ID，而不是 device evidence 文件 SHA。

控制点 CSV 列为 `tag_id,truth_x_m,truth_y_m,truth_height_m,estimated_x_m,estimated_y_m,estimated_height_m`。文件通过单一 descriptor 一次读取，同时产生解析结果、SHA、字节数和 inode identity；symlink、hard link、读中替换、超过 16 MiB、超过 50,000 行、非法 UTF-8、非有限数字、重复 tag ID 或少于 20 个控制点均失败关闭。控制点 tag ID 还必须存在于不可变 localized tag inventory。工具计算标签平面/高度误差，并检查 node coverage、correction、relative residual、weak/lost、图连通/收敛、inventory、用户确认保护和跨 run 拓扑/货架关联重复性。

可单独导出同一 typed trajectory evidence 供独立复核：

```bash
python3 tools/Qualification/qualification.py trajectory \
  --localized-output /path/to/MapStudio-Localized-output \
  --version-id v000123 \
  --version-manifest-sha256 <64-hex-selected-manifest-sha> \
  --release-manifest /path/to/release-manifest.json \
  --output /path/to/new/trajectory_evidence.json
```

```bash
python3 tools/Qualification/qualification.py field \
  --plan /path/to/executed_field_plan.json \
  --output /path/to/new/field_acceptance.json
```

输出使用排他创建：同一路径已存在时拒绝覆盖。Field Evidence v3 用 `MarketScannerQualificationSourceBundle` v1 内嵌 exact Field Plan/release manifest/quality policy，用每个 run 的 `MarketScannerTrajectorySourceBundle` v1 保存 manifest-bound trajectory artifacts，并用 `MarketScannerFieldRunInputBundle` v1 内嵌 exact 控制点 CSV 与 Device Evidence bytes；inspect 从这些 bytes 重新计算阈值来源、轨迹指标、标签误差/ID、App/build/session/prior identity，并逐项比对摘要。Field Evidence 稳定读取上限为 128 MiB；bundle 内单个 CSV/Device Evidence 各不超过 16 MiB，trajectory source manifest 不超过 4 MiB、选定 artifact 合计不超过 12 MiB。稳定读取分别比较 path-stat 和已打开 descriptor/Windows handle 的读取前后身份，不依赖两种 API 的 device/inode/timestamp 表示完全相同；主 descriptor 保持打开到最终检查结束，并以同类 path descriptor 在读取前后绑定文件身份，因此同尺寸路径替换、临时替换后恢复、descriptor 读取期间变化、部分读取、链接和多硬链接均失败关闭。正式发布在 store 写锁内重新稳定读取选择时 SHA 对应的 exact Field Evidence bytes；这些字节和 `qualification_manifest.json` 进入 published version manifest v4 的不可变 hash tree。外部 evidence 后续删除或修改不影响已发布快照的自包含审计。

`evidenceSha256` 是完整性/意外篡改检测，不是数字签名。V1 信任模型选择 execution attestation：实际操作者对执行声明负责，独立 reviewer 必须检查原始 session、Device Evidence、控制点和不可变 publication package；当前没有 PKI 或 reviewer signing，不得宣称该 hash 能阻止恶意操作者重算伪造内容。PASS 仍不替代独立审查。
