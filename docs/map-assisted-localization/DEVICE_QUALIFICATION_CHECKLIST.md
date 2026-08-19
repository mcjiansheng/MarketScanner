# 真实 LiDAR iPhone 资格验证清单

> 文档状态：**当前有效，尚未执行**。最后核对日期：2026-08-19。

本清单用于 P5 人工真机执行。勾选、日志和 JSON 声明必须来自实际操作者；fixture、模拟器、本机 Swift 测试和 CI 均不能替代。本仓库目前没有真实设备证据，因此结论保持 **NOT EXECUTED / NO-GO**。

当前 `mobile-only-v1-release-candidate-blocker-closeout` 仍不具备 `DEVICE LAB TESTABLE` 状态。开始本清单前必须先完成并保存当前 exact SHA 的 GitHub Actions、平台正确的 iOS Simulator/iphoneos clean compile-link、独立只读代码审查以及 Replay/FAR 冻结证据；缺少任一项时只能做 developer smoke，不能把运行结果登记为正式 Device Lab。

## 执行前冻结

- 记录操作者、日期、iPhone 型号、iOS build、LiDAR availability；
- 记录 App 40 位 Git SHA、build ID，并提供所有 native 静态库文件给 collector 重算 SHA-256；
- App Git SHA 必须精确等于本轮正式 release manifest 的 `git_sha`；当前 V1 使用同仓库同 SHA 合同，PC/iOS 若确需不同 SHA，必须先引入版本化 release-bundle identity，禁止现场静默豁免；
- 记录 `.github/marketscanner-repair-v2-wave.json` 的 implementation/validation SHA，并证明本次 App SHA 对应的 required Actions jobs 可见且成功；
- 保存 iphoneos 与 iphonesimulator 各自的 native dependency manifest v2，核对 archive/fat/nested Mach-O 架构和 `LC_BUILD_VERSION` platform，禁止 device/simulator 依赖混用；
- 记录 prior-map ID，并提供导入的原始 prior-map package 给 collector 重算 SHA-256；
- 记录显式 store ID 和 map name；原值必须符合 NFC、UTF-8 byte limit、无首尾空白、无 hidden/path/control 字符和单一安全路径组件合同；
- 记录测试区域尺寸、Files provider、初始可用空间、电量和热状态；
- 保证每个 run 使用唯一 run ID，失败 run 不删除、不重命名成成功。

## 必需执行矩阵

| 场景键 | 人工操作与证据 | 预期安全结果 |
| --- | --- | --- |
| `normal_long_scan` | 冷启动，导入 prior，选择楼层/锚点，闭环或近闭环长扫 | raw DB 连续增长，最终正常落盘 |
| `weak_texture` | 制造 10–20 秒弱纹理 | weak/lost 有审计，不硬吸附 |
| `dynamic_occlusion` | 行人或动态物体遮挡 | 状态可见，不错误自动确认 |
| `tag_scan` | 至少 3 次 tag scan，一处靠近货架端点 | 不确定样本进入 review |
| `manual_correction` | 人工确认一次位置 | correction 绑定 node/time 并可审计 |
| `manual_reselection_20x` | 手机保持静止与正常步行各连续执行缩放、平移、选点、X/Y/yaw/离散旋转后确认，共 20 次；记录请求/新 node/恢复事件 | 无需晃动手机即可绑定严格 post-request node；node-time≤1 秒；UI/event/alignment/PC 值一致；扫描 profile 恢复；失败保持弹窗和输入 |
| `manual_persistence_failure` | 对 manual JSONL 做安全故障注入 | durable append 失败时 live alignment 不改变，raw DB 继续增长 |
| `stop_finalization` | Stop 并等待 DB save/sidecar finalization | metadata 最后提交；required evidence 缺失时 fail closed |
| `provider_copy` | 用实际 Files/iCloud/SMB provider 复制并复读 | receipt v2、package manifest、local retained；不宣称断电保证 |
| `kill_relaunch` | 扫描中强杀并重新启动 | raw DB 不丢，checkpoint/恢复状态明确 |
| `metrickit_delivery` | crash/hang 后等待系统交付 MetricKit，导出原始会话 | payload 绑定旧 tracking session；PC 显示摘要；8 MiB 内原始 call tree 保留，超限时有明确 omission 审计 |
| `provider_failure` | 复制中取消或断开 provider | 失败可见，本地唯一副本保留 |
| `low_disk` | 可用空间逼近产品阈值 | 资源保护、日志和最终状态一致 |
| `thermal_serious` | 真机达到 serious 并记录系统状态 | 节流/告警有证据，数据库安全 |
| `checkpoint_cleanup` | 对已 finalized 的旧 checkpoint 执行显式确认清理 | 同 identity、时间、SHA CAS；审计失败不删除 |
| `route_a_fallback` | 构造 Fast 质量失败并允许至多一次 Full existing-graph optimization | Full 仍失败时明确 `RESCAN_SESSION`；不得进入 True sensor Deep |
| `result_commit_relaunch` | 在 result validating/committing 边界执行 crash/relaunch | receipt 可恢复 commit→completed 窗口；result 已冻结且无重复发布 |
| `business_identity` | 分别尝试合法、缺失、首尾空白和路径型 store/map identity | 非法输入在导入/任务创建前 fail closed，合法 manifest 保留 exact identity |

异常 run 的 `expectedSessionOutcome` 使用 `interrupted_or_ineligible`，正常完成且可处理的 run 使用 `finalized_eligible`。每个 run 至少附一份真实日志、屏幕录制或系统诊断文件，并填写所有 `operatorAssertions=true`；任何 false/缺项都会使整体 FAIL。

## 自动收集与复核

按 [`tools/Qualification/README.md`](../../tools/Qualification/README.md) 创建执行计划并运行：

```bash
python3 tools/Qualification/qualification.py device \
  --plan /path/to/executed_device_plan.json \
  --output /path/to/new/device_evidence.json
```

自动门检查 metadata、continuous streaming、raw DB、required sidecars、capture health、processing eligibility、live checkpoint、tracking/prior identity、复制 receipt/package 的实际逐文件 SHA、同尺寸 mutation、路径隐私和本地副本保留。输出为 FAIL 时不得手改结果；修复代码后使用新 App SHA、新 run ID 和新输出文件重测。

Mobile-Only run 还必须保存 Route A 的 Fast/Full/RESCAN disposition、snapshot generation/manifest SHA、clock/trace/burst watermarks、peak RSS/disk/battery/thermal samples、result commit receipt、result manifest/workbook SHA，以及 quarantine（若发生）的 immutable diagnostic。CPU fallback 不得标记成 GPU 成功，未采到的 resource measurement 必须按 fail-closed 处理。

## 人工签收

PASS 证据包至少包含执行计划、collector 输出、原始 session、prior package、App/native build manifest、对应 exact-SHA release manifest、外部复制包和全部日志。独立审查者从这些输入重算 hash、核对 App/release SHA 并抽查 UI/审计语义后才能关闭 P5。`evidenceSha256` 不是数字签名；执行声明由真实操作者负责，恶意声明风险由独立 reviewer 检查原始包控制。
