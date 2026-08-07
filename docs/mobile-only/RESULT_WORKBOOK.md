# 结果工作簿（Result Workbook）

> 状态：**当前有效**；IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED。最后核对：2026-08-07。

## 模块

`app/ios/RTABMapApp/MobileResults/`

- `XLSXWorkbookWriter.swift`：真正 Open XML `.xlsx` ZIP 打包器（自研 ZIP writer，系统 zlib raw deflate），原子导出。
- `MobileWorksheets.swift`：四张业务表的冻结列定义与行类型。
- `MobileResultExporter.swift`：从最终轨迹/价签/补扫任务/汇总组装四张表。
- `ResultShareController.swift`（UIKit）：系统分享菜单导出。

## 包结构

`[Content_Types].xml` / `_rels/.rels` / `docProps/core.xml` / `docProps/app.xml` /
`xl/workbook.xml` / `xl/_rels/workbook.xml.rels` / `xl/styles.xml` /
`xl/worksheets/sheet1..4.xml`（PriceTags / DevicePositions / RunSummary / RescanRequired）

## 安全

- 全部业务字符串写 inline string，不生成 `<f>`；`= + - @` 开头加 `'` 前缀防公式注入。
- XML 控制字符过滤；Excel 行上限 1,048,576（超限失败提示分 Session，不截断）。
- 导出 staging → rename 原子化；workbook SHA 进 result manifest。
- PriceTags 和 RescanRequired 均包含物理 `shelf_segment_id`；`shelf_code` 不再承担唯一键职责。DevicePositions 的 `estimated_uncertainty_m` 允许空值，空值对应不可用而不是零误差。
- 整个 Result package 先写入 `Results/.result-staging-<task-sha256>.<result-sha256>/` 隐藏 staging；逐文件 hash/fsync 并写入 `result_manifest.json` 与 `result_commit_receipt.json` 后，在最终路径不存在时先将全部文件冻结为 `0444`、staging 根目录冻结为 `0555`，验证 exact set/modes，再执行同父目录 `renameatx_np(..., RENAME_EXCL)` 并 fsync Results parent。因 Darwin 拒绝跨父目录移动已冻结目录，隐藏 staging 必须与最终 result 为同级路径；这保证 final path 从首次可见开始就不可写。
- rename 后重新读取并验证最终目录的 exact modes/file set、commit receipt、manifest SHA 和每个 artifact 的 bytes/SHA-256；任何 rename 前失败均保持 final path 不存在，并把隐藏 staging 恢复为 directories `0755` / files `0644`，使重启清理可恢复执行。
- 读取历史结果时重新验证 exact file set、权限、receipt、manifest 和逐文件 SHA。损坏/未知 root entry 移入 durable quarantine wrapper，保留原 payload 与 `quarantine_diagnostic.json`；不得静默 `continue`。

## 测试（Swift host）

- X1：工作簿是真实 Open XML ZIP。
- X4：恰有四张要求的工作表且名称正确。
- X6/T12：100,000 行 DevicePositions 可导出。
- X8：公式注入防护（`=HYPERLINK` 被前缀化）且无 `<f>`。
- X9：XML 控制字符过滤与特殊字符转义。
