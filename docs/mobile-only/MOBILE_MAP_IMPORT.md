# 手机地图导入（Mobile Map Import）

> 文档状态：**当前有效**；IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED（Swift host I1-I14 + MapCase02 正式套件）。最后核对日期：2026-08-09。

正式超市 XLSX 使用 `Basic Info + Element Info` 权威合同；`Shelf Info` 只做审计。`Basic Info` 冻结门店、地图名、画布和 top-left anchor/pivot，调用方参数只能精确匹配，不能覆盖。历史 Element-only XLSX 只有在显式 legacy 模式下才可进入旧合同。

## 模块

`app/ios/RTABMapApp/MobileMapImport/`

- `MapSourceDocumentPicker.swift`（UIKit）：Files 选择 XLSX/CSV/JSON，security-scoped，复制到私有 staging。
- `MapSourceImportCoordinator.swift`：格式识别 → 调用对应 importer → 计算 `sourceFileSha256` / `canonicalSourceSha256` → 产出 `MapSourceImportReport`。
- `CanonicalPriorMapSource.swift` / `CanonicalJSONEncoder.swift`：三格式统一业务模型与确定性编码（sort keys、无空白、数值规范化、忽略原始文件名/格式）。
- `XLSXZipReader.swift`（自研安全 ZIP 读取，系统 zlib raw inflate）：traversal/数量/大小/压缩比限制。
- `XLSXWorkbookReader.swift` / `XLSXWorksheetReader.swift`：按 OpenXML namespace、精确根/父层级和唯一 internal worksheet relationship 定位权威 sheet；sheet/relationship 各限制 4096 并建立线性索引；严格 shared strings、row/cell reference、布尔值与单元格大小；公式（`<f>` 或 `t="str"`）拒绝。
- `RFC4180CSVReader.swift` / `CSVMapSourceImporter.swift`：流式 RFC 4180，quoted newline、`""` 转义、CRLF/LF/BOM、NUL/非法 UTF-8/字段数不一致拒绝。
- `JSONMapSourceImporter.swift`：接受 `MarketScannerPriorMapSource` v1，复用严格解析器；缺 identity 时补入。
- `SourceGeometry.swift` / `ElementNormalizer.swift`：坐标合同（top_left/bottom_left 预设）与元素规范化（与 PC `_normalized_element` 一致）。

## 错误码（冻结）

`map_source_unknown_format` / `map_source_file_too_large` / `map_source_copy_failed` /
`map_source_missing_header` / `map_source_duplicate_header` / `map_source_malformed_row` /
`map_source_empty_floor` / `map_source_element_not_object` / `map_source_formula_not_supported` /
`map_source_zip_traversal` / `map_source_zip_entry_too_many` / `map_source_zip_entry_too_large` /
`map_source_zip_total_too_large` / `map_source_zip_ratio_too_large` / `map_source_zip_corrupt` /
`map_source_xlsx_missing_part` / `map_source_xlsx_invalid_xml` / `map_source_xlsx_sheet_not_found` /
`map_source_xlsx_shared_string_too_many` / `map_source_xlsx_row_too_many` / `map_source_xlsx_cell_too_large` /
`map_source_csv_field_count_mismatch` / `map_source_csv_contains_nul` / `map_source_csv_field_too_large` /
`map_source_csv_row_too_many` / `map_source_coordinate_contract_missing` / `invalid_utf8` / `invalid_json` /
`duplicate_json_key` / `json_nesting_too_deep` / `json_document_too_large` / `map_source_element_count_too_large` /
`map_source_cancelled`

## 测试（Swift host）

- I1/I2/I3：XLSX / CSV / JSON baseline 导入。
- I4：三格式 canonical parity（`canonicalSourceSha256` 相同、元素相同、`sourceFileSha256` 不同）——`--import-suite`。
- I5：公式单元格拒绝（`map_source_formula_not_supported`）。
- I6：ZIP traversal 拒绝（`map_source_zip_traversal`）。
- I7：ZIP bomb（压缩比超限）拒绝。
- I8：CSV quoted newline 保留。
- I9：CSV 未闭合引号拒绝。
- I10：JSON 重复 key 拒绝。
- I11：非法 UTF-8 拒绝。
- I13：坐标预设 top_left / bottom_left y 轴符号。
- I14：多楼层导入。
- MapCase02：正式 `Basic Info + Element Info`、Shelf audit、1838→1630 active、角色几何、top-left anchor、canonical v3 round-trip、XML root/authority、sheet/relationship 上限、关系/row/cell/resource 负例与 MapCase01 legacy 兼容；同时执行小写/长度安全 ID、冻结 Swift package SHA、package integrity、MobileMapLibrary install/register/list/exact-read、manifest/report strict integer/array mutation，以及旧 uppercase v2 在 production validator 拒绝、diagnostic-only validator 接受的双向门。Swift 原样输出还必须通过 Python production validator。
- `--xlsx-library-smoke`：运行时接收本地真实 XLSX 路径，不把被忽略的客户样本纳入仓库；2026-08-09 的 `map 2.xlsx`、TianHong、北京昌平与 Kohl's 四张地图全部通过手机端完整地图库链路。

MapCase02 canonical SHA 冻结为 `5ddfac7dc439afc45abdcf800b799c05d53704895b620d161ef08a442c55b2db`。这是标准工作簿局部 PASS；整体仍为 **REJECTED / NO-GO / developer smoke only**，J-04 未关闭。
