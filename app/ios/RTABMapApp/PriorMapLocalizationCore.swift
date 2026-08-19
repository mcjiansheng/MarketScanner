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

/// Human-readable display name for one scan session.
///
/// The name is strictly optional metadata: it never gates scan start, never
/// changes session directory, database or sidecar naming, and a missing or
/// invalid value always falls back to a deterministic default. It is written
/// into `metadata.json` / `live_checkpoint.json` as the optional
/// `scanDisplayName` field and displayed in the historical-scan list; older
/// sessions without the field keep working unchanged.
enum MarketScannerScanName {
    static let maximumLength = 64
    static let metadataKey = "scanDisplayName"

    /// Slashes, wildcards, quotes, angle brackets, pipes and control
    /// characters are removed so the value can never break file browsers,
    /// export paths, logs or JSON/CSV transports. The name is never used as
    /// a path component, so this is defense in depth.
    private static let forbiddenCharacters = CharacterSet(
        charactersIn: "/\\:*?\"<>|")
        .union(CharacterSet.controlCharacters)
        .union(CharacterSet.newlines)

    /// Returns a cleaned display name, or nil when nothing usable remains.
    /// Whitespace runs collapse to single spaces and the result is capped at
    /// `maximumLength`; the operation is idempotent so the host can re-run
    /// it on a UI-supplied value without changing an already-clean name.
    static func sanitize(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        var filteredScalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars
            where !forbiddenCharacters.contains(scalar) {
            filteredScalars.append(scalar)
        }
        let filtered = String(filteredScalars)
        let collapsed = filtered
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var result = collapsed
        if result.count > maximumLength {
            result = String(result.prefix(maximumLength))
                .trimmingCharacters(in: .whitespaces)
        }
        return result.isEmpty ? nil : result
    }

    /// Deterministic default: `<store>-<floor>-MMdd-HHmm`, e.g.
    /// `hs6599-F1-0814-1530`. Parts that are empty are skipped.
    static func defaultName(
        storeID: String,
        floorID: String,
        at date: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMdd-HHmm"
        let stamp = formatter.string(from: date)
        let parts = [storeID, floorID].filter { !$0.isEmpty }
        let prefix = parts.isEmpty ? "Scan" : parts.joined(separator: "-")
        return sanitize("\(prefix)-\(stamp)") ?? "Scan-\(stamp)"
    }

    /// The single resolution rule shared by the setup UI and the scanner
    /// host: a cleaned user value wins; otherwise the default applies.
    static func effectiveName(
        userInput: String?,
        storeID: String,
        floorID: String,
        at date: Date = Date()
    ) -> String {
        return sanitize(userInput)
            ?? defaultName(storeID: storeID, floorID: floorID, at: date)
    }
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
    static let maximumStepTranslationM = 0.25
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
    /// Format-independent identity shared by the Swift and Python map
    /// compilers. The package digest remains the exact on-device artifact
    /// identity; this digest binds a later PC build to the same source map.
    let priorMapCanonicalSourceSha256: String?
    let floorId: String?
    /// Business identity committed by the Mobile-Only scan setup. Prior-map
    /// capture is not formally startable without it because finalized
    /// metadata and later XLSX/result processing validate the store fail-closed.
    let storeID: String?
    let initialMapPose: PriorMapPose2D?
    /// Optional human-readable scan display name committed by the scan
    /// setup screen. Pure metadata: decoding older configurations without
    /// the field yields nil and every consumer treats nil as "unnamed".
    let scanDisplayName: String?

    static let freeMapping = PriorMapScanConfiguration(
        formatVersion: 1,
        workflowMode: .freeMapping,
        packageDirectory: nil,
        priorMapId: nil,
        priorMapSha256: nil,
        priorMapCanonicalSourceSha256: nil,
        floorId: nil,
        storeID: nil,
        initialMapPose: nil,
        scanDisplayName: nil)

    var isReadyToStart: Bool {
        switch workflowMode {
        case .freeMapping:
            return true
        case .priorMapLocalized:
            return packageDirectory != nil
                && !(priorMapId ?? "").isEmpty
                && !(priorMapSha256 ?? "").isEmpty
                && !(floorId ?? "").isEmpty
                && !(storeID ?? "").isEmpty
                && initialMapPose != nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case workflowMode
        case packageDirectory
        case priorMapId
        case priorMapSha256
        case priorMapCanonicalSourceSha256
        case floorId
        case storeID = "storeId"
        case initialMapPose
        case scanDisplayName
    }

    init(
        formatVersion: Int,
        workflowMode: ScanWorkflowMode,
        packageDirectory: URL?,
        priorMapId: String?,
        priorMapSha256: String?,
        priorMapCanonicalSourceSha256: String? = nil,
        floorId: String?,
        storeID: String?,
        initialMapPose: PriorMapPose2D?,
        scanDisplayName: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.workflowMode = workflowMode
        self.packageDirectory = packageDirectory
        self.priorMapId = priorMapId
        self.priorMapSha256 = priorMapSha256
        self.priorMapCanonicalSourceSha256 = priorMapCanonicalSourceSha256
        self.floorId = floorId
        self.storeID = storeID
        self.initialMapPose = initialMapPose
        self.scanDisplayName = scanDisplayName
    }
}

enum PriorMapStageOneMath {
    /// Convert ARKit's right-handed x/y/z world frame to the map's horizontal
    /// SE(2) frame. ARKit +x is map +x, ARKit -z is map +y, and map yaw zero
    /// points toward +x. Positive yaw turns counter-clockwise in map space.
    ///
    /// The yaw definition must stay identical to imported map geometry,
    /// MobileScanConfiguration and every map preview: 0 = east/right,
    /// +pi/2 = north/up. ARKit's camera forward axis is local -z, so its
    /// horizontal map-space direction is `(forwardX, -forwardZ)`.
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
            yawRad: normalizeAngle(atan2(-forwardZ, forwardX)))
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

/// Exact-node admission for a user-submitted map position.
///
/// RTAB-Map normally drops stationary frames below RGBD/LinearUpdate and
/// RGBD/AngularUpdate. The UI therefore opens a request-scoped native retention
/// window for a post-request node instead of reusing an arbitrarily old node or
/// asking the operator to move the phone. This pure policy is shared with the
/// host tests and still requires the retained node to satisfy the formal
/// one-second node-time contract.
enum PriorMapManualNodeBindingPolicy {
    static let maximumNodeTimeDeltaSeconds: TimeInterval = 1.0
    private static let stampEpsilonSeconds: TimeInterval = 0.000_001

    static func accepts(
        requestedAtFrameTimestamp: TimeInterval,
        requestedAtNodeTimebaseTimestamp: TimeInterval,
        baselineNodeID: Int?,
        baselineNodeStamp: TimeInterval?,
        candidateFrameTimestamp: TimeInterval,
        candidateNodeID: Int,
        candidateNodeStamp: TimeInterval,
        candidateNodeTimeDeltaSeconds: TimeInterval
    ) -> Bool {
        guard requestedAtFrameTimestamp.isFinite,
              requestedAtNodeTimebaseTimestamp.isFinite,
              candidateFrameTimestamp.isFinite,
              candidateNodeID > 0,
              candidateNodeStamp.isFinite,
              candidateNodeTimeDeltaSeconds.isFinite,
              candidateNodeTimeDeltaSeconds >= 0,
              candidateNodeTimeDeltaSeconds
                <= maximumNodeTimeDeltaSeconds,
              candidateFrameTimestamp > requestedAtFrameTimestamp,
              candidateNodeStamp
                > requestedAtNodeTimebaseTimestamp + stampEpsilonSeconds else {
            return false
        }
        guard let baselineNodeID, let baselineNodeStamp else {
            return true
        }
        return baselineNodeStamp.isFinite
            && candidateNodeID != baselineNodeID
            && candidateNodeStamp
                > baselineNodeStamp + stampEpsilonSeconds
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
        if let arkitOrigin {
            return PriorMapStageOneMath.project(
                arkitPose: arkitPose,
                arkitOrigin: arkitOrigin,
                initialMapPose: initialMapPose)
        }
        else {
            arkitOrigin = arkitPose
            return initialMapPose
        }
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

/// Why an active Recovery episode was cancelled. The reason is persisted in
/// the terminal lifecycle evidence and decides whether the automatic trigger
/// is suppressed afterwards; a successful convergence or manual reset always
/// clears the cooldown instead.
enum PriorMapRecoveryCancellationReason: String, Codable, Equatable {
    case scanStopped = "scan_stopped"
    case mapUnloaded = "map_unloaded"
    case appInterrupted = "app_interrupted"
    case sessionGenerationChanged = "session_generation_changed"
    case operatorCancelled = "operator_cancelled"

    var suppressesAutomaticRetry: Bool {
        switch self {
        case .scanStopped, .appInterrupted:
            return true
        case .mapUnloaded, .sessionGenerationChanged, .operatorCancelled:
            return false
        }
    }
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

/// One bounded trigger record retained per episode. At most eight records are
/// kept so a hostile or chatty trigger source cannot grow episode memory.
struct PriorMapRecoveryTriggerRecord: Codable, Equatable {
    let reason: String
    let automatic: Bool
    let atUptime: TimeInterval

    private enum CodingKeys: String, CodingKey {
        case reason
        case automatic
        case atUptime = "at_uptime"
    }
}

struct PriorMapRecoveryEpisode: Equatable {
    static let maximumRetainedTriggerRecords = 8

    let id: Int
    let reason: String
    let startedAtUptime: TimeInterval
    let deadlineUptime: TimeInterval
    let maximumValidAttempts: Int
    var validMatcherAttempts: Int
    var acceptedCorrections: Int
    var triggerCount: Int
    let automatic: Bool
    var automaticTriggerCount: Int
    var reliableLoopTriggerCount: Int
    var lastTriggerReason: String
    var lastTriggerAtUptime: TimeInterval
    var triggerRecords: [PriorMapRecoveryTriggerRecord]

    var remainingValidAttempts: Int {
        max(0, maximumValidAttempts - validMatcherAttempts)
    }

    /// Appends one bounded trigger source record. Returns false once the
    /// episode already reached its trigger budget.
    mutating func recordTrigger(
        reason: String,
        automatic: Bool,
        now: TimeInterval,
        maximumTriggerCount: Int
    ) -> Bool {
        guard triggerCount < maximumTriggerCount else { return false }
        triggerCount = min(maximumTriggerCount, triggerCount + 1)
        if automatic {
            automaticTriggerCount += 1
        }
        else {
            reliableLoopTriggerCount += 1
        }
        lastTriggerReason = reason
        lastTriggerAtUptime = now
        triggerRecords.append(
            PriorMapRecoveryTriggerRecord(
                reason: reason,
                automatic: automatic,
                atUptime: now))
        if triggerRecords.count > Self.maximumRetainedTriggerRecords {
            triggerRecords.removeFirst(
                triggerRecords.count - Self.maximumRetainedTriggerRecords)
        }
        return true
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
    let cancellationReason: PriorMapRecoveryCancellationReason?

    init(
        episode: PriorMapRecoveryEpisode,
        outcome: PriorMapRecoveryOutcome,
        finishedAtUptime: TimeInterval,
        selectedHypothesisId: Int? = nil,
        finalFreshSupportFrames: Int = 0,
        finalResidualTranslationM: Double? = nil,
        finalResidualYawRad: Double? = nil,
        correctionStepAppliedOnCompletionFrame: Bool = false,
        cancellationReason: PriorMapRecoveryCancellationReason? = nil
    ) {
        self.episode = episode
        self.outcome = outcome
        self.finishedAtUptime = finishedAtUptime
        self.selectedHypothesisId = selectedHypothesisId
        self.finalFreshSupportFrames = finalFreshSupportFrames
        self.finalResidualTranslationM = finalResidualTranslationM
        self.finalResidualYawRad = finalResidualYawRad
        self.correctionStepAppliedOnCompletionFrame =
            correctionStepAppliedOnCompletionFrame
        self.cancellationReason = cancellationReason
    }
}

/// Bounded episode diagnostics. Every episode elapsed value exposed to traces
/// or lifecycle evidence must come from this single reducer so a completion
/// consumed on a later frame is bound to its finish time, never to the
/// consuming frame clock.
enum PriorMapRecoveryDiagnostics {
    static func elapsedMs(
        episode: PriorMapRecoveryEpisode,
        completion: PriorMapRecoveryCompletion?,
        now: TimeInterval
    ) -> Double {
        let elapsedEnd = completion?.finishedAtUptime ?? now
        return max(0, elapsedEnd - episode.startedAtUptime) * 1000
    }
}

/// Terminal Recovery lifecycle evidence. One record per finished episode is
/// persisted to `localization_recovery_events.jsonl` so post-processing can
/// distinguish convergence, timeout, manual reset, and cancellation, including
/// scan-stop or map-unload teardowns that never see another update frame.
struct PriorMapRecoveryLifecycleRecord: Codable, Equatable {
    static let formatName = "MarketScannerRecoveryLifecycleEvent"
    /// P7R6: v2 persists the deadline, the attempts budget, and the bounded
    /// trigger source sequence so post-processing can audit the full episode
    /// without trusting summary counters alone. v1 records remain readable.
    static let formatVersion = 2
    static let fileName = "localization_recovery_events.jsonl"

    let format: String
    let version: Int
    let trackingSessionId: String
    let priorMapId: String
    let priorMapSha256: String
    let floorId: String
    let episodeId: Int
    let reason: String
    let outcome: String
    let cancellationReason: String?
    let episodeAutomatic: Bool
    let startedAtUptime: TimeInterval
    let deadlineUptime: TimeInterval
    let finishedAtUptime: TimeInterval
    let elapsedMs: Double
    let maximumValidAttempts: Int
    let validMatcherAttempts: Int
    let acceptedCorrections: Int
    let triggerCount: Int
    let automaticTriggerCount: Int
    let reliableLoopTriggerCount: Int
    let lastTriggerReason: String
    let lastTriggerAtUptime: TimeInterval
    let triggerRecords: [PriorMapRecoveryTriggerRecord]
    let selectedHypothesisId: Int?
    let freshSupportFrames: Int
    let finalResidualTranslationM: Double?
    let finalResidualYawRad: Double?
    let completionFrameStepApplied: Bool

    private enum CodingKeys: String, CodingKey {
        case format
        case version
        case trackingSessionId = "tracking_session_id"
        case priorMapId = "prior_map_id"
        case priorMapSha256 = "prior_map_sha256"
        case floorId = "floor_id"
        case episodeId = "episode_id"
        case reason
        case outcome
        case cancellationReason = "cancellation_reason"
        case episodeAutomatic = "episode_automatic"
        case startedAtUptime = "started_at_uptime"
        case deadlineUptime = "deadline_uptime"
        case finishedAtUptime = "finished_at_uptime"
        case elapsedMs = "elapsed_ms"
        case maximumValidAttempts = "maximum_valid_attempts"
        case validMatcherAttempts = "valid_matcher_attempts"
        case acceptedCorrections = "accepted_corrections"
        case triggerCount = "trigger_count"
        case automaticTriggerCount = "automatic_trigger_count"
        case reliableLoopTriggerCount = "reliable_loop_trigger_count"
        case lastTriggerReason = "last_trigger_reason"
        case lastTriggerAtUptime = "last_trigger_at_uptime"
        case triggerRecords = "trigger_records"
        case selectedHypothesisId = "selected_hypothesis_id"
        case freshSupportFrames = "fresh_support_frames"
        case finalResidualTranslationM = "final_residual_translation_m"
        case finalResidualYawRad = "final_residual_yaw_rad"
        case completionFrameStepApplied = "completion_frame_step_applied"
    }

    init(
        trackingSessionId: String,
        priorMapId: String,
        priorMapSha256: String,
        floorId: String,
        completion: PriorMapRecoveryCompletion
    ) {
        self.format = Self.formatName
        self.version = Self.formatVersion
        self.trackingSessionId = trackingSessionId
        self.priorMapId = priorMapId
        self.priorMapSha256 = priorMapSha256
        self.floorId = floorId
        self.episodeId = completion.episode.id
        self.reason = completion.episode.reason
        self.outcome = completion.outcome.rawValue
        self.cancellationReason = completion.cancellationReason?.rawValue
        self.episodeAutomatic = completion.episode.automatic
        self.startedAtUptime = completion.episode.startedAtUptime
        self.deadlineUptime = completion.episode.deadlineUptime
        self.finishedAtUptime = completion.finishedAtUptime
        self.elapsedMs = PriorMapRecoveryDiagnostics.elapsedMs(
            episode: completion.episode,
            completion: completion,
            now: completion.finishedAtUptime)
        self.maximumValidAttempts = completion.episode.maximumValidAttempts
        self.validMatcherAttempts = completion.episode.validMatcherAttempts
        self.acceptedCorrections = completion.episode.acceptedCorrections
        self.triggerCount = completion.episode.triggerCount
        self.automaticTriggerCount = completion.episode.automaticTriggerCount
        self.reliableLoopTriggerCount =
            completion.episode.reliableLoopTriggerCount
        self.lastTriggerReason = completion.episode.lastTriggerReason
        self.lastTriggerAtUptime = completion.episode.lastTriggerAtUptime
        self.triggerRecords = completion.episode.triggerRecords
        self.selectedHypothesisId = completion.selectedHypothesisId
        self.freshSupportFrames = completion.finalFreshSupportFrames
        self.finalResidualTranslationM = completion.finalResidualTranslationM
        self.finalResidualYawRad = completion.finalResidualYawRad
        self.completionFrameStepApplied =
            completion.correctionStepAppliedOnCompletionFrame
    }
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
    /// closures retain the episode ID, deadline, attempts, and fresh support
    /// but append a bounded trigger-source summary (F-04).
    @discardableResult
    func request(
        reason: String,
        now: TimeInterval,
        automatic: Bool = false
    ) -> Bool {
        if var episode = activeEpisode {
            _ = episode.recordTrigger(
                reason: reason,
                automatic: automatic,
                now: now,
                maximumTriggerCount: maximumTriggerCount)
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
            automatic: automatic,
            automaticTriggerCount: automatic ? 1 : 0,
            reliableLoopTriggerCount: automatic ? 0 : 1,
            lastTriggerReason: reason,
            lastTriggerAtUptime: now,
            triggerRecords: [
                PriorMapRecoveryTriggerRecord(
                    reason: reason,
                    automatic: automatic,
                    atUptime: now),
            ])
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

    /// Finishes the active episode and reconciles the automatic cooldown
    /// against the terminal outcome (F-01). Cooldown only throttles automatic
    /// weak/lost triggers: any convergence clears stale cooldown, any timeout
    /// extends it regardless of how the episode started, and cancellations
    /// follow their explicit reason.
    @discardableResult
    func finish(
        _ outcome: PriorMapRecoveryOutcome,
        now: TimeInterval,
        selectedHypothesisId: Int? = nil,
        finalFreshSupportFrames: Int = 0,
        finalResidualTranslationM: Double? = nil,
        finalResidualYawRad: Double? = nil,
        correctionStepAppliedOnCompletionFrame: Bool = false,
        cancellationReason: PriorMapRecoveryCancellationReason? = nil
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
                correctionStepAppliedOnCompletionFrame,
            cancellationReason: cancellationReason)
        activeEpisode = nil
        lastCompletion = completion
        switch outcome {
        case .converged:
            nextAutomaticRecoveryAllowedAt = 0

        case .timedOut:
            nextAutomaticRecoveryAllowedAt = max(
                nextAutomaticRecoveryAllowedAt,
                now + Self.automaticRecoveryCooldownSeconds)

        case .cancelled:
            if cancellationReason?.suppressesAutomaticRetry == true {
                nextAutomaticRecoveryAllowedAt = max(
                    nextAutomaticRecoveryAllowedAt,
                    now + Self.automaticRecoveryCooldownSeconds)
            }

        case .manualReset:
            nextAutomaticRecoveryAllowedAt = 0
        }
        return completion
    }
}

/// Admission gate for the native RTAB-Map node clock used by every required
/// localization evidence record. The native offset is legitimately absent for
/// the first AR frames before the first node-time snapshot exists. That is a
/// transient "not ready" condition, not corrupt evidence: callers must wait
/// instead of manufacturing a non-finite placeholder and poisoning the whole
/// scan's sticky evidence health.
enum PriorMapNodeTimebaseAdmission {
    static func accepts(offsetSeconds: TimeInterval?) -> Bool {
        guard let offsetSeconds else { return false }
        return offsetSeconds.isFinite
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
