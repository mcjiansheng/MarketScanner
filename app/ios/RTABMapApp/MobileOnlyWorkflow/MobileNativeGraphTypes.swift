import Foundation

/// Native factor-graph product types and the gateway seam (V1R2 Gate G).
///
/// `MobileNativeFactorGraphGateway` is the ONLY entry point the
/// processing pipeline uses. The real app wires the shared native
/// factor-graph core (compiled from `core/MarketScannerFactorGraph`) at
/// startup; the Swift host suite wires a deterministic reference
/// implementation so pipeline orchestration stays testable without the
/// C bridge. Production runs always use the native core — the Swift
/// `SE2FactorGraphCore` solver is a host-test reference only (§11.5).
enum MobileGraphDisposition: Int32 {
    case pass = 0
    case recoverableFail = 1
    case nonRecoverableFail = 2
    case resourceRequired = 3

    var reportValue: String {
        switch self {
        case .pass: return "PASS"
        case .recoverableFail: return "RECOVERABLE_FAIL"
        case .nonRecoverableFail: return "NON_RECOVERABLE_FAIL"
        case .resourceRequired: return "RESOURCE_REQUIRED"
        }
    }
}

struct MobileNativeTrajectoryRow {
    var id: Int64
    var stamp: Double
    var xM: Double
    var yM: Double
    var yawRad: Double
}

struct MobileNativeGraphOutcome {
    var disposition: MobileGraphDisposition
    var qualityJSON: String
    var trajectory: [MobileNativeTrajectoryRow]
    var skeletonIDs: [Int64]
}

enum MobileNativeFactorGraphError: Error, LocalizedError {
    case nativeFailed(String)
    case notWired

    var errorDescription: String? {
        switch self {
        case .nativeFailed(let detail): return "原生因子图求解失败：\(detail)"
        case .notWired: return "原生因子图核心尚未接线"
        }
    }
}

enum MobileNativeFactorGraphGateway {

    /// Signature shared by Fast/Deep implementations.
    typealias RunImplementation = (
        _ databaseURL: URL,
        _ tagNodeIDs: [Int64],
        _ maxWallSeconds: Double,
        _ isCancelled: @escaping () -> Bool
    ) throws -> MobileNativeGraphOutcome

    /// Wired implementations. The app assigns the native-core closures
    /// at startup (`MobileNativeFactorGraph.wireIntoGateway()`); host
    /// tests assign a reference implementation before running.
    static var runFastImplementation: RunImplementation?
    static var runDeepImplementation: RunImplementation?

    /// Fast Path (§2): real graph health → adaptive skeleton → robust
    /// native SE(2) optimization → quality gate → full trajectory.
    static func runFast(
        databaseURL: URL,
        tagNodeIDs: [Int64],
        maxWallSeconds: Double = 600,
        isCancelled: @escaping () -> Bool
    ) throws -> MobileNativeGraphOutcome {
        guard let implementation = runFastImplementation else {
            throw MobileNativeFactorGraphError.notWired
        }
        return try implementation(databaseURL, tagNodeIDs, maxWallSeconds, isCancelled)
    }

    /// Deep Path (§12): resource-controlled full-graph rebuild. The
    /// pipeline calls this AT MOST once and only after a Fast
    /// RECOVERABLE_FAIL.
    static func runDeep(
        databaseURL: URL,
        tagNodeIDs: [Int64],
        maxWallSeconds: Double = 1800,
        isCancelled: @escaping () -> Bool
    ) throws -> MobileNativeGraphOutcome {
        guard let implementation = runDeepImplementation else {
            throw MobileNativeFactorGraphError.notWired
        }
        return try implementation(databaseURL, tagNodeIDs, maxWallSeconds, isCancelled)
    }
}
