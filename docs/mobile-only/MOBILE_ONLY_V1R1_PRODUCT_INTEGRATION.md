# Mobile-Only V1R1 产品整合收口状态

> 分支：`mobile-only-v1r1-product-integration-closeout`
> 基线：`mobile-only-v1-end-to-end-integration` HEAD `81f6ab1bd849878a68b56d7d3b7100589314960d`
> 本文件核对日期：2026-08-05（实现 + Swift host 集成测试阶段）
> 权威代码事实：本分支当前源码；本文件与代码冲突时以已测试代码为准。

## Wave 身份

```json
{
  "wave": "mobile-only-v1r1-product-integration-closeout",
  "branch": "mobile-only-v1r1-product-integration-closeout",
  "base_branch": "mobile-only-v1-end-to-end-integration",
  "previous_recorded_implementation_sha": "f616b9711b860d8f473c94405420cb5d0ebf3c1b",
  "implementation_sha": "<final clean-build SHA>"
}
```

## 目标

一台 iPhone 从原始 XLSX/CSV/JSON 到最终四表 XLSX，全程不依赖 PC。
V1R1 修复的是"模块存在但未形成真实 App 产品链"的问题。

## 本轮交付（IMPLEMENTED + Swift host INTEGRATION TESTED）

### Gate A — 真实 App UI 与总协调器

- `MobileOnlyWorkflow/`：`MobileOnlyWorkflowCoordinator`（强持有
  documentPicker / importTask / processingTask，禁止提前释放）、
  `MobileOnlyWorkflowState`（idle…interrupted 全状态持久化、可恢复）、
  `MobileOnlyWorkflowError`（稳定错误码）、`MobileMapLibrary`
  （`packages/<prior-map-id>/<package-sha>` + CAS registry + rebuild）、
  `MobileProcessingTaskStore`、`MobileResultLibrary`
  （workbook SHA 只写外部 `result_manifest.json`）。
- `MobileProcessingPipeline`：snapshot → Fast Path SE(2) → 1 Hz 最终轨迹
  → 价签最终化 → 结果包 → 流式 XLSX → 外部 manifest。
- `UI/`：8 个 programmatic UIKit 页面（Home / 地图库 / 导入向导 /
  编译进度 / 扫描设置 / 处理 / 结果 / 补扫任务）。
- `ViewController` 新增 MarketScanner 菜单入口：门店地图 / 开始门店扫描
  / 处理历史扫描 / 历史结果。

### Gate B — 严格地图导入

- Picker 复制失败返回 `.failed(.copyFailed)`，绝不返回 provider URL；
  staging 为独占流式复制 + fsync + staged SHA。
- `XLSXZipReader` 加固：最后完整 EOCD 搜索（校验 comment length）、
  拒绝 multi-disk / ZIP64 / encrypted、拒绝重复条目名（含 Unicode
  规范化碰撞）、local/central 名称/方法/尺寸一致性、CRC32 校验、
  中央目录精确边界、canonical path components。
- `RFC4180CSVReader` 流式 `parse(stream:)`（无全文件拷贝）；引号只能
  在字段开头；关闭引号后只允许 `,` CR LF EOF；裸 CR 与空白行政策明确。
- `JSONMapSourceImporter` 严格 schema：必填顶层/元素字段，禁止
  `missing floor -> 1` / `missing shape -> Unknown`；
  `StrictJSONScalar` 布尔/整数/数字；未知字段保存到 extensions。
- Canonical source v2：跨格式业务载荷（不含文件名/源 SHA/行号/警告/
  原始字段）+ 稳定元素 ID（正式 source id 优先，否则几何+业务身份
  hash，禁止依赖 row）+ 独立 `MapImportAudit`。

### Gate E — RTAB-Map DB 图读取（in-process）

- `MSRTABMapGraphReaderBridge.h/.mm`：`mode=ro&immutable=1` 只读打开 +
  `PRAGMA quick_check`；Node（id/map_id/stamp/原始 3x4 pose）与 Link
  （from/to/type/SE3 transform/6x6 information）；保持原始 3D，
  业务层按记录的 projection_policy_version 投影 SE(2)。
- `MobileGraphReader.swift` Swift 封装。
- 真实会话 DB 验证：4442 nodes（与 metadata `storedTrajectorySamples`
  完全一致）、15070 links、quick_check 通过。

### Gate F（部分）— Fast Path 求解器护栏

- SE2 factor graph：重复节点 ID 变为类型化错误（原实现会触发
  Dictionary trap）；显式 anchor 要求（10.2 前两条）。
- 完整 information matrix / robust kernel 与 native 共享库重构列为
  后续工作（见"未执行"）。

### Gate J — 真正流式原子 XLSX

- `XLSXRowSequence.forEachRow` 行协议；sheet XML 逐行写临时文件；
  ZIP 写入用 local header + data descriptor + 增量 deflate + 增量
  CRC32 —— 100k DevicePositions 行不整体驻留内存（100k 导出通过
  峰值 RSS 门限）。
- 原子替换：staging → fsync → 生产 reader 重开校验 → backup →
  rename → 父目录 fsync → 删除 backup；失败保留旧工作簿。
- 无 apostrophe 前缀（inlineStr 不执行公式，barcode 保持原值）；
  NaN/Inf blocker；RunSummary 写 `result_id`，最终 workbook/manifest
  SHA 只写外部 `result_manifest.json`。

### Replay E2E（§15）

- host suite 新增 Replay E2E：原始 CSV → 生产导入 → 手机编译 → 地图库
  注册 → finalized session fixture → snapshot → Fast Path → 轨迹 →
  价签 → 结果包 → 流式 XLSX → 重开校验；禁止直接构造
  `FinalTrajectory.Node` / `FinalPriceTag`。

### CI（§17）

- `marketscanner-repair-v2.yml` push 分支增加 `mobile-only-**`。

## 验证证据（本轮已跑）

- `python3 -m unittest tools.PriorMap.tests.test_prior_map.IOSCoreContractTests -v`
  → OK（含 I3/I10/I11 导入、G 套件、X1–X9 workbook、100k xlsx-scale
  峰值 RSS、Recovery fixtures、Replay E2E）。
- 全量 `swiftc -typecheck`（除依赖 native bridge 的宿主文件外）→ 0 error。
- Bridge 真实 DB：4442 nodes / 15070 links / quick_check ok。
- `plutil -lint project.pbxproj` OK。

## 未执行（诚实记录，禁止写 PASS）

- Gate D 扫描接线（clock_correlations/tag_bursts 写入与 map 绑定、
  scan setup → ARKit 启动）——扫描配置已持久化，真正启动待接线。
- Gate G Deep Path：`reprocessMobileSession` native API 未实现（需求
  禁止空 stub，未写 stub）；`tools/Reprocess` 重构为共享库待办。
- Gate F 完整求解器（information matrix / robust kernel / weighted
  objective）与 native 共享 core。
- Gate K 的三格式业务结果一致性断言（Replay 已覆盖 CSV 单格式）。
- Xcode clean build / unsigned arm64 build / 真机短路线 / Sam 实地。
- independent reviewer 只读审查。
- exact-SHA CI 运行（workflow 已允许分支，仓库需在远端跑）。

## 结论

**IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED（Swift host）**；
NOT CI VERIFIED / NOT DEVICE SMOKE PASS / NOT SAM FIELD PASS。
状态：`MOBILE-ONLY V1 TESTABLE`（待 Gate D/G 接线与真机验证后复审）。
