# 手机端测试计划（Mobile Test Plan）

> 状态：**当前有效**；自动测试已实现，DEVICE/exact-SHA CI 尚未完成。最后核对：2026-08-07。

## 自动测试（已实现，Swift host 默认模式 + 模式化套件）

| 组 | 覆盖 | 状态 |
|---|---|---|
| I1-I14 | 三格式导入、canonical parity、公式/ZIP/CSV/JSON 安全 | Swift host + --import-suite |
| C5/C7/C9/C10 | 编译器路网统计、距离场 SHA、package self-load、PC parity | Swift host |
| P1/P2/P7/P8/P12 | Fast Path 收敛、快照事务、任务状态机 | Swift host |
| Native/AbsolutePrior contract | 4096/4097、RESOURCE_REQUIRED+error；quality v2 strict typed DTO 的 unknown/duplicate/wrong type/Bool、path/disposition/request identity、graph/factor SHA、runtime ABI、C trajectory/skeleton/publish/factor count mismatch；RunSummary 仅投影已验证 `solver.factor_count`；constraint/manual/recovery exact raw-line watermark、345,600 资格上限、accepted=false 非致命、manual ISO/Unix 与 v2/v3 nearest/second margin | Native executable + Swift host（合并后统一重跑） |
| J-04 component identity | Graph Reader node mapID/link component derivation；constraint/manual 新 schema 的原子 bound node + RTAB-Map map ID；最终 component 重算与错 component 拒绝 | **BLOCKER：写侧 schema 尚无可核验证据，NOT RUN / NOT CLOSED** |
| T1/T3/T4/T6/T7/T12 | 1 Hz 重采样、yaw 最短弧、lost/gap、100k 行 | Swift host |
| G1-G10 | 价签绑定/传播/融合/货架/质量门 | Swift host |
| X1-X9 | 工作簿结构、四表、公式注入、控制字符、100k | Swift host |
| Scale/stream | 300k finalization（12,795,904-byte peak RSS）；60k clock writer；1,728,000 trace transition storm（保留 172,801、58,769,408-byte peak RSS）；200k burst frames + 200k observations 经 parser/resolver/shelf/fusion/quality 全链路（670,662,656-byte peak RSS，低于 768 MiB host 门）；JSONL per-line autorelease pool | Swift host；未优化 macOS developer evidence，不是 target-device PASS |
| Contract/parity | 11 份生成证据合同、scan-event mixed-session fail-closed、strict trace PC/device stable reason parity、82 shipping Swift source membership | Python + Swift runner |
| Map quarantine | 损坏 package 的 v2 durable immutable diagnostic（transaction/source identity/path/mode/payload-tree SHA）、library-lock startup reconciliation；真实子进程分别在 payload rename、diagnostic placement/freeze、publish rename + parent fsync 后 `_exit`，新进程从 list/map/rebuild 入口恢复；最终只能保留 source 或 durable final quarantine，registry 不引用 pending；权限篡改、unknown/conflicting state fail closed 且无 silent loss | Swift host + real filesystem subprocess |
| Result/RESCAN transaction | committed Result rename/parent-fsync 与 completed task writer 4 边界恢复；RESCAN artifact writer 4 边界、checkpoint writer 4 边界、terminal writer 4 边界；restart no-native-rerun/no-Result；strict Bool、reason/disposition、RESOURCE_REQUIRED、EEXIST race、same-task Result conflict；recovered completed clears stale interruption/resource error | Swift host + real filesystem failure injection |
| P7R2-P7R6C 回归 | 既有三端套件 | 全量 unittest |

## 待执行（NOT RUN，未写 PASS）

- Host E2E fixture（导入 → 编译 → immutable snapshot → Fast/full-existing-graph → trajectory/tag/result/workbook reopen）已作为 developer smoke 执行；它不是 Replay/FAR 或真机 PASS。
- 三格式 canonical/编译语义 parity 已自动覆盖；真实业务大图 Replay/FAR 仍 NOT RUN。
- E2E-3 真机短路线（5~10 分钟扫描、10 个价签、手机处理、手机导出）。
- E2E-4 Sam 路线（100+ truth tags、现场控制点）。
- Excel / Numbers / WPS 打开验证。
- 资源门：peak RSS、处理时长、thermal、磁盘、电量、中断/崩溃恢复。
- exact-final-SHA GitHub Actions：simulator/device 两套 cold native dependencies + 两次真实 clean compile/link。
- 当前 diff 独立只读审查已完成并修复 findings；implementation/governance commit 形成后仍需复核精确 staged manifest/cached diff，并完成 exact-SHA evidence/release review。J-04 component identity 继续保持 NOT CLOSED。
