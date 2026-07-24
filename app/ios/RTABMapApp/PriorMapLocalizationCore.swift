//
//  PriorMapLocalizationCore.swift
//  RTABMapApp
//
//  Platform-neutral stage-one workflow and SE(2) projection contract.
//

import Foundation

enum ScanWorkflowMode: String, Codable {
    case freeMapping = "free_mapping"
    case priorMapLocalized = "prior_map_localized"
}

struct PriorMapPose2D: Codable, Equatable {
    var xM: Double
    var yM: Double
    var yawRad: Double

    enum CodingKeys: String, CodingKey {
        case xM = "x_m"
        case yM = "y_m"
        case yawRad = "yaw_rad"
    }
}

struct PriorMapScanConfiguration: Codable {
    let formatVersion: Int
    let workflowMode: ScanWorkflowMode
    let packageDirectory: URL?
    let priorMapId: String?
    let priorMapSha256: String?
    let floorId: String?
    let initialMapPose: PriorMapPose2D?

    static let freeMapping = PriorMapScanConfiguration(
        formatVersion: 1,
        workflowMode: .freeMapping,
        packageDirectory: nil,
        priorMapId: nil,
        priorMapSha256: nil,
        floorId: nil,
        initialMapPose: nil)

    var isReadyToStart: Bool {
        switch workflowMode {
        case .freeMapping:
            return true
        case .priorMapLocalized:
            return packageDirectory != nil
                && !(priorMapId ?? "").isEmpty
                && !(priorMapSha256 ?? "").isEmpty
                && !(floorId ?? "").isEmpty
                && initialMapPose != nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case workflowMode
        case packageDirectory
        case priorMapId
        case priorMapSha256
        case floorId
        case initialMapPose
    }

    init(
        formatVersion: Int,
        workflowMode: ScanWorkflowMode,
        packageDirectory: URL?,
        priorMapId: String?,
        priorMapSha256: String?,
        floorId: String?,
        initialMapPose: PriorMapPose2D?
    ) {
        self.formatVersion = formatVersion
        self.workflowMode = workflowMode
        self.packageDirectory = packageDirectory
        self.priorMapId = priorMapId
        self.priorMapSha256 = priorMapSha256
        self.floorId = floorId
        self.initialMapPose = initialMapPose
    }
}

enum PriorMapStageOneMath {
    /// Convert ARKit's right-handed x/y/z world frame to the map's horizontal
    /// SE(2) frame. ARKit +x is map +x, ARKit -z is map +y, and map yaw zero
    /// points toward +y. Positive yaw turns counter-clockwise in map space.
    ///
    /// ARKit position y is deliberately absent: a scan is bound to one floor,
    /// and small height changes within that floor do not affect 2D location.
    static func arkitHorizontalPose(
        positionX: Double,
        positionZ: Double,
        forwardX: Double,
        forwardZ: Double
    ) -> PriorMapPose2D {
        return PriorMapPose2D(
            xM: positionX,
            yM: -positionZ,
            yawRad: normalizeAngle(atan2(-forwardX, -forwardZ)))
    }

    static func project(
        arkitPose: PriorMapPose2D,
        arkitOrigin: PriorMapPose2D,
        initialMapPose: PriorMapPose2D
    ) -> PriorMapPose2D {
        let rotation = initialMapPose.yawRad - arkitOrigin.yawRad
        let dx = arkitPose.xM - arkitOrigin.xM
        let dy = arkitPose.yM - arkitOrigin.yM
        let cosine = cos(rotation)
        let sine = sin(rotation)
        return PriorMapPose2D(
            xM: initialMapPose.xM + cosine * dx - sine * dy,
            yM: initialMapPose.yM + sine * dx + cosine * dy,
            yawRad: normalizeAngle(arkitPose.yawRad + rotation))
    }

    static func normalizeAngle(_ value: Double) -> Double {
        return atan2(sin(value), cos(value))
    }
}

enum PriorMapUpdateDecision: Equatable {
    case accepted(ticket: Int)
    case throttled
    case busy(droppedCount: Int)
}

/// Thread-safe latest-frame gate. At most one update may execute at a time;
/// stale completions from a previous/reset generation cannot release a newer
/// update.
final class PriorMapUpdateGate {
    private let minimumInterval: TimeInterval
    private let lock = NSLock()
    private var lastAcceptedTimestamp = -TimeInterval.infinity
    private var activeTicket: Int?
    private var nextTicket = 0
    private var droppedCount = 0

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = max(0, minimumInterval)
    }

    func begin(timestamp: TimeInterval) -> PriorMapUpdateDecision {
        lock.lock()
        defer { lock.unlock() }
        if timestamp - lastAcceptedTimestamp < minimumInterval {
            return .throttled
        }
        if activeTicket != nil {
            droppedCount += 1
            return .busy(droppedCount: droppedCount)
        }
        nextTicket += 1
        activeTicket = nextTicket
        lastAcceptedTimestamp = timestamp
        return .accepted(ticket: nextTicket)
    }

    func finish(ticket: Int) {
        lock.lock()
        if activeTicket == ticket {
            activeTicket = nil
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        nextTicket += 1
        activeTicket = nil
        lastAcceptedTimestamp = -TimeInterval.infinity
        droppedCount = 0
        lock.unlock()
    }
}
