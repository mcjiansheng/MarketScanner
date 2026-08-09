# MapCase02 后续低影响修复与资格测试 TODO

> 文档状态：**当前有效**。最后核对日期：2026-08-09。

本清单只登记已审查为 P2/低影响、尚未开始的增强和延期资格测试。阻断级缺陷不得移入本清单规避修复。当前局部结论为 `MAPCASE02 / STANDARD SUPERMARKET XLSX FORMAT PASS`；整体仍为 **REJECTED / NO-GO / developer smoke only**，J-04 为 **BLOCKER / NOT CLOSED**。

## 解析与跨端 parity

- `Shelf Info` 审计计数目前假设首条 XML row 是 header；前导空 row 时审计行数可能偏 1。它不影响 active elements、canonical identity 或 geometry，但应改为按解析出的 header row 计数。
- Python 会跳过完全空的 `Element Info` 行，Swift 正式 strict 路径会以 empty floor 拒绝；补充正式合同与一致负例后统一行为。
- `ElementNormalizer` 的数值 `code`、road `crossCodes` 在 Foundation NSNumber bridge 与 Python `str(float)` 之间仍有低影响格式 parity 差异；MapCase02 无 road，后续应冻结 strict business-scalar 规则。
- Swift XLSX 的 DOCTYPE/ENTITY 预扫描当前复制完整 `Data`；在不降低 64 MiB/1 MiB fail-closed 上限的前提下改为 bounded streaming scan。
- 扩大真实工作簿 mutation matrix，包括更多 ZIP/XML namespace、关系 target、shared string、单元格类型和非 ASCII business identity 组合。

## UI、预览与可观测性

- 正式 XLSX 实际强制 `Basic Info` top-left，但 iOS 导入向导仍显示 coordinate selector；正式工作簿识别后应禁用并解释该控件。
- Preview 中 shelf 与 fixed structure 暂用同色；按稳定角色着色并保持定位数学不受展示样式影响。
- 增加 preview tap 专门 golden/round-trip 回归，以及结构 mask/SSIM visual baseline；不能用视觉相似替代 canonical/geometry exact assertion。
- Result exact-SHA 资格 observer 编入 production module、默认 `nil` 且当前安全；后续评估 host-test/debug gating，避免生产符号面无必要扩大。
- 清理既有 Swift/Xcode warning，包括 always-succeeds cast、unused value、deprecated API 和 duplicate asset build-file 警告；不得与业务冻结改动混合。

## 宿主测试深化

- Map quarantine 的两个 descriptor-opened/read-before 确定性替换用例仍复用 `after_diagnostic_large` 创建 128 MiB payload；同步 observer 已不再依赖大文件延迟，后续改用小 fixture，并同步删除旧的 timing 说明。
- 当前 crash-worker 断言生产拒绝、替换确实执行且原/替换证据均保留；后续再绑定稳定的 pathname/inode rejection category，防止未来由更下游校验代偿而假绿。该增强不改变现有 fail-closed 生产合同。
- Tombstone atomic-swap fixture 后续可在 Python 侧记录交换前 source/clone 双方 inode，并在边界后精确断言交换方向、原 inode 审计路径和 payload bytes 一致；当前 syscall 语义、50 次边界重复、restart return 19 与三方证据保留已足够关闭 P1。

## 延期测试（2026-08-10 起执行）

- 在 I9 final exact SHA 上重新完整运行 `IOSCoreContractTests.test_swift_workflow_state_and_se2_projection`；run `31303500822` 已完成 300k finalization、1,728,000 trace、200k tag-evidence RSS 和 I8 fixture，但被随后已修复的 tombstone fixture 91 退出阻断，不能登记为 final exact-SHA PASS。
- 在依赖齐全的 clean runner 补齐 `Eigen/PCL/OpenCV` 后完成 iphoneos 与 iphonesimulator Release clean compile-link；当前本机只通过 Xcode project/SwiftPM 解析，完整 build 在缺失 `Eigen/Core` 处停止。
- 执行真实 LiDAR iPhone、30 秒连续性、内存/thermal/background/provider、Device Lab、Replay/FAR、Sam 同路线和正式现场控制点矩阵。
- 对 MapCase02 执行更多设备端 package discover/import、长时间 scan matcher 和真实地图点击/定位回放，不把 host suite 当作真机证据。

## 不得降级的独立阻断项

- J-04 absolute-prior component identity 仍要求 writer schema、atomic bound node/map identity 与最终 component 重算迁移；它不是 MapCase02 P2，未关闭前产品资格保持 NO-GO。
- exact-final-SHA CI、Apple clean link、Device Lab 和现场验收必须绑定最终提交；本地 golden 与代码审查不能替代这些资格门。
