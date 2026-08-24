# 先验地图会话捆绑（V1R6）：结果包附带扫描当时的地图包

> 文档状态：**当前有效**。最后核对日期：2026-08-24。
> 实现分支：`fix/esl-field-capture-efficiency`（提交见本文件末尾“验证证据”）。
> 关联文档：`PRIOR_MAP_FORMAT.md`、`DATA_FORMATS.md`、`PC_UX.md`。

## 1. 背景与问题

2026-08-23 处理 `扫描结果/0823` 批次（天虹 / Kohl's）时暴露一条生产链路缺口：

- 手机会话 metadata 绑定 `priorMapId = 02402-6bfaef41d384`（含 canonical SHA 前缀），
  而 PC 本地 `map/` 文件夹中的天虹包是旧版本 `02402-d4eb3e633cc2`；
- 用本地 `map/Mapxlsx/map-TianHong.02402-20260809123904.xlsx` 重新编译仍得到旧
  SHA，证明手机扫描时使用的是 8/9 之后更新的工作簿，PC 侧没有对应版本；
- 手机导出合同（`exportFinalizedCapture`）只复制 `segment_0001` 扫描证据目录，
  **不携带地图包本身**；metadata 只记录 `priorMapId / priorMapSha256 /
  priorMapCanonicalSourceSha256` 三个身份字段（哈希不是内容）；
- PC localized 合同（`offline_localization._resolve_session_prior_map_identity`）
  要求 `prior_map_id` 与 `canonical_source_sha256` 精确匹配，失败即拒绝，
  因此该批次只能执行标准重处理，**无法做先验地图结构校正**。

结论：知道“地图是天虹”不等于有“手机当时用的那个版本”；要保证 PC 结构校正
必然可执行，必须让**会话结果包自携带扫描当时在用的地图包**。

## 2. 目标与设计原则

1. **finalize 即捆绑**：扫描终结时把地图库中与扫描绑定精确一致（`priorMapId +
   packageSHA256`，canonical SHA 可选复核）的已安装包写入
   `<session>/prior_map/`，并写 `<session>/prior_map_receipt.json`。
2. **fail-closed**：捆绑失败与定位 sidecar 写入失败同级别，进入
   `processingEligibility.blockers`（`prior_map_bundle_failed` /
   `prior_map_binding_missing`），finalize 拒绝提交 —— 不允许产出一个无法保证
   PC 结构校正的“正式”结果包。
3. **字节级精确**：`prior_map/` 目录内容与已安装包逐文件 SHA-256 一致，且
   “文件集合 == package_manifest artifacts”；收据放在包外，避免包完整性校验
   因额外文件被拒。
4. **幂等**：同一身份的合法捆绑不重复复制、不覆盖。
5. **兼容**：历史会话（无捆绑）导出时尝试从地图库补捆，补不到仍可导出（收据
   记录 `bundled=false`），PC 保持原地图选择流程。
6. **身份仍是硬门**：PC 只在收据身份与 metadata 精确匹配时才自动选用捆绑包，
   任何失配继续拒绝，不放宽既有安全合同。

## 3. 手机端实现

### 3.1 新文件 `app/ios/RTABMapApp/MobileOnlyWorkflow/PriorMapSessionBundler.swift`

Foundation-only（Foundation + CryptoKit），可进入 Swift host 测试。公开 API：

- `bundleInstalledPackage(into:priorMapID:packageSHA256:canonicalSourceSHA256:)`
  - 经 `MobileMapLibrary.map` 全量复验（manifest/digest/身份/不可变）取得唯一
    已安装包；`canonicalSourceSHA256` 给定且不一致时抛 `identityMismatch`；
  - 复制到 `<session>/prior_map`（`.prior_map.partial-<uuid>` 暂存 → 校验 → 原子
    替换），逐 artifact 重算 SHA-256 并与 `package_manifest.json` 比对；
  - 校验“顶层文件集合 == artifacts ∪ {package_manifest.json}”，拒绝多余文件；
  - 幂等：已有同身份且 `verifyBundledPackage` 通过的捆绑直接复用；
  - 写 `<session>/prior_map_receipt.json`。
- `verifyBundledPackage(in:)`：重新哈希全部 artifact 并复核收据内容摘要。
- `readReceipt(in:)` / `bundledPackageDirectory(in:)`。
- `restoreInstalledPackage(from:)`：当库中已无该身份时，从会话内捆绑包恢复注册
  —— `unregister` 会保留只读字节，优先**复用内容寻址目录**（重新校验 digest/
  身份后直接 `register`，register 内部重新冻结）；仅当字节被物理删除时才从捆绑
  包复制安装。这使**手机本地后处理**同样不再受“地图被移除”影响。

### 3.2 finalize 接入（`ViewController.swift`）

在 metadata 构造前，对 `isPriorMapScan` 会话执行捆绑；异常写入
`processingBlockers`。metadata 新增可选字段 `priorMapBundled`（`Bool?`，向后
兼容，nil 时 JSON 键省略）。

### 3.3 导出接入（`SupermarketScanSession.exportFinalizedCapture`）

- 复制 `segment_0001` 后同步复制 `<session>/prior_map/` 与收据到导出根；
- 历史会话（本地无捆绑）尝试 `bundleInstalledPackage(into: exportRoot, ...)` 补捆；
- 导出内捆绑包必须通过 `verifyBundledPackage`，否则导出失败并回滚（fail-closed）；
- `copy_verification.json`（`ExternalCopyVerificationReceipt`）新增可选字段
  `priorMapBundled / priorMapId / priorMapPackageSha256`；
- 三段式 SHA 复核自动覆盖 `prior_map/`（manifest 基于导出根计算）。

## 4. 数据格式

### 4.1 `prior_map_receipt.json`（MarketScannerPriorMapBundleReceipt v1）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| format | string | `MarketScannerPriorMapBundleReceipt` |
| version | int | 1 |
| bundled | bool | 恒 true（缺失视为无捆绑） |
| prior_map_id | string | 与 metadata `priorMapId` 一致 |
| package_sha256 | string | 手机侧包摘要，与 metadata `priorMapSha256` 一致 |
| canonical_source_sha256 | string? | 与 metadata `priorMapCanonicalSourceSha256` 一致 |
| name / floor_count / element_count / compiler_version | … | 包身份审计 |
| bundled_at_unix | double | 捆绑时刻 |
| file_count / bundle_content_sha256 / files | … | 逐文件 `相对路径→sha256` 与整体摘要，供 PC 复核 |

### 4.2 会话目录布局（新增）

```text
SupermarketSession-*/
  segment_0001/            # 原扫描证据（不变）
  prior_map/               # 字节级精确的 v2 先验地图包（manifest.json 等）
  prior_map_receipt.json   # 捆绑收据（包外）
```

## 5. PC 端实现（`tools/SupermarketMapStudio/server.py`）

- `bundled_prior_map_summary(session)`：inspect 新增 `bundled_prior_map` 节，
  读取收据并与 `segment_*/metadata.json` 的 `priorMapId / priorMapSha256 /
  priorMapCanonicalSourceSha256` 精确比对，报告
  `present / package_path / prior_map_id / package_sha256 /
  canonical_source_sha256 / identity_matches_session`；
- `resolve_localized_prior_map(data, session)`：localized 任务未指定
  `prior_map` 时，仅在 `identity_matches_session == true` 时自动选用捆绑包
  路径；否则按原错误语义要求显式地图；显式指定时仍以显式值为准；
- 深层校验不变：捆绑包仍会走 `validate_prior_map_package` 与
  `_resolve_session_prior_map_identity` 精确身份门；
- Web（`app.js`）：inspect 到身份匹配的捆绑包时自动填充本地化地图路径字段。

## 6. 手机本地后处理审查结论

审查覆盖 `MobileProcessingPipeline` / `MobileOnlyWorkflowCoordinator` /
`MobileProcessingViewController` 的地图解析路径：

- 扫描启动即要求已安装并验证的包（`beginScanSetup(map:)`），本地处理按
  metadata 的 `priorMapId + priorMapSha256` 从注册库内容寻址解析，不依赖外部
  路径 —— 与 PC“本地缺包”问题的机制不同；
- 唯一缺口（库中包被移除后重处理旧会话）已由
  `restoreInstalledPackage` 兜底并接入 UI 选择流程（第 3.1/3.4 节）；
- 恢复路径遵守库合同：复用未删除的只读字节并重新校验、`register` 重新冻结，
  不执行对冻结树的移动/删除（避免 rename EACCES）。

## 7. 验证证据（2026-08-24，分支 `fix/esl-field-capture-efficiency`）

| 项目 | 结果 |
| --- | --- |
| Swift host `--prior-map-bundle-focused` | PASS：编译安装 → 捆绑 → 收据身份一致 → 逐文件复验 → 幂等 → unregister 后恢复注册 → 篡改拒绝 → canonical 失配拒绝 → 未知 SHA 拒绝 |
| PriorMap 全量 | 370/370 OK |
| Map Studio 全量 | 148/148 OK（含 5 个捆绑解析新测试） |
| Qualification（含 iOS source membership，87 Swift 源） | 32/32 OK |
| Python 语法 / JS 语法 | OK |
| unsigned generic iPhoneOS Debug 全量编译 | BUILD SUCCEEDED |

## 8. 边界与未验证项

- 真机未执行：签名安装、LiDAR 现场扫描 finalize/导出、Files provider 大包导出、
  PC localized 端到端（捆绑包自动选用 → 结构校正 → 发布门）。
- 历史会话补捆是尽力而为（库中已无该包时收据 `bundled=false`），PC 需显式地图。
- 捆绑包体积约 2–5 MB/会话；连续多会话扫描会增加少量磁盘占用，未做配额测试。
- 手机端“结果包自校验地图包”依赖地图库在 finalize 时刻仍持有该包；若用户在
  扫描后、finalize 前移除地图，finalize 会因 `prior_map_bundle_failed` 拒绝并
  提示重新导入（预期行为，非静默降级）。
- 结论维持 **NO-GO / NOT PRODUCTION READY**（真机资格矩阵未完成）。
