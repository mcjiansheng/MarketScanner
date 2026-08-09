import Foundation

/// Typed, stable errors for the mobile map-source import pipeline.
///
/// Every case carries a machine-readable `stableCode` and a human
/// `message` that never contains raw file bytes. The codes are frozen
/// contracts: the iOS UI, the Swift host tests and the PC golden oracle
/// all refer to them by value.
enum MapSourceImportError: Error, Equatable {
    case unknownFormat
    case fileTooLarge(limitBytes: Int64)
    case unreadableSource(reason: String)
    case copyFailed(reason: String)
    case invalidUTF8(detail: String)
    case invalidJSON(detail: String)
    case duplicateJSONKey(key: String)
    case jsonDepthTooDeep(limit: Int)
    case jsonTooLarge(limitBytes: Int64)
    case elementCountTooLarge(limit: Int)
    case missingHeader(column: String)
    case duplicateHeader(column: String)
    case malformedRow(row: Int, reason: String)
    case emptyFloor(row: Int)
    case elementNotObject(row: Int)
    case formulaNotSupported(row: Int, column: String)
    case zipTraversalDetected(entry: String)
    case zipEntryTooMany(limit: Int)
    case zipEntryTooLarge(entry: String)
    case zipTotalTooLarge(limitBytes: Int64)
    case zipRatioTooLarge(entry: String)
    case zipCorrupt(reason: String)
    case xlsxMissingPart(name: String)
    case xlsxInvalidXML(name: String, reason: String)
    case xlsxSheetNotFound(name: String)
    case xlsxSharedStringTooMany(limit: Int)
    case xlsxRowTooMany(limit: Int)
    case xlsxCellTooLarge(limitBytes: Int64)
    case csvFieldCountMismatch(row: Int, expected: Int, actual: Int)
    case csvContainsNUL(row: Int)
    case csvFieldTooLarge(row: Int)
    case csvRowTooMany(limit: Int)
    case coordinateContractMissing
    case unknownShapeTypePolicy(shapeType: String)
    case invalidGeometry(shapeType: String, reason: String)
    case duplicateElementIdentity(duplicateID: String)
    /// V1R5 §13.5 (review H-13): XLSX/CSV imports REQUIRE an explicit,
    /// user-confirmed store ID — a defaulted "default" can collide
    /// across stores and sessions.
    case storeIDRequired
    case invalidBusinessIdentity(field: String, reason: String)
    case cancelled

    /// Frozen machine-readable code. UI and tests must not parse the
    /// human `message`; they switch on this value.
    var stableCode: String {
        switch self {
        case .unknownFormat: return "map_source_unknown_format"
        case .fileTooLarge: return "map_source_file_too_large"
        case .unreadableSource: return "map_source_unreadable"
        case .copyFailed: return "map_source_copy_failed"
        case .invalidUTF8: return "invalid_utf8"
        case .invalidJSON: return "invalid_json"
        case .duplicateJSONKey: return "duplicate_json_key"
        case .jsonDepthTooDeep: return "json_nesting_too_deep"
        case .jsonTooLarge: return "json_document_too_large"
        case .elementCountTooLarge: return "map_source_element_count_too_large"
        case .missingHeader: return "map_source_missing_header"
        case .duplicateHeader: return "map_source_duplicate_header"
        case .malformedRow: return "map_source_malformed_row"
        case .emptyFloor: return "map_source_empty_floor"
        case .elementNotObject: return "map_source_element_not_object"
        case .formulaNotSupported: return "map_source_formula_not_supported"
        case .zipTraversalDetected: return "map_source_zip_traversal"
        case .zipEntryTooMany: return "map_source_zip_entry_too_many"
        case .zipEntryTooLarge: return "map_source_zip_entry_too_large"
        case .zipTotalTooLarge: return "map_source_zip_total_too_large"
        case .zipRatioTooLarge: return "map_source_zip_ratio_too_large"
        case .zipCorrupt: return "map_source_zip_corrupt"
        case .xlsxMissingPart: return "map_source_xlsx_missing_part"
        case .xlsxInvalidXML: return "map_source_xlsx_invalid_xml"
        case .xlsxSheetNotFound: return "map_source_xlsx_sheet_not_found"
        case .xlsxSharedStringTooMany: return "map_source_xlsx_shared_string_too_many"
        case .xlsxRowTooMany: return "map_source_xlsx_row_too_many"
        case .xlsxCellTooLarge: return "map_source_xlsx_cell_too_large"
        case .csvFieldCountMismatch: return "map_source_csv_field_count_mismatch"
        case .csvContainsNUL: return "map_source_csv_contains_nul"
        case .csvFieldTooLarge: return "map_source_csv_field_too_large"
        case .csvRowTooMany: return "map_source_csv_row_too_many"
        case .coordinateContractMissing: return "map_source_coordinate_contract_missing"
        case .unknownShapeTypePolicy: return "map_source_unknown_shape_type"
        case .invalidGeometry: return "map_source_invalid_geometry"
        case .duplicateElementIdentity: return "map_source_duplicate_element_identity"
        case .storeIDRequired: return "map_source_store_id_required"
        case .invalidBusinessIdentity:
            return "map_source_invalid_business_identity"
        case .cancelled: return "map_source_cancelled"
        }
    }

    var message: String {
        switch self {
        case .unknownFormat:
            return "无法识别文件格式（支持 .xlsx / .csv / .json）。"
        case .fileTooLarge(let limitBytes):
            return "文件超过大小限制（\(limitBytes / (1024 * 1024)) MiB）。"
        case .unreadableSource(let reason):
            return "无法读取源文件：\(reason)"
        case .copyFailed(let reason):
            return "复制源文件到应用私有目录失败：\(reason)"
        case .invalidUTF8(let detail):
            return "文件包含非法 UTF-8 字节：\(detail)"
        case .invalidJSON(let detail):
            return "JSON 无效：\(detail)"
        case .duplicateJSONKey(let key):
            return "JSON 包含重复键：\(key)"
        case .jsonDepthTooDeep(let limit):
            return "JSON 嵌套深度超过限制（\(limit)）。"
        case .jsonTooLarge(let limitBytes):
            return "JSON 文档超过大小限制（\(limitBytes / (1024 * 1024)) MiB）。"
        case .elementCountTooLarge(let limit):
            return "元素数量超过限制（\(limit)）。"
        case .missingHeader(let column):
            return "缺少必需列：\(column)"
        case .duplicateHeader(let column):
            return "列名重复：\(column)"
        case .malformedRow(let row, let reason):
            return "第 \(row) 行格式错误：\(reason)"
        case .emptyFloor(let row):
            return "第 \(row) 行 floor 为空。"
        case .elementNotObject(let row):
            return "第 \(row) 行 element 不是 JSON 对象。"
        case .formulaNotSupported(let row, let column):
            return "第 \(row) 行 \(column) 列使用公式；手机端不接受公式。"
        case .zipTraversalDetected(let entry):
            return "ZIP 包含不安全的路径项：\(entry)"
        case .zipEntryTooMany(let limit):
            return "ZIP 条目数量超过限制（\(limit)）。"
        case .zipEntryTooLarge(let entry):
            return "ZIP 条目解压后过大：\(entry)"
        case .zipTotalTooLarge(let limitBytes):
            return "ZIP 总解压大小超过限制（\(limitBytes / (1024 * 1024)) MiB）。"
        case .zipRatioTooLarge(let entry):
            return "ZIP 条目压缩比异常：\(entry)"
        case .zipCorrupt(let reason):
            return "ZIP 结构损坏：\(reason)"
        case .xlsxMissingPart(let name):
            return "XLSX 缺少必要部件：\(name)"
        case .xlsxInvalidXML(let name, let reason):
            return "XLSX 部件 \(name) 的 XML 无效：\(reason)"
        case .xlsxSheetNotFound(let name):
            return "找不到工作表：\(name)"
        case .xlsxSharedStringTooMany(let limit):
            return "共享字符串数量超过限制（\(limit)）。"
        case .xlsxRowTooMany(let limit):
            return "工作表行数超过限制（\(limit)）。"
        case .xlsxCellTooLarge(let limitBytes):
            return "单元格内容超过大小限制（\(limitBytes / (1024 * 1024)) MiB）。"
        case .csvFieldCountMismatch(let row, let expected, let actual):
            return "第 \(row) 行字段数不一致（应为 \(expected)，实际 \(actual)）。"
        case .csvContainsNUL(let row):
            return "第 \(row) 行包含 NUL 字节。"
        case .csvFieldTooLarge(let row):
            return "第 \(row) 行字段超过大小限制。"
        case .csvRowTooMany(let limit):
            return "CSV 行数超过限制（\(limit)）。"
        case .coordinateContractMissing:
            return "原始地图缺少坐标合同。"
        case .unknownShapeTypePolicy(let shapeType):
            return "未知元素类型：\(shapeType)"
        case .invalidGeometry(let shapeType, let reason):
            return "元素 \(shapeType) 几何无效：\(reason)"
        case .duplicateElementIdentity(let duplicateID):
            return "地图包含重复的元素身份：\(duplicateID)"
        case .storeIDRequired:
            return "导入要求用户确认的 store ID（不允许默认值）。"
        case .invalidBusinessIdentity(let field, let reason):
            return "地图业务标识 \(field) 无效：\(reason)"
        case .cancelled:
            return "导入已取消。"
        }
    }
}

/// One policy for every store/map identity entering canonical JSON,
/// compiler manifests, the map registry and result exports. Values are
/// preserved byte-for-byte; unsafe values are rejected, never trimmed or
/// silently rewritten into a different business identity.
enum MapSourceBusinessIdentityPolicy {
    static let maximumStoreIDBytes = 128
    static let maximumMapNameBytes = 200

    static func validate(storeID: String, mapName: String) throws {
        try validateComponent(
            storeID, field: "store_id", maximumUTF8Bytes: maximumStoreIDBytes)
        try validateComponent(
            mapName, field: "map_name", maximumUTF8Bytes: maximumMapNameBytes)
    }

    static func isValidStoreID(_ value: String) -> Bool {
        return (try? validateComponent(
            value, field: "store_id",
            maximumUTF8Bytes: maximumStoreIDBytes)) != nil
    }

    static func isValidMapName(_ value: String) -> Bool {
        return (try? validateComponent(
            value, field: "map_name",
            maximumUTF8Bytes: maximumMapNameBytes)) != nil
    }

    private static func validateComponent(
        _ value: String,
        field: String,
        maximumUTF8Bytes: Int
    ) throws {
        guard !value.isEmpty else {
            throw MapSourceImportError.invalidBusinessIdentity(
                field: field, reason: "must not be empty")
        }
        guard value == value.precomposedStringWithCanonicalMapping else {
            throw MapSourceImportError.invalidBusinessIdentity(
                field: field, reason: "must use NFC Unicode normalization")
        }
        guard value.utf8.count <= maximumUTF8Bytes else {
            throw MapSourceImportError.invalidBusinessIdentity(
                field: field,
                reason: "exceeds \(maximumUTF8Bytes) UTF-8 bytes")
        }
        guard value != ".", value != "..", !value.hasPrefix("."),
              !value.contains("/"), !value.contains("\\") else {
            throw MapSourceImportError.invalidBusinessIdentity(
                field: field, reason: "must be a safe non-hidden basename")
        }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MapSourceImportError.invalidBusinessIdentity(
                field: field, reason: "leading/trailing or all whitespace is forbidden")
        }
        guard !value.unicodeScalars.contains(where: {
            $0.value < 0x20 || ($0.value >= 0x7F && $0.value <= 0x9F)
        }) else {
            throw MapSourceImportError.invalidBusinessIdentity(
                field: field, reason: "control characters are forbidden")
        }
        guard URL(fileURLWithPath: value).lastPathComponent == value else {
            throw MapSourceImportError.invalidBusinessIdentity(
                field: field, reason: "must be one path-safe component")
        }
    }
}

/// Frozen per-format and pipeline resource limits (V1).
enum MapSourceImportLimits {
    static let maximumSourceFileBytes: Int64 = 64 * 1024 * 1024
    static let maximumZIPEntries: Int = 4096
    static let maximumZIPEntryBytes: Int64 = 64 * 1024 * 1024
    static let maximumZIPTotalBytes: Int64 = 256 * 1024 * 1024
    static let maximumZIPRatio: Int64 = 200
    static let maximumXMLBytes: Int64 = 64 * 1024 * 1024
    static let maximumWorkbookSheets: Int = 4096
    static let maximumWorkbookRelationships: Int = 4096
    static let maximumWorksheetRows: Int = 500_000
    static let maximumWorksheetColumns: Int = 16_384
    static let maximumSharedStrings: Int = 1_000_000
    static let maximumCellBytes: Int64 = 1 * 1024 * 1024
    static let maximumJSONBytes: Int64 = 64 * 1024 * 1024
    static let maximumJSONNestingDepth: Int = 64
    static let maximumElements: Int = 100_000
    static let maximumCSVFieldBytes: Int64 = 4 * 1024 * 1024
    static let maximumCSVRows: Int = 500_000
}
