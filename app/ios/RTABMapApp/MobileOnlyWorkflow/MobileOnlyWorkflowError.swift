import Foundation

/// Errors surfaced by the Mobile-Only product workflow (V1R1 Gate A).
///
/// Every error carries a stable `code` that the UI maps to a localized
/// message; new codes must be added to the UI mapping table so the user
/// never sees an unknown raw code.
enum MobileOnlyWorkflowError: Error, LocalizedError, Equatable {
    case importFailed(String)
    case compileFailed(String)
    case libraryUnavailable(String)
    case snapshotFailed(String)
    case processingFailed(String)
    case exportFailed(String)
    case pickerCopyFailed(String)
    case invalidState(String)
    case cancelled
    case interrupted

    /// Stable machine code for UI mapping.
    var code: String {
        switch self {
        case .importFailed: return "workflow.import_failed"
        case .compileFailed: return "workflow.compile_failed"
        case .libraryUnavailable: return "workflow.library_unavailable"
        case .snapshotFailed: return "workflow.snapshot_failed"
        case .processingFailed: return "workflow.processing_failed"
        case .exportFailed: return "workflow.export_failed"
        case .pickerCopyFailed: return "workflow.picker_copy_failed"
        case .invalidState: return "workflow.invalid_state"
        case .cancelled: return "workflow.cancelled"
        case .interrupted: return "workflow.interrupted"
        }
    }

    var errorDescription: String? {
        switch self {
        case .importFailed(let detail):
            return "地图导入失败：\(detail)"
        case .compileFailed(let detail):
            return "地图编译失败：\(detail)"
        case .libraryUnavailable(let detail):
            return "地图库不可用：\(detail)"
        case .snapshotFailed(let detail):
            return "会话快照失败：\(detail)"
        case .processingFailed(let detail):
            return "处理失败：\(detail)"
        case .exportFailed(let detail):
            return "结果导出失败：\(detail)"
        case .pickerCopyFailed(let detail):
            return "文件复制失败：\(detail)"
        case .invalidState(let detail):
            return "流程状态错误：\(detail)"
        case .cancelled:
            return "操作已取消"
        case .interrupted:
            return "操作已中断"
        }
    }
}
