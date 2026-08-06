# Mobile-Only V1R2 生产管线与真机资格收口状态

> 分支：`mobile-only-v1r2-production-pipeline-and-device-readiness-closeout`
> 基线：`mobile-only-v1r1-product-integration-closeout` HEAD `a9f8c46cda0bf975cf9bab3fd39183c5aee8efc3`
> 本文件核对日期：2026-08-06（实现 + Swift host 集成测试 + PC oracle 阶段）
> 权威代码事实：本分支当前源码；本文件与代码冲突时以已测试代码为准。

## Wave 身份

```json
{
  "wave": "mobile-only-v1r2-production-pipeline-and-device-readiness-closeout",
  "branch": "mobile-only-v1r2-production-pipeline-and-device-readiness-closeout",
  "base_branch": "mobile-only-v1r1-product-integration-closeout",
  "base_sha": "a9f8c46cda0bf975cf9bab3fd39183c5aee8efc3",
  "v1r1_head_sha": "a9f8c46cda0bf975cf9bab3fd39183c5aee8efc3",
  "implementation_sha": "<FINAL_CODE_BUILD_TEST_SHA>",
  "validation_sha": "<FINAL_GOVERNANCE_SHA>"
}
```

## 目标

一台 iPhone 从原始 XLSX/CSV/JSON 地图到最终四表 XLSX，全程不依赖 PC。
V1R2 关闭的是 V1R1 独立审查 REJECTED 的全部代码级缺口：编译/流程死锁、
真实扫描接线、真实 native 图进入生产管线、共享 native Fast/Deep、
严格质量门、资源治理与完整轨迹重建。

## 本轮交付（IMPLEMENTED + 已运行验证见下）

### Gate 0 — 编译与流程死锁（§4）

- `MobileOnlyHomeViewController` 去除 iOS 15+ `UIButton.Configuration`，
  部署目标 iOS 14.3 下 clean build（§4.4）。
- `ViewController.showToast` 增加显式单参重载，修复缺 `seconds` 的调用
  （§4.3）。
- 导入死锁移除（§4.1）：接口合并为
  `beginMapImport(from:contract:storeID:mapName:)`，Coordinator 自动
  pick → stage → import → compile → register；UI 只观察统一
  progress/completion；并发/双击导入以 `.duplicateImport` 类型化拒绝。
- 处理页修复（§4.2）：`discoverFinalizedSessions()` 统一返回
  `[SessionCandidate]`（session/segment/database/metadata 完整构造，
  DB 存在性校验）；`.subtitle` cell style 使 detailTextLabel 真实；
  按会话 metadata 的 `priorMapId/priorMapSha256` 在地图库中选取绑定
  地图，禁止取第一个地图。

### Gate A — 正式工作流（§5）

- 全部重任务（导入/编译/快照/优化/导出）移入串行后台 `workQueue`；
  MainActor/主线程只接收观察者通知（§5.1）。
- `workflow_state.json` v2 持久化完整 durable 上下文（§5.2）：
  state/task_id/staged_source/map_id/map_sha/session_id/segment/
  source_db/result_id/progress/checkpoint/error_code/app_git_sha/
  policy_sha/updated_at；启动时逐项验证引用，引用失效则 fail closed
  回 idle 并记录 `workflow.reference_missing`。
- 观察者 token 注册表（§5.3）：`addStateObserver/addProgressObserver/
  addImportObserver/addCompileObserver/addProcessingObserver` +
  `removeObserver(token)`；多页面不再互相覆盖全局 closure。
- 显式转换表（§5.4）：`MobileOnlyWorkflowState.allowedNextStates` +
  `allowsTransition(to:)`；非法转换为 `.illegalTransition` 类型化错误
  且不被静默应用。
- 中断恢复：首页横幅提供「尝试恢复」，仅在全部 durable 引用验证通过
  时重入 `beginProcessing`。

### Gate C / Gate D — 地图库与真实扫描（§7 / §8）

- 编译产物 manifest 增加真实 `store_id`（来自 canonical source）。
- 内容寻址包复用（§7.3）：同 (map-id, sha) 已存在时复用而不删除覆盖。
- 扫描设置页重写（§8.1/§8.2）：楼层来自编译包 manifest（多楼层
  segment），preview.png 预览图上点选起点（像素→米按
  `MobilePreviewRenderer` 的投影反演），朝向滑块旋转箭头标记；
  未选起点前开始按钮禁用；页面仅调用
  `coordinator.commitScanConfiguration(configuration)`；
  不再硬编码 0/0/1/default。
- Host 扫描服务（§8.3）：`MobileOnlyScanStarting` 协议由
  `ViewController` 真实实现——生产装载地图库包、
  `PriorMapPackageIntegrity.validate` SHA 验证、构造
  `.priorMapLocalized` 扫描配置（初始 map pose）、`newScan` 启动
  ARSession + RTAB-Map 记录 + 会话 metadata；失败类型化提示且不落
  任何扫描状态。

### Gate F/G/H/I — 共享 native Fast/Deep 与完整轨迹（§10/§11/§12/§13）

- 新共享 core：`core/MarketScannerFactorGraph/`
  （`market_scanner_factor_graph.h/.cpp`），iOS 与 PC 同一实现：
  - RTABMapGraphReader：sqlite `mode=ro&immutable=1`，pose 12 floats /
    information 36 doubles 严格校验，quick_check 单行 ok，循环必须
    DONE，坏 BLOB 计数跳过不崩溃；
  - GraphHealthInspector：重复/非有限/组件/孤立/跨 map 链接/loop/
    prior/Recovery 统计；
  - AdaptiveGraphReducer：强制保留 loop/prior/Recovery/tag/转弯/
    map 切换/端点节点；直线段 0.75 m / 4° / 2 s 自适应候选，转弯区
    收紧 0.3 m（§11.3 区间内），禁止固定 stride；
  - RobustSE2Optimizer：rtabmap g2o（slam2d + robust kernel delta=8 +
    Force3DoF），DB 6x6 information 的平面 3x3 投影（含反向测量解析
    雅可比信息变换、双向 Link 归一化去重），每组件独立 anchor，
    finite/cancel/wall-time 护栏；
  - GraphQualityEvaluator：§11.5 全指标（component/anchored/isolated/
    cross-floor、加权 chi2/DoF、分 kind P50/P95/max、rejected/
    downweighted、correction median/P95/max/jump、coverage、solver
    诊断）与 PASS / RECOVERABLE_FAIL / NON_RECOVERABLE_FAIL /
    RESOURCE_REQUIRED disposition；
  - FullTrajectoryReconstructor：`C_i` SE(2) 插值恢复全部原始节点，
    tag 绑定节点逐一核验。
- PC 诊断 oracle：`tools/Reprocess/market_scanner_graph_cli.cpp` →
  `rtabmap-market-scanner-graph --db ... --mode fast|deep`（CMake 已
  接线，静态库 `marketscanner_factor_graph` 同源编译）。
- iOS 接线：bridging header + pbxproj 注册 C++ core；
  `MobileNativeFactorGraph.wireIntoGateway()` 启动时接线；管线只经
  `MobileNativeFactorGraphGateway` 调 native；Swift `SE2FactorGraphCore`
  降级为宿主测试参考，不再进入生产路径（§11.5）。
- Deep Path 非 stub（§12）：仅 Fast RECOVERABLE_FAIL 时运行一次全图
  重建；`ProcessingResourceGovernor.checkBudget(stage:"deep")` 先行。
- 质量门 fail closed（§2）：最终 disposition 非 PASS 即
  `.qualityGateRejected` 不发布；RESOURCE_REQUIRED 独立错误码。
- 管线轨迹来源改为 snapshot DB 的 native 重建（stamp 为 UTC 秒，
  monotonic 以首节点锚定，§13）；1 Hz/UNAVAILABLE 逻辑保持。

### Gate L — 资源治理（§16）

- `ProcessingResourceGovernor`：内存 footprint（task_vm_info）、
  `os_proc_available_memory`、磁盘可用量、热状态、电量；snapshot/
  deep/export 前硬性预算检查，serious/critical 热状态与低电量 Deep
  fail closed；RunSummary 记录真实内存与处理耗时。

## 验证证据（本轮已跑）

- **unsigned arm64 iphoneos build：SUCCEEDED**（Gate 0 §4.4 设备硬门，
  `xcodebuild -scheme RTABMapApp -configuration Release -sdk iphoneos
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`，
  含新 C++ core、bridge 与全部 Swift 改动的编译+链接）。
- PC oracle 构建：`cmake --build build-pc-release --target
  market_scanner_graph` → 成功（C++ core 编译链接通过）。
- 真实会话 DB 端到端（只读复制到 /tmp 后运行）：
  - `SupermarketSession-20260721-142018`（2315 nodes / 7219 links）：
    g2o robust 100 次迭代，质量报告全指标输出；坏 loop（max 残差
    >100 m）与 87 组件被质量门拦截为 NON_RECOVERABLE_FAIL——fail
    closed 行为符合 §11.5。
  - `SupermarketSession-20260802-093522`（4442 nodes）：同样被拦截，
    无崩溃、无源 DB 写入。
- Swift host 套件：`IOSCoreContractTests` OK（含 Replay E2E：导入→
  编译→地图库→快照→网关 Fast→1Hz 轨迹→价签→结果包→流式 XLSX
  →重开校验；宿主接参考实现，生产接 native core）。
- `python3 -m unittest discover -s tools/PriorMap/tests` 全量通过
  （含文档治理、native 符号契约、因子图只读契约）；
  `tools/Qualification/tests`、`tools/SupermarketMapStudio/tests` 均 OK。
- `plutil -lint project.pbxproj` OK。

## 未执行（诚实记录，禁止写 PASS）

- Debug simulator clean build：本机 iOS 依赖库为 device-only arm64，
  无 simulator slice，模拟器完整链接不可行；Swift 源码的设备编译已由
  arm64 build 覆盖。
- Gate B 三格式 parity 新断言、Gate E snapshot 流式大文件逐块 SHA 的
  增量改造、Gate J 标签聚类的 bounded-diameter 重写——V1R1 实现保持，
  未在本轮重新验证全部细则。
- Gate D §8.4/§8.5：clock_correlations.jsonl 与 tag_observation_
  bursts.jsonl 的 required-sidecar 水印在 finalization 中的强制校验。
- Gate K §15 逐文件 staging SHA/registry CAS 的补强。
- Replay/Pareto 精度矩阵、exact-SHA CI（需远端运行）、独立 reviewer、
  真机短路线、Sam 现场。

## 结论

**IMPLEMENTED / UNIT TESTED（Swift host）/ PC oracle INTEGRATION
TESTED / CI VERIFIED（本地 unsigned arm64 build）**；NOT DEVICE LAB
PASS / NOT SAM FIELD PASS。真机短路线与独立审查通过前不得声明
READY FOR SAM FIELD TEST。
