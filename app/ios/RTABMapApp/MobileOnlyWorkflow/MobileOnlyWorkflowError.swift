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
    /// V1R2 §5.4: the requested state transition is not in the table.
    case illegalTransition(String)
    /// V1R2 §4.1: an import/compile run is already in flight (double
    /// click / concurrent import guard).
    case duplicateImport(String)
    /// V1R2 §4.2: no map bound to the session metadata is registered.
    case mapNotBound(String)
    /// V1R2 §5.2: a persisted reference (staged file, map package,
    /// session, database) disappeared before resume.
    case referenceMissing(String)
    /// V1R2 §16 / Gate L: a resource budget blocked the run.
    case resourceRequired(String)
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
        case .illegalTransition: return "workflow.illegal_transition"
        case .duplicateImport: return "workflow.duplicate_import"
        case .mapNotBound: return "workflow.map_not_bound"
        case .referenceMissing: return "workflow.reference_missing"
        case .resourceRequired: return "workflow.resource_required"
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
        case .illegalTransition(let detail):
            return "非法状态转换：\(detail)"
        case .duplicateImport(let detail):
            return "导入已在进行中：\(detail)"
        case .mapNotBound(let detail):
            return "会话绑定的地图不在地图库：\(detail)"
        case .referenceMissing(let detail):
            return "恢复所需的引用缺失：\(detail)"
        case .resourceRequired(let detail):
            return "资源不足，无法继续：\(detail)"
        case .cancelled:
            return "操作已取消"
        case .interrupted:
            return "操作已中断"
        }
    }
}
