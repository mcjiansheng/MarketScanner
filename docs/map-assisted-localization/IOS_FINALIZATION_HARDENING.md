# iOS 长会话结束与外部复制加固

> 文档状态：**当前有效**。最后核对日期：2026-08-07。

## 流式 evidence 校验

`LocalizationEvidenceBundleValidator` 和 Mobile-Only 后处理 parser 不再把 JSONL 整文件读成 `Data`/`String` 或保留全量行数组。每个文件通过父目录 descriptor、`openat(O_NOFOLLOW)` 和前后 `fstat/fstatat` 绑定到同一 regular inode，以 64 KiB 分块读取。共享 `StrictJSONLStreamReader` 要求 final newline、禁止空行并逐 record 交付；旧 `ParsedLines`/`readLines(` API 已从生产调用链清零。

安全边界：

- 单条 JSONL 最大 1,000,000 bytes；
- parser hard cap 与 qualification ceiling 分层；例如 localization trace 最多解析 2,000,000 records，但当前资格上限为 1,728,000，不能用 parser 上限冒充产品资格；
- required JSONL 上限按 metadata 期望数量推导，最低 1 MiB、最高 512 MiB；
- optional JSONL 最大 128 MiB；
- `localized_price_tags.json` 是唯一仍整数组解码的 sidecar，V1 单店上限收紧为 16 MiB、50,000 条；超限 fail closed，业务上要求拆店/分包；
- 空行、partial final line、非法 UTF-8、非 object、非有限数值、错误 format/version/identity、数量或 state watermark 不一致全部 fail closed；
- trace/state 时间戳必须严格递增；node timebase、pose、confidence、constraint accepted/uniqueness、tag observation 和 localized tag 关键业务字段与 PC versioned contract 对齐；strict thermal evidence 必须来自已冻结 snapshot，坏行或身份/数量不一致不能跳过。

metadata 仍是 sidecar bundle 的最后 commit marker。Mobile-Only snapshot eligibility 只接受严格 finalized metadata v2，metadata 最大 1 MiB，并从 `captureHealth.localizationTraceRecordCount` 读取正式 nested watermark。任何校验错误都会保持 `finalized=false`；本 wave 不改变 terminal finalization disposition，也不恢复已关闭的 NFC 入口。

immutable snapshot 的 required set 包括数据库、正式 evidence sidecar 和 `scan_events.jsonl`。snapshot 在复制前后核对完整 file inventory；非空 `-wal`、`-journal`、`-shm`、hardlink、symlink、路径替换、inode/size/time 变化和额外 required file 变化全部阻断。成功 generation 的普通文件冻结为 `0444`，目录冻结为 `0555`；处理阶段只读取 snapshot，不回读原始 session 路径。

## 长会话压力证据

Foundation Swift 可执行测试分别生成并验证 100,000 条 trace、100,000 条 constraint 和 100,000 条 state event，同时覆盖：

- 1,000,001-byte 单行拒绝；
- partial final line；
- 非法 UTF-8；
- symlink；
- 打开后路径 inode 被替换；
- count、identity、last state 不一致。
- 16 MiB localized tags 上限越界拒绝。

100k finalization 资格门现在运行在独立 Swift host 进程中，避免被同一大型测试进程内的 60k clock、workbook、E2E 和 crash-recovery 场景污染。门槛固定为 peak RSS `< 256 MiB`，本轮独立 gate 通过；具体采样值以该次测试输出为准，不再沿用历史进程的固定 RSS 数字。该结果仍只是 Foundation 主机压力证据，不是假冒 iPhone 热状态、内存压力、后台执行或真实 provider 证据；真机 smoke 仍属于 P5。

## 外部复制 package

`copy_verification.json` 升级为 `MarketScannerExternalCopyVerification` version 2：只记录 session/package ID、provider display name、相对路径、逐文件 bytes/SHA-256、package content SHA-256、`localCopyRetained=true` 和明确的 durability boundary，不再写设备或共享盘绝对路径。

export root 同时写 `copy_package_manifest.json`，把复制后的 segment 和 receipt 纳入可复核清单。初始状态固定为 `durabilityQualificationStatus=not_executed`；关闭 provider 后立即复读只证明当时可读，不证明断电持久性。

`recordExternalCopyDurabilityQualification()` 是仅供真实设备资格测试调用的 hook。只有调用者实际完成 provider reconnect/disconnect 或 device power-cycle 后，函数才重新散列完整 package 并写 `copy_durability_qualification.json`。自动测试和普通复制不得把该状态改成已执行。

## 本地副本保留

外部复制成功后，界面继续明确提示“本地副本已保留”。复制函数不调用本地删除；任何后续清理都必须走现有 identity-bound、单 segment、no-follow 验证路径。P4 没有增加自动删除策略。

## 仍未关闭

- 支持 LiDAR 的真实 iPhone 开始/结束、内存警告、热状态、前后台和 provider 矩阵；
- 当前 exact-SHA 的 simulator/device 双平台 clean compile-link；
- 60k clock、100k finalization 和 200k tag 之外的真实整机峰值、耗时、电量和 thermal evidence；
- provider 断连及设备断电后的真实 durability evidence；
- Windows 最终 handle/delete 行为（PC 侧）；
- 三次办公室和三次超市场景资格测试。

上述项目缺少真实证据时，产品保持 **NO-GO**。
