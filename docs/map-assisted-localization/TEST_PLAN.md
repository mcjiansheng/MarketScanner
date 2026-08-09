# 地图辅助定位阶段一至阶段三测试计划

> 文档状态：**当前有效**。最后核对日期：2026-08-10。

## 自动测试

### 统一扫描 UX、启动事务和 build identity

生产入口、线程边界、导航、相机权限、启动 receipt/context、取消/回滚、地图包单快照/descriptor freeze、zoom/nudge/discrete heading 和 QualifiedDevice scheme 使用以下聚焦组：

```bash
python3 -m unittest \
  tools.PriorMap.tests.test_mobile_scan_ux_contract \
  tools.PriorMap.tests.test_yaw_arrow_geometry \
  tools.Qualification.tests.test_market_scanner_build_identity \
  -v
```

2026-08-10 当前源码结果为 **27/27 PASS**。它必须继续证明：首页和菜单不进入旧 `PriorMapWizardViewController`；地图库普通列表、完整刷新、provider copy/fsync、selected-package 加载和 scan-start preparation 不在主线程；手机编译地图与 PC v2 package 进入同一 registry/setup/coordinator；root Close 与 push Back 同时存在；首次权限在 workflow commit 前完成；旧 tmp-db recovery 不可绕过 receipt；取消/持久化失败会 rollback；地图设置支持 1×–8× zoom、方向键和离散朝向；普通 Debug 无 build identity，`RTABMapApp-QualifiedDevice` 的 Run 为 Release 且不存在 `--allow-dirty`。

Swift 核心可执行长方法 `IOSCoreContractTests.test_swift_workflow_state_and_se2_projection` 在当前改动上 **1/1 PASS（1233.541 s）**，覆盖 map-library CAS、register/rebuild/freeze/quarantine、异常 symlink 外部目标权限保护和 workflow/SE(2) 合同。该单个长方法、27 个源码/几何合同和 host XLSX smoke 均不能冒充完整 discover、真机交互延迟或现场扫描 PASS。

### MapCase02 冻结回归

正式输入 `map/mapcase02/mapcase02.xlsx` 的 SHA-256 必须为 `1ddf428fc4dd6e4e8bd33258d0cbfaab87b809c4dedd6b8baca9e167c14b5e6a`。Swift `--mapcase02-suite <xlsx> <output> <canonical-sha> <swift-package-sha> [legacy-xlsx]` 与 PC converter/schema 必须同时满足 1838/1630/1301/329/0/208 统计、0 active 越界、canonical ID `piaseczno-5ddfac7dc439`、canonical SHA `5ddfac7dc439afc45abdcf800b799c05d53704895b620d161ef08a442c55b2db`、Swift package `8d3564ce68aadb087a2820a02b4747d15ea1f4d22b14e8776f913d33775b1b84`、PC package `41332d093e652ec2de94f0f86b8f15107cd6f67f3b2e5ddec1c0685ab4d7d3be` 和 PC preview `d0c02be63dff3ab002dcf931ce7d0c5149152b78bea139fb1b0a2d86be196a18`。Swift 套件必须继续执行 compile → integrity → content-addressed move → register → listMaps → exact map read，并对重签的旧 uppercase v2 包断言 production 默认拒绝、显式 diagnostic-only 允许；`validation_report.summary.node_count/edge_count` 必须绑定 road graph 且 Swift 输出须由 Python production validator 直接接受；PC 正式 golden 测试必须直接断言 source/canonical/ID/package/preview SHA。只做自洽 digest 或只验证编译包均不再足够。

真实工作簿回归使用 Swift host `--xlsx-library-smoke <xlsx...>`，输出仅写入 `/private/tmp` 下的临时地图库。2026-08-09 已对 `map 2.xlsx`、TianHong 02402、北京昌平 6599 和 Kohl's 1224 共四张正式工作簿执行，四张均完成严格导入、编译、完整性、安装、注册、列表和 exact ID/SHA 读取。跨端 slug 负例覆盖 `Piaseczno`、`Kohl's 1224`、`İstanbul`、Kelvin sign、中文夹 ASCII 与 200-byte 合法地图名；最终 ID 必须匹配 `^[a-z0-9._-]+$` 且最长 128。

负例覆盖关系别名/外部 target/namespace 伪 authority、缺失/重复/前导零 row 与 cell、非法 shared-string/boolean/公式/超大 cell、100001 元素、错误角色几何、重复 element ID、严格整数 token、距离场预算，以及重签名后 canonical/graph/spatial/distance/shelf 派生工件篡改。任一端接受集合不同即失败。

2026-08-09 本机证据：MapCase02 Swift 正式套件 PASS；PriorMap 非超长组 217 项 PASS；Map Studio 109/109 PASS；PC MapCase02 validator `valid=true`；I10 完整 Python 外层 Swift host 1/1 PASS（973.769 s）。run `31307753672@8f0e730d…` 的全部非 Apple jobs、完整 macOS host、SwiftPM/Xcode metadata 与 200k RSS `794,099,712 < 805,306,368` bytes 均 PASS，但 iphoneos cold dependency configure 未找到 host `rtabmap-res_tool`，整体仍为 7/8，双平台 clean link skipped。I11 `37e6ed8c4afa00202693cd56919aea78fd4c7af5` 显式绑定该工具，本地全新 prebuild/configure 与独立复审 `P0=0/P1=0` PASS；replacement exact-SHA、Apple clean link、完整 discover、真机/LiDAR/现场仍待执行，required jobs 全绿前不得冻结。

P0 生产安全不变量（CI 使用相同选择器，任一失败即失败关闭）：

```bash
python3 -m unittest -v \
  tools.SupermarketMapStudio.tests.test_map_studio.MapStudioApiTests.test_review_transition_is_versioned_and_bounded_solver_cannot_publish \
  tools.SupermarketMapStudio.tests.test_map_studio.MapStudioApiTests.test_checkpoint_cleanup_requires_confirmation_and_exact_evidence \
  tools.PriorMap.tests.test_ios_sidecar_health_contract.IOSLocalizationSidecarHealthContractTests.test_atomic_visibility_and_copy_retention_contracts_are_explicit \
  tools.PriorMap.tests.test_ios_sidecar_health_contract.IOSLocalizationSidecarHealthContractTests.test_finalized_metadata_is_bound_to_persisted_evidence_bytes
```

该快速组锁定四项既有行为：bounded solver 禁止发布、checkpoint cleanup 的人工确认与精确 CAS、外部复制不自动删除本地副本、required evidence 异常阻断 finalized metadata。它不能替代下面的全量测试、macOS 上的 Swift 可执行 core 测试、真机矩阵或现场验收。

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
  -scheme RTABMapApp-QualifiedDevice -configuration Release \
  -sdk iphoneos -destination generic/platform=iOS \
  -derivedDataPath /private/tmp/marketscanner-derived \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

普通 UI/导入 smoke 可另用 `RTABMapApp` Debug；该构建按设计删除 `MarketScannerBuildIdentity.json`，不得用于开始正式 prior-map 扫描。QualifiedDevice Release 构建必须在所有 tracked 代码与当前文档已提交、tracked tree 干净时执行；无签名 generic-device build 只证明编译/链接和 build-identity 生成，不证明真机权限、相机、LiDAR 或现场流程。

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

该基准只测 `bounded_correction_field` draft fallback，不代表完整 SE(2) 因子图、`rtabmap-reprocess`、地图生成或真实 iPhone matcher 性能。

## P1 相对 SE(2) 因子图

```bash
cmake --build build-pc-release \
  --target rtabmap-prior-map-factor-graph --config Release -j2
python3 -m unittest tools.PriorMap.tests.test_factor_graph_schema -v
```

真实 DB 资格测试必须把 `--database` 指向 `rtabmap-reprocess` 的一次性输出副本，传入真实文件 SHA-256、正确的 `--horizontal-axes xz|xy`，执行前后重新计算 DB SHA，并用 `factor_graph_schema.validate_factor_graph_result()` 复核结果。至少记录 DB version、nodes/factors、factor digest、initial/final objective、iterations、gauge mode、残差 p95 和被拒绝/降权的 factor IDs。扫描 DB 和生成报告均不得进入 Git。

自动负例覆盖断连、缺 endpoint、奇异 information、非有限结果、canonical/digest 篡改、错误 gauge 和不收敛；既有 `SE2TagPropagationTests` 覆盖 ±90°/180°、平移旋转耦合和 yaw wrap。clean runner 的 native helper 构建属于 P2，不得用已有本机构建目录替代。

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

1. 提交全部 tracked 改动并确认 tracked tree 干净；在 Xcode 选择 `RTABMapApp-QualifiedDevice`，clean build 后安装到支持 ARKit/LiDAR 的 iPhone。普通 Debug 只做 UI/地图导入 smoke。
2. 从首页大型“新建扫描”进入统一配置页，确认左上角 Close；从“门店地图”选择同一地图进入，确认系统 Back/返回手势。进入、返回和重复切换不得再出现 3–4 秒主线程冻结，并记录 p50/p95。
3. 分别导入手机 XLSX 和 PC 正式 v2 地图包，确认都进入同一地图库和同一配置页；编译/复制期间持续显示阶段、百分比与用时，完成后核对 store ID、map ID、package/canonical SHA、楼层、元素和 warning 摘要。
4. 在配置页验证 1×–8× 捏合、平移、双击、点击选点、0.1/0.5/1.0 m 四方向微调，以及东/北/西/南和左右 15° 朝向；不得出现横向 yaw slider。
5. 在首次权限未决定的干净安装上点击开始：授权前不得创建会话；授权后必须重新执行完整入口并成功启动。拒绝权限时恢复交互并提供系统设置入口，不能出现后台幽灵扫描。
6. 选择有效起点开始扫描，确认配置页关闭后直接进入 `.STATE_MAPPING`，无需再点 Record；检查 session-scoped DB、receipt 和 workflow context 均存在且身份一致。随后测试启动页离开/取消、host 失败和持久化故障注入，确认 CameraMobile/ARSession/mapping/clock 全部停止、失败数据库被脱离且没有可继续录制的未提交会话。
7. 在办公室步行，确认 HUD 轨迹连续；遮挡相机后变 weak/lost，但数据库继续增长。人工确认/重新选择位置，检查定位 JSONL。
8. 另从“实验与兼容工具”新建自由扫描，确认旧连续单库和 sidecar 兼容行为不变，且它不再占据主入口。
9. 正常结束，确认 metadata 地图身份、`finalized=true`、capture health 完整、eligibility blockers 为空、无 checkpoint、NFC 不可见。
10. 在测试构建中注入一次必需 sidecar 写失败，确认红色告警持续、停止新的先验地图修正/价签确认、原数据库继续增长、结束后 `finalized=false` 且 checkpoint 保留，PC 明确拒绝；不得在真实扫描目录上用权限破坏方式注入。
11. 单独注入 metadata 已成功但 checkpoint 删除失败，确认数据库关闭、相机/映射不恢复、metadata 保持 `finalized=true`，启动后只显示严格校验的人工清理提示。
12. 对实际业务文件提供者完成复制，核对 `copy_verification.json` 与源/目标复读清单；确认应用默认保留本地副本。分别记录普通完成、应用强退和设备重启后的可读性，不把前两者替代断电测试。

正式超市验收只按 `FIELD_TEST_PLAN.md` 执行；尚未执行时不得声称生产通过。
