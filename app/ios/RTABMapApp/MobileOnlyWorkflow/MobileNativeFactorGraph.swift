import Foundation

/// App-side wiring of the shared native MarketScanner factor-graph core
/// (V1R2 Gate G §11 / Gate H §12). The core itself lives in
/// `core/MarketScannerFactorGraph` and is compiled directly into this
/// app target and into the PC diagnostic CLI — one implementation, two
/// surfaces.
///
/// `wireIntoGateway()` is called once at startup; afterwards the
/// processing pipeline reaches the native core only through
/// `MobileNativeFactorGraphGateway`.
enum MobileNativeFactorGraph {

    static func wireIntoGateway() {
        MobileNativeFactorGraphGateway.runFastImplementation = { databaseURL, tagNodeIDs, maxWallSeconds, isCancelled in
            return try run(
                databaseURL: databaseURL,
                tagNodeIDs: tagNodeIDs,
                deep: false,
                maxWallSeconds: maxWallSeconds,
                isCancelled: isCancelled)
        }
        MobileNativeFactorGraphGateway.runDeepImplementation = { databaseURL, tagNodeIDs, maxWallSeconds, isCancelled in
            return try run(
                databaseURL: databaseURL,
                tagNodeIDs: tagNodeIDs,
                deep: true,
                maxWallSeconds: maxWallSeconds,
                isCancelled: isCancelled)
        }
    }

    // MARK: - C ABI bridge

    private static func run(
        databaseURL: URL,
        tagNodeIDs: [Int64],
        deep: Bool,
        maxWallSeconds: Double,
        isCancelled: @escaping () -> Bool
    ) throws -> MobileNativeGraphOutcome {
        let context = MSNativeFactorGraphRunContext(isCancelled: isCancelled)
        let contextPointer = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<MSNativeFactorGraphRunContext>.fromOpaque(contextPointer).release() }

        var request = MSFactorGraphRequestC(
            db_path: databaseURL.path,
            tag_node_ids: tagNodeIDs.isEmpty ? nil : tagNodeIDs,
            tag_node_count: Int64(tagNodeIDs.count),
            max_nodes: 0,
            max_wall_seconds: maxWallSeconds,
            fast_iterations: 0,
            deep_iterations: 0,
            cancel: msNativeFactorGraphCancelProbe,
            cancel_user: contextPointer,
            progress: nil,
            progress_user: nil)

        var outcome = deep
            ? MSFactorGraphRunDeep(&request)
            : MSFactorGraphRunFast(&request)
        defer { MSFactorGraphFree(&outcome) }

        // Cancellation first: the native core reports it through the
        // error string, and the run must surface `.cancelled`, not a
        // generic failure (V1R2 review fix).
        if context.cancelledFlag {
            throw MobileOnlyWorkflowError.cancelled
        }
        if let error = outcome.error {
            throw MobileNativeFactorGraphError.nativeFailed(String(cString: error))
        }

        let qualityJSON: String
        if let json = outcome.quality_json {
            qualityJSON = String(cString: json)
        } else {
            qualityJSON = ""
        }

        var trajectory: [MobileNativeTrajectoryRow] = []
        trajectory.reserveCapacity(Int(outcome.count))
        if outcome.count > 0,
           let ids = outcome.ids, let stamps = outcome.stamps,
           let xs = outcome.x, let ys = outcome.y, let yaws = outcome.yaw {
            for index in 0..<Int(outcome.count) {
                trajectory.append(MobileNativeTrajectoryRow(
                    id: ids[index],
                    stamp: stamps[index],
                    xM: xs[index],
                    yM: ys[index],
                    yawRad: yaws[index]))
            }
        }

        var skeletonIDs: [Int64] = []
        if outcome.skeleton_count > 0, let ids = outcome.skeleton_ids {
            skeletonIDs.reserveCapacity(Int(outcome.skeleton_count))
            for index in 0..<Int(outcome.skeleton_count) {
                skeletonIDs.append(ids[index])
            }
        }

        return MobileNativeGraphOutcome(
            disposition: MobileGraphDisposition(rawValue: outcome.disposition) ?? .nonRecoverableFail,
            qualityJSON: qualityJSON,
            trajectory: trajectory,
            skeletonIDs: skeletonIDs)
    }
}

/// Bridges cancellation state across the C ABI. File-private top-level
/// type so the free-function C probe below can reference it.
private final class MSNativeFactorGraphRunContext {
    var isCancelled: () -> Bool
    var cancelledFlag = false

    init(isCancelled: @escaping () -> Bool) {
        self.isCancelled = isCancelled
    }
}

/// Free-function C cancellation probe (a C function pointer can only be
/// formed from a free `func` reference, not a static method).
private func msNativeFactorGraphCancelProbe(_ user: UnsafeMutableRawPointer?) -> Int32 {
    guard let user = user else { return 0 }
    let context = Unmanaged<MSNativeFactorGraphRunContext>.fromOpaque(user).takeUnretainedValue()
    if context.isCancelled() {
        context.cancelledFlag = true
        return 1
    }
    return 0
}
