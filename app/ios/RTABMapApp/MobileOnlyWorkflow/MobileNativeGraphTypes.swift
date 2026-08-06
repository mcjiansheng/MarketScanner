import Foundation

/// Native factor-graph product types and the gateway seam (V1R2 Gate G,
/// V1R3 evidence-integrity closeout).
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
    /// Solved in the local frame only: no accepted prior-map absolute
    /// constraint anchors the graph to the map (V1R3 §6.4). Diagnostics
    /// only — never publishable.
    case localFrameOnly = 4

    var reportValue: String {
        switch self {
        case .pass: return "PASS"
        case .recoverableFail: return "RECOVERABLE_FAIL"
        case .nonRecoverableFail: return "NON_RECOVERABLE_FAIL"
        case .resourceRequired: return "RESOURCE_REQUIRED"
        case .localFrameOnly: return "LOCAL_FRAME_ONLY"
        }
    }
}

/// Absolute prior-map constraint (V1R3 §6.3): the node pose expressed in
/// the PRIOR-MAP frame (T_map_node) with policy-sourced information.
struct MobileAbsolutePrior {
    var nodeID: Int64
    var mapXM: Double
    var mapYM: Double
    var mapYawRad: Double
    /// Row-major 3x3 planar information.
    var information3x3: [Double]
    /// 0 localization, 1 recovery, 2 manual.
    var kind: Int32
    var episodeID: Int64
}

/// One reconstructed trajectory row (V1R3 §15): component and floor
/// identity travel with every node; uncertainty is nil when it cannot be
/// estimated (never fabricated as 0).
struct MobileNativeTrajectoryRow {
    var id: Int64
    var stamp: Double
    var xM: Double
    var yM: Double
    var yawRad: Double
    var mapID: Int32
    var componentID: Int64
    var publishEligible: Bool
    var uncertaintyM: Double?
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
    /// The C outcome failed validation (§9.2) — never trust unvalidated
    /// native memory.
    case invalidOutcome(String)

    var errorDescription: String? {
        switch self {
        case .nativeFailed(let detail): return "原生因子图求解失败：\(detail)"
        case .notWired: return "原生因子图核心尚未接线"
        case .invalidOutcome(let detail): return "原生结果校验失败：\(detail)"
        }
    }
}

/// Run request for the gateway (§6.1): identity bindings and accepted
/// absolute priors are mandatory inputs, never just DB + tag IDs.
struct MobileNativeGraphRequest {
    var databaseURL: URL
    var tagNodeIDs: [Int64]
    var absolutePriors: [MobileAbsolutePrior]
    var priorMapID: String
    var priorMapSHA256: String
    var trackingSessionID: String
    var projectionPolicyVersion: Int32
    var maxWallSeconds: Double
}

enum MobileNativeFactorGraphGateway {

    /// Signature shared by Fast/full-graph implementations.
    typealias RunImplementation = (
        _ request: MobileNativeGraphRequest,
        _ isCancelled: @escaping () -> Bool
    ) throws -> MobileNativeGraphOutcome

    /// Wired implementations. The app assigns the native-core closures
    /// at startup (`MobileNativeFactorGraph.wireIntoGateway()`); host
    /// tests assign a reference implementation before running.
    static var runFastImplementation: RunImplementation?
    /// Full-graph optimization (§13.1) — NOT a sensor reprocess.
    static var runFullGraphImplementation: RunImplementation?

    /// Fast Path (§2).
    static func runFast(
        request: MobileNativeGraphRequest,
        isCancelled: @escaping () -> Bool
    ) throws -> MobileNativeGraphOutcome {
        guard let implementation = runFastImplementation else {
            throw MobileNativeFactorGraphError.notWired
        }
        return try implementation(request, isCancelled)
    }

    /// Full-graph optimization. The pipeline calls this AT MOST once and
    /// only after a Fast RECOVERABLE_FAIL whose recovery policy allows
    /// it (§13.3).
    static func runFullGraph(
        request: MobileNativeGraphRequest,
        isCancelled: @escaping () -> Bool
    ) throws -> MobileNativeGraphOutcome {
        guard let implementation = runFullGraphImplementation else {
            throw MobileNativeFactorGraphError.notWired
        }
        return try implementation(request, isCancelled)
    }
}
