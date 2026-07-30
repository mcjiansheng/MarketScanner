# iOS 长会话结束与外部复制加固

> 文档状态：**当前有效**。最后核对日期：2026-07-30。

## 流式 evidence 校验

`LocalizationEvidenceBundleValidator` 不再把 JSONL 整文件读成 `Data`/`String`，也不保留全量字典。每个文件通过父目录 descriptor、`openat(O_NOFOLLOW)` 和前后 `fstat/fstatat` 绑定到同一 regular inode，以 64 KiB 分块读取。验证过程只保留 record count、最后 durable state、前一时间戳，以及价签 observation ID 去重集合。

安全边界：

- 单条 JSONL 最大 1,000,000 bytes；
- 每个文件最多 500,000 records；
- required JSONL 上限按 metadata 期望数量推导，最低 1 MiB、最高 512 MiB；
- optional JSONL 最大 128 MiB；
- `localized_price_tags.json` 是唯一仍整数组解码的 sidecar，V1 单店上限收紧为 16 MiB、50,000 条；超限 fail closed，业务上要求拆店/分包；
- 空行、partial final line、非法 UTF-8、非 object、非有限数值、错误 format/version/identity、数量或 state watermark 不一致全部 fail closed；
- trace/state 时间戳必须严格递增；node timebase、pose、confidence、constraint accepted/uniqueness、tag observation 和 localized tag 关键业务字段与 PC versioned contract 对齐。

metadata 仍是 sidecar bundle 的最后 commit marker。任何校验错误都会保持 `finalized=false`；本 wave 不改变 terminal finalization disposition，也不恢复已关闭的 NFC 入口。

## 长会话压力证据

Foundation Swift 可执行测试分别生成并验证 100,000 条 trace、100,000 条 constraint 和 100,000 条 state event，同时覆盖：

- 1,000,001-byte 单行拒绝；
- partial final line；
- 非法 UTF-8；
- symlink；
- 打开后路径 inode 被替换；
- count、identity、last state 不一致。
- 16 MiB localized tags 上限越界拒绝。

本机 macOS 主机测试的进程 peak RSS 为 15,040,512 bytes，低于固定 256 MiB 门槛。该数值是 Foundation 主机压力基准，不是假冒 iPhone 热状态/内存压力或后台执行证据；真机 smoke 仍属于 P5。

## 外部复制 package

`copy_verification.json` 升级为 `MarketScannerExternalCopyVerification` version 2：只记录 session/package ID、provider display name、相对路径、逐文件 bytes/SHA-256、package content SHA-256、`localCopyRetained=true` 和明确的 durability boundary，不再写设备或共享盘绝对路径。

export root 同时写 `copy_package_manifest.json`，把复制后的 segment 和 receipt 纳入可复核清单。初始状态固定为 `durabilityQualificationStatus=not_executed`；关闭 provider 后立即复读只证明当时可读，不证明断电持久性。

`recordExternalCopyDurabilityQualification()` 是仅供真实设备资格测试调用的 hook。只有调用者实际完成 provider reconnect/disconnect 或 device power-cycle 后，函数才重新散列完整 package 并写 `copy_durability_qualification.json`。自动测试和普通复制不得把该状态改成已执行。

## 本地副本保留

外部复制成功后，界面继续明确提示“本地副本已保留”。复制函数不调用本地删除；任何后续清理都必须走现有 identity-bound、单 segment、no-follow 验证路径。P4 没有增加自动删除策略。

## 仍未关闭

- 支持 LiDAR 的真实 iPhone 开始/结束、内存警告、热状态、前后台和 provider 矩阵；
- provider 断连及设备断电后的真实 durability evidence；
- Windows 最终 handle/delete 行为（PC 侧）；
- 三次办公室和三次超市场景资格测试。

上述项目缺少真实证据时，产品保持 **NO-GO**。
