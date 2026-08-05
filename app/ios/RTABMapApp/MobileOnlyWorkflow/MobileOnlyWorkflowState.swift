import Foundation

/// Persistent workflow state of a Mobile-Only product run (V1R1 Gate A).
///
/// Every state is a value that can be serialised to `workflow_state.json`
/// so that an app interruption (background kill, crash, user cancel) never
/// loses the product chain position. The coordinator drives transitions
/// strictly through this state; no module writes a state directly.
enum MobileOnlyWorkflowState: String, Codable, Equatable, CaseIterable {
    case idle
    case pickingMap
    case stagingMapSource
    case importingMap
    case compilingMap
    case mapReady
    case configuringScan
    case scanning
    case finalizingScan
    case snapshotting
    case fastProcessing
    case deepProcessing
    case buildingTrajectory
    case resolvingTags
    case exporting
    case completed
    case failed
    case cancelled
    case interrupted

    /// States that can be resumed after an app relaunch.
    var isResumable: Bool {
        switch self {
        case .completed, .failed, .cancelled, .idle:
            return false
        case .interrupted:
            return true
        default:
            return true
        }
    }

    /// Human readable (localized) label for UI.
    var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .pickingMap: return "选择地图文件"
        case .stagingMapSource: return "安全暂存地图"
        case .importingMap: return "解析地图"
        case .compilingMap: return "编译地图"
        case .mapReady: return "地图就绪"
        case .configuringScan: return "配置扫描"
        case .scanning: return "扫描中"
        case .finalizingScan: return "结束扫描"
        case .snapshotting: return "生成会话快照"
        case .fastProcessing: return "快速处理"
        case .deepProcessing: return "深度处理"
        case .buildingTrajectory: return "构建轨迹"
        case .resolvingTags: return "解析价签"
        case .exporting: return "导出结果"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断"
        }
    }
}
