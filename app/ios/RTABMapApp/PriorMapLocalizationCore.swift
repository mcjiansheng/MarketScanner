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

/// Owns the only mutable map/ARKit alignment anchor used by Stage One.
/// Recovery hypothesis tracks may be cleared at any episode boundary without
/// moving this anchor or reverting to a historical hypothesis.
final class PriorMapLocalizationAnchor {
    private(set) var arkitOrigin: PriorMapPose2D?
    private(set) var initialMapPose: PriorMapPose2D

    init(initialMapPose: PriorMapPose2D) {
        self.initialMapPose = initialMapPose
    }

    func project(arkitPose: PriorMapPose2D) -> PriorMapPose2D {
        if arkitOrigin == nil {
            arkitOrigin = arkitPose
        }
        return PriorMapStageOneMath.project(
            arkitPose: arkitPose,
            arkitOrigin: arkitOrigin!,
            initialMapPose: initialMapPose)
    }

    func retainAppliedCorrection(
        arkitPose: PriorMapPose2D,
        estimatedMapPose: PriorMapPose2D
    ) {
        arkitOrigin = arkitPose
        initialMapPose = estimatedMapPose
    }
}

enum PriorMapUpdateDecision: Equatable {
    case accepted(ticket: Int)
    case throttled
    case busy(droppedCount: Int)
}

enum PriorMapRecoveryFrameDisposition: String, Equatable {
    case trackingLimited = "tracking_limited"
    case noDepth = "no_depth"
    case observationUnavailable = "observation_unavailable"
    case insufficientPoints = "insufficient_points"
    case busy
    case throttled
    case searched

    var searchPerformed: Bool {
        self == .searched
    }
}

extension PriorMapUpdateDecision {
    var recoveryFrameDisposition: PriorMapRecoveryFrameDisposition? {
        switch self {
        case .accepted:
            return nil
        case .throttled:
            return .throttled
        case .busy:
            return .busy
        }
    }
}

enum PriorMapRecoveryOutcome: String, Equatable {
    case converged
    case timedOut = "timed_out"
    case cancelled
    case manualReset = "manual_reset"
}

protocol PriorMapMonotonicClock {
    var now: TimeInterval { get }
}

struct PriorMapSystemMonotonicClock: PriorMapMonotonicClock {
    var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

enum PriorMapConstraintDisposition: String, Codable, Equatable {
    case rejected
    case provisionalRecoveryStep = "provisional_recovery_step"
    case acceptedLocal = "accepted_local"
    case acceptedRecoveryConvergence = "accepted_recovery_convergence"
}

struct PriorMapRecoveryDecisionInput: Equatable {
    let recoveryActive: Bool
    let hypothesisTrusted: Bool
    let geometryAndSafetyAccepted: Bool
    let residualTranslationM: Double
    let residualYawRad: Double
    let wallClockExpired: Bool
}

struct PriorMapRecoveryDecision: Equatable {
    let measurementAccepted: Bool
    let hypothesisTrusted: Bool
    let correctionStepApplied: Bool
    let recoveryConvergedThisUpdate: Bool
    let confidenceAccepted: Bool
    let constraintDisposition: PriorMapConstraintDisposition
}

/// The single production/test decision point that separates accepting a scan
/// measurement, applying one bounded anchor step, and accepting localization
/// as confidence-bearing evidence.
enum PriorMapRecoveryDecisionEngine {
    static let convergenceTranslationM = 0.5
    static let convergenceYawRad = 10.0 * Double.pi / 180.0

    static func evaluate(
        _ input: PriorMapRecoveryDecisionInput
    ) -> PriorMapRecoveryDecision {
        let accepted = input.hypothesisTrusted
            && input.geometryAndSafetyAccepted
            && !input.wallClockExpired
        guard accepted else {
            return PriorMapRecoveryDecision(
                measurementAccepted: false,
                hypothesisTrusted: input.hypothesisTrusted,
                correctionStepApplied: false,
                recoveryConvergedThisUpdate: false,
                confidenceAccepted: false,
                constraintDisposition: .rejected)
        }
        guard input.recoveryActive else {
            return PriorMapRecoveryDecision(
                measurementAccepted: true,
                hypothesisTrusted: true,
                correctionStepApplied: true,
                recoveryConvergedThisUpdate: false,
                confidenceAccepted: true,
                constraintDisposition: .acceptedLocal)
        }
        let converged = input.residualTranslationM <= convergenceTranslationM
            && input.residualYawRad <= convergenceYawRad
        return PriorMapRecoveryDecision(
            measurementAccepted: true,
            hypothesisTrusted: true,
            correctionStepApplied: true,
            recoveryConvergedThisUpdate: converged,
            confidenceAccepted: converged,
            constraintDisposition: converged
                ? .acceptedRecoveryConvergence
                : .provisionalRecoveryStep)
    }
}

enum PriorMapRecoveryUpdateAction: String, Equatable {
    case none
    case converged
    case timedOut = "timed_out"
}

struct PriorMapRecoveryUpdateInput {
    let timestamp: TimeInterval
    let preMatchNow: TimeInterval
    let postMatchNow: TimeInterval
    let recoveryWasActiveAtUpdateStart: Bool
    let recoveryActiveForMatch: Bool
    let pendingCompletionOutcome: PriorMapRecoveryOutcome?
    let frameDisposition: PriorMapRecoveryFrameDisposition
    let hypothesisTrusted: Bool
    let geometryAndSafetyAccepted: Bool
    let residualTranslationM: Double
    let residualYawRad: Double
    let trackingState: String
    let validPointCount: Int
    let coverageAngleRad: Double
    let uniqueness: Double
    let residualCost: Double
    let mapMismatch: Bool
}

struct PriorMapRecoveryUpdateOutput {
    let decision: PriorMapRecoveryDecision
    let action: PriorMapRecoveryUpdateAction
    let nextConfidence: PriorMapConfidenceResult
    let reason: String
    let searchedAttemptRecorded: Bool
    let recoveryFailedThisUpdate: Bool

    var finalConstraintAccepted: Bool {
        decision.constraintDisposition == .acceptedLocal
            || decision.constraintDisposition == .acceptedRecoveryConvergence
    }
}

/// Production-shared Recovery/Local update reducer. It is the only place that
/// joins frame disposition, monotonic expiry, attempt exhaustion, correction
/// acceptance, Recovery action, next confidence phase, and audit reason.
enum PriorMapRecoveryUpdateReducer {
    static func reduce(
        _ input: PriorMapRecoveryUpdateInput,
        recoveryController: PriorMapRecoveryController,
        confidenceManager: PriorMapConfidenceManager
    ) -> PriorMapRecoveryUpdateOutput {
        let expiredBeforeMatch = input.recoveryActiveForMatch
            && recoveryController.isWallClockExpired(now: input.preMatchNow)
        let attemptRecorded = input.recoveryActiveForMatch
            && !expiredBeforeMatch
            && recoveryController.recordFrameDisposition(input.frameDisposition)
        let expiredAfterMatch = input.recoveryActiveForMatch
            && recoveryController.isWallClockExpired(now: input.postMatchNow)
        var decision = PriorMapRecoveryDecisionEngine.evaluate(
            PriorMapRecoveryDecisionInput(
                recoveryActive: input.recoveryActiveForMatch,
                hypothesisTrusted: input.hypothesisTrusted,
                geometryAndSafetyAccepted: input.geometryAndSafetyAccepted,
                residualTranslationM: input.residualTranslationM,
                residualYawRad: input.residualYawRad,
                wallClockExpired: expiredBeforeMatch || expiredAfterMatch))
        var action: PriorMapRecoveryUpdateAction = .none
        var reason = decision.constraintDisposition.rawValue
        if expiredBeforeMatch {
            action = .timedOut
            reason = "recovery_timed_out_before_match"
        }
        else if expiredAfterMatch {
            action = .timedOut
            reason = "recovery_timed_out_after_match_deadline"
        }
        else if decision.recoveryConvergedThisUpdate {
            action = .converged
            reason = "recovery_converged"
        }
        else if input.recoveryActiveForMatch,
                recoveryController.activeEpisode?.remainingValidAttempts == 0 {
            action = .timedOut
            decision = PriorMapRecoveryDecision(
                measurementAccepted: decision.measurementAccepted,
                hypothesisTrusted: decision.hypothesisTrusted,
                correctionStepApplied: decision.correctionStepApplied,
                recoveryConvergedThisUpdate: false,
                confidenceAccepted: false,
                constraintDisposition: decision.correctionStepApplied
                    ? .provisionalRecoveryStep : .rejected)
            reason = decision.correctionStepApplied
                ? "recovery_timed_out_after_bounded_step"
                : "recovery_timed_out_attempt_budget"
        }
        let recoveryFailed = action == .timedOut
            || input.pendingCompletionOutcome.map { $0 != .converged } == true
        let recoveryConverged = decision.recoveryConvergedThisUpdate
            || input.pendingCompletionOutcome == .converged
        let confidence = confidenceManager.update(
            timestamp: input.timestamp,
            observation: PriorMapConfidenceObservation(
                trackingState: input.trackingState,
                measurementAccepted: decision.measurementAccepted,
                correctionStepApplied: decision.correctionStepApplied,
                recoveryActive: (input.recoveryActiveForMatch
                    || input.recoveryWasActiveAtUpdateStart)
                    && action == .none
                    && !recoveryConverged,
                recoveryConvergedThisUpdate: recoveryConverged,
                recoveryFailedThisUpdate: recoveryFailed,
                recoveryCooldownActive: recoveryController
                    .isAutomaticTriggerSuppressed(now: input.postMatchNow),
                validPointCount: input.validPointCount,
                coverageAngleRad: input.coverageAngleRad,
                uniqueness: input.uniqueness,
                residualCost: input.residualCost,
                mapMismatch: input.mapMismatch))
        return PriorMapRecoveryUpdateOutput(
            decision: decision,
            action: action,
            nextConfidence: confidence,
            reason: reason,
            searchedAttemptRecorded: attemptRecorded,
            recoveryFailedThisUpdate: recoveryFailed)
    }
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
    let automatic: Bool

    var remainingValidAttempts: Int {
        max(0, maximumValidAttempts - validMatcherAttempts)
    }
}

struct PriorMapRecoveryCompletion: Equatable {
    let episode: PriorMapRecoveryEpisode
    let outcome: PriorMapRecoveryOutcome
    let finishedAtUptime: TimeInterval
    let selectedHypothesisId: Int?
    let finalFreshSupportFrames: Int
    let finalResidualTranslationM: Double?
    let finalResidualYawRad: Double?
    let correctionStepAppliedOnCompletionFrame: Bool
}

struct PriorMapHypothesisTraceBinding: Equatable {
    let currentHypothesisVisible: Bool
    let currentSelectedHypothesisId: Int?
    let recoverySelectedHypothesisId: Int?
}

/// Keeps immutable Recovery completion evidence separate from any Local
/// candidate observed on the same frame. A completion frame never exposes the
/// new candidate through the flat/current hypothesis fields.
enum PriorMapHypothesisTraceBinder {
    static func bind(
        completion: PriorMapRecoveryCompletion?,
        currentSelectedHypothesisId: Int?
    ) -> PriorMapHypothesisTraceBinding {
        guard let completion else {
            return PriorMapHypothesisTraceBinding(
                currentHypothesisVisible: true,
                currentSelectedHypothesisId: currentSelectedHypothesisId,
                recoverySelectedHypothesisId: nil)
        }
        return PriorMapHypothesisTraceBinding(
            currentHypothesisVisible: false,
            currentSelectedHypothesisId: nil,
            recoverySelectedHypothesisId: completion.selectedHypothesisId)
    }
}

/// Owns the bounded lifetime of one Recovery search. Frame availability is
/// deliberately outside this type: callers record an attempt only after the
/// matcher received its minimum valid input and actually searched the map.
final class PriorMapRecoveryController {
    static let automaticRecoveryCooldownSeconds: TimeInterval = 20

    private let maximumValidAttempts: Int
    private let maximumWallClockSeconds: TimeInterval
    private let maximumTriggerCount: Int
    private var nextEpisodeId = 1

    private(set) var activeEpisode: PriorMapRecoveryEpisode?
    private(set) var lastCompletion: PriorMapRecoveryCompletion?
    private(set) var nextAutomaticRecoveryAllowedAt: TimeInterval = 0

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
    func request(
        reason: String,
        now: TimeInterval,
        automatic: Bool = false
    ) -> Bool {
        if var episode = activeEpisode {
            episode.triggerCount = min(
                maximumTriggerCount,
                episode.triggerCount + 1)
            activeEpisode = episode
            return false
        }
        if automatic && now < nextAutomaticRecoveryAllowedAt {
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
            triggerCount: 1,
            automatic: automatic)
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

    /// The single attempt-accounting reducer shared by production and tests.
    /// Only a matcher-owned `searched` disposition consumes the bounded budget;
    /// all unavailable, dropped, or undersized frames consume wall time only.
    @discardableResult
    func recordFrameDisposition(
        _ disposition: PriorMapRecoveryFrameDisposition
    ) -> Bool {
        guard disposition.searchPerformed else { return false }
        return recordValidMatcherAttempt()
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

    func isWallClockExpired(now: TimeInterval) -> Bool {
        guard let episode = activeEpisode else { return false }
        return now >= episode.deadlineUptime
    }

    func isAutomaticTriggerSuppressed(now: TimeInterval) -> Bool {
        activeEpisode == nil && now < nextAutomaticRecoveryAllowedAt
    }

    func automaticCooldownRemaining(now: TimeInterval) -> TimeInterval {
        max(0, nextAutomaticRecoveryAllowedAt - now)
    }

    func resetAutomaticCooldownAfterManualCorrection() {
        nextAutomaticRecoveryAllowedAt = 0
    }

    @discardableResult
    func finish(
        _ outcome: PriorMapRecoveryOutcome,
        now: TimeInterval,
        selectedHypothesisId: Int? = nil,
        finalFreshSupportFrames: Int = 0,
        finalResidualTranslationM: Double? = nil,
        finalResidualYawRad: Double? = nil,
        correctionStepAppliedOnCompletionFrame: Bool = false
    ) -> PriorMapRecoveryCompletion? {
        guard let episode = activeEpisode else { return nil }
        let completion = PriorMapRecoveryCompletion(
            episode: episode,
            outcome: outcome,
            finishedAtUptime: now,
            selectedHypothesisId: selectedHypothesisId,
            finalFreshSupportFrames: finalFreshSupportFrames,
            finalResidualTranslationM: finalResidualTranslationM,
            finalResidualYawRad: finalResidualYawRad,
            correctionStepAppliedOnCompletionFrame:
                correctionStepAppliedOnCompletionFrame)
        activeEpisode = nil
        lastCompletion = completion
        if episode.automatic && (outcome == .timedOut || outcome == .cancelled) {
            nextAutomaticRecoveryAllowedAt = max(
                nextAutomaticRecoveryAllowedAt,
                now + Self.automaticRecoveryCooldownSeconds)
        }
        if outcome == .manualReset {
            nextAutomaticRecoveryAllowedAt = 0
        }
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
