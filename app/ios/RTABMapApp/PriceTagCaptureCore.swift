//
//  PriceTagCaptureCore.swift
//  RTABMapApp
//
//  Platform-neutral barcode-capture state, ROI geometry and candidate
//  selection. The shipping UI and Vision adapter are intentionally thin:
//  this file is the single authority for generation invalidation, bounded
//  detection scheduling, candidate lock and unique-frame burst progress.
//

import CoreGraphics
import Foundation
import ImageIO

enum PriceTagVideoGravity: String, Codable {
    case resizeAspectFill
    case resizeAspectFit
}

enum PriceTagScanROIError: Error, Equatable {
    case invalidGeometry
    case emptyIntersection
}

enum PriceTagScanROIMapper {
    static func orientedImageSize(
        imageResolution: CGSize,
        orientation: CGImagePropertyOrientation
    ) -> CGSize {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(
                width: imageResolution.height,
                height: imageResolution.width)
        default:
            return imageResolution
        }
    }

    static func displayedImageRect(
        previewBounds: CGRect,
        imageResolution: CGSize,
        orientation: CGImagePropertyOrientation,
        videoGravity: PriceTagVideoGravity
    ) throws -> CGRect {
        let imageSize = orientedImageSize(
            imageResolution: imageResolution,
            orientation: orientation)
        guard previewBounds.width.isFinite,
              previewBounds.height.isFinite,
              imageSize.width.isFinite,
              imageSize.height.isFinite,
              previewBounds.width > 0,
              previewBounds.height > 0,
              imageSize.width > 0,
              imageSize.height > 0 else {
            throw PriceTagScanROIError.invalidGeometry
        }
        let widthScale = previewBounds.width / imageSize.width
        let heightScale = previewBounds.height / imageSize.height
        let scale = videoGravity == .resizeAspectFill
            ? max(widthScale, heightScale)
            : min(widthScale, heightScale)
        let displayedSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale)
        return CGRect(
            x: previewBounds.midX - displayedSize.width / 2,
            y: previewBounds.midY - displayedSize.height / 2,
            width: displayedSize.width,
            height: displayedSize.height)
    }

    /// Converts the visible UIKit scan box (top-left origin) into the
    /// normalized, bottom-left-origin coordinates expected by Vision after
    /// the same EXIF orientation is supplied to VNImageRequestHandler.
    static func visionRegionOfInterest(
        scanRectInView: CGRect,
        previewBounds: CGRect,
        imageResolution: CGSize,
        orientation: CGImagePropertyOrientation,
        videoGravity: PriceTagVideoGravity = .resizeAspectFill
    ) throws -> CGRect {
        let displayed = try displayedImageRect(
            previewBounds: previewBounds,
            imageResolution: imageResolution,
            orientation: orientation,
            videoGravity: videoGravity)
        let visible = scanRectInView.intersection(previewBounds)
            .intersection(displayed)
        guard !visible.isNull, !visible.isEmpty else {
            throw PriceTagScanROIError.emptyIntersection
        }
        let normalizedTopLeft = CGRect(
            x: (visible.minX - displayed.minX) / displayed.width,
            y: (visible.minY - displayed.minY) / displayed.height,
            width: visible.width / displayed.width,
            height: visible.height / displayed.height)
        let vision = CGRect(
            x: normalizedTopLeft.minX,
            y: 1 - normalizedTopLeft.maxY,
            width: normalizedTopLeft.width,
            height: normalizedTopLeft.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !vision.isNull, !vision.isEmpty,
              vision.minX >= 0,
              vision.minY >= 0,
              vision.maxX <= 1,
              vision.maxY <= 1 else {
            throw PriceTagScanROIError.emptyIntersection
        }
        return vision
    }

    /// Test/UI inverse of `visionRegionOfInterest`. Keeping the inverse next
    /// to the production mapping prevents orientation-specific copies from
    /// drifting across view controllers.
    static func viewRect(
        forVisionRegion region: CGRect,
        previewBounds: CGRect,
        imageResolution: CGSize,
        orientation: CGImagePropertyOrientation,
        videoGravity: PriceTagVideoGravity = .resizeAspectFill
    ) throws -> CGRect {
        guard region.minX >= 0,
              region.minY >= 0,
              region.maxX <= 1,
              region.maxY <= 1,
              !region.isEmpty else {
            throw PriceTagScanROIError.invalidGeometry
        }
        let displayed = try displayedImageRect(
            previewBounds: previewBounds,
            imageResolution: imageResolution,
            orientation: orientation,
            videoGravity: videoGravity)
        return CGRect(
            x: displayed.minX + region.minX * displayed.width,
            y: displayed.minY + (1 - region.maxY) * displayed.height,
            width: region.width * displayed.width,
            height: region.height * displayed.height)
    }
}

struct PriceTagCaptureLayout {
    /// Wide enough for an ESL barcode while leaving a clear exclusion area
    /// around it. The UI and ROI mapper both consume this single value.
    static let normalizedScanRect = CGRect(
        x: 0.12,
        y: 0.36,
        width: 0.76,
        height: 0.25)
    /// Text/progress controls are anchored to the exact scan-box edges with
    /// these clearances. They must never be positioned with centerY magic
    /// numbers, which overlap the border on taller Dynamic Type/device sizes.
    static let statusClearancePoints: CGFloat = 18
    static let payloadClearancePoints: CGFloat = 18

    static func scanRect(in bounds: CGRect) -> CGRect {
        return CGRect(
            x: bounds.minX + normalizedScanRect.minX * bounds.width,
            y: bounds.minY + normalizedScanRect.minY * bounds.height,
            width: normalizedScanRect.width * bounds.width,
            height: normalizedScanRect.height * bounds.height)
    }
}

struct PriceTagBarcodeCandidate: Equatable {
    let payload: String
    let symbology: String
    /// Vision normalized coordinates: bottom-left origin in the oriented
    /// image supplied to VNImageRequestHandler.
    let visionBounds: CGRect
}

struct PriceTagSelectedBarcode: Equatable {
    let candidate: PriceTagBarcodeCandidate
    let roiIntersectionRatio: Double
    let centerProximity: Double
    let normalizedArea: Double
    let score: Double
}

enum PriceTagBarcodeSelection: Equatable {
    case none
    case selected(PriceTagSelectedBarcode)
    case ambiguous([PriceTagSelectedBarcode])
}

enum PriceTagBarcodeSelector {
    /// Vision can occasionally return duplicate observations for the same
    /// physical symbol. Only nearly coincident boxes are detector duplicates;
    /// equal payload text at a different position is still a second physical
    /// barcode and must participate in the ambiguity gate.
    private static let duplicateObservationIoU = 0.85

    static func select(
        candidates: [PriceTagBarcodeCandidate],
        regionOfInterest roi: CGRect,
        minimumIntersectionRatio: Double,
        minimumNormalizedArea: Double,
        ambiguityScoreDelta: Double
    ) -> PriceTagBarcodeSelection {
        guard !roi.isEmpty, roi.width > 0, roi.height > 0 else {
            return .none
        }
        let roiCenter = CGPoint(x: roi.midX, y: roi.midY)
        let halfDiagonal = max(1.0e-9, hypot(roi.width, roi.height) / 2)
        var physicalCandidates: [PriceTagSelectedBarcode] = []
        for value in candidates {
            let payload = value.payload.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !payload.isEmpty,
                  value.visionBounds.width > 0,
                  value.visionBounds.height > 0 else {
                continue
            }
            let center = CGPoint(
                x: value.visionBounds.midX,
                y: value.visionBounds.midY)
            guard roi.contains(center) else { continue }
            let candidateArea = value.visionBounds.width
                * value.visionBounds.height
            let intersection = value.visionBounds.intersection(roi)
            let intersectionArea = intersection.isNull
                ? 0
                : intersection.width * intersection.height
            let intersectionRatio = Double(intersectionArea / candidateArea)
            guard intersectionRatio + 1.0e-9 >= minimumIntersectionRatio else {
                continue
            }
            let normalizedArea = Double(candidateArea / (roi.width * roi.height))
            guard normalizedArea + 1.0e-9 >= minimumNormalizedArea else {
                continue
            }
            let distance = hypot(center.x - roiCenter.x, center.y - roiCenter.y)
            let centerProximity = max(0, 1 - Double(distance / halfDiagonal))
            let areaScore = min(1, normalizedArea / 0.25)
            let score = 0.52 * intersectionRatio
                + 0.34 * centerProximity
                + 0.14 * areaScore
            let selected = PriceTagSelectedBarcode(
                candidate: PriceTagBarcodeCandidate(
                    payload: payload,
                    symbology: value.symbology,
                    visionBounds: value.visionBounds),
                roiIntersectionRatio: intersectionRatio,
                centerProximity: centerProximity,
                normalizedArea: normalizedArea,
                score: score)
            if let duplicateIndex = physicalCandidates.firstIndex(where: {
                $0.candidate.payload == payload
                    && $0.candidate.symbology == value.symbology
                    && intersectionOverUnion(
                        $0.candidate.visionBounds,
                        value.visionBounds) >= duplicateObservationIoU
            }) {
                if selected.score > physicalCandidates[duplicateIndex].score {
                    physicalCandidates[duplicateIndex] = selected
                }
            }
            else {
                physicalCandidates.append(selected)
            }
        }
        let ranked = physicalCandidates.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.candidate.payload != $1.candidate.payload {
                return $0.candidate.payload < $1.candidate.payload
            }
            if $0.candidate.symbology != $1.candidate.symbology {
                return $0.candidate.symbology < $1.candidate.symbology
            }
            if $0.candidate.visionBounds.minX
                != $1.candidate.visionBounds.minX {
                return $0.candidate.visionBounds.minX
                    < $1.candidate.visionBounds.minX
            }
            return $0.candidate.visionBounds.minY
                < $1.candidate.visionBounds.minY
        }
        guard let first = ranked.first else { return .none }
        if ranked.count > 1,
           first.score - ranked[1].score <= ambiguityScoreDelta {
            return .ambiguous(Array(ranked.prefix(3)))
        }
        return .selected(first)
    }

    private static func intersectionOverUnion(
        _ first: CGRect,
        _ second: CGRect
    ) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = first.width * first.height
            + second.width * second.height
            - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}

struct PriceTagCapturePolicy: Equatable {
    let minimumCandidateLockFrames: Int
    let minimumEvidenceFrames: Int
    let targetEvidenceFrames: Int
    let minimumCaptureDuration: TimeInterval
    let maximumCaptureDuration: TimeInterval
    let maximumVisionRequestDuration: TimeInterval
    let visionRateHz: Double
    let previewRateHz: Double
    let minimumROIIntersectionRatio: Double
    let minimumCandidateNormalizedArea: Double
    let ambiguityScoreDelta: Double
    let completedDuplicateSuppressionSeconds: TimeInterval

    static let field = PriceTagCapturePolicy(
        minimumCandidateLockFrames: 2,
        minimumEvidenceFrames: 3,
        targetEvidenceFrames: 4,
        minimumCaptureDuration: 0.30,
        maximumCaptureDuration: 2.0,
        maximumVisionRequestDuration: 1.0,
        visionRateHz: 8,
        previewRateHz: 24,
        minimumROIIntersectionRatio: 0.80,
        minimumCandidateNormalizedArea: 0.002,
        ambiguityScoreDelta: 0.08,
        completedDuplicateSuppressionSeconds: 2.0)
}

enum PriceTagCaptureState: Equatable {
    case idle
    case entering(generation: UUID)
    case aiming(generation: UUID)
    case candidate(
        generation: UUID,
        payload: String,
        symbology: String,
        firstSeenMonotonic: TimeInterval,
        lockFrames: Int)
    case collecting(
        generation: UUID,
        captureID: UUID,
        payload: String,
        symbology: String,
        acceptedFrames: Int,
        requiredFrames: Int)
    case resolving(generation: UUID, captureID: UUID)
    case confirming(generation: UUID, captureID: UUID)
    case cancelling(generation: UUID, reason: String)

    var generation: UUID? {
        switch self {
        case .idle:
            return nil
        case .entering(let value), .aiming(let value):
            return value
        case .candidate(let value, _, _, _, _),
             .collecting(let value, _, _, _, _, _),
             .resolving(let value, _),
             .confirming(let value, _),
             .cancelling(let value, _):
            return value
        }
    }
}

struct PriceTagCaptureGeometry: Equatable {
    let previewBounds: CGRect
    let scanRect: CGRect
}

struct PriceTagVisionSubmission: Equatable {
    let generation: UUID
    let geometry: PriceTagCaptureGeometry
}

/// Scanner-local admission authority for one asynchronous Vision request.
///
/// A capture generation alone is not sufficient when a request can hang past
/// the collection deadline and the same generation returns to `aiming`. A
/// restart therefore revokes the old request ID while keeping the generation
/// active. The eventual old callback cannot clear or complete the fresh
/// request that replaced it.
struct PriceTagVisionRequestTokenGate {
    private(set) var activeGeneration: UUID?
    private(set) var activeRequestID: UUID?

    mutating func activate(generation: UUID) {
        activeGeneration = generation
        activeRequestID = nil
    }

    mutating func cancel(generation: UUID? = nil) {
        guard generation == nil || generation == activeGeneration else {
            return
        }
        activeGeneration = nil
        activeRequestID = nil
    }

    @discardableResult
    mutating func restart(generation: UUID) -> Bool {
        guard activeGeneration == generation else { return false }
        activeRequestID = nil
        return true
    }

    mutating func beginRequest(generation: UUID) -> UUID? {
        guard activeGeneration == generation,
              activeRequestID == nil else {
            return nil
        }
        let requestID = UUID()
        activeRequestID = requestID
        return requestID
    }

    mutating func completeRequest(
        generation: UUID,
        requestID: UUID
    ) -> Bool {
        guard activeGeneration == generation,
              activeRequestID == requestID else {
            return false
        }
        activeRequestID = nil
        return true
    }
}

struct PriceTagVisionWorkerExecutorSnapshot: Equatable {
    let availableWorkers: Int
    let activeWorkers: Int
    let quarantinedWorkers: Int
}

/// A bounded executor that lets one replacement Vision request actually run
/// when a prior synchronous `perform()` call fails to return. Normal operation
/// uses one lane. A timed-out/cancelled lane is quarantined until its work
/// returns; at most one spare lane exists, so repeated hangs fail closed
/// instead of creating an unbounded queue or thread population.
final class PriceTagVisionWorkerExecutor {
    private enum WorkerState: Equatable {
        case available
        case active(requestID: UUID)
        case quarantined(requestID: UUID)
    }

    private let lock = NSLock()
    private let queues: [DispatchQueue]
    private var states: [WorkerState]

    init(
        maximumWorkers: Int = 2,
        labelPrefix: String = "com.introlab.rtabmap.price-tag-vision"
    ) {
        precondition(maximumWorkers > 0)
        states = Array(repeating: .available, count: maximumWorkers)
        queues = (0..<maximumWorkers).map { index in
            DispatchQueue(
                label: "\(labelPrefix).worker-\(index)",
                qos: .userInitiated)
        }
    }

    @discardableResult
    func submit(
        requestID: UUID,
        _ body: @escaping () -> Void
    ) -> Bool {
        lock.lock()
        guard let workerIndex = states.firstIndex(of: .available) else {
            lock.unlock()
            return false
        }
        states[workerIndex] = .active(requestID: requestID)
        let queue = queues[workerIndex]
        lock.unlock()
        queue.async {
            body()
            self.lock.lock()
            switch self.states[workerIndex] {
            case .active(let activeID) where activeID == requestID:
                self.states[workerIndex] = .available
            case .quarantined(let activeID) where activeID == requestID:
                self.states[workerIndex] = .available
            default:
                break
            }
            self.lock.unlock()
        }
        return true
    }

    @discardableResult
    func quarantine(requestID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let workerIndex = states.firstIndex(
            of: .active(requestID: requestID)) else {
            return false
        }
        states[workerIndex] = .quarantined(requestID: requestID)
        return true
    }

    func snapshot() -> PriceTagVisionWorkerExecutorSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var available = 0
        var active = 0
        var quarantined = 0
        for state in states {
            switch state {
            case .available:
                available += 1
            case .active:
                active += 1
            case .quarantined:
                quarantined += 1
            }
        }
        return PriceTagVisionWorkerExecutorSnapshot(
            availableWorkers: available,
            activeWorkers: active,
            quarantinedWorkers: quarantined)
    }
}

enum PriceTagCaptureVisionAction: Equatable {
    case ignored
    case keepAiming(code: String)
    case candidateSeen(payload: String, lockFrames: Int, requiredFrames: Int)
    case candidateLocked(captureID: UUID, barcode: PriceTagSelectedBarcode)
    case collect(captureID: UUID, barcode: PriceTagSelectedBarcode)
    case duplicateCompleted(payload: String)
    case multipleBarcodes
    case targetChanged(previousCaptureID: UUID, payload: String)
    case requestTimedOut(frameTimestamp: TimeInterval)
    case resolve(captureID: UUID, observationIDs: [String])
    /// `revokeVisionRequest` is true only for the synchronous ARFrame-deadline
    /// path that just revoked coordinator admission while a scanner request
    /// may still be running. Callback/evidence completion paths have already
    /// completed their exact scanner request and must not restart by generation
    /// later, because that could cancel a fresh same-generation request.
    case timedOut(captureID: UUID, revokeVisionRequest: Bool)
}

enum PriceTagCaptureEvidenceAction: Equatable {
    case ignored
    case continueCollecting(acceptedFrames: Int, requiredFrames: Int)
    case resolve(captureID: UUID, observationIDs: [String])
    case timedOut(captureID: UUID)
    case requiredEvidenceFailed(captureID: UUID)
}

enum PriceTagCaptureTrackingDisposition: Equatable {
    case allow
    case pause(reason: String)
    case cancel(reason: String)
}

/// One shared fail-closed policy for the ARKit and prior-map states that may
/// authorize barcode evidence. Hard tracking/localization loss invalidates the
/// workflow; the two recoverable ARKit limited states pause new submissions
/// without stopping the underlying AR/RTAB-Map scan.
enum PriceTagCaptureTrackingGate {
    static func evaluate(
        trackingState: String,
        localizationState: String?
    ) -> PriceTagCaptureTrackingDisposition {
        if localizationState == "lost" {
            return .cancel(reason: "prior_map_localization_lost")
        }
        switch trackingState {
        case "normal":
            return .allow
        case "limited.excessiveMotion":
            return .pause(reason: "arkit_tracking_excessive_motion")
        case "limited.insufficientFeatures":
            return .pause(reason: "arkit_tracking_insufficient_features")
        case "notAvailable":
            return .cancel(reason: "arkit_tracking_not_available")
        case "limited.initializing":
            return .cancel(reason: "arkit_tracking_initializing")
        case "limited.relocalizing":
            return .cancel(reason: "arkit_tracking_relocalizing")
        default:
            return .cancel(reason: "arkit_tracking_unknown")
        }
    }
}

struct PriceTagCaptureContinuitySample: Equatable {
    let generation: UUID
    let capturedAtMonotonic: TimeInterval
    let frameTimestamp: TimeInterval
    let trackingSessionID: String
    let mappingActive: Bool
    let dataRecording: Bool
    let nativePipelineAvailable: Bool
    let databaseWriterReady: Bool
    let databaseIdentity: String?
    let clockWriterReady: Bool
    let sessionFinalizing: Bool
    let localizationRequiredWriteFailed: Bool
    let sensorPoseCount: Int
    let odometrySubmissionCount: UInt64
    let mapNodeCount: Int
    /// Audit-only. SQLite checkpointing can legitimately reduce the WAL and
    /// total byte count, so this value is never treated as monotonic evidence.
    let databaseBytes: UInt64
    let clockBoundNodeID: Int
    let localizationTraceCount: Int
    let localizationConstraintCount: Int
}

enum PriceTagCaptureContinuityAssessment: Equatable {
    case passed
    case notEvaluable(reasons: [String])
    case failed(reasons: [String])
}

enum PriceTagCaptureContinuityEvaluator {
    /// The prior-map trace is intentionally rate-limited to 2 Hz. Shorter
    /// workflows cannot honestly prove that every asynchronous channel moved.
    static let minimumEvaluationDuration: TimeInterval = 0.75

    static func evaluate(
        start: PriceTagCaptureContinuitySample,
        end: PriceTagCaptureContinuitySample
    ) -> PriceTagCaptureContinuityAssessment {
        var failures: [String] = []
        let duration = end.capturedAtMonotonic - start.capturedAtMonotonic
        if !duration.isFinite || duration < 0 {
            failures.append("invalid_monotonic_duration")
        }
        if start.generation != end.generation {
            failures.append("capture_generation_changed")
        }
        if start.trackingSessionID.isEmpty
            || start.trackingSessionID != end.trackingSessionID {
            failures.append("tracking_session_changed")
        }
        if !start.mappingActive || !end.mappingActive {
            failures.append("mapping_state_inactive")
        }
        if start.dataRecording || end.dataRecording {
            failures.append("data_recording_mode_active")
        }
        if !start.nativePipelineAvailable || !end.nativePipelineAvailable {
            failures.append("native_pipeline_unavailable")
        }
        if !start.databaseWriterReady || !end.databaseWriterReady {
            failures.append("database_writer_unavailable")
        }
        if start.databaseIdentity == nil
            || start.databaseIdentity != end.databaseIdentity {
            failures.append("database_identity_changed")
        }
        if !start.clockWriterReady || !end.clockWriterReady {
            failures.append("clock_writer_unavailable")
        }
        if start.sessionFinalizing || end.sessionFinalizing {
            failures.append("session_finalization_active")
        }
        if start.localizationRequiredWriteFailed
            || end.localizationRequiredWriteFailed {
            failures.append("required_localization_write_failed")
        }
        if end.frameTimestamp < start.frameTimestamp {
            failures.append("frame_timestamp_regressed")
        }
        if end.sensorPoseCount < start.sensorPoseCount {
            failures.append("sensor_pose_count_regressed")
        }
        if end.odometrySubmissionCount < start.odometrySubmissionCount {
            failures.append("odometry_submission_count_regressed")
        }
        if end.mapNodeCount < start.mapNodeCount {
            failures.append("map_node_count_regressed")
        }
        if end.clockBoundNodeID < start.clockBoundNodeID {
            failures.append("clock_node_binding_regressed")
        }
        if end.localizationTraceCount < start.localizationTraceCount {
            failures.append("localization_trace_count_regressed")
        }
        if end.localizationConstraintCount
            < start.localizationConstraintCount {
            failures.append("localization_constraint_count_regressed")
        }
        if !failures.isEmpty {
            return .failed(reasons: failures)
        }
        guard duration >= minimumEvaluationDuration else {
            return .notEvaluable(
                reasons: ["capture_duration_below_evaluation_window"])
        }
        if end.frameTimestamp <= start.frameTimestamp {
            failures.append("frame_timestamp_did_not_advance")
        }
        if end.sensorPoseCount == start.sensorPoseCount {
            failures.append("sensor_pose_did_not_advance")
        }
        if end.odometrySubmissionCount == start.odometrySubmissionCount {
            failures.append("odometry_submission_did_not_advance")
        }
        if end.localizationTraceCount == start.localizationTraceCount {
            failures.append("localization_trace_did_not_advance")
        }
        if end.mapNodeCount > start.mapNodeCount,
           end.clockBoundNodeID == start.clockBoundNodeID {
            failures.append("new_map_node_missing_clock_binding")
        }
        return failures.isEmpty
            ? .passed
            : .failed(reasons: failures)
    }
}

struct PriceTagCaptureCancellation: Equatable {
    let generation: UUID
    let captureID: UUID?
    let reason: String
    let confirmationCommitInFlight: Bool
}

/// Immutable prior-map authority captured on the main thread when one
/// barcode workflow begins. Background callbacks never read ViewController's
/// mutable prior-map generation directly; they consult this lock-protected
/// value through the coordinator.
struct PriceTagCapturePriorMapAuthority: Equatable {
    let priorMapGeneration: UUID
    let trackingSessionID: String
    let priorMapID: String
    let priorMapSHA256: String
    let floorID: String
}

/// The exact authority returned once, at the confirmation linearization
/// point. It binds the UI generation and burst identity to the scan identity
/// that the session writer must validate in its own persistence transaction.
struct PriceTagConfirmationCommitAuthority: Equatable, Hashable {
    let captureGeneration: UUID
    let captureID: UUID
    let priorMapGeneration: UUID
    let trackingSessionID: String
    let priorMapID: String
    let priorMapSHA256: String
    let floorID: String
}

enum PriceTagConfirmationReservationFailure: String, Equatable {
    case finalizationInProgress = "confirmation_finalization_in_progress"
    case duplicateReservation = "confirmation_duplicate_reservation"
    case reservationMissing = "confirmation_reservation_missing"
}

enum PriceTagConfirmationReservationResult: Equatable {
    case reserved
    case rejected(PriceTagConfirmationReservationFailure)
}

/// Session-level admission authority shared by localization writes,
/// confirmation reservations and finalization. A transaction registers before
/// it waits on the serialized writer lock, so finalization can drain both the
/// current writer and any already-admitted waiter without relying on NSLock
/// fairness. Once finalization wins, only the exact confirmation authorities
/// reserved beforehand (plus explicitly finalization-owned writes) may enter.
final class PriceTagSessionAdmissionGate {
    private let condition = NSCondition()
    private var finalizing = false
    private var activeTransactions = 0
    private var confirmationReservations =
        Set<PriceTagConfirmationCommitAuthority>()

    var isFinalizing: Bool {
        condition.lock()
        defer { condition.unlock() }
        return finalizing
    }

    var activeTransactionCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return activeTransactions
    }

    var confirmationReservationCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return confirmationReservations.count
    }

    @discardableResult
    func beginFinalization() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !finalizing else { return false }
        finalizing = true
        condition.broadcast()
        return true
    }

    func endFinalization() {
        condition.lock()
        finalizing = false
        condition.broadcast()
        condition.unlock()
    }

    func reserveConfirmation(
        _ authority: PriceTagConfirmationCommitAuthority
    ) -> PriceTagConfirmationReservationResult {
        condition.lock()
        defer { condition.unlock() }
        guard !finalizing else {
            return .rejected(.finalizationInProgress)
        }
        guard confirmationReservations.insert(authority).inserted else {
            return .rejected(.duplicateReservation)
        }
        condition.broadcast()
        return .reserved
    }

    func cancelConfirmationReservation(
        _ authority: PriceTagConfirmationCommitAuthority
    ) {
        condition.lock()
        confirmationReservations.remove(authority)
        condition.broadcast()
        condition.unlock()
    }

    func containsConfirmationReservation(
        _ authority: PriceTagConfirmationCommitAuthority
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return confirmationReservations.contains(authority)
    }

    /// Registers a transaction before it waits for the serialized writer.
    /// This is the key ordering rule that prevents a pre-finalization waiter
    /// from entering after the finalization drain has already returned.
    func beginTransaction(
        reservedConfirmation authority:
            PriceTagConfirmationCommitAuthority? = nil,
        allowDuringFinalization: Bool = false
    ) -> PriceTagConfirmationReservationFailure? {
        condition.lock()
        defer { condition.unlock() }
        if let authority {
            guard confirmationReservations.contains(authority) else {
                return .reservationMissing
            }
        }
        else if finalizing && !allowDuringFinalization {
            return .finalizationInProgress
        }
        activeTransactions += 1
        condition.broadcast()
        return nil
    }

    func endTransaction(
        reservedConfirmation authority:
            PriceTagConfirmationCommitAuthority? = nil
    ) {
        condition.lock()
        if let authority {
            confirmationReservations.remove(authority)
        }
        activeTransactions = max(0, activeTransactions - 1)
        condition.broadcast()
        condition.unlock()
    }

    /// Must be called off the main thread. It returns only after all work
    /// admitted before finalization, including reserved confirmations, has
    /// completed. New ordinary work cannot enter while `finalizing == true`.
    func waitForFinalizationDrain() {
        condition.lock()
        while activeTransactions > 0 || !confirmationReservations.isEmpty {
            condition.wait()
        }
        condition.unlock()
    }
}

enum PriceTagCaptureAuditCode: String, CaseIterable {
    case startUnavailable = "price_tag_capture_start_unavailable"
    case captureCancelled = "price_tag_capture_cancelled"
    case roiUnavailable = "price_tag_capture_roi_unavailable"
    case roiMiss = "price_tag_capture_roi_miss"
    case visionFailed = "price_tag_capture_vision_failed"
    case multipleBarcodes = "price_tag_multiple_barcodes"
    case duplicateFrame = "price_tag_capture_duplicate_frame"
    case duplicateCompleted = "price_tag_capture_duplicate_completed"
    case trackingUnavailable = "price_tag_tracking_unavailable"
    case measurementUnavailable = "price_tag_measurement_unavailable"
    case evidenceWriteFailed = "price_tag_capture_evidence_write_failed"
    case captureTimeout = "price_tag_capture_timeout"
    case shelfUnavailable = "price_tag_shelf_unavailable"
    case shelfAmbiguous = "price_tag_shelf_ambiguous"
    case userRescan = "price_tag_user_rescan"
    case illegalTransition = "price_tag_capture_illegal_transition"
    case confirmationAdmissionRejected =
        "price_tag_confirmation_admission_rejected"
    case confirmationPersistenceFailed =
        "price_tag_confirmation_persistence_failed"
}

enum PriceTagConfirmationIdentityValidator {
    static func matches(
        tag: LocalizedPriceTag,
        authority: PriceTagConfirmationCommitAuthority,
        configuration: PriorMapScanConfiguration,
        trackingSessionID: String
    ) -> Bool {
        return configuration.workflowMode == .priorMapLocalized
            && configuration.isReadyToStart
            && authority.trackingSessionID == trackingSessionID
            && authority.priorMapID == configuration.priorMapId
            && authority.priorMapSHA256 == configuration.priorMapSha256
            && authority.floorID == configuration.floorId
            && tag.trackingSessionId == authority.trackingSessionID
            && tag.priorMapId == authority.priorMapID
            && tag.priorMapSha256 == authority.priorMapSHA256
            && tag.floorId == authority.floorID
            && tag.captureId == authority.captureID.uuidString.lowercased()
    }
}

struct PriceTagCaptureResolution {
    let tag: LocalizedPriceTag
    let candidates: [PriceTagShelfCandidate]
    let algorithmCandidateReliable: Bool
}

enum PriceTagCaptureResolver {
    static func resolve(
        _ frames: [PriceTagShelfAssociationResult],
        minimumEvidenceFrames: Int
    ) -> PriceTagCaptureResolution? {
        guard frames.count >= minimumEvidenceFrames,
              let first = frames.first,
              frames.allSatisfy({
                  $0.tag.payload == first.tag.payload
                      && $0.tag.symbology == first.tag.symbology
              }),
              Set(frames.map(\.tag.observationId)).count == frames.count else {
            return nil
        }
        struct GroupKey: Hashable {
            let segmentID: String
            let side: String
        }
        var groupIndices: [GroupKey: [Int]] = [:]
        for (index, frame) in frames.enumerated() {
            if frame.algorithmCandidateReliable,
               !frame.tag.needsReview,
               let segmentID = frame.tag.algorithmShelfSegmentId
                ?? frame.tag.shelfSegmentId,
               let side = frame.tag.algorithmSide ?? frame.tag.shelfSide {
                groupIndices[GroupKey(segmentID: segmentID, side: side), default: []]
                    .append(index)
            }
        }
        let rankedGroups = groupIndices.sorted {
            if $0.value.count != $1.value.count {
                return $0.value.count > $1.value.count
            }
            if $0.key.segmentID != $1.key.segmentID {
                return $0.key.segmentID < $1.key.segmentID
            }
            return $0.key.side < $1.key.side
        }
        let stableGroup = rankedGroups.first.flatMap { firstGroup -> [Int]? in
            guard firstGroup.value.count >= minimumEvidenceFrames else {
                return nil
            }
            if rankedGroups.count > 1,
               rankedGroups[1].value.count == firstGroup.value.count {
                return nil
            }
            return firstGroup.value
        }
        let candidateIndices = stableGroup ?? Array(frames.indices)
        guard let selectedIndex = candidateIndices.max(by: { left, right in
            quality(frames[left].tag) < quality(frames[right].tag)
        }) else {
            return nil
        }
        var candidatesByIdentity: [String: PriceTagShelfCandidate] = [:]
        for frame in frames {
            for candidate in frame.candidates {
                let identity = candidate.shelfSegmentId + "\u{0}" + candidate.side
                if candidatesByIdentity[identity] == nil
                    || candidate.associationConfidence
                        > candidatesByIdentity[identity]!.associationConfidence {
                    candidatesByIdentity[identity] = candidate
                }
            }
        }
        let candidates = candidatesByIdentity.values.sorted {
            if $0.associationConfidence != $1.associationConfidence {
                return $0.associationConfidence > $1.associationConfidence
            }
            if $0.shelfSegmentId != $1.shelfSegmentId {
                return $0.shelfSegmentId < $1.shelfSegmentId
            }
            return $0.side < $1.side
        }
        return PriceTagCaptureResolution(
            tag: frames[selectedIndex].tag,
            candidates: Array(candidates.prefix(5)),
            algorithmCandidateReliable: stableGroup != nil
                && frames[selectedIndex].algorithmCandidateReliable)
    }

    private static func quality(_ tag: LocalizedPriceTag) -> Double {
        let reviewPenalty = tag.needsReview ? 0.0 : 1.0
        return reviewPenalty
            + 0.40 * tag.localizationConfidence
            + 0.35 * tag.measurementConfidence
            + 0.25 * tag.associationConfidence
    }
}

/// One serial logical authority guarded by a lock. Vision/depth work stays on
/// their existing queues, but no queue can mutate capture state directly.
final class PriceTagCaptureCoordinator {
    private let lock = NSLock()
    private let policy: PriceTagCapturePolicy
    private var stateValue = PriceTagCaptureState.idle
    private var geometryValue: PriceTagCaptureGeometry?
    private var visionInFlight = false
    private var visionInFlightFrameTimestamp: TimeInterval?
    private var evidenceInFlight = false
    private var lastVisionSubmission = -Double.infinity
    private var lastPreviewSubmission = -Double.infinity
    private var candidateLastFrameTimestamp = -Double.infinity
    private var captureStartedAt = -Double.infinity
    private var deadlinePending = false
    private var pendingEvidenceFrameTimestamp: TimeInterval?
    private var acceptedFrameTimestamps = Set<TimeInterval>()
    private var acceptedObservationIDs: [String] = []
    private var completedPayloads: [String: TimeInterval] = [:]
    private var capturePriorMapAuthorityValue: PriceTagCapturePriorMapAuthority?
    private var confirmationCommitAuthorityValue:
        PriceTagConfirmationCommitAuthority?
    private var confirmationCommitClaimed = false
    private var diagnostics: [String] = []

    init(policy: PriceTagCapturePolicy = .field) {
        self.policy = policy
    }

    func begin(
        now: TimeInterval,
        priorMapAuthority: PriceTagCapturePriorMapAuthority? = nil
    ) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let generation = UUID()
        resetTransientLocked()
        capturePriorMapAuthorityValue = priorMapAuthority
        completedPayloads = completedPayloads.filter {
            now - $0.value <= max(5, policy.completedDuplicateSuppressionSeconds)
        }
        stateValue = .entering(generation: generation)
        return generation
    }

    func markAiming(generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stateValue == .entering(generation: generation) else {
            illegalTransitionLocked("entering_to_aiming", generation: generation)
            return false
        }
        stateValue = .aiming(generation: generation)
        return true
    }

    func updateGeometry(_ geometry: PriceTagCaptureGeometry) {
        lock.lock()
        geometryValue = geometry
        lock.unlock()
    }

    func currentState() -> PriceTagCaptureState {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

    func isCurrent(_ generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stateValue.generation == generation
    }

    func matchesPriorMapAuthority(
        generation: UUID,
        priorMapGeneration: UUID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stateValue.generation == generation
            && capturePriorMapAuthorityValue?.priorMapGeneration
                == priorMapGeneration
    }

    func currentPriorMapGeneration() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard stateValue.generation != nil else { return nil }
        return capturePriorMapAuthorityValue?.priorMapGeneration
    }

    func currentPriorMapAuthority() -> PriceTagCapturePriorMapAuthority? {
        lock.lock()
        defer { lock.unlock() }
        guard stateValue.generation != nil else { return nil }
        return capturePriorMapAuthorityValue
    }

    func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stateValue != .idle
    }

    func shouldSubmitPreview(frameTimestamp: TimeInterval) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard let generation = stateValue.generation,
              frameTimestamp.isFinite,
              frameTimestamp - lastPreviewSubmission
                >= 1 / max(1, policy.previewRateHz) else {
            return nil
        }
        lastPreviewSubmission = frameTimestamp
        return generation
    }

    func requestVisionSubmission(
        frameTimestamp: TimeInterval
    ) -> PriceTagVisionSubmission? {
        lock.lock()
        defer { lock.unlock() }
        guard let generation = stateValue.generation,
              let geometry = geometryValue,
              frameTimestamp.isFinite,
              !visionInFlight,
              !evidenceInFlight,
              !deadlinePending,
              isDetectionStateLocked(),
              frameTimestamp - lastVisionSubmission
                >= 1 / max(1, policy.visionRateHz) else {
            return nil
        }
        visionInFlight = true
        visionInFlightFrameTimestamp = frameTimestamp
        lastVisionSubmission = frameTimestamp
        return PriceTagVisionSubmission(
            generation: generation,
            geometry: geometry)
    }

    /// Independent ARFrame-driven deadline. It does not depend on a successful
    /// Vision request or evidence callback. A Vision request still running at
    /// the deadline loses coordinator admission immediately, so its late
    /// callback is ignored. If one evidence frame is already in flight, the
    /// deadline is latched and that exact frame is allowed to reach the
    /// linearized durable boundary before the final resolve/timeout choice.
    func tickDeadline(
        frameTimestamp: TimeInterval
    ) -> PriceTagCaptureVisionAction {
        lock.lock()
        defer { lock.unlock() }
        guard frameTimestamp.isFinite else { return .ignored }
        if let requestTimestamp = visionInFlightFrameTimestamp,
           frameTimestamp - requestTimestamp
                >= policy.maximumVisionRequestDuration {
            visionInFlight = false
            visionInFlightFrameTimestamp = nil
            return .requestTimedOut(frameTimestamp: requestTimestamp)
        }
        guard case .collecting(
                let generation, let captureID, _, _, _, _) = stateValue,
              frameTimestamp - captureStartedAt
                >= policy.maximumCaptureDuration else {
            return .ignored
        }
        deadlinePending = true
        // Vision has not crossed the evidence persistence boundary. Revoking
        // its in-flight bit makes the eventual callback generation-current but
        // admission-stale, which finishVision() rejects without side effects.
        visionInFlight = false
        visionInFlightFrameTimestamp = nil
        guard !evidenceInFlight else {
            return .ignored
        }
        return finishDeadlineLocked(
            generation: generation,
            captureID: captureID,
            revokeVisionRequest: true)
    }

    func finishVision(
        generation: UUID,
        frameTimestamp: TimeInterval,
        candidates: [PriceTagBarcodeCandidate],
        regionOfInterest: CGRect
    ) -> PriceTagCaptureVisionAction {
        lock.lock()
        defer { lock.unlock() }
        guard stateValue.generation == generation,
              visionInFlight,
              visionInFlightFrameTimestamp == frameTimestamp else {
            return .ignored
        }
        visionInFlight = false
        visionInFlightFrameTimestamp = nil
        let selection = PriceTagBarcodeSelector.select(
            candidates: candidates,
            regionOfInterest: regionOfInterest,
            minimumIntersectionRatio: policy.minimumROIIntersectionRatio,
            minimumNormalizedArea: policy.minimumCandidateNormalizedArea,
            ambiguityScoreDelta: policy.ambiguityScoreDelta)
        switch selection {
        case .none:
            if case .candidate = stateValue {
                stateValue = .aiming(generation: generation)
                candidateLastFrameTimestamp = -Double.infinity
            }
            if case .collecting(_, let captureID, _, _, _, _) = stateValue,
               deadlineReachedLocked(frameTimestamp: frameTimestamp) {
                return finishDeadlineLocked(
                    generation: generation,
                    captureID: captureID)
            }
            return .keepAiming(code: "price_tag_roi_miss")
        case .ambiguous:
            if case .collecting(_, let captureID, _, _, _, _) = stateValue,
               deadlineReachedLocked(frameTimestamp: frameTimestamp) {
                return finishDeadlineLocked(
                    generation: generation,
                    captureID: captureID)
            }
            if case .candidate = stateValue {
                stateValue = .aiming(generation: generation)
            }
            return .multipleBarcodes
        case .selected(let selected):
            let payload = selected.candidate.payload
            let symbology = selected.candidate.symbology
            if let completedAt = completedPayloads[payload],
               frameTimestamp - completedAt
                < policy.completedDuplicateSuppressionSeconds,
               !isCollectingLocked() {
                return .duplicateCompleted(payload: payload)
            }
            switch stateValue {
            case .aiming:
                candidateLastFrameTimestamp = frameTimestamp
                stateValue = .candidate(
                    generation: generation,
                    payload: payload,
                    symbology: symbology,
                    firstSeenMonotonic: frameTimestamp,
                    lockFrames: 1)
                return .candidateSeen(
                    payload: payload,
                    lockFrames: 1,
                    requiredFrames: policy.minimumCandidateLockFrames)
            case .candidate(
                _, let previousPayload, let previousSymbology,
                let firstSeen, let lockFrames):
                guard frameTimestamp > candidateLastFrameTimestamp else {
                    return .keepAiming(code: "price_tag_duplicate_detection_frame")
                }
                candidateLastFrameTimestamp = frameTimestamp
                guard payload == previousPayload,
                      symbology == previousSymbology else {
                    stateValue = .candidate(
                        generation: generation,
                        payload: payload,
                        symbology: symbology,
                        firstSeenMonotonic: frameTimestamp,
                        lockFrames: 1)
                    return .candidateSeen(
                        payload: payload,
                        lockFrames: 1,
                        requiredFrames: policy.minimumCandidateLockFrames)
                }
                let updatedFrames = lockFrames + 1
                guard updatedFrames >= policy.minimumCandidateLockFrames else {
                    stateValue = .candidate(
                        generation: generation,
                        payload: payload,
                        symbology: symbology,
                        firstSeenMonotonic: firstSeen,
                        lockFrames: updatedFrames)
                    return .candidateSeen(
                        payload: payload,
                        lockFrames: updatedFrames,
                        requiredFrames: policy.minimumCandidateLockFrames)
                }
                let captureID = UUID()
                resetCollectionLocked()
                captureStartedAt = frameTimestamp
                pendingEvidenceFrameTimestamp = frameTimestamp
                evidenceInFlight = true
                stateValue = .collecting(
                    generation: generation,
                    captureID: captureID,
                    payload: payload,
                    symbology: symbology,
                    acceptedFrames: 0,
                    requiredFrames: policy.targetEvidenceFrames)
                return .candidateLocked(
                    captureID: captureID,
                    barcode: selected)
            case .collecting(
                _, let captureID, let activePayload, let activeSymbology,
                _, _):
                guard payload == activePayload,
                      symbology == activeSymbology else {
                    if deadlinePending {
                        return finishDeadlineLocked(
                            generation: generation,
                            captureID: captureID)
                    }
                    stateValue = .candidate(
                        generation: generation,
                        payload: payload,
                        symbology: symbology,
                        firstSeenMonotonic: frameTimestamp,
                        lockFrames: 1)
                    resetCollectionLocked()
                    candidateLastFrameTimestamp = frameTimestamp
                    return .targetChanged(
                        previousCaptureID: captureID,
                        payload: payload)
                }
                guard !acceptedFrameTimestamps.contains(frameTimestamp),
                      pendingEvidenceFrameTimestamp != frameTimestamp else {
                    if deadlinePending {
                        return finishDeadlineLocked(
                            generation: generation,
                            captureID: captureID)
                    }
                    return .keepAiming(code: "price_tag_duplicate_capture_frame")
                }
                pendingEvidenceFrameTimestamp = frameTimestamp
                evidenceInFlight = true
                return .collect(captureID: captureID, barcode: selected)
            default:
                return .ignored
            }
        }
    }

    func failVision(
        generation: UUID,
        frameTimestamp: TimeInterval
    ) {
        lock.lock()
        guard stateValue.generation == generation,
              visionInFlightFrameTimestamp == frameTimestamp else {
            lock.unlock()
            return
        }
        visionInFlight = false
        visionInFlightFrameTimestamp = nil
        lock.unlock()
    }

    /// Linearizes the last generation/capture/frame check with the durable
    /// observation append. Without this boundary, cancellation can flush the
    /// pending burst after a callback's last generation check but before its
    /// append; that stale callback could then create a second pending burst
    /// with the same capture ID and make the finalized evidence ambiguous.
    ///
    /// The body must not call back into this coordinator. It is intentionally
    /// executed while the coordinator lock is held so cancellation has only
    /// two safe orders: win before the append (body is skipped), or wait until
    /// the append has joined the still-active burst.
    @discardableResult
    func performEvidenceCommitIfCurrent(
        generation: UUID,
        captureID: UUID,
        frameTimestamp: TimeInterval,
        priorMapGeneration: UUID,
        _ body: () -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .collecting(
                let currentGeneration, let currentCaptureID,
                _, _, _, _) = stateValue,
              currentGeneration == generation,
              currentCaptureID == captureID,
              capturePriorMapAuthorityValue?.priorMapGeneration
                == priorMapGeneration,
              evidenceInFlight,
              pendingEvidenceFrameTimestamp == frameTimestamp else {
            return false
        }
        body()
        return true
    }

    func finishEvidence(
        generation: UUID,
        captureID: UUID,
        frameTimestamp: TimeInterval,
        observationID: String,
        succeeded: Bool
    ) -> PriceTagCaptureEvidenceAction {
        lock.lock()
        defer { lock.unlock() }
        guard case .collecting(
                let currentGeneration, let currentCaptureID,
                let payload, let symbology, _, let requiredFrames) = stateValue,
              currentGeneration == generation,
              currentCaptureID == captureID,
              evidenceInFlight,
              pendingEvidenceFrameTimestamp == frameTimestamp else {
            return .ignored
        }
        evidenceInFlight = false
        pendingEvidenceFrameTimestamp = nil
        guard succeeded,
              frameTimestamp.isFinite,
              !observationID.isEmpty,
              !acceptedFrameTimestamps.contains(frameTimestamp),
              !acceptedObservationIDs.contains(observationID) else {
            stateValue = .cancelling(
                generation: generation,
                reason: "price_tag_evidence_write_failure")
            resetTransientLocked(keepingState: true)
            return .requiredEvidenceFailed(captureID: captureID)
        }
        acceptedFrameTimestamps.insert(frameTimestamp)
        acceptedObservationIDs.append(observationID)
        let accepted = acceptedObservationIDs.count
        let duration = frameTimestamp - captureStartedAt
        let reachedTarget = accepted >= policy.targetEvidenceFrames
            && duration >= policy.minimumCaptureDuration
        let reachedDeadline = deadlinePending
            || duration >= policy.maximumCaptureDuration
        if reachedTarget
            || (reachedDeadline && accepted >= policy.minimumEvidenceFrames) {
            stateValue = .resolving(
                generation: generation,
                captureID: captureID)
            return .resolve(
                captureID: captureID,
                observationIDs: acceptedObservationIDs)
        }
        if reachedDeadline {
            stateValue = .aiming(generation: generation)
            resetCollectionLocked()
            return .timedOut(captureID: captureID)
        }
        stateValue = .collecting(
            generation: generation,
            captureID: captureID,
            payload: payload,
            symbology: symbology,
            acceptedFrames: accepted,
            requiredFrames: requiredFrames)
        return .continueCollecting(
            acceptedFrames: accepted,
            requiredFrames: requiredFrames)
    }

    func markConfirming(generation: UUID, captureID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stateValue == .resolving(
                generation: generation,
                captureID: captureID),
              let authority = capturePriorMapAuthorityValue else {
            illegalTransitionLocked("resolving_to_confirming", generation: generation)
            return false
        }
        confirmationCommitAuthorityValue = PriceTagConfirmationCommitAuthority(
            captureGeneration: generation,
            captureID: captureID,
            priorMapGeneration: authority.priorMapGeneration,
            trackingSessionID: authority.trackingSessionID,
            priorMapID: authority.priorMapID,
            priorMapSHA256: authority.priorMapSHA256,
            floorID: authority.floorID)
        confirmationCommitClaimed = false
        stateValue = .confirming(
            generation: generation,
            captureID: captureID)
        return true
    }

    /// Atomically claims the one durable confirmation write. A cancellation
    /// that wins first moves the state to idle and this returns nil. Once this
    /// returns an authority, later cancellation is ordered after the accepted
    /// decision and cannot invalidate that same in-flight write.
    func claimConfirmationCommit(
        generation: UUID,
        captureID: UUID
    ) -> PriceTagConfirmationCommitAuthority? {
        lock.lock()
        defer { lock.unlock() }
        guard stateValue == .confirming(
                generation: generation,
                captureID: captureID),
              !confirmationCommitClaimed,
              let authority = confirmationCommitAuthorityValue,
              authority.captureGeneration == generation,
              authority.captureID == captureID else {
            return nil
        }
        confirmationCommitClaimed = true
        return authority
    }

    /// Returns the immutable authority that may be reserved by the session
    /// writer before the coordinator claim. A cancellation may still win
    /// after this snapshot; in that case the subsequent claim fails and the
    /// caller must release the session reservation.
    func pendingConfirmationCommitAuthority(
        generation: UUID,
        captureID: UUID
    ) -> PriceTagConfirmationCommitAuthority? {
        lock.lock()
        defer { lock.unlock() }
        guard stateValue == .confirming(
                generation: generation,
                captureID: captureID),
              !confirmationCommitClaimed,
              let authority = confirmationCommitAuthorityValue,
              authority.captureGeneration == generation,
              authority.captureID == captureID else {
            return nil
        }
        return authority
    }

    func isConfirmationCommitInFlight(
        _ authority: PriceTagConfirmationCommitAuthority
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return confirmationCommitClaimed
            && confirmationCommitAuthorityValue == authority
            && stateValue == .confirming(
                generation: authority.captureGeneration,
                captureID: authority.captureID)
    }

    func finishConfirmation(
        generation: UUID,
        payload: String,
        completedAt: TimeInterval,
        committed: Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .confirming(let current, _) = stateValue,
              current == generation,
              !committed || confirmationCommitClaimed else {
            illegalTransitionLocked("confirming_to_idle", generation: generation)
            return false
        }
        if committed {
            completedPayloads[payload] = completedAt
        }
        stateValue = .idle
        resetTransientLocked(keepingState: true)
        return true
    }

    func cancel(reason: String) -> PriceTagCaptureCancellation? {
        lock.lock()
        defer { lock.unlock() }
        guard let generation = stateValue.generation else { return nil }
        let captureID: UUID?
        switch stateValue {
        case .collecting(_, let value, _, _, _, _),
             .resolving(_, let value),
             .confirming(_, let value):
            captureID = value
        default:
            captureID = nil
        }
        if confirmationCommitClaimed {
            return PriceTagCaptureCancellation(
                generation: generation,
                captureID: captureID,
                reason: reason,
                confirmationCommitInFlight: true)
        }
        stateValue = .cancelling(generation: generation, reason: reason)
        resetTransientLocked(keepingState: true)
        stateValue = .idle
        return PriceTagCaptureCancellation(
            generation: generation,
            captureID: captureID,
            reason: reason,
            confirmationCommitInFlight: false)
    }

    func drainDiagnostics() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let values = diagnostics
        diagnostics.removeAll(keepingCapacity: true)
        return values
    }

    private func isDetectionStateLocked() -> Bool {
        switch stateValue {
        case .aiming, .candidate, .collecting:
            return true
        default:
            return false
        }
    }

    private func isCollectingLocked() -> Bool {
        if case .collecting = stateValue { return true }
        return false
    }

    private func resetCollectionLocked() {
        captureStartedAt = -Double.infinity
        deadlinePending = false
        pendingEvidenceFrameTimestamp = nil
        acceptedFrameTimestamps.removeAll(keepingCapacity: true)
        acceptedObservationIDs.removeAll(keepingCapacity: true)
        evidenceInFlight = false
    }

    private func deadlineReachedLocked(
        frameTimestamp: TimeInterval
    ) -> Bool {
        return deadlinePending
            || frameTimestamp - captureStartedAt
                >= policy.maximumCaptureDuration
    }

    private func finishDeadlineLocked(
        generation: UUID,
        captureID: UUID,
        revokeVisionRequest: Bool = false
    ) -> PriceTagCaptureVisionAction {
        if acceptedObservationIDs.count >= policy.minimumEvidenceFrames {
            stateValue = .resolving(
                generation: generation,
                captureID: captureID)
            return .resolve(
                captureID: captureID,
                observationIDs: acceptedObservationIDs)
        }
        stateValue = .aiming(generation: generation)
        resetCollectionLocked()
        return .timedOut(
            captureID: captureID,
            revokeVisionRequest: revokeVisionRequest)
    }

    private func resetTransientLocked(keepingState: Bool = false) {
        geometryValue = keepingState ? geometryValue : nil
        visionInFlight = false
        visionInFlightFrameTimestamp = nil
        lastVisionSubmission = -Double.infinity
        lastPreviewSubmission = -Double.infinity
        candidateLastFrameTimestamp = -Double.infinity
        resetCollectionLocked()
        capturePriorMapAuthorityValue = nil
        confirmationCommitAuthorityValue = nil
        confirmationCommitClaimed = false
    }

    private func illegalTransitionLocked(_ name: String, generation: UUID) {
        let message = "price_tag_capture_illegal_transition:\(name):\(generation.uuidString)"
        diagnostics.append(message)
        if diagnostics.count > 32 {
            diagnostics.removeFirst(diagnostics.count - 32)
        }
        #if DEBUG
        assertionFailure(message)
        #endif
    }
}
