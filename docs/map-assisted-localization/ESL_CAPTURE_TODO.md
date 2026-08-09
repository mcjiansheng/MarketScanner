# ESL Barcode Capture / Shelf Confirmation TODO

> 文档状态：**当前有效**。最后核对日期：2026-08-09。
>
> 本清单只登记本轮未开始或明确延期的低影响增强与资格测试。阻断级实现缺陷必须在代码审查中立即处理，不能仅移入本清单。当前整体判断仍是 **REJECTED / NO-GO / developer smoke only**；J-04 为 **BLOCKER / NOT CLOSED**。

## 明日优先测试

1. 在支持 LiDAR 的真实 iPhone 上运行至少 30 秒 Barcode Capture Mode，证明 ARSession、RTAB-Map、连续数据库、Clock、Pose、node creation 和 prior-map localization 均持续前进。
2. 记录 Vision p50/p95、CPU、内存、thermal、相机预览帧率、one-in-flight 丢帧计数和 SQLite/WAL 字节增长；不得把 simulator 或 macOS host 指标当作真机性能。
3. 覆盖强光、暗光、反光价签、斜视、运动模糊、ROI 边缘、无条码、持续多条码和条码离开 ROI 的 bounded-time 行为。
4. 覆盖 EAN-13、Code128、QR 现场样本，以及同 payload 多独立帧、capture 完成后 2 秒重复抑制和超过 512 个 capture 的 FIFO 保留。
5. 覆盖 3 帧 minimum / 4 帧 target：第 4 帧前条码离开或持续 multiple，在 2 秒 deadline 后必须解析已持久化的 3 帧，而不是丢失证据。
6. 覆盖正确货架、同 segment 不同 side、替代货架、无可靠候选、定位 weak/lost、prior-map unload、系统中断、低空间、thermal 和 required-write failure。
7. 验证 `tag_observations.jsonl`、`tag_observation_bursts.jsonl`、`localized_price_tags.json`、metadata watermark 和 PC manifest v3 的 count、last ID、SHA-256 与 exact observation/burst binding。
8. 在 PC 完成现场 A + optimized A、现场 A + optimized B、现场 A + offline unavailable 三类回放，分别验证 `NO_CONFLICT` approved、`USER_CONFIRMATION_CONFLICT` review/rescan、`OFFLINE_ASSOCIATION_UNAVAILABLE` review/rescan。
9. 补齐平台 scoped `Libraries/iphonesimulator` / `Libraries/iphoneos` native dependencies，完成 simulator/device clean compile-link；当前本机 Xcode 已编译本轮 Swift 文件并 emit module，但最终被缺失的 Eigen/PCL/OpenCV headers（`Eigen/Core`、`pcl/point_cloud.h`、`opencv2/highgui/highgui.hpp`）阻断，不能记为 clean build PASS。
10. 完整运行 `python3 -m unittest discover -s tools/PriorMap/tests -v`；I5 的关键长时 host workflow 已在 943.159 秒内 PASS（包括 Snapshot/Result/Map crash matrix、finalization/trace/tag scale），但不能把单方法结果冒充完整 discover PASS。
11. 测量 scan-stop 期间 finalization-owned audit append、`persistTerminalRecoveryEvidence()` 与 `priorMapQueue.sync` 的主线程延迟；正确性和 snapshot 线性化已关闭，但慢盘或较大 Recovery sidecar 下的 UI latency 尚未资格化。

## 已延期的低影响实现

- Candidate lock 增加 maximum inter-frame gap，明确覆盖 `A → 长停顿/Vision error → A`，避免跨过长间隔直接锁定。
- `didReceiveMemoryWarning` 和 host `ViewController` dismissal 路径增加 Barcode UX 的显式 generation invalidation、overlay/preview 清理回归。
- candidate lock 增加一次 light haptic，错误状态增加 warning haptic；不得按 frame 重复震动。
- 小地图使用统一米制 scale 并居中 letterbox，避免 X/Y 分别拉伸造成几何误导。
- VoiceOver announcement 只在语义状态变化时播报，并对采集进度做节流。
- 增加 in-flight request 遇设备旋转时的 ROI/orientation race 回归；旧 orientation callback 必须被 request/generation 身份拒绝或按其捕获时几何解释。
- 补齐 ESL 新文案的 `zh-Hans` 本地化资源，不以英文 fallback 冒充已完成中文现场 UX。
- resolving / confirming 阶段停止不必要的 24 Hz camera-only preview，降低 GPU 和热压力。
- 将 Vision 底层错误安全截断后写入 audit，同时保持 UI 使用稳定错误码。
- 增加可注入 Vision request/worker 的 scanner 级集成测试，端到端覆盖 A hang→deadline restart→B 在 A 返回前实际开始→late A 被拒→B 成功→A/B 连续 hang 后 capacity exhausted；当前 coordinator、token gate 和真实阻塞 executor 分层测试已覆盖生产逻辑，因此本项不阻断 I6。
- 增加 torch 控制和对应热/电量策略。
- confirmation sheet 增加明确的 submitting 状态；持久化失败的恢复交互继续优化。
- 对大楼层 shelf association 做 `O(N + kN)` 基准；基准证明需要后再引入 spatial index，避免在没有规模证据时扩大算法改动。
- PC observation/burst parity 继续交叉验证 `depth / tracking / confidence / prior_map_id`，当前 exact node/frame/payload/symbology 合同不得放宽。
- `SupermarketScanSession` completed-capture cache 除 observation ID set 外，评估即时缓存并复核 payload + symbology，减少最终化前重复读取；磁盘 strict validator 仍是 authority。
- 对确认字段进入正式 XLSX/CSV schema bump，而不是依赖当前 JSON/GeoJSON/内部导出字段。
- 继续 UI 视觉精修、Dynamic Type、VoiceOver focus order 和横竖屏真机检查。
- 完整 PriorMap、scale、Replay/FAR 和现场控制点矩阵按主测试计划执行。
- MapCase02 已按独立正式规则完成阻断级收口；后续低影响 parity/UI/visual/真机项转入 [`MAPCASE02_TODO.md`](MAPCASE02_TODO.md)。继续禁止 store/map/file-specific scale、offset、rotation hack。
- 深化 Windows-portable source database basename：拒绝尾随点/空格别名和 `CON`、`NUL` 等保留设备名。当前已拒绝 slash、drive path 与 canonical casefold 冲突，macOS 当前生产路径风险较低，因此延期。
- 评估 `PriceTagCaptureCoordinator.illegalTransitionLocked` 的 Debug 诊断顺序。当前 `assertionFailure` 可能在 diagnostic 被 ViewController 持久化前中止 Debug 进程；后续可采用非致命 assertion hook 或先持久化再触发的测试策略，Release 行为不受影响。
- 为 `ProcessingResourceGovernor` host test 增加独立的约 250 ms cadence 合同，并用锁保护 `thermalStateOverride` 的测试 backing storage。当前 2 秒有界轮询只验证真实 production timer liveness；完全不触发仍会失败，但不把严格 cadence 或 Thread Sanitizer 资格写成已完成。
- 深化 Result publish-intent removal 回归：对 replacement conflict 再执行一次重启恢复并继续要求同一 conflict inode 永久阻断；另增加 identity 完全匹配的合法 removal tombstone 正例，证明正常 crash cleanup 不被永久 quarantine。
- 深化 Map quarantine lock-replacement 证据断言：除 `diagnostic.tmp` / `diagnostic.removing` 合计恰好一个外，再核对 regular-file、`0444` 和 canonical diagnostic bytes。

## 明确不属于本清单的事项

- J-04 component identity 是独立阻断级资格门，不得降级为低影响 TODO。
- 任何 observation/burst exact binding、用户/算法证据覆盖、AR/RTAB/DB 暂停、第二相机、无界队列或确认冲突静默覆盖问题均属于阻断级，发现后必须立即修复。
- 真机、Device Lab、Sam field、Replay/FAR、exact-SHA CI 和 Apple clean build 未完成时，不得声明 Production Ready、Device Lab PASS 或现场验收通过。
