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

/// A global SE(2) transform from the persistent ARKit world frame into the
/// prior-map frame. Unlike a body-local translation correction, this value is
/// invariant while the device turns or moves under one valid alignment.
struct PriorMapAlignmentTransform: Equatable {
    var translationXM: Double
    var translationYM: Double
    var yawRad: Double
}

enum PriorMapAlignmentMath {
    static func mapFromArkit(
        arkitPose: PriorMapPose2D,
        candidateMapPose: PriorMapPose2D
    ) -> PriorMapAlignmentTransform {
        let yaw = PriorMapStageOneMath.normalizeAngle(
            candidateMapPose.yawRad - arkitPose.yawRad)
        let cosine = cos(yaw)
        let sine = sin(yaw)
        return PriorMapAlignmentTransform(
            translationXM: candidateMapPose.xM
                - (cosine * arkitPose.xM - sine * arkitPose.yM),
            translationYM: candidateMapPose.yM
                - (sine * arkitPose.xM + cosine * arkitPose.yM),
            yawRad: yaw)
    }

    static func apply(
        mapFromArkit: PriorMapAlignmentTransform,
        arkitPose: PriorMapPose2D
    ) -> PriorMapPose2D {
        let cosine = cos(mapFromArkit.yawRad)
        let sine = sin(mapFromArkit.yawRad)
        return PriorMapPose2D(
            xM: mapFromArkit.translationXM
                + cosine * arkitPose.xM - sine * arkitPose.yM,
            yM: mapFromArkit.translationYM
                + sine * arkitPose.xM + cosine * arkitPose.yM,
            yawRad: PriorMapStageOneMath.normalizeAngle(
                arkitPose.yawRad + mapFromArkit.yawRad))
    }

    static func interpolate(
        from current: PriorMapAlignmentTransform,
        to observed: PriorMapAlignmentTransform,
        gain: Double
    ) -> PriorMapAlignmentTransform {
        let boundedGain = min(1, max(0, gain))
        return PriorMapAlignmentTransform(
            translationXM: current.translationXM * (1 - boundedGain)
                + observed.translationXM * boundedGain,
            translationYM: current.translationYM * (1 - boundedGain)
                + observed.translationYM * boundedGain,
            yawRad: PriorMapStageOneMath.normalizeAngle(
                current.yawRad
                    + PriorMapStageOneMath.normalizeAngle(
                        observed.yawRad - current.yawRad) * boundedGain))
    }
}

enum PriorMapCorrectionSafety {
    static let localTranslationLimitM = 0.35
    static let localYawLimitRad = 8.0 * Double.pi / 180.0
    static let recoveryTranslationLimitM = 5.0
    static let recoveryYawLimitRad = 30.0 * Double.pi / 180.0
    static let stepGain = 0.35
    static let maximumStepTranslationM = 0.35
    static let maximumStepYawRad = 8.0 * Double.pi / 180.0

    static func difference(
        from current: PriorMapPose2D,
        to target: PriorMapPose2D
    ) -> (translationM: Double, yawRad: Double) {
        return (
            hypot(target.xM - current.xM, target.yM - current.yM),
            abs(PriorMapStageOneMath.normalizeAngle(
                target.yawRad - current.yawRad)))
    }

    static func isWithinGate(
        current: PriorMapPose2D,
        target: PriorMapPose2D,
        recoverySearch: Bool
    ) -> Bool {
        let delta = difference(from: current, to: target)
        let translationLimit = recoverySearch
            ? recoveryTranslationLimitM : localTranslationLimitM
        let yawLimit = recoverySearch ? recoveryYawLimitRad : localYawLimitRad
        return delta.translationM <= translationLimit && delta.yawRad <= yawLimit
    }

    static func boundedStep(
        current: PriorMapPose2D,
        target: PriorMapPose2D
    ) -> PriorMapPose2D {
        let deltaX = (target.xM - current.xM) * stepGain
        let deltaY = (target.yM - current.yM) * stepGain
        let deltaLength = hypot(deltaX, deltaY)
        let scale = deltaLength > maximumStepTranslationM
            ? maximumStepTranslationM / deltaLength : 1.0
        let yawStep = max(
            -maximumStepYawRad,
            min(
                maximumStepYawRad,
                PriorMapStageOneMath.normalizeAngle(
                    target.yawRad - current.yawRad) * stepGain))
        return PriorMapPose2D(
            xM: current.xM + deltaX * scale,
            yM: current.yM + deltaY * scale,
            yawRad: PriorMapStageOneMath.normalizeAngle(
                current.yawRad + yawStep))
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

enum PriorMapRecoveryOutcome: String, Equatable {
    case converged
    case timedOut = "timed_out"
    case cancelled
    case manualReset = "manual_reset"
}

struct PriorMapRecoveryEpisode: Equatable {
    let id: Int
    let reason: String
    let startedAtUptime: TimeInterval
    let deadlineUptime: TimeInterval
    let maximumValidAttempts: Int
    var validMatcherAttempts: Int
    var acceptedCorrections: Int
    var triggerCount: Int

    var remainingValidAttempts: Int {
        max(0, maximumValidAttempts - validMatcherAttempts)
    }
}

struct PriorMapRecoveryCompletion: Equatable {
    let episode: PriorMapRecoveryEpisode
    let outcome: PriorMapRecoveryOutcome
}

/// Owns the bounded lifetime of one Recovery search. Frame availability is
/// deliberately outside this type: callers record an attempt only after the
/// matcher received its minimum valid input and actually searched the map.
final class PriorMapRecoveryController {
    private let maximumValidAttempts: Int
    private let maximumWallClockSeconds: TimeInterval
    private let maximumTriggerCount: Int
    private var nextEpisodeId = 1

    private(set) var activeEpisode: PriorMapRecoveryEpisode?
    private(set) var lastCompletion: PriorMapRecoveryCompletion?

    init(
        maximumValidAttempts: Int = 40,
        maximumWallClockSeconds: TimeInterval = 30,
        maximumTriggerCount: Int = 100
    ) {
        self.maximumValidAttempts = max(32, maximumValidAttempts)
        self.maximumWallClockSeconds = max(1, maximumWallClockSeconds)
        self.maximumTriggerCount = max(1, maximumTriggerCount)
    }

    /// Returns true only for the inactive -> active transition. Repeated loop
    /// closures retain the episode ID, deadline, attempts, and fresh support.
    @discardableResult
    func request(reason: String, now: TimeInterval) -> Bool {
        if var episode = activeEpisode {
            episode.triggerCount = min(
                maximumTriggerCount,
                episode.triggerCount + 1)
            activeEpisode = episode
            return false
        }
        activeEpisode = PriorMapRecoveryEpisode(
            id: nextEpisodeId,
            reason: reason,
            startedAtUptime: now,
            deadlineUptime: now + maximumWallClockSeconds,
            maximumValidAttempts: maximumValidAttempts,
            validMatcherAttempts: 0,
            acceptedCorrections: 0,
            triggerCount: 1)
        nextEpisodeId += 1
        lastCompletion = nil
        return true
    }

    /// Records one real search, including ambiguous and mismatch results. The
    /// caller must not invoke this for nil/undersized observations.
    @discardableResult
    func recordValidMatcherAttempt() -> Bool {
        guard var episode = activeEpisode,
              episode.remainingValidAttempts > 0 else {
            return false
        }
        episode.validMatcherAttempts += 1
        activeEpisode = episode
        return true
    }

    func recordAcceptedCorrection() {
        guard var episode = activeEpisode else { return }
        episode.acceptedCorrections += 1
        activeEpisode = episode
    }

    func isExpired(now: TimeInterval) -> Bool {
        guard let episode = activeEpisode else { return false }
        return now >= episode.deadlineUptime
            || episode.remainingValidAttempts == 0
    }

    @discardableResult
    func finish(_ outcome: PriorMapRecoveryOutcome) -> PriorMapRecoveryCompletion? {
        guard let episode = activeEpisode else { return nil }
        let completion = PriorMapRecoveryCompletion(
            episode: episode,
            outcome: outcome)
        activeEpisode = nil
        lastCompletion = completion
        return completion
    }
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
