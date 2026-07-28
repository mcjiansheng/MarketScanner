# 地图辅助定位阶段一至阶段三测试计划

> 文档状态：**当前有效**。最后核对日期：2026-07-28。

## 自动测试

```bash
python3 -m unittest discover -s tools/PriorMap/tests -v
python3 -m unittest discover -s tools/SupermarketMapStudio/tests -v

python3 -m py_compile \
  tools/PriorMap/*.py \
  tools/Supermarket2DMap/supermarket_2d_map.py \
  tools/SupermarketMapStudio/server.py \
  tools/SupermarketMapStudio/offline_processing.py

xcrun swiftc -parse \
  app/ios/RTABMapApp/SupermarketFinalizationCore.swift \
  app/ios/RTABMapApp/PriorMapLocalizationCore.swift \
  app/ios/RTABMapApp/PriorMapLocalization.swift \
  app/ios/RTABMapApp/SupermarketScanSession.swift \
  app/ios/RTABMapApp/ViewController.swift

node --check tools/SupermarketMapStudio/web/app.js
git diff --check

xcodebuild -quiet -project app/ios/RTABMapApp.xcodeproj \
  -scheme RTABMapApp -configuration Release \
  -sdk iphoneos -destination generic/platform=iOS \
  -derivedDataPath /private/tmp/marketscanner-derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

覆盖：

- XLSX `Element Info`、六种 shape；
- 损坏 JSON、未知类型、隐藏元素；
- 损坏 PNG、错误 hash/count/bounds、错误子集、道路引用、空间索引和验证报告的拒绝；
- Swift 对 swapped shelves、tampered bounds、broken road、mixed preview/distance 和 validation=false 的导入拒绝；
- 业务字段保留；
- 坐标轴、厘米/米、90° 旋转矩形、bounds；
- 道路字符串/数字 ID、缺失引用、连通统计；
- 大型结构/道路空间网格的有界查询；
- schema 和逐字节可复现输出；
- 默认及逐楼层 PNG 预览有效；
- PC API 异步导入、检查、artifact allowlist、源 XLSX 不变；
- 自由扫描旧会话兼容和连续单库识别；
- 直接编译运行 iOS 无 UI 核心，以恒等、前后左右和非零原点金标验证 ARKit `x/z` 到地图 `x/y/yaw`、UI 朝向约定、双模式启动门控和 SE(2) 投影；
- 平行通道歧义拒绝、唯一道路软修正上限；
- 平移/旋转 drift（旋转必须改变 XY 误差）、yaw 误差、tracking 状态转换、道路边分配和人工校准前后误差。
- 正方形/近正方形和反转 ring 的稳定货架 `A/B`/offset，柜台所有边 `E##`；
- 密集深度内点、稀疏孔洞和前后景错误多数拒绝，0/100/300/800 ms 与版本滞后的快照门；
- 阶段三源 DB hash 不变、确定性输出、离线漂移降低、错误约束拒绝、人工编辑 undo/redo/分支重放；
- manual localization v3 使用 native 原子 node/timebase/generation 快照；无 node、过期、generation/身份/时间等式错误拒绝；严格 v2 可兼容，legacy v1 拒绝；
- JSONL 必需/可选策略、非法 UTF‑8、NaN/Infinity、format/version、身份、时间、空文件、重复 observation/tag ID；
- staging 失败、陈旧 staging、损坏指针、无效版本不切 current、不可变旧版本和具体 version artifact；
- POSIX/Windows 并发锁、Windows write-through 原子移动、输入 identity、处理中输入变化、旧版本 local-input 隔离和已打开文件字节复核；
- iOS 必需 sidecar 结构化写结果、state watermark 仅在成功后推进、粘性 capture health；可注入 Swift writer 实际覆盖每个必需文件部分失败、metadata 提交前失败、checkpoint 提交后删除失败、成功终态和同字节数复制篡改；
- iOS 原子 writer 对 temp write、flush、rename 分别注入失败，确认旧字节保持且无临时文件泄漏；合同仅承诺原子可见和进程恢复，不把 hosted/模拟测试写成设备断电持久化；
- Foundation finalization effects 执行四种 disposition：只有 `resumeRecording` 恢复 camera/mapping；正常 finalized 关闭会话并允许校验复制；needs-cleanup 关闭且禁止复制；ineligible 关闭并保留 checkpoint；ViewController completion 返回枚举而非 Bool；
- finalized metadata 提交前对真实 sidecar 字节执行 bundle 复核；删除、空文件、非法/半行 JSON、identity/count/state watermark 不符和 symlink 均降级为 `finalized=false`，optional 空文件保持合法；
- finalized checkpoint 手机/PC 显式清理只接受同 tracking identity、有限 Unix 时间且 checkpoint 不晚于 metadata commit；session/segment/metadata/checkpoint/events symlink、Windows reparse、相邻前缀、TOCTOU 替换全部拒绝；PC 必须 `confirmed=true` 并绑定 expected identity/time/双 SHA，冲突和重复请求返回 409；authorized/completed/failed 审计覆盖终态；
- expected version/revision 缺失、两个客户端使用同一基准版本的 CAS 冲突、HTTP 409、服务端 old value/UTC/ID、字段/范围/货架边长/批准前校验、重放失败回滚；
- draft→review 新版本、bounded solver 发布 422 硬阻断、published 指针不产生；
- 自由扫描默认入口和旧会话处理回归。

阶段三快速 E2E：

```bash
python3 -m unittest tools.PriorMap.tests.test_stage3 -v
```

阶段三确定性性能/内存门：

```bash
python3 tools/PriorMap/benchmark_stage3.py \
  --nodes 2000 --max-seconds 15 --max-peak-mib 64
```

该基准只测 `bounded_correction_field`，不代表完整 SE(2) 因子图、`rtabmap-reprocess`、地图生成或真实 iPhone matcher 性能。

## 样例地图验收

```bash
out="$(mktemp -d /private/tmp/prior-map.XXXXXX)"
rmdir "$out"
python3 tools/PriorMap/xlsx_to_prior_map.py map/mapcase01/mapcase01.xlsx --output "$out"
python3 tools/PriorMap/validate_prior_map.py "$out"
python3 tools/PriorMap/replay_localization.py "$out" \
  --output /private/tmp/prior-map-replay \
  --floor 1 \
  --translation-drift-per-m 0.01 \
  --rotation-drift-deg-per-m 0.02 \
  --tracking-loss-start 30 \
  --tracking-loss-length 8
```

核对 manifest 元素统计为 1,563、楼层为 1/2，并分别视觉对比每层 `preview_file` 与用户 PNG 的方向、结构和比例。手机干跑只选择其中一个楼层，整个会话不得切层；楼层内部少量竖直移动不应改变二维平面位置。

## iOS 手工干跑

无需超市场景：

1. 构建到支持 ARKit 的 iPhone。
2. 新建自由扫描，确认原连续单库和 sidecar 不变。
3. 新建已有地图辅助扫描，完成五步向导。
4. 在办公室步行，确认 HUD 轨迹连续；遮挡相机后变 weak/lost，但数据库继续增长。
5. 人工确认/重新选择位置，检查两个 JSONL。
6. 正常结束，确认 metadata 地图身份、`finalized=true`、capture health 完整、eligibility blockers 为空、无 checkpoint、NFC 不可见。
7. 在测试构建中注入一次必需 sidecar 写失败，确认红色告警持续、停止新的先验地图修正/价签确认、原数据库继续增长、结束后 `finalized=false` 且 checkpoint 保留，PC 明确拒绝；不得在真实扫描目录上用权限破坏方式注入。
8. 单独注入 metadata 已成功但 checkpoint 删除失败，确认数据库关闭、相机/映射不恢复、metadata 保持 `finalized=true`，启动后只显示严格校验的人工清理提示。
9. 对实际业务文件提供者完成复制，核对 `copy_verification.json` 与源/目标复读清单；确认应用默认保留本地副本。分别记录普通完成、应用强退和设备重启后的可读性，不把前两者替代断电测试。

正式超市验收只按 `FIELD_TEST_PLAN.md` 执行；尚未执行时不得声称生产通过。
