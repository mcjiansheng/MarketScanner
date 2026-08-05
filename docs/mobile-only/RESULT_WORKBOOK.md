# 结果工作簿（Result Workbook）

> 状态：IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED（X1/X4/X6/X8/X9/T12）

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

## 测试（Swift host）

- X1：工作簿是真实 Open XML ZIP。
- X4：恰有四张要求的工作表且名称正确。
- X6/T12：100,000 行 DevicePositions 可导出。
- X8：公式注入防护（`=HYPERLINK` 被前缀化）且无 `<f>`。
- X9：XML 控制字符过滤与特殊字符转义。
