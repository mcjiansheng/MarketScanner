# 手机端测试计划（Mobile Test Plan）

> 状态：**当前有效**；I5 关键长时 host workflow 已执行，完整 discover、设备与现场详细测试仍按时间安排延期；V4 exact-SHA 为 7/8 FAIL，DEVICE 未完成。最后核对：2026-08-09。

## 自动测试（已实现，Swift host 默认模式 + 模式化套件）

| 组 | 覆盖 | 状态 |
|---|---|---|
| I1-I14 | 三格式导入、canonical parity、公式/ZIP/CSV/JSON 安全 | Swift host + --import-suite |
| C5/C7/C9/C10 | 编译器路网统计、距离场 SHA、package self-load、PC parity | Swift host |
| P1/P2/P7/P8/P12 | Fast Path 收敛、快照事务、任务状态机；Snapshot/Result durable intent、`0755→rename→bound-FD 0555/fsync`、root/lock descriptor/path最终复核、mismatched removal tombstone 永久 conflict quarantine | I5 长时 host workflow 943.159 s PASS；Qualification focused PASS；完整 PriorMap discover 延期；exact-SHA 待新 run |
| Native/AbsolutePrior contract | 4096/4097、RESOURCE_REQUIRED+error；quality v2 strict typed DTO 的 unknown/duplicate/wrong type/Bool、path/disposition/request identity、graph/factor SHA、runtime ABI、C trajectory/skeleton/publish/factor count mismatch；RunSummary 仅投影已验证 `solver.factor_count`；constraint/manual/recovery exact raw-line watermark、345,600 资格上限、accepted=false 非致命、manual ISO/Unix 与 v2/v3 nearest/second margin | Native executable + Swift host（合并后统一重跑） |
| J-04 component identity | Graph Reader node mapID/link component derivation；constraint/manual 新 schema 的原子 bound node + RTAB-Map map ID；最终 component 重算与错 component 拒绝 | **BLOCKER：写侧 schema 尚无可核验证据，NOT RUN / NOT CLOSED** |
| T1/T3/T4/T6/T7/T12 | 1 Hz 重采样、yaw 最短弧、lost/gap、100k 行 | Swift host |
| G1-G10 | 价签绑定/传播/融合/货架/质量门 | Swift host |
| ESL Capture / confirmation v2 | ARFrame-only camera preview、真实 ROI、8 Hz/one-in-flight、2-frame lock、3 minimum/4 target、2 秒 minimum fallback、逐帧可靠 quorum、segment+side 替代选择、durable observation↔burst exact binding、manifest v3、PC confirmation conflict policy；session admission/drain、ordinary/terminal Recovery 权限、active-only exact-session audit | capture/finalization focused + Stage-3/output-store **104 tests PASS**；I5 长时 host workflow PASS；本机完整 build 仍因 platform Eigen/PCL/OpenCV headers 缺失而 FAIL；真机/性能/现场矩阵 NOT RUN |
| X1-X9 | 工作簿结构、四表、公式注入、控制字符、100k | Swift host |
| Scale/stream | 300k finalization（12,795,904-byte peak RSS）；60k clock writer；1,728,000 trace transition storm（保留 172,801、58,769,408-byte peak RSS）；200k burst frames + 200k observations 经 parser/resolver/shelf/fusion/quality 全链路（670,662,656-byte peak RSS，低于 768 MiB host 门）；JSONL per-line autorelease pool | Swift host；未优化 macOS developer evidence，不是 target-device PASS |
| Contract/parity | 11 份生成证据合同、scan-event mixed-session fail-closed、strict trace parity、83 shipping Swift source membership与Windows exact-case | Qualification 28/28 PASS；membership/SwiftPM lock/contracts PASS |
| Map quarantine | diagnostic v3、legacy v2 fail-closed、payload dev/inode、FD-relative rollback、root/lock最终复核、canonical UUID和`.`/`..`拒绝 | 关键focused真实进程PASS；EEXIST/UUID/CAS完整Python集成延期 |
| Result/RESCAN transaction | Result publish intent、root lock最终验证、artifact generation sweep；Result quarantine hidden pending + source move前durable v2 diagnostic + startup recovery + v1顶层symlink兼容；RESCAN既有事务 | Qualification与quarantine/publication focused PASS；完整artifact/intent replacement矩阵延期 |
| Publication platform contract | parent/root 以 `O_RDONLY|O_DIRECTORY` 打开，app owner 必须具备 read + write + search；no-follow directory FD、directory `fsync`、`lockf`、同卷同父目录 `renameatx_np(..., RENAME_EXCL)` 均为必要能力 | 当前 macOS/iOS 运行前提；不满足这些能力的文件系统不在已资格范围 |
| P7R2-P7R6C 回归 | 既有三端套件 | 全量 unittest |

## 未关闭（未写 PASS；逐项注明已运行/未运行）

- I5 的长时 host workflow 已 PASS，但完整 PriorMap `discover` 仍按时间要求延期。新 publication/ESL 合同仍需 committed exact-SHA run；host evidence 不是 Replay/FAR 或真机 PASS。
- 三格式 canonical/编译语义 parity 已自动覆盖；真实业务大图 Replay/FAR 仍 NOT RUN。
- E2E-3 真机短路线（5~10 分钟扫描、10 个价签、手机处理、手机导出）。
- E2E-4 Sam 路线（100+ truth tags、现场控制点）。
- Excel / Numbers / WPS 打开验证。
- 资源门：peak RSS、处理时长、thermal、磁盘、电量、中断/崩溃恢复。macOS ACL、BSD `uchg`/`schg` file flags 和相关扩展属性仍未资格化；POSIX `0444/0555` 不能冒充这些边界的 PASS。
- exact-final-SHA GitHub Actions：历史三次、V3 与 V4 均 FAIL。V4 run `31276999280@8ba2f697a8213a1bcd4bf6fb7197d155cb09b865` 为 7/8，仅 macOS/iOS host §18 contract FAIL；当前 I5/G5 需 E5/V5 后新的全量 rerun。
- V4 已证明 P0、exact binding、ABI、Ubuntu/Windows native clean build 与 Python contracts PASS；I5 本地 P0 4/4、Map Studio 106/106、长 host 943.159 s PASS。新 exact-HEAD 全绿前仍不得声明 exact-SHA PASS。
- Apple simulator/device 两套 cold native dependencies + 两次真实 clean compile/link：最新 run `31180693841` 中因前置 macOS host E2E 失败而全部 skipped，仍为 NOT RUN。
- I5 最终关键增量完成两轮只读复审，结论 `P0=0 / P1=0`；cadence/override 与更深 recovery evidence 断言已登记 TODO。Qualification 28/28、Map Studio 106/106、P0 4/4、长 host workflow与关键 scale PASS。完整 PriorMap discover、新 exact-SHA、Apple/设备/现场与 J-04 仍未关闭，最终判断保持 **REJECTED / NO-GO / developer smoke only**。

## 明日详细执行队列

1. `python3 -m unittest discover -s tools/PriorMap/tests -v`；不得把已通过的单一长方法冒充全 discover。
2. 保留 XLSX 100k、Replay/FAR 与真实业务数据矩阵；workflow/finalization/trace/tag 主长路径已在 I5 执行。
3. Map EEXIST、uppercase/noncanonical UUID、`.`/`..` CAS集成。
4. Result hardlink/`0644` clone/post-hash mutation、manifest/receipt post-read、root final sweep、intent creation/temp/removal/staging replacement。
5. 将两个128 MiB delayed replacement改为精确fault hook测试。
6. 修复`listResultsLocked()` root枚举错误的审计诊断；为根级非symlink special file设计durable conflict evidence。
7. 按 [`../map-assisted-localization/ESL_CAPTURE_TODO.md`](../map-assisted-localization/ESL_CAPTURE_TODO.md) 执行 LiDAR 真机 30 秒连续性、Vision p50/p95/CPU/memory/thermal、照明/反光/斜视/多价签、confirmation conflict 和 manifest v3 矩阵。
8. 补齐 `Libraries/iphonesimulator` / `Libraries/iphoneos` platform dependencies 并完成两次 clean compile-link；当前缺失的 Eigen/PCL/OpenCV headers 只可记录为 build blocker。
9. 完整运行本轮已中断的长时 PriorMap host workflow；测量 scan-stop finalization-owned audit/terminal Recovery stable-read 的 UI latency。
10. 深化 Windows portable basename 尾随点/空格和设备名拒绝，并评估 Debug illegal-transition assertion 前后的 audit 持久化顺序。
