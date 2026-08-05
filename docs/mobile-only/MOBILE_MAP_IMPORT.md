# 手机地图导入（Mobile Map Import）

> 状态：IMPLEMENTED / UNIT TESTED / INTEGRATION TESTED（Swift host 套件 I1-I14）

## 模块

`app/ios/RTABMapApp/MobileMapImport/`

- `MapSourceDocumentPicker.swift`（UIKit）：Files 选择 XLSX/CSV/JSON，security-scoped，复制到私有 staging。
- `MapSourceImportCoordinator.swift`：格式识别 → 调用对应 importer → 计算 `sourceFileSha256` / `canonicalSourceSha256` → 产出 `MapSourceImportReport`。
- `CanonicalPriorMapSource.swift` / `CanonicalJSONEncoder.swift`：三格式统一业务模型与确定性编码（sort keys、无空白、数值规范化、忽略原始文件名/格式）。
- `XLSXZipReader.swift`（自研安全 ZIP 读取，系统 zlib raw inflate）：traversal/数量/大小/压缩比限制。
- `XLSXWorkbookReader.swift` / `XLSXWorksheetReader.swift`：workbook relationships 定位 `Element Info` sheet、shared strings、流式行/单元格解析；公式（`<f>` 或 `t="str"`）拒绝。
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
