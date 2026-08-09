# MapCase02 后续低影响修复与资格测试 TODO

> 文档状态：**当前有效**。最后核对日期：2026-08-09。

本清单只登记已审查为 P2/低影响、尚未开始的增强和延期资格测试。阻断级缺陷不得移入本清单规避修复。当前局部结论为 `MAPCASE02 / STANDARD SUPERMARKET XLSX FORMAT PASS`；整体仍为 **REJECTED / NO-GO / developer smoke only**，J-04 为 **BLOCKER / NOT CLOSED**。

## 解析与跨端 parity

- `Shelf Info` 审计计数目前假设首条 XML row 是 header；前导空 row 时审计行数可能偏 1。它不影响 active elements、canonical identity 或 geometry，但应改为按解析出的 header row 计数。
- Python 会跳过完全空的 `Element Info` 行，Swift 正式 strict 路径会以 empty floor 拒绝；补充正式合同与一致负例后统一行为。
- `ElementNormalizer` 的数值 `code`、road `crossCodes` 在 Foundation NSNumber bridge 与 Python `str(float)` 之间仍有低影响格式 parity 差异；MapCase02 无 road，后续应冻结 strict business-scalar 规则。
- 为 `validate_prior_map.py --allow-legacy-v2-identifier-for-diagnostics` 增加 committed CLI 参数端到端测试；当前已有 API fixture，且本机已手工确认默认 production 模式拒绝、显式 diagnostic-only 模式接受，但参数解析行为仍应自动固化。
- 增加 uppercase、Unicode、超长 floor ID 的楼层预览文件名跨端 exact fixture，并在格式文档中明确预览派生文件名使用与地图 ID 相同的 lowercase/bounded slug；楼层序号前缀仍负责避免 slug collision，预览文件不作为定位身份 authority。
- Swift XLSX 的 DOCTYPE/ENTITY 预扫描当前复制完整 `Data`；在不降低 64 MiB/1 MiB fail-closed 上限的前提下改为 bounded streaming scan。
- 扩大真实工作簿 mutation matrix，包括更多 ZIP/XML namespace、关系 target、shared string、单元格类型和非 ASCII business identity 组合。

## UI、预览与可观测性

- 为 pre-hardened uppercase v2 package 和缺 `generation` 的旧开发 registry 增加显式、可恢复的 UI 指引：当前核心会保留 bytes、拒绝 case-fold 路径别名并要求从原始地图重新导入，但“重建索引”界面仍应展示稳定原因，不能吞掉错误或暗示可透明迁移历史 session exact ID/SHA。
- 正式 XLSX 实际强制 `Basic Info` top-left，但 iOS 导入向导仍显示 coordinate selector；正式工作簿识别后应禁用并解释该控件。
- Preview 中 shelf 与 fixed structure 暂用同色；按稳定角色着色并保持定位数学不受展示样式影响。
- 增加 preview tap 专门 golden/round-trip 回归，以及结构 mask/SSIM visual baseline；不能用视觉相似替代 canonical/geometry exact assertion。
- Result exact-SHA 资格 observer 编入 production module、默认 `nil` 且当前安全；后续评估 host-test/debug gating，避免生产符号面无必要扩大。
- 为 Device Lab、PC replay 和独立 hash 复核提供手机实际生成 prior-map package 的显式只读导出入口，或冻结一套可审计的 Xcode/App-container 提取步骤。Mobile-Only 最终用户链路本身不依赖 PC，因此这不阻断当前地图导入；但不能让资格操作者误用 PC 从同一 XLSX 重新生成的不同 package SHA 代替手机 exact package。
- 清理既有 Swift/Xcode warning，包括 always-succeeds cast、unused value、deprecated API 和 duplicate asset build-file 警告；不得与业务冻结改动混合。

## 宿主测试深化

- 为 case-fold 路径冲突补充两条直接集成 fixture：伪造 lowercase registry entry + uppercase 实际父目录时 `listMaps()` 必须拒绝；packages root 仅存在 uppercase ID 时 `rebuildRegistry()` 必须拒绝。当前 `packageDirectory()` 写前拒绝、共享 verify 和静态调用链已经覆盖，不影响本轮四图导入。
- `readRegistryPayload()` 当前对每个 registry entry 重新枚举一次 packages root，随后 package verify 又会枚举；地图数量增长时接近 O(N²) 元数据扫描。后续在单次 list/read/rebuild 操作中构建一次 lowercase→actual spelling 快照并复用，不改变 fail-closed 语义。
- Map quarantine 的两个 descriptor-opened/read-before 确定性替换用例仍复用 `after_diagnostic_large` 创建 128 MiB payload；同步 observer 已不再依赖大文件延迟，后续改用小 fixture，并同步删除旧的 timing 说明。
- 当前 crash-worker 断言生产拒绝、替换确实执行且原/替换证据均保留；后续再绑定稳定的 pathname/inode rejection category，防止未来由更下游校验代偿而假绿。该增强不改变现有 fail-closed 生产合同。
- Tombstone atomic-swap fixture 后续可在 Python 侧记录交换前 source/clone 双方 inode，并在边界后精确断言交换方向、原 inode 审计路径和 payload bytes 一致；当前 syscall 语义、50 次边界重复、restart return 19 与三方证据保留已足够关闭 P1。
- Map quarantine 的 lock-path 替换负例仍用 `RENAME_EXCL` 后 `open(O_EXCL)` 安装新 inode；生产会在下一次 descriptor/path identity 校验 fail-closed，当前用例也已稳定通过，但后续可预制 replacement 并用 `RENAME_SWAP` 消除测试自身的短暂缺路径窗口。
- iOS dependency 的 host `rtabmap-res_tool` prebuild 后续可显式设置 `CMAKE_BUILD_TYPE=Release`、把 cache 参数标注为 `FILEPATH`，并增加一次实际执行/动态库装载 smoke；I11 当前已验证产物可执行并完成 iOS configure，这些只属于构建一致性深化，不是当前阻断。

## 延期测试（2026-08-10 起执行）

- 完整运行 `python3 -m unittest discover -s tools/PriorMap/tests -v`；I10 final SHA 的本机完整长方法与 run `31307753672` 的远端 host contract 已 PASS，但不等于全 discover PASS。
- 在新 I11 exact SHA 上完成 iphoneos 与 iphonesimulator cold dependency、Release clean compile-link；`31307753672` 已到 iphoneos RTAB-Map configure 后因 host resource tool discovery 失败，I11 本地已关闭该配置错误，但远端双平台 link 仍待证明。
- 执行真实 LiDAR iPhone、30 秒连续性、内存/thermal/background/provider、Device Lab、Replay/FAR、Sam 同路线和正式现场控制点矩阵。
- 对 MapCase02 执行更多设备端 package discover/import、长时间 scan matcher 和真实地图点击/定位回放，不把 host suite 当作真机证据。

## 不得降级的独立阻断项

- J-04 absolute-prior component identity 仍要求 writer schema、atomic bound node/map identity 与最终 component 重算迁移；它不是 MapCase02 P2，未关闭前产品资格保持 NO-GO。
- exact-final-SHA CI、Apple clean link、Device Lab 和现场验收必须绑定最终提交；本地 golden 与代码审查不能替代这些资格门。
