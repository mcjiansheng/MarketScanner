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

    /// V1R2 §5.4: explicit transition table. The coordinator drives every
    /// state change through `allowsTransition(to:)`; an illegal transition
    /// is a typed error and never silently applied.
    var allowedNextStates: Set<MobileOnlyWorkflowState> {
        switch self {
        case .idle:
            return [.pickingMap, .configuringScan, .snapshotting, .interrupted]
        case .pickingMap:
            return [.stagingMapSource, .importingMap, .idle, .failed, .cancelled, .interrupted]
        case .stagingMapSource:
            return [.importingMap, .idle, .failed, .cancelled, .interrupted]
        case .importingMap:
            return [.compilingMap, .failed, .cancelled, .interrupted]
        case .compilingMap:
            return [.mapReady, .failed, .cancelled, .interrupted]
        case .mapReady:
            return [.configuringScan, .idle, .pickingMap, .interrupted]
        case .configuringScan:
            return [.scanning, .idle, .failed, .interrupted]
        case .scanning:
            return [.finalizingScan, .cancelled, .failed, .interrupted]
        case .finalizingScan:
            return [.snapshotting, .idle, .failed, .interrupted]
        case .snapshotting:
            return [.fastProcessing, .failed, .cancelled, .interrupted]
        case .fastProcessing:
            return [.deepProcessing, .buildingTrajectory, .failed, .cancelled, .interrupted]
        case .deepProcessing:
            return [.buildingTrajectory, .failed, .cancelled, .interrupted]
        case .buildingTrajectory:
            return [.resolvingTags, .failed, .cancelled, .interrupted]
        case .resolvingTags:
            return [.exporting, .failed, .cancelled, .interrupted]
        case .exporting:
            return [.completed, .failed, .cancelled, .interrupted]
        case .completed:
            return [.idle, .pickingMap, .configuringScan, .snapshotting]
        case .failed:
            return [.idle, .pickingMap, .configuringScan, .snapshotting]
        case .cancelled:
            return [.idle, .pickingMap, .configuringScan, .snapshotting]
        case .interrupted:
            return [.idle, .pickingMap, .configuringScan, .snapshotting]
        }
    }

    func allowsTransition(to next: MobileOnlyWorkflowState) -> Bool {
        return allowedNextStates.contains(next)
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
        // V1R4 §17 Gate N freeze: V1 has no true sensor Deep on device;
        // the deep stage is a controlled full-graph recovery only.
        case .deepProcessing: return "全图优化"
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
