import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import Dispatch
import ImageIO
import SQLite3

extension Date {
    func getFormattedDate(format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: self)
    }
}

// Foundation-host stubs for the ARKit/UI-owned types consumed by
// SupermarketScanSession. Production definitions remain in their iOS files;
// the host executable uses these exact Codable shapes to exercise real session
// admission and persistence code without importing UIKit.
struct ScanStructureCoverageCell: Codable {
    let x: Int
    let z: Int
    let floorObservationCount: Int
    let elevatedObservationCount: Int
    let highObservationCount: Int
    let distinctTimeBucketCount: Int
    let viewDirectionMask: Int
    let highConfidenceObservationCount: Int
    let firstElevatedObservedAt: TimeInterval?
    let lastElevatedObservedAt: TimeInterval?
    let lastObservedAt: TimeInterval
}

struct ScanStructureCoverageSummary: Codable {
    let evaluatedDepthFrameCount: Int
    let depthUnavailableFrameCount: Int
    let validDepthSampleCount: Int
    let observedCellCount: Int
    let floorCellCount: Int
    let elevatedCellCount: Int
    let stableStructureCellCount: Int
    let multiViewStructureCellCount: Int
    let groundConflictCellCount: Int
    let singleViewStructureCellCount: Int
    let coverageScore: Double
    let currentDetectionRateHz: Double
}

struct ScanStructureCoverageSnapshot: Codable {
    let format: String
    let version: Int
    let updatedAt: String
    let cellSizeM: Double
    let floorHeightM: Double?
    let summary: ScanStructureCoverageSummary
    let cells: [ScanStructureCoverageCell]
}

struct PriorMapRoadCandidate: Codable {
    let edgeId: String
    let distanceM: Double
}

struct PriorMapLocalizationUpdate: Codable {
    let format: String
    let version: Int
    let timestamp: TimeInterval
    let trackingState: String
    let localizationState: String
    let confidence: Double
    let rawPose: PriorMapPose2D
    let estimatedPose: PriorMapPose2D
    let roadCandidates: [PriorMapRoadCandidate]
    let structureSource: String
    let structurePointCount: Int
    let structureCoverageAngleRad: Double
    let matchCandidates: [PriorMapScanMatchCandidate]
    let matchUniqueness: Double
    let matchResidualCost: Double?
    let matcherElapsedMs: Double
    let constraintAccepted: Bool
    let constraintReason: String
    var measurementAccepted = false
    var hypothesisTrusted = false
    var correctionStepApplied = false
    var recoveryConvergedThisUpdate = false
    var confidenceAccepted = false
    var constraintDisposition: PriorMapConstraintDisposition = .rejected
    var trackingSessionId: String? = nil
    var priorMapId: String? = nil
    var priorMapSha256: String? = nil
    var floorId: String? = nil
    var nodeTimebaseTimestamp: TimeInterval? = nil
    var nodeTimebaseOffsetSeconds: TimeInterval? = nil
}

final class InjectedSidecarWriter: ScanSidecarFileWriting {
    var storage: [URL: Data] = [:]
    var writeError: Error?
    var appendError: Error?
    var appendErrors: [URL: Error] = [:]
    var removeError: Error?

    func fileExists(at url: URL) -> Bool {
        return storage[url] != nil
    }

    func append(_ data: Data, to url: URL) throws {
        if let error = appendErrors[url] { throw error }
        if let appendError { throw appendError }
        storage[url, default: Data()].append(data)
    }

    func writeAtomic(_ data: Data, to url: URL) throws {
        if let writeError { throw writeError }
        storage[url] = data
    }

    func removeItem(at url: URL) throws {
        if let removeError { throw removeError }
        storage.removeValue(forKey: url)
    }
}

final class BlockingFirstAppendSidecarWriter: ScanSidecarFileWriting {
    let firstAppendEntered = DispatchSemaphore(value: 0)
    let releaseFirstAppend = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var appendCount = 0
    private var storage: [URL: Data] = [:]

    func fileExists(at url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[url] != nil
    }

    func append(_ data: Data, to url: URL) throws {
        lock.lock()
        let shouldBlock = appendCount == 0
        appendCount += 1
        lock.unlock()
        if shouldBlock {
            firstAppendEntered.signal()
            _ = releaseFirstAppend.wait(timeout: .now() + 5)
        }
        lock.lock()
        storage[url, default: Data()].append(data)
        lock.unlock()
    }

    func writeAtomic(_ data: Data, to url: URL) throws {
        lock.lock()
        storage[url] = data
        lock.unlock()
    }

    func removeItem(at url: URL) throws {
        lock.lock()
        storage.removeValue(forKey: url)
        lock.unlock()
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(1)
    }
}

func close(_ first: Double, _ second: Double, tolerance: Double = 1.0e-9) -> Bool {
    return abs(first - second) <= tolerance
}

require(
    !PriorMapNodeTimebaseAdmission.accepts(offsetSeconds: nil),
    "a missing native node timebase must wait without writing evidence")
require(
    !PriorMapNodeTimebaseAdmission.accepts(offsetSeconds: .nan)
        && !PriorMapNodeTimebaseAdmission.accepts(offsetSeconds: .infinity),
    "non-finite node-time offsets must never enter required evidence")
require(
    PriorMapNodeTimebaseAdmission.accepts(offsetSeconds: 0)
        && PriorMapNodeTimebaseAdmission.accepts(offsetSeconds: -123.5),
    "every finite native node-time offset must remain admissible")
require(
    MobileOnlyWorkflowState.scanning.allowsTransition(to: .finalizingScan)
        && MobileOnlyWorkflowState.finalizingScan.allowsTransition(to: .scanning)
        && MobileOnlyWorkflowState.finalizingScan.allowsTransition(to: .idle),
    "scan finalization must support terminal close and recoverable resume")
if case .success = MobileHistoricalProcessingAdmission.evaluate(
    currentState: .idle,
    processingBusy: false
) {
    // Expected.
} else {
    require(false, "idle must admit historical processing")
}
for rejectedState in [
    MobileOnlyWorkflowState.pickingMap,
    .stagingMapSource,
    .importingMap,
    .compilingMap,
    MobileOnlyWorkflowState.mapReady,
    .configuringScan,
    .startingScan,
    .scanning,
    .finalizingScan,
    .snapshotting,
    .fastProcessing,
    .deepProcessing,
    .buildingTrajectory,
    .resolvingTags,
    .exporting,
] {
    if case .failure(.illegalTransition) =
        MobileHistoricalProcessingAdmission.evaluate(
            currentState: rejectedState,
            processingBusy: false) {
        // Expected.
    } else {
        require(
            false,
            "active state \(rejectedState.rawValue) must reject historical processing")
    }
}
require(
    !MobileOnlyWorkflowState.mapReady.allowsTransition(to: .snapshotting),
    "historical-processing repair must not broaden mapReady -> snapshotting")
require(
    MobileOnlyWorkflowState.finalizingScan.allowsTransition(to: .snapshotting),
    "scan lifecycle transition table must retain its internal finalization edge")
if case .failure(.invalidState) =
    MobileHistoricalProcessingAdmission.evaluate(
        currentState: .idle,
        processingBusy: true) {
    // Expected.
} else {
    require(false, "duplicate historical processing admission must be rejected")
}
let previewProjectionBounds = SourceGeometry.Bounds(
    minX_m: 0,
    minY_m: -100,
    maxX_m: 200,
    maxY_m: 0)
let previewLowerLeft = MobilePreviewRenderer.quartzPoint(
    xM: 0,
    yM: -100,
    bounds: previewProjectionBounds,
    canvasWidth: 1_000,
    canvasHeight: 500)
let previewUpperRight = MobilePreviewRenderer.quartzPoint(
    xM: 200,
    yM: 0,
    bounds: previewProjectionBounds,
    canvasWidth: 1_000,
    canvasHeight: 500)
require(
    close(Double(previewLowerLeft.x), 0)
        && close(Double(previewLowerLeft.y), 0)
        && close(Double(previewUpperRight.x), 1_000)
        && close(Double(previewUpperRight.y), 500),
    "Quartz preview projection must preserve canonical map +Y without a second flip")

func runESLFinalizationBindingFocusedTests() {
    do {
        let cleanDirectory = try p7r6FreshDirectory("esl-focused-clean")
        _ = try p7r6WriteBaseBundle(in: cleanDirectory)
        try p7r6WriteTagBurstBindingFixture(in: cleanDirectory)
        let cleanBlockers = LocalizationEvidenceBundleValidator.blockers(
            in: cleanDirectory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 0,
                tagBurstCount: 1,
                tagBurstLastID: "burst-1"))
        require(
            cleanBlockers.isEmpty,
            "ESL focused exact durable binding must finalize: \(cleanBlockers)")

        let mismatchedDirectory = try p7r6FreshDirectory(
            "esl-focused-mismatch")
        _ = try p7r6WriteBaseBundle(in: mismatchedDirectory)
        try p7r6WriteTagBurstBindingFixture(
            in: mismatchedDirectory,
            observationFrameID: "different-frame")
        let mismatchedBlockers = LocalizationEvidenceBundleValidator.blockers(
            in: mismatchedDirectory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 0,
                tagBurstCount: 1,
                tagBurstLastID: "burst-1"))
        require(
            mismatchedBlockers.contains(
                "evidence_bundle_tag_burst_observation_binding_mismatch"),
            "ESL focused mismatched durable binding must block: "
                + "\(mismatchedBlockers)")

        let extraDirectory = try p7r6FreshDirectory("esl-focused-extra")
        _ = try p7r6WriteBaseBundle(in: extraDirectory)
        try p7r6WriteTagBurstBindingFixture(
            in: extraDirectory,
            includeUnlistedBoundObservation: true)
        let extraBlockers = LocalizationEvidenceBundleValidator.blockers(
            in: extraDirectory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 0,
                tagBurstCount: 1,
                tagBurstLastID: "burst-1"))
        require(
            extraBlockers.contains(
                "evidence_bundle_tag_burst_observation_binding_mismatch"),
            "ESL focused unlisted durable binding must block: "
                + "\(extraBlockers)")

        let sequenceCleanDirectory = try p7r6FreshDirectory(
            "esl-focused-sequence-clean")
        _ = try p7r6WriteBaseBundle(in: sequenceCleanDirectory)
        let sequenceLastID = try p7r6WriteBurstSequenceFixture(
            in: sequenceCleanDirectory,
            sequences: [1, 2])
        let sequenceCleanBlockers =
            LocalizationEvidenceBundleValidator.blockers(
                in: sequenceCleanDirectory,
                expectation: p7r6BundleExpectation(
                    recoveryCount: 0,
                    tagBurstCount: 2,
                    tagBurstLastID: sequenceLastID))
        require(
            sequenceCleanBlockers.isEmpty,
            "strictly increasing burst sequences must finalize: "
                + "\(sequenceCleanBlockers)")

        for (label, sequences) in [
            ("duplicate", [1, 1]),
            ("decreasing", [2, 1]),
        ] {
            let directory = try p7r6FreshDirectory(
                "esl-focused-sequence-\(label)")
            _ = try p7r6WriteBaseBundle(in: directory)
            let lastID = try p7r6WriteBurstSequenceFixture(
                in: directory,
                sequences: sequences)
            let blockers = LocalizationEvidenceBundleValidator.blockers(
                in: directory,
                expectation: p7r6BundleExpectation(
                    recoveryCount: 0,
                    tagBurstCount: sequences.count,
                    tagBurstLastID: lastID))
            require(
                blockers.contains(
                    "evidence_bundle_tag_observation_bursts.jsonl_tag_burst_sequence_invalid"),
                "\(label) burst sequence must fail closed: \(blockers)")
        }

        let confirmedDirectory = try p7r6FreshDirectory(
            "esl-focused-confirmed-clean")
        _ = try p7r6WriteBaseBundle(in: confirmedDirectory)
        let confirmedCaptureID = try p7r6WriteConfirmedTagBurstFixture(
            in: confirmedDirectory)
        let confirmedBlockers = LocalizationEvidenceBundleValidator.blockers(
            in: confirmedDirectory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 0,
                localizedPriceTagCount: 1,
                tagBurstCount: 1,
                tagBurstLastID: confirmedCaptureID))
        require(
            confirmedBlockers.isEmpty,
            "localized v2 tag must match its verified burst authority: "
                + "\(confirmedBlockers)")

        for (label, payload, symbology) in [
            ("payload", "DIFFERENT-PAYLOAD", "EAN13"),
            ("symbology", "6901234567890", "Code128"),
        ] {
            let directory = try p7r6FreshDirectory(
                "esl-focused-confirmed-\(label)")
            _ = try p7r6WriteBaseBundle(in: directory)
            let captureID = try p7r6WriteConfirmedTagBurstFixture(
                in: directory,
                tagPayload: payload,
                tagSymbology: symbology)
            let blockers = LocalizationEvidenceBundleValidator.blockers(
                in: directory,
                expectation: p7r6BundleExpectation(
                    recoveryCount: 0,
                    localizedPriceTagCount: 1,
                    tagBurstCount: 1,
                    tagBurstLastID: captureID))
            require(
                blockers.contains(
                    "evidence_bundle_localized_price_tags_tag_confirmation_schema_invalid"),
                "localized tag \(label) tamper must fail closed: \(blockers)")
        }
    } catch {
        require(false, "ESL finalization focused tests failed: \(error)")
    }
    print("ESL finalization binding focused tests passed")
}

// MARK: - ESL barcode capture focused blocker tests

func runESLBarcodeCaptureFocusedTests() {
    func closeRect(
        _ first: CGRect,
        _ second: CGRect,
        tolerance: Double = 1.0e-9
    ) -> Bool {
        return close(Double(first.minX), Double(second.minX), tolerance: tolerance)
            && close(Double(first.minY), Double(second.minY), tolerance: tolerance)
            && close(Double(first.width), Double(second.width), tolerance: tolerance)
            && close(Double(first.height), Double(second.height), tolerance: tolerance)
    }

    let selectorROI = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    func barcode(
        _ payload: String,
        _ bounds: CGRect,
        symbology: String = "EAN13"
    ) -> PriceTagBarcodeCandidate {
        return PriceTagBarcodeCandidate(
            payload: payload,
            symbology: symbology,
            visionBounds: bounds)
    }
    func select(
        _ candidates: [PriceTagBarcodeCandidate],
        roi: CGRect? = nil
    ) -> PriceTagBarcodeSelection {
        return PriceTagBarcodeSelector.select(
            candidates: candidates,
            regionOfInterest: roi ?? selectorROI,
            minimumIntersectionRatio: 0.8,
            minimumNormalizedArea: 0.002,
            ambiguityScoreDelta: 0.08)
    }
    func isSelected(_ selection: PriceTagBarcodeSelection) -> Bool {
        if case .selected = selection { return true }
        return false
    }
    func isNone(_ selection: PriceTagBarcodeSelection) -> Bool {
        if case .none = selection { return true }
        return false
    }
    func isAmbiguous(_ selection: PriceTagBarcodeSelection) -> Bool {
        if case .ambiguous = selection { return true }
        return false
    }

    // BC-00: Vision revision 1 already reports full-image coordinates;
    // revision 2+ reports request-ROI-local coordinates and must be converted
    // with the exact request that produced the observation.
    let primaryRequestROI = CGRect(
        x: 0.2, y: 0.3, width: 0.5, height: 0.4)
    let localObservation = CGRect(
        x: 0.1, y: 0.2, width: 0.2, height: 0.2)
    let revisionOne = PriceTagVisionBoundingBoxNormalizer.fullImageBounds(
        observationBounds: localObservation,
        requestRegionOfInterest: primaryRequestROI,
        requestRevision: 1)
    require(
        revisionOne != nil
            && closeRect(revisionOne!, localObservation),
        "BC-00 revision 1 must preserve full-image observation bounds")
    let convertedPrimary =
        PriceTagVisionBoundingBoxNormalizer.fullImageBounds(
            observationBounds: localObservation,
            requestRegionOfInterest: primaryRequestROI,
            requestRevision: 2)
    let expectedPrimary = CGRect(
        x: 0.25, y: 0.38, width: 0.10, height: 0.08)
    require(
        convertedPrimary != nil
            && closeRect(convertedPrimary!, expectedPrimary),
        "BC-00 revision 2 must affinely restore primary ROI-local bounds")

    let operatorROI = CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2)
    let expandedRequestROI = CGRect(
        x: 0.2, y: 0.3, width: 0.6, height: 0.4)
    let expandedLocalInside = CGRect(
        x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    let convertedExpanded =
        PriceTagVisionBoundingBoxNormalizer.fullImageBounds(
            observationBounds: expandedLocalInside,
            requestRegionOfInterest: expandedRequestROI,
            requestRevision: 4)
    let expectedExpanded = CGRect(
        x: 0.44, y: 0.46, width: 0.12, height: 0.08)
    require(
        convertedExpanded != nil
            && closeRect(convertedExpanded!, expectedExpanded),
        "BC-00 expanded fallback must use the expanded request ROI")
    require(
        isSelected(select([
            barcode("expanded-inside", convertedExpanded!),
        ], roi: operatorROI)),
        "BC-00 expanded detection remains selectable only inside the operator ROI")
    let expandedLocalMargin = CGRect(
        x: 1.0 / 30.0,
        y: 0.4,
        width: 1.0 / 15.0,
        height: 0.2)
    let convertedMargin =
        PriceTagVisionBoundingBoxNormalizer.fullImageBounds(
            observationBounds: expandedLocalMargin,
            requestRegionOfInterest: expandedRequestROI,
            requestRevision: 2)
    require(
        convertedMargin != nil
            && isNone(select([
                barcode("expanded-margin", convertedMargin!),
            ], roi: operatorROI)),
        "BC-00 expanded-only margin detection must not enlarge the operator ROI")

    let sameLocalBounds = CGRect(
        x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    let leftFullBounds =
        PriceTagVisionBoundingBoxNormalizer.fullImageBounds(
            observationBounds: sameLocalBounds,
            requestRegionOfInterest: CGRect(
                x: 0.2, y: 0.4, width: 0.2, height: 0.2),
            requestRevision: 2)!
    let rightFullBounds =
        PriceTagVisionBoundingBoxNormalizer.fullImageBounds(
            observationBounds: sameLocalBounds,
            requestRegionOfInterest: CGRect(
                x: 0.6, y: 0.4, width: 0.2, height: 0.2),
            requestRevision: 2)!
    require(
        isAmbiguous(select([
            barcode("SAME-LOCAL", leftFullBounds),
            barcode("SAME-LOCAL", rightFullBounds),
        ], roi: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.2))),
        "BC-00 disjoint physical barcodes must not deduplicate by overlapping ROI-local boxes")

    let expectedNativeCenters: [PriorMapCapturedImageOrientation: CGPoint] = [
        .up: CGPoint(x: 0.30, y: 0.42),
        .down: CGPoint(x: 0.70, y: 0.58),
        .right: CGPoint(x: 0.58, y: 0.30),
        .left: CGPoint(x: 0.42, y: 0.70),
    ]
    for (orientation, expectedCenter) in expectedNativeCenters {
        let native = PriorMapImageGeometry.nativeSensorBounds(
            visionBounds: convertedPrimary!,
            orientation: orientation)
        require(
            close(Double(native.midX), Double(expectedCenter.x))
                && close(Double(native.midY), Double(expectedCenter.y)),
            "BC-00 \(orientation.rawValue) depth/ray center must use converted full-image bounds")
    }
    require(
        !close(Double(convertedPrimary!.midX), Double(localObservation.midX))
            && !close(
                Double(convertedPrimary!.midY),
                Double(localObservation.midY)),
        "BC-00 integration geometry must consume the converted center, not the ROI-local center")
    for invalid in [
        CGRect(x: 0.1, y: 0.1, width: -0.1, height: 0.2),
        CGRect(x: 0.1, y: 0.1, width: 0, height: 0.2),
        CGRect(x: 0.95, y: 0.1, width: 0.1, height: 0.2),
        CGRect(x: CGFloat.nan, y: 0.1, width: 0.1, height: 0.2),
    ] {
        require(
            PriceTagVisionBoundingBoxNormalizer.fullImageBounds(
                observationBounds: invalid,
                requestRegionOfInterest: primaryRequestROI,
                requestRevision: 2) == nil,
            "BC-00 invalid Vision evidence must fail closed")
    }
    require(
        PriceTagVisionBoundingBoxNormalizer.fullImageBounds(
            observationBounds: localObservation,
            requestRegionOfInterest: primaryRequestROI,
            requestRevision: 0) == nil,
        "BC-00 unsupported Vision revisions must fail closed")

    // BC-01: the visible scan box is also the actual detector ROI. Center,
    // containment and the 80% intersection threshold all apply.
    require(
        isSelected(select([
            barcode("inside", CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)),
        ])),
        "BC-01 a barcode centered inside the ROI must be accepted")
    require(
        isNone(select([
            barcode("outside", CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)),
        ])),
        "BC-01 a barcode outside the ROI must be rejected")
    require(
        isNone(select([
            // Center is inside, but only 20% of the candidate area overlaps.
            barcode("overlap-20", CGRect(x: 0, y: 0.45, width: 1, height: 0.1)),
        ])),
        "BC-01 20% ROI overlap must be rejected")
    require(
        isSelected(select([
            // 0.20 / 0.25 = exactly 80% horizontal overlap.
            barcode("overlap-80", CGRect(x: 0.35, y: 0.45, width: 0.25, height: 0.1)),
        ])),
        "BC-01 80% ROI overlap must be accepted")

    // BC-02: the one production mapper must round-trip the center and all
    // corners for every supported back-camera orientation.
    let previewBounds = CGRect(x: 0, y: 0, width: 390, height: 844)
    let scanRect = CGRect(x: 62, y: 292, width: 266, height: 180)
    let imageResolution = CGSize(width: 1920, height: 1080)
    let orientations: [CGImagePropertyOrientation] = [
        .up, .down, .left, .right,
    ]
    for orientation in orientations {
        do {
            let roi = try PriceTagScanROIMapper.visionRegionOfInterest(
                scanRectInView: scanRect,
                previewBounds: previewBounds,
                imageResolution: imageResolution,
                orientation: orientation,
                videoGravity: .resizeAspectFill)
            let roundTrip = try PriceTagScanROIMapper.viewRect(
                forVisionRegion: roi,
                previewBounds: previewBounds,
                imageResolution: imageResolution,
                orientation: orientation,
                videoGravity: .resizeAspectFill)
            require(
                closeRect(roundTrip, scanRect, tolerance: 1.0e-7),
                "BC-02 orientation \(orientation.rawValue) must round-trip center and corners")
            require(
                roi.contains(CGPoint(x: roi.midX, y: roi.midY)),
                "BC-02 mapped ROI center must remain inside")
        } catch {
            require(false, "BC-02 orientation mapping failed: \(error)")
        }
    }
    require(
        PriceTagScanROIMapper.orientedImageSize(
            imageResolution: imageResolution,
            orientation: .left) == CGSize(width: 1080, height: 1920),
        "BC-02 left/right orientations must swap sensor dimensions")
    require(
        PriceTagScanROIMapper.orientedImageSize(
            imageResolution: imageResolution,
            orientation: .down) == imageResolution,
        "BC-02 up/down orientations must retain sensor dimensions")

    // BC-03: outside candidates cannot steal the target and near-equal
    // in-ROI candidates fail closed as an ambiguity.
    let centerA = barcode(
        "A", CGRect(x: 0.445, y: 0.445, width: 0.11, height: 0.11))
    let centerB = barcode(
        "B", CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10))
    let outsideB = barcode(
        "B", CGRect(x: 0.05, y: 0.05, width: 0.12, height: 0.12))
    require(isSelected(select([centerA])), "BC-03 one candidate must select")
    require(
        isSelected(select([centerA, outsideB])),
        "BC-03 an outside candidate must not steal an in-ROI target")
    require(
        isAmbiguous(select([centerA, centerB])),
        "BC-03 near-equal in-ROI candidates must be ambiguous")
    let sameIdentityLeft = barcode(
        "SAME", CGRect(x: 0.41, y: 0.46, width: 0.08, height: 0.08))
    let sameIdentityRight = barcode(
        "SAME", CGRect(x: 0.51, y: 0.46, width: 0.08, height: 0.08))
    require(
        isAmbiguous(select([sameIdentityLeft, sameIdentityRight])),
        "BC-03 equal payloads at disjoint physical positions must remain ambiguous")
    require(
        isSelected(select([
            barcode(
                "SAME",
                CGRect(x: 0.45, y: 0.45, width: 0.10, height: 0.10)),
            barcode(
                "SAME",
                CGRect(x: 0.452, y: 0.452, width: 0.10, height: 0.10)),
        ])),
        "BC-03 high-IoU observations of one physical barcode must deduplicate")
    require(
        isSelected(select([
            barcode(
                "SAME",
                CGRect(x: 0.47, y: 0.47, width: 0.06, height: 0.06)),
            barcode(
                "SAME",
                CGRect(x: 0.57, y: 0.47, width: 0.05, height: 0.05)),
        ])),
        "BC-03 the existing score-margin policy may select a clear physical winner")

    require(
        PriceTagCapturePolicy.field.minimumCandidateLockFrames == 2
            && PriceTagCapturePolicy.field.minimumEvidenceFrames == 3
            && PriceTagCapturePolicy.field.targetEvidenceFrames == 4
            && PriceTagCapturePolicy.field.visionRateHz >= 5
            && PriceTagCapturePolicy.field.visionRateHz <= 10
            && PriceTagCapturePolicy.field.minimumROIIntersectionRatio == 0.80,
        "field policy must retain the 2/3/4 frame contract, bounded Vision and exact 80% ROI gate")
    let stableAuditCodes = Set(
        PriceTagCaptureAuditCode.allCases.map(\.rawValue))
    for requiredCode in [
        "price_tag_capture_timeout",
        "price_tag_multiple_barcodes",
        "price_tag_tracking_unavailable",
        "price_tag_measurement_unavailable",
        "price_tag_shelf_ambiguous",
        "price_tag_user_rescan",
        "price_tag_confirmation_admission_rejected",
        "price_tag_confirmation_persistence_failed",
    ] {
        require(
            stableAuditCodes.contains(requiredCode),
            "stable ESL audit contract must include \(requiredCode)")
    }

    require(
        PriceTagCaptureTrackingGate.evaluate(
            trackingState: "normal",
            localizationState: "stable") == .allow,
        "tracking gate must allow normal ARKit plus stable prior-map state")
    require(
        PriceTagCaptureTrackingGate.evaluate(
            trackingState: "limited.insufficientFeatures",
            localizationState: "stable")
            == .pause(reason: "arkit_tracking_insufficient_features"),
        "recoverable limited tracking must pause new barcode submissions")
    for (tracking, reason) in [
        ("notAvailable", "arkit_tracking_not_available"),
        ("limited.initializing", "arkit_tracking_initializing"),
        ("limited.relocalizing", "arkit_tracking_relocalizing"),
    ] {
        require(
            PriceTagCaptureTrackingGate.evaluate(
                trackingState: tracking,
                localizationState: "stable") == .cancel(reason: reason),
            "hard ARKit state \(tracking) must cancel the capture generation")
    }
    require(
        PriceTagCaptureTrackingGate.evaluate(
            trackingState: "normal",
            localizationState: "lost")
            == .cancel(reason: "prior_map_localization_lost"),
        "prior-map localization loss must override otherwise normal ARKit")

    let continuityGeneration = UUID()
    func continuitySample(
        uptime: TimeInterval,
        frameTimestamp: TimeInterval,
        sensorPoses: Int,
        odometrySubmissions: UInt64,
        mapNodes: Int = 10,
        databaseBytes: UInt64 = 10_000,
        clockNodeID: Int = 10,
        localizationTraces: Int,
        mappingActive: Bool = true,
        databaseWriterReady: Bool = true
    ) -> PriceTagCaptureContinuitySample {
        return PriceTagCaptureContinuitySample(
            generation: continuityGeneration,
            capturedAtMonotonic: uptime,
            frameTimestamp: frameTimestamp,
            trackingSessionID: "SESSION-ESL",
            mappingActive: mappingActive,
            dataRecording: false,
            nativePipelineAvailable: true,
            databaseWriterReady: databaseWriterReady,
            databaseIdentity: databaseWriterReady ? "/scan/segment_0001.db" : nil,
            clockWriterReady: true,
            sessionFinalizing: false,
            localizationRequiredWriteFailed: false,
            sensorPoseCount: sensorPoses,
            odometrySubmissionCount: odometrySubmissions,
            mapNodeCount: mapNodes,
            databaseBytes: databaseBytes,
            clockBoundNodeID: clockNodeID,
            localizationTraceCount: localizationTraces,
            localizationConstraintCount: 2)
    }
    let continuityStart = continuitySample(
        uptime: 0,
        frameTimestamp: 1,
        sensorPoses: 100,
        odometrySubmissions: 80,
        localizationTraces: 20)
    let stationaryEnd = continuitySample(
        uptime: 1,
        frameTimestamp: 2,
        sensorPoses: 130,
        odometrySubmissions: 110,
        databaseBytes: 9_000,
        localizationTraces: 22)
    require(
        PriceTagCaptureContinuityEvaluator.evaluate(
            start: continuityStart,
            end: stationaryEnd) == .passed,
        "continuity must pass while standing without a new node and after WAL shrink when odometry/trace/writers advance")
    let frozenNativeEnd = continuitySample(
        uptime: 1,
        frameTimestamp: 2,
        sensorPoses: 130,
        odometrySubmissions: 80,
        localizationTraces: 20)
    if case .failed(let reasons) = PriceTagCaptureContinuityEvaluator.evaluate(
        start: continuityStart,
        end: frozenNativeEnd) {
        require(
            reasons.contains("odometry_submission_did_not_advance")
                && reasons.contains("localization_trace_did_not_advance"),
            "AR-only progress must fail when native odometry and localization freeze")
    }
    else {
        require(false, "AR-only continuity false-pass must be rejected")
    }
    let unboundNodeEnd = continuitySample(
        uptime: 1,
        frameTimestamp: 2,
        sensorPoses: 130,
        odometrySubmissions: 110,
        mapNodes: 11,
        clockNodeID: 10,
        localizationTraces: 22)
    if case .failed(let reasons) = PriceTagCaptureContinuityEvaluator.evaluate(
        start: continuityStart,
        end: unboundNodeEnd) {
        require(
            reasons.contains("new_map_node_missing_clock_binding"),
            "a new map node without its durable clock binding must fail")
    }
    else {
        require(false, "unbound map-node continuity must fail")
    }
    let shortEnd = continuitySample(
        uptime: 0.2,
        frameTimestamp: 1.2,
        sensorPoses: 106,
        odometrySubmissions: 86,
        localizationTraces: 21)
    require(
        PriceTagCaptureContinuityEvaluator.evaluate(
            start: continuityStart,
            end: shortEnd)
            == .notEvaluable(
                reasons: ["capture_duration_below_evaluation_window"]),
        "short capture must be not-evaluable instead of a false PASS")
    let writerLostEnd = continuitySample(
        uptime: 1,
        frameTimestamp: 2,
        sensorPoses: 130,
        odometrySubmissions: 110,
        localizationTraces: 22,
        databaseWriterReady: false)
    if case .failed(let reasons) = PriceTagCaptureContinuityEvaluator.evaluate(
        start: continuityStart,
        end: writerLostEnd) {
        require(
            reasons.contains("database_writer_unavailable")
                && reasons.contains("database_identity_changed"),
            "database writer/identity loss must fail continuity")
    }
    else {
        require(false, "database writer loss must not pass continuity")
    }
    let policy = PriceTagCapturePolicy(
        minimumCandidateLockFrames: 2,
        minimumEvidenceFrames: 3,
        targetEvidenceFrames: 3,
        minimumCaptureDuration: 0.30,
        maximumCaptureDuration: 2.0,
        maximumVisionRequestDuration: 1.0,
        visionRateHz: 8,
        previewRateHz: 24,
        minimumROIIntersectionRatio: 0.8,
        minimumCandidateNormalizedArea: 0.002,
        ambiguityScoreDelta: 0.08,
        completedDuplicateSuppressionSeconds: 2.0)
    let captureGeometry = PriceTagCaptureGeometry(
        previewBounds: previewBounds,
        scanRect: scanRect)
    let captureROI = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
    let activeA = barcode(
        "ACTIVE-A", CGRect(x: 0.42, y: 0.45, width: 0.16, height: 0.10))
    let activeB = barcode(
        "ACTIVE-B", CGRect(x: 0.42, y: 0.45, width: 0.16, height: 0.10))
    let capturePriorMapAuthority = PriceTagCapturePriorMapAuthority(
        priorMapGeneration: UUID(),
        trackingSessionID: "SESSION-ESL",
        priorMapID: "MAP-ESL",
        priorMapSHA256: String(repeating: "a", count: 64),
        floorID: "F1")

    func startCoordinator(
        now: TimeInterval = 0
    ) -> (PriceTagCaptureCoordinator, UUID) {
        let coordinator = PriceTagCaptureCoordinator(policy: policy)
        let generation = coordinator.begin(
            now: now,
            priorMapAuthority: capturePriorMapAuthority)
        require(
            coordinator.markAiming(generation: generation),
            "capture must enter aiming from its current generation")
        coordinator.updateGeometry(captureGeometry)
        return (coordinator, generation)
    }
    func submit(
        _ coordinator: PriceTagCaptureCoordinator,
        generation: UUID,
        timestamp: TimeInterval,
        candidates: [PriceTagBarcodeCandidate]
    ) -> PriceTagCaptureVisionAction {
        guard let submission = coordinator.requestVisionSubmission(
                frameTimestamp: timestamp) else {
            require(false, "expected bounded Vision submission at \(timestamp)")
            return .ignored
        }
        require(
            submission.generation == generation,
            "Vision submission must carry the current generation")
        return coordinator.finishVision(
            generation: generation,
            frameTimestamp: timestamp,
            candidates: candidates,
            regionOfInterest: captureROI)
    }

    // Workstream D: at most one request is in-flight and the policy enforces
    // the configured 8 Hz submission ceiling.
    do {
        let (coordinator, generation) = startCoordinator()
        require(
            coordinator.requestVisionSubmission(frameTimestamp: 0) != nil,
            "bounded Vision must accept the first request")
        require(
            coordinator.requestVisionSubmission(frameTimestamp: 0.01) == nil,
            "bounded Vision must allow at most one in-flight request")
        _ = coordinator.finishVision(
            generation: generation,
            frameTimestamp: 0,
            candidates: [],
            regionOfInterest: captureROI)
        require(
            coordinator.requestVisionSubmission(frameTimestamp: 0.05) == nil,
            "bounded Vision must reject submissions above 8 Hz")
        require(
            coordinator.requestVisionSubmission(frameTimestamp: 0.13) != nil,
            "bounded Vision must reopen after the 8 Hz interval")
        _ = coordinator.cancel(reason: "focused_test_complete")
    }

    // BC-04: A,A locks; A,B resets; A,none,A resets and requires another
    // subsequent A before it can lock.
    do {
        let (coordinator, generation) = startCoordinator()
        let first = submit(
            coordinator, generation: generation,
            timestamp: 0, candidates: [activeA])
        let second = submit(
            coordinator, generation: generation,
            timestamp: 0.2, candidates: [activeA])
        if case .candidateSeen(_, let lockFrames, _) = first {
            require(lockFrames == 1, "BC-04 first A must start lock at one")
        } else {
            require(false, "BC-04 first A must enter candidate state")
        }
        if case .candidateLocked = second {
            // Expected.
        } else {
            require(false, "BC-04 A,A must lock")
        }
    }

    // A transient missing exact node snapshot must release only the current
    // evidence slot. It must not turn into the sticky required-write failure
    // path or discard the already locked barcode/capture.
    do {
        let (coordinator, generation) = startCoordinator()
        _ = submit(
            coordinator, generation: generation,
            timestamp: 0, candidates: [activeA])
        let locked = submit(
            coordinator, generation: generation,
            timestamp: 0.2, candidates: [activeA])
        guard case .candidateLocked(let captureID, _) = locked else {
            require(false, "transient-binding test must lock the barcode")
            return
        }
        let deferred = coordinator.deferEvidenceUntilNodeBinding(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.2)
        require(
            deferred == .waitingForNodeBinding(
                acceptedFrames: 0, requiredFrames: 3),
            "missing node binding must wait without cancelling the capture")
        let resumed = submit(
            coordinator, generation: generation,
            timestamp: 0.4, candidates: [activeA])
        if case .collect(let resumedID, _) = resumed {
            require(
                resumedID == captureID,
                "the next exact-bound frame must resume the same capture")
        }
        else {
            require(false, "the deferred capture must accept a later frame")
        }
        let saved = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.4,
            observationID: "deferred-observation-1",
            succeeded: true)
        if case .continueCollecting(let accepted, _) = saved {
            require(
                accepted == 1,
                "a later exact-bound frame must count normally")
        }
        else {
            require(false, "deferred evidence must return to collection")
        }
        _ = coordinator.cancel(reason: "transient_binding_test_complete")
    }
    do {
        let (coordinator, generation) = startCoordinator()
        _ = submit(
            coordinator, generation: generation,
            timestamp: 0, candidates: [activeA])
        let changed = submit(
            coordinator, generation: generation,
            timestamp: 0.2, candidates: [activeB])
        if case .candidateSeen(let payload, let lockFrames, _) = changed {
            require(
                payload == activeB.payload && lockFrames == 1,
                "BC-04 A,B must reset the lock to B/1")
        } else {
            require(false, "BC-04 A,B must stay candidate, not collect")
        }
    }
    do {
        let (coordinator, generation) = startCoordinator()
        _ = submit(
            coordinator, generation: generation,
            timestamp: 0, candidates: [activeA])
        let empty = submit(
            coordinator, generation: generation,
            timestamp: 0.2, candidates: [])
        if case .keepAiming = empty {
            // Expected: the empty frame contributes no lock/evidence count.
        } else {
            require(false, "BC-04 A,none must remain in bounded aiming behavior")
        }
        let nextA = submit(
            coordinator, generation: generation,
            timestamp: 0.4, candidates: [activeA])
        if case .candidateSeen(let payload, let lockFrames, _) = nextA {
            require(
                payload == activeA.payload && lockFrames == 1,
                "BC-04 A,none,A must restart candidate lock at A/1")
        } else {
            require(false, "BC-04 A,none,A must not lock across an empty frame")
        }
        let finalA = submit(
            coordinator, generation: generation,
            timestamp: 0.6, candidates: [activeA])
        if case .candidateLocked = finalA {
            // Expected.
        } else {
            require(false, "BC-04 A,none,A,A must lock on consecutive real frames")
        }
    }

    // BC-05/06: the active burst accepts repeated payloads only from unique
    // frame timestamps and unique durable observation ids. After commit, the
    // same payload is suppressed for the short duplicate window.
    do {
        let (coordinator, generation) = startCoordinator()
        _ = submit(
            coordinator, generation: generation,
            timestamp: 0, candidates: [activeA])
        let locked = submit(
            coordinator, generation: generation,
            timestamp: 0.2, candidates: [activeA])
        let captureID: UUID
        if case .candidateLocked(let value, _) = locked {
            captureID = value
        } else {
            require(false, "BC-05 second stable frame must start the burst")
            return
        }
        let evidence1 = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.2,
            observationID: "observation-1",
            succeeded: true)
        if case .continueCollecting(let accepted, _) = evidence1 {
            require(accepted == 1, "BC-05 first unique frame must count once")
        } else {
            require(false, "BC-05 first evidence frame must continue")
        }
        let repeatedSameFrame = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.2,
            observationID: "observation-2",
            succeeded: true)
        if case .ignored = repeatedSameFrame {
            // Expected: no pending evidence exists for the same ARFrame.
        } else {
            require(false, "BC-05 the same ARFrame cannot count twice")
        }

        let collect2 = submit(
            coordinator, generation: generation,
            timestamp: 0.4, candidates: [activeA])
        if case .collect(let value, _) = collect2 {
            require(value == captureID, "BC-05 same-payload frame 2 stays in burst")
        } else {
            require(false, "BC-05 unique frame 2 must collect")
        }
        _ = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.4,
            observationID: "observation-2",
            succeeded: true)

        let collect3 = submit(
            coordinator, generation: generation,
            timestamp: 0.6, candidates: [activeA])
        if case .collect = collect3 {
            // Expected.
        } else {
            require(false, "BC-05 unique frame 3 must collect")
        }
        let evidence3 = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.6,
            observationID: "observation-3",
            succeeded: true)
        if case .resolve(let resolvedID, let observationIDs) = evidence3 {
            require(
                resolvedID == captureID
                    && Set(observationIDs).count == 3
                    && observationIDs.count == 3,
                "BC-05 three unique frames and observation ids must resolve")
        } else {
            require(false, "BC-05 three unique evidence frames must succeed")
        }
        require(
            coordinator.markConfirming(
                generation: generation,
                captureID: captureID),
            "BC-06 resolved burst must enter confirmation")
        guard let commitAuthority = coordinator.claimConfirmationCommit(
                generation: generation,
                captureID: captureID) else {
            require(false, "SC commit must atomically claim its authority")
            return
        }
        let cancellationAfterClaim = coordinator.cancel(
            reason: "system_interruption_after_commit_claim")
        require(
            cancellationAfterClaim?.confirmationCommitInFlight == true
                && coordinator.currentState() == .confirming(
                    generation: generation,
                    captureID: captureID)
                && coordinator.isConfirmationCommitInFlight(commitAuthority),
            "cancel after the linearization point must not stale the claimed write")
        require(
            coordinator.claimConfirmationCommit(
                generation: generation,
                captureID: captureID) == nil,
            "a confirmation authority may be claimed exactly once")
        require(
            coordinator.finishConfirmation(
                generation: generation,
                payload: activeA.payload,
                completedAt: 0.7,
                committed: true),
            "BC-06 committed confirmation must complete")
        require(
            !coordinator.finishConfirmation(
                generation: generation,
                payload: activeA.payload,
                completedAt: 0.71,
                committed: true),
            "a claimed confirmation may finish exactly once")

        let duplicateGeneration = coordinator.begin(now: 0.8)
        require(
            coordinator.markAiming(generation: duplicateGeneration),
            "BC-06 duplicate scan must enter aiming")
        coordinator.updateGeometry(captureGeometry)
        let duplicate = submit(
            coordinator,
            generation: duplicateGeneration,
            timestamp: 0.8,
            candidates: [activeA])
        if case .duplicateCompleted(let payload) = duplicate {
            require(payload == activeA.payload, "BC-06 duplicate payload must be reported")
        } else {
            require(false, "BC-06 a just-committed payload must be suppressed")
        }
    }

    // Confirmation linearization: when cancellation wins before the atomic
    // claim, the generation becomes idle and no persistence authority can be
    // obtained afterwards.
    do {
        let (coordinator, generation) = startCoordinator(now: 10)
        _ = submit(
            coordinator,
            generation: generation,
            timestamp: 10,
            candidates: [activeA])
        let locked = submit(
            coordinator,
            generation: generation,
            timestamp: 10.2,
            candidates: [activeA])
        guard case .candidateLocked(let captureID, _) = locked else {
            require(false, "pre-claim cancellation fixture must lock")
            return
        }
        _ = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 10.2,
            observationID: "cancel-before-1",
            succeeded: true)
        _ = submit(
            coordinator,
            generation: generation,
            timestamp: 10.4,
            candidates: [activeA])
        _ = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 10.4,
            observationID: "cancel-before-2",
            succeeded: true)
        _ = submit(
            coordinator,
            generation: generation,
            timestamp: 10.6,
            candidates: [activeA])
        let resolved = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 10.6,
            observationID: "cancel-before-3",
            succeeded: true)
        guard case .resolve = resolved else {
            require(false, "pre-claim cancellation fixture must resolve")
            return
        }
        require(
            coordinator.markConfirming(
                generation: generation,
                captureID: captureID),
            "pre-claim cancellation fixture must confirm")
        let cancellation = coordinator.cancel(reason: "cancel_before_claim")
        require(
            cancellation?.confirmationCommitInFlight == false
                && coordinator.currentState() == .idle,
            "cancel before claim must invalidate the generation")
        require(
            coordinator.claimConfirmationCommit(
                generation: generation,
                captureID: captureID) == nil,
            "cancel-before-claim must never produce persistence authority")
    }

    // Session admission linearization: finalization and confirmation
    // reservation share one authority. A reservation that wins first drains
    // before snapshot; finalization that wins first rejects the reservation.
    do {
        let gate = PriceTagSessionAdmissionGate()
        let authority = PriceTagConfirmationCommitAuthority(
            captureGeneration: UUID(),
            captureID: UUID(),
            priorMapGeneration: capturePriorMapAuthority.priorMapGeneration,
            trackingSessionID: capturePriorMapAuthority.trackingSessionID,
            priorMapID: capturePriorMapAuthority.priorMapID,
            priorMapSHA256: capturePriorMapAuthority.priorMapSHA256,
            floorID: capturePriorMapAuthority.floorID)
        require(
            gate.reserveConfirmation(authority) == .reserved,
            "session confirmation reservation must succeed before finalization")
        require(
            gate.beginFinalization(),
            "finalization admission must close after the reservation")
        require(
            gate.beginTransaction() == .finalizationInProgress,
            "ordinary writes must be rejected after finalization admission")
        require(
            gate.beginTransaction(reservedConfirmation: authority) == nil,
            "the exact pre-finalization reservation must remain admissible")
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            gate.waitForFinalizationDrain()
            drained.signal()
        }
        require(
            drained.wait(timeout: .now() + 0.05) == .timedOut,
            "finalization drain must wait for the reserved durable attempt")
        gate.endTransaction(reservedConfirmation: authority)
        require(
            drained.wait(timeout: .now() + 1) == .success,
            "finalization drain must finish after the reserved commit attempt")
        gate.endFinalization()
    }
    do {
        let gate = PriceTagSessionAdmissionGate()
        let authority = PriceTagConfirmationCommitAuthority(
            captureGeneration: UUID(),
            captureID: UUID(),
            priorMapGeneration: capturePriorMapAuthority.priorMapGeneration,
            trackingSessionID: capturePriorMapAuthority.trackingSessionID,
            priorMapID: capturePriorMapAuthority.priorMapID,
            priorMapSHA256: capturePriorMapAuthority.priorMapSHA256,
            floorID: capturePriorMapAuthority.floorID)
        require(
            gate.beginFinalization(),
            "finalization-first fixture must close admission")
        require(
            gate.reserveConfirmation(authority)
                == .rejected(.finalizationInProgress),
            "finalization admission that wins first must reject confirmation")
        gate.waitForFinalizationDrain()
        gate.endFinalization()
    }
    do {
        let gate = PriceTagSessionAdmissionGate()
        let authority = PriceTagConfirmationCommitAuthority(
            captureGeneration: UUID(),
            captureID: UUID(),
            priorMapGeneration: capturePriorMapAuthority.priorMapGeneration,
            trackingSessionID: capturePriorMapAuthority.trackingSessionID,
            priorMapID: capturePriorMapAuthority.priorMapID,
            priorMapSHA256: capturePriorMapAuthority.priorMapSHA256,
            floorID: capturePriorMapAuthority.floorID)
        require(
            gate.reserveConfirmation(authority) == .reserved,
            "cancel-before-claim fixture must reserve")
        gate.cancelConfirmationReservation(authority)
        require(
            gate.confirmationReservationCount == 0
                && gate.beginFinalization(),
            "a coordinator claim loss must release the session reservation")
        gate.waitForFinalizationDrain()
        gate.endFinalization()
    }

    // Session-level writer regression: the second localization transaction
    // registers before finalization but waits behind the first writer. Both
    // pre-admitted writes must finish successfully, and the drain must remain
    // blocked until they do. This catches any inner isFinalizing re-check that
    // would reject an already-admitted waiter after it acquires the writer lock.
    do {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "marketscanner-session-admission-\(UUID().uuidString)",
                isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = BlockingFirstAppendSidecarWriter()
        let session = SupermarketScanSession(
            documentsDirectory: root,
            sidecarWriter: writer)
        do {
            try session.startNewSessionIfNeeded()
            _ = try session.currentSegmentDirectory()
        }
        catch {
            require(false, "session admission fixture must create its segment")
        }
        session.configureScan(PriorMapScanConfiguration(
            formatVersion: 1,
            workflowMode: .priorMapLocalized,
            packageDirectory: root,
            priorMapId: "map-a",
            priorMapSha256: String(repeating: "a", count: 64),
            floorId: "1",
            storeID: "store-a",
            initialMapPose: PriorMapPose2D(xM: 0, yM: 0, yawRad: 0)))
        func update(_ timestamp: TimeInterval) -> PriorMapLocalizationUpdate {
            let pose = PriorMapPose2D(xM: timestamp, yM: 0, yawRad: 0)
            return PriorMapLocalizationUpdate(
                format: "MarketScannerLocalizationTrace",
                version: 1,
                timestamp: timestamp,
                trackingState: "normal",
                localizationState: "tracking",
                confidence: 0.9,
                rawPose: pose,
                estimatedPose: pose,
                roadCandidates: [],
                structureSource: "host_test",
                structurePointCount: 10,
                structureCoverageAngleRad: 1,
                matchCandidates: [],
                matchUniqueness: 1,
                matchResidualCost: 0,
                matcherElapsedMs: 1,
                constraintAccepted: false,
                constraintReason: "host_test")
        }
        let resultLock = NSLock()
        var firstResult: LocalizationWriteResult?
        var secondResult: LocalizationWriteResult?
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = session.appendLocalizationTrace(
                update(1),
                expectedTrackingSessionId: session.trackingSessionId,
                nodeTimebaseOffsetSeconds: 0)
            resultLock.lock()
            firstResult = result
            resultLock.unlock()
            firstFinished.signal()
        }
        require(
            writer.firstAppendEntered.wait(timeout: .now() + 1) == .success,
            "first localization writer must reach the injected block")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = session.appendLocalizationTrace(
                update(2),
                expectedTrackingSessionId: session.trackingSessionId,
                nodeTimebaseOffsetSeconds: 0)
            resultLock.lock()
            secondResult = result
            resultLock.unlock()
            secondFinished.signal()
        }
        let admissionDeadline = Date().addingTimeInterval(1)
        while session.activeLocalizationTransactionCount < 2,
              Date() < admissionDeadline {
            usleep(1_000)
        }
        require(
            session.activeLocalizationTransactionCount == 2,
            "second localization transaction must register before finalization")
        require(
            session.beginFinalization(),
            "session finalization must close after both writers are admitted")
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            session.waitForFinalizationTransactionDrain()
            drained.signal()
        }
        require(
            drained.wait(timeout: .now() + 0.05) == .timedOut,
            "session drain must wait for both admitted localization writers")
        writer.releaseFirstAppend.signal()
        require(
            firstFinished.wait(timeout: .now() + 1) == .success
                && secondFinished.wait(timeout: .now() + 1) == .success
                && drained.wait(timeout: .now() + 1) == .success,
            "both admitted writers and the session drain must complete")
        resultLock.lock()
        let bothSucceeded = firstResult?.succeeded == true
            && secondResult?.succeeded == true
        resultLock.unlock()
        require(
            bothSucceeded,
            "pre-finalization admitted localization writers must both persist")
        session.endFinalization()
    }

    // Ordinary frame-driven Recovery persistence must not inherit terminal
    // finalization authority. Only the explicit terminal coordinator may pass
    // allowDuringFinalization=true to the durable writer.
    do {
        func recoveryFixture() -> (
            P7R6FakeRecoverySource,
            PriorMapRecoveryCompletion
        ) {
            let controller = PriorMapRecoveryController()
            _ = controller.request(
                reason: "esl_finalization_admission", now: 1)
            guard let completion = controller.finish(.converged, now: 2) else {
                fatalError("Recovery fixture must complete")
            }
            let source = P7R6FakeRecoverySource()
            source.pending = [completion]
            return (source, completion)
        }

        let ordinaryFixture = recoveryFixture()
        let ordinaryWriter = P7R6FakeRecoveryWriter()
        let ordinaryCoordinator = RecoveryLifecyclePersistenceCoordinator(
            source: ordinaryFixture.0,
            writer: ordinaryWriter,
            trackingSessionId: "session-a",
            priorMapId: "map-a",
            priorMapSha256: String(repeating: "a", count: 64),
            floorId: "1",
            persistedEvidenceSnapshot: { Data() })
        require(
            ordinaryCoordinator.persistTerminalEvidence(
                cancellationReason: nil, now: 3).allPersisted
                && ordinaryWriter.allowDuringFinalizationValues == [false],
            "frame-driven Recovery persistence must use ordinary admission")

        let terminalFixture = recoveryFixture()
        let terminalWriter = P7R6FakeRecoveryWriter()
        let terminalCoordinator = RecoveryLifecyclePersistenceCoordinator(
            source: terminalFixture.0,
            writer: terminalWriter,
            trackingSessionId: "session-a",
            priorMapId: "map-a",
            priorMapSha256: String(repeating: "a", count: 64),
            floorId: "1",
            allowDuringFinalization: true,
            persistedEvidenceSnapshot: { Data() })
        require(
            terminalCoordinator.persistTerminalEvidence(
                cancellationReason: nil, now: 3).allPersisted
                && terminalWriter.allowDuringFinalizationValues == [true],
            "only terminal Recovery persistence may bypass closed admission")
    }

    // A delayed ESL audit must never create a successor session after the
    // original session has been detached. The active-only API binds the exact
    // tracking identity and fails closed without calling currentSegmentDirectory.
    do {
        let auditRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "marketscanner-esl-audit-\(UUID().uuidString)",
                isDirectory: true)
        try? FileManager.default.createDirectory(
            at: auditRoot,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: auditRoot) }
        let session = SupermarketScanSession(
            documentsDirectory: auditRoot,
            sidecarWriter: InjectedSidecarWriter())
        require(
            !session.appendScanEventIfSessionActive(
                expectedTrackingSessionId: "missing",
                event: "price_tag_capture_cancelled",
                message: "late audit"),
            "active-only audit must reject when no scan exists")
        require(
            (try? FileManager.default.contentsOfDirectory(atPath: auditRoot.path))?
                .isEmpty == true,
            "rejected audit must not create an empty session directory")
        do {
            try session.startNewSessionIfNeeded()
            _ = try session.currentSegmentDirectory()
        }
        catch {
            require(false, "active-only audit fixture must create one session")
        }
        let completedTrackingSessionID = session.trackingSessionId
        let sessionNamesBeforeDetach =
            (try? FileManager.default.contentsOfDirectory(atPath: auditRoot.path))
                ?? []
        require(
            session.beginFinalization(),
            "active-only audit fixture must close ordinary admission")
        require(
            !session.appendScanEventIfSessionActive(
                expectedTrackingSessionId: completedTrackingSessionID,
                event: "price_tag_capture_cancelled",
                message: "ordinary late audit"),
            "ordinary audit must not bypass finalization admission")
        require(
            session.appendScanEventIfSessionActive(
                expectedTrackingSessionId: completedTrackingSessionID,
                allowDuringFinalization: true,
                event: "price_tag_capture_cancelled",
                message: "finalization-owned audit"),
            "explicit scan-stop audit must remain writable during finalization")
        session.endFinalization()
        session.completeCurrentSession()
        require(
            !session.appendScanEventIfSessionActive(
                expectedTrackingSessionId: completedTrackingSessionID,
                event: "price_tag_capture_cancelled",
                message: "late audit after detach"),
            "late audit must reject after the exact session is detached")
        require(
            ((try? FileManager.default.contentsOfDirectory(
                atPath: auditRoot.path)) ?? []) == sessionNamesBeforeDetach,
            "late audit must not create a successor session")
    }

    // BC-05 deadline fallback: three durable independent frames satisfy the
    // minimum even when the barcode leaves the ROI before a fourth target
    // frame. The maximum window must resolve, not discard valid evidence.
    do {
        let minimumPolicy = PriceTagCapturePolicy(
            minimumCandidateLockFrames: 2,
            minimumEvidenceFrames: 3,
            targetEvidenceFrames: 4,
            minimumCaptureDuration: 0.30,
            maximumCaptureDuration: 2.0,
            maximumVisionRequestDuration: 1.0,
            visionRateHz: 8,
            previewRateHz: 24,
            minimumROIIntersectionRatio: 0.8,
            minimumCandidateNormalizedArea: 0.002,
            ambiguityScoreDelta: 0.08,
            completedDuplicateSuppressionSeconds: 2.0)
        let coordinator = PriceTagCaptureCoordinator(policy: minimumPolicy)
        let generation = coordinator.begin(now: 0)
        require(
            coordinator.markAiming(generation: generation),
            "BC-05 minimum fallback must enter aiming")
        coordinator.updateGeometry(captureGeometry)
        _ = submit(
            coordinator, generation: generation,
            timestamp: 0, candidates: [activeA])
        let locked = submit(
            coordinator, generation: generation,
            timestamp: 0.2, candidates: [activeA])
        guard case .candidateLocked(let captureID, _) = locked else {
            require(false, "BC-05 minimum fallback must lock")
            return
        }
        _ = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.2,
            observationID: "minimum-observation-1",
            succeeded: true)
        for (timestamp, observationID) in [
            (0.4, "minimum-observation-2"),
            (0.6, "minimum-observation-3"),
        ] {
            let action = submit(
                coordinator,
                generation: generation,
                timestamp: timestamp,
                candidates: [activeA])
            if case .collect = action {
                _ = coordinator.finishEvidence(
                    generation: generation,
                    captureID: captureID,
                    frameTimestamp: timestamp,
                    observationID: observationID,
                    succeeded: true)
            } else {
                require(false, "BC-05 minimum fallback frame must collect")
            }
        }
        let deadline = submit(
            coordinator,
            generation: generation,
            timestamp: 2.3,
            candidates: [])
        if case .resolve(let resolvedID, let observationIDs) = deadline {
            require(
                resolvedID == captureID && observationIDs.count == 3,
                "BC-05 three-frame deadline fallback must preserve evidence")
        } else {
            require(
                false,
                "BC-05 three-frame deadline fallback must resolve, not time out")
        }
    }

    let deadlinePolicy = PriceTagCapturePolicy(
        minimumCandidateLockFrames: 2,
        minimumEvidenceFrames: 3,
        targetEvidenceFrames: 4,
        minimumCaptureDuration: 0.30,
        maximumCaptureDuration: 2.0,
        maximumVisionRequestDuration: 1.0,
        visionRateHz: 8,
        previewRateHz: 24,
        minimumROIIntersectionRatio: 0.8,
        minimumCandidateNormalizedArea: 0.002,
        ambiguityScoreDelta: 0.08,
        completedDuplicateSuppressionSeconds: 2.0)

    // A per-request deadline exists before candidate lock. A first Vision
    // request that never calls back must not leave aiming/candidate admission
    // permanently occupied while ARFrame timestamps continue advancing.
    do {
        let coordinator = PriceTagCaptureCoordinator(policy: deadlinePolicy)
        let generation = coordinator.begin(now: 0)
        require(
            coordinator.markAiming(generation: generation),
            "aiming request-deadline fixture must enter aiming")
        coordinator.updateGeometry(captureGeometry)
        require(
            coordinator.requestVisionSubmission(frameTimestamp: 0) != nil,
            "aiming request-deadline fixture must admit request A")
        require(
            coordinator.tickDeadline(frameTimestamp: 1.01)
                == .requestTimedOut(frameTimestamp: 0),
            "aiming request A must expire independently of burst collection")
        require(
            coordinator.requestVisionSubmission(frameTimestamp: 1.2) != nil,
            "aiming must admit request B after request A expires")
        coordinator.failVision(
            generation: generation,
            frameTimestamp: 1.2)

        let firstCandidate = submit(
            coordinator,
            generation: generation,
            timestamp: 1.4,
            candidates: [activeA])
        if case .candidateSeen = firstCandidate {
            // Expected.
        }
        else {
            require(false, "candidate request-deadline fixture must see A")
        }
        require(
            coordinator.requestVisionSubmission(frameTimestamp: 1.6) != nil,
            "candidate request-deadline fixture must admit request C")
        require(
            coordinator.tickDeadline(frameTimestamp: 2.61)
                == .requestTimedOut(frameTimestamp: 1.6),
            "candidate request C must expire without waiting for collecting")
        require(
            coordinator.requestVisionSubmission(frameTimestamp: 2.8) != nil,
            "candidate must admit a fresh request after timeout")
        coordinator.failVision(
            generation: generation,
            frameTimestamp: 2.8)
    }

    func startDeadlineCoordinator() -> (PriceTagCaptureCoordinator, UUID, UUID) {
        let coordinator = PriceTagCaptureCoordinator(policy: deadlinePolicy)
        let generation = coordinator.begin(now: 0)
        require(
            coordinator.markAiming(generation: generation),
            "deadline fixture must enter aiming")
        coordinator.updateGeometry(captureGeometry)
        _ = submit(
            coordinator,
            generation: generation,
            timestamp: 0,
            candidates: [activeA])
        let locked = submit(
            coordinator,
            generation: generation,
            timestamp: 0.2,
            candidates: [activeA])
        guard case .candidateLocked(let captureID, _) = locked else {
            fatalError("deadline fixture must lock")
        }
        return (coordinator, generation, captureID)
    }

    // The 2-second deadline is driven by ARFrame ticks, not by successful
    // Vision callbacks. Three durable frames survive repeated Vision errors.
    do {
        let (coordinator, generation, captureID) = startDeadlineCoordinator()
        _ = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.2,
            observationID: "deadline-vision-1",
            succeeded: true)
        for (timestamp, observationID) in [
            (0.4, "deadline-vision-2"),
            (0.6, "deadline-vision-3"),
        ] {
            _ = submit(
                coordinator,
                generation: generation,
                timestamp: timestamp,
                candidates: [activeA])
            _ = coordinator.finishEvidence(
                generation: generation,
                captureID: captureID,
                frameTimestamp: timestamp,
                observationID: observationID,
                succeeded: true)
        }
        for timestamp in [0.8, 1.0, 1.2] {
            require(
                coordinator.requestVisionSubmission(
                    frameTimestamp: timestamp) != nil,
                "deadline fixture must submit the failing Vision request")
            coordinator.failVision(
                generation: generation,
                frameTimestamp: timestamp)
        }
        let deadline = coordinator.tickDeadline(frameTimestamp: 2.21)
        if case .resolve(let resolvedID, let observationIDs) = deadline {
            require(
                resolvedID == captureID && observationIDs.count == 3,
                "independent deadline must resolve three durable frames after Vision failure")
        }
        else {
            require(false, "Vision failure must not leave collecting unbounded")
        }
    }

    // A Vision implementation that never calls back cannot own the capture
    // past the deadline. The coordinator revokes that request and rejects its
    // eventual late completion without starting another evidence write.
    do {
        let (coordinator, generation, captureID) = startDeadlineCoordinator()
        _ = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.2,
            observationID: "deadline-hung-vision-1",
            succeeded: true)
        require(
            coordinator.requestVisionSubmission(frameTimestamp: 0.4) != nil,
            "hung Vision fixture must have one admitted request")
        require(
            coordinator.tickDeadline(frameTimestamp: 1.41)
                == .requestTimedOut(frameTimestamp: 0.4),
            "collecting request A must expire before the burst deadline")
        let deadline = coordinator.tickDeadline(frameTimestamp: 2.21)
        require(
            deadline == .timedOut(
                captureID: captureID,
                revokeVisionRequest: true)
                && coordinator.currentState() == .aiming(
                    generation: generation),
            "a hung Vision request must not keep collecting past the deadline")
        require(
            coordinator.requestVisionSubmission(frameTimestamp: 2.4) != nil,
            "the aiming state may admit a fresh request after deadline cleanup")
        let late = coordinator.finishVision(
            generation: generation,
            frameTimestamp: 0.4,
            candidates: [activeA],
            regionOfInterest: captureROI)
        require(
            late == .ignored,
            "the callback revoked by the deadline must not consume a fresh admission")
        let fresh = coordinator.finishVision(
            generation: generation,
            frameTimestamp: 2.4,
            candidates: [activeA],
            regionOfInterest: captureROI)
        if case .candidateSeen = fresh {
            // Expected.
        }
        else {
            require(false, "the fresh post-deadline Vision request must remain valid")
        }
    }

    // A timeout returned by an already-completed Vision callback must not ask
    // the ViewController to restart by generation. Between finishVision()
    // returning and UI handling, a fresh request B may already be active; a
    // generation-only restart there would cancel/quarantine healthy B.
    do {
        let (coordinator, generation, captureID) = startDeadlineCoordinator()
        _ = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.2,
            observationID: "callback-timeout-1",
            succeeded: true)
        let callbackTimeout = submit(
            coordinator,
            generation: generation,
            timestamp: 2.3,
            candidates: [])
        guard case .timedOut(
                let timedOutCaptureID,
                let revokeVisionRequest) = callbackTimeout else {
            require(false, "completed Vision callback must return a timeout")
            return
        }
        require(
            timedOutCaptureID == captureID && !revokeVisionRequest,
            "completed Vision callback timeout must not revoke a future request")

        var requestTokens = PriceTagVisionRequestTokenGate()
        requestTokens.activate(generation: generation)
        guard let requestA = requestTokens.beginRequest(generation: generation)
        else {
            require(false, "callback-timeout token fixture must admit A")
            return
        }
        require(
            requestTokens.completeRequest(
                generation: generation,
                requestID: requestA),
            "request A must finish before its callback timeout is handled")
        guard let requestB = requestTokens.beginRequest(generation: generation)
        else {
            require(false, "callback-timeout token fixture must admit B")
            return
        }
        require(
            requestTokens.activeRequestID == requestB,
            "callback timeout handling must leave fresh request B active")
        require(
            requestTokens.completeRequest(
                generation: generation,
                requestID: requestB),
            "fresh request B must complete without stale A cleanup")
    }

    // Scanner-level request identity must survive a same-generation restart.
    // The deadline may return the coordinator to aiming without changing the
    // capture generation, so generation-only callback checks are insufficient.
    do {
        var requestTokens = PriceTagVisionRequestTokenGate()
        let generation = UUID()
        requestTokens.activate(generation: generation)
        guard let oldRequestID = requestTokens.beginRequest(
                generation: generation) else {
            require(false, "scanner token fixture must admit the old request")
            return
        }
        require(
            requestTokens.restart(generation: generation),
            "deadline cleanup must restart the current scanner generation")
        guard let freshRequestID = requestTokens.beginRequest(
                generation: generation) else {
            require(false, "same-generation restart must admit a fresh request")
            return
        }
        require(
            oldRequestID != freshRequestID,
            "a restarted request must receive a distinct identity")
        require(
            !requestTokens.completeRequest(
                generation: generation,
                requestID: oldRequestID),
            "the old callback must be rejected after same-generation restart")
        require(
            requestTokens.activeRequestID == freshRequestID,
            "the old callback must not clear the fresh in-flight request")
        require(
            requestTokens.completeRequest(
                generation: generation,
                requestID: freshRequestID),
            "the fresh callback must complete normally")
        require(
            requestTokens.activeRequestID == nil,
            "successful completion must release scanner admission")
    }

    // The executor test blocks worker A for real. Quarantining A must let B
    // start on the sole spare lane before A returns; two simultaneous hangs
    // must exhaust the fixed pool instead of queuing or creating worker C.
    do {
        let clampedExecutor = PriceTagVisionWorkerExecutor(
            maximumWorkers: 0,
            labelPrefix: "marketscanner.tests.price-tag-vision-clamped")
        require(
            clampedExecutor.snapshot()
                == PriceTagVisionWorkerExecutorSnapshot(
                    availableWorkers: 1,
                    activeWorkers: 0,
                    quarantinedWorkers: 0),
            "a non-positive worker configuration must clamp to one bounded lane")

        let executor = PriceTagVisionWorkerExecutor(
            maximumWorkers: 2,
            labelPrefix: "marketscanner.tests.price-tag-vision")
        let requestA = UUID()
        let requestB = UUID()
        let requestC = UUID()
        let startedA = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let finishedA = DispatchSemaphore(value: 0)
        let startedB = DispatchSemaphore(value: 0)
        let releaseB = DispatchSemaphore(value: 0)
        let finishedB = DispatchSemaphore(value: 0)
        require(
            executor.submit(requestID: requestA) {
                startedA.signal()
                _ = releaseA.wait(timeout: .now() + 2)
                finishedA.signal()
            },
            "worker A must start")
        require(
            startedA.wait(timeout: .now() + 1) == .success,
            "worker A must actually occupy its executor lane")
        require(
            executor.quarantine(requestID: requestA),
            "timed-out worker A must enter quarantine")
        require(
            executor.submit(requestID: requestB) {
                startedB.signal()
                _ = releaseB.wait(timeout: .now() + 2)
                finishedB.signal()
            },
            "worker B must use the bounded replacement lane")
        require(
            startedB.wait(timeout: .now() + 1) == .success,
            "worker B must actually start before worker A returns")
        require(
            executor.quarantine(requestID: requestB),
            "a second hung worker must enter quarantine")
        require(
            executor.snapshot()
                == PriceTagVisionWorkerExecutorSnapshot(
                    availableWorkers: 0,
                    activeWorkers: 0,
                    quarantinedWorkers: 2),
            "the worker population must remain bounded at two quarantined lanes")
        require(
            !executor.submit(requestID: requestC) {},
            "worker C must fail closed instead of forming an unbounded backlog")
        releaseA.signal()
        releaseB.signal()
        require(
            finishedA.wait(timeout: .now() + 1) == .success
                && finishedB.wait(timeout: .now() + 1) == .success,
            "quarantined test workers must be released")
    }

    // A frame that was already admitted before the deadline may finish its
    // durable write once. The latched deadline is applied immediately after.
    do {
        let (coordinator, generation, captureID) = startDeadlineCoordinator()
        _ = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.2,
            observationID: "deadline-pending-1",
            succeeded: true)
        _ = submit(
            coordinator,
            generation: generation,
            timestamp: 0.4,
            candidates: [activeA])
        _ = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.4,
            observationID: "deadline-pending-2",
            succeeded: true)
        _ = submit(
            coordinator,
            generation: generation,
            timestamp: 0.6,
            candidates: [activeA])
        require(
            coordinator.tickDeadline(frameTimestamp: 2.21) == .ignored,
            "deadline must latch while one admitted evidence frame is in flight")
        let completion = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.6,
            observationID: "deadline-pending-3",
            succeeded: true)
        if case .resolve(let resolvedID, let observationIDs) = completion {
            require(
                resolvedID == captureID && observationIDs.count == 3,
                "the third admitted frame must resolve immediately after the latched deadline")
        }
        else {
            require(false, "latched deadline must resolve after the third durable frame")
        }
    }
    do {
        let (coordinator, generation, captureID) = startDeadlineCoordinator()
        _ = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.2,
            observationID: "deadline-insufficient-1",
            succeeded: true)
        _ = submit(
            coordinator,
            generation: generation,
            timestamp: 0.4,
            candidates: [activeA])
        require(
            coordinator.tickDeadline(frameTimestamp: 2.21) == .ignored,
            "insufficient pending evidence must still be linearized")
        let completion = coordinator.finishEvidence(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 0.4,
            observationID: "deadline-insufficient-2",
            succeeded: true)
        require(
            completion == .timedOut(captureID: captureID)
                && coordinator.currentState() == .aiming(
                    generation: generation),
            "latched deadline with fewer than three durable frames must time out")
    }

    // BC-07: a callback that returns after cancellation is generation-stale
    // and cannot mutate state or progress toward confirmation.
    do {
        let (coordinator, generation) = startCoordinator()
        require(
            coordinator.requestVisionSubmission(frameTimestamp: 1) != nil,
            "BC-07 Vision request must be in-flight before cancellation")
        let cancellation = coordinator.cancel(reason: "price_tag_capture_cancelled")
        require(
            cancellation?.generation == generation
                && coordinator.currentState() == .idle,
            "BC-07 cancellation must invalidate the active generation")
        let late = coordinator.finishVision(
            generation: generation,
            frameTimestamp: 1,
            candidates: [activeA],
            regionOfInterest: captureROI)
        if case .ignored = late {
            // Expected.
        } else {
            require(false, "BC-07 a late Vision callback must be ignored")
        }
    }

    // BC-08: beginning a new generation invalidates the old in-flight
    // callback while allowing the new capture to proceed normally.
    do {
        let (coordinator, oldGeneration) = startCoordinator(now: 2)
        require(
            coordinator.requestVisionSubmission(frameTimestamp: 2) != nil,
            "BC-08 old generation must have an in-flight callback")
        let newGeneration = coordinator.begin(now: 2.01)
        require(
            newGeneration != oldGeneration
                && coordinator.markAiming(generation: newGeneration),
            "BC-08 begin must issue and activate a new generation")
        coordinator.updateGeometry(captureGeometry)
        let stale = coordinator.finishVision(
            generation: oldGeneration,
            frameTimestamp: 2,
            candidates: [activeA],
            regionOfInterest: captureROI)
        if case .ignored = stale {
            // Expected.
        } else {
            require(false, "BC-08 an old callback cannot pollute a new scan")
        }
        let fresh = submit(
            coordinator,
            generation: newGeneration,
            timestamp: 2.01,
            candidates: [activeA])
        if case .candidateSeen = fresh {
            // Expected.
        } else {
            require(false, "BC-08 the new generation must accept fresh evidence")
        }
    }

    // Evidence append linearization: cancellation and the final durable
    // append must have only two safe orders. If cancellation wins, the stale
    // callback cannot execute its append body. If append wins, cancellation
    // waits until that append has joined the still-active burst instead of
    // flushing first and allowing a duplicate capture ID to be recreated.
    do {
        let (coordinator, generation) = startCoordinator(now: 20)
        _ = submit(
            coordinator,
            generation: generation,
            timestamp: 20,
            candidates: [activeA])
        let locked = submit(
            coordinator,
            generation: generation,
            timestamp: 20.2,
            candidates: [activeA])
        guard case .candidateLocked(let captureID, _) = locked else {
            require(false, "cancel-wins evidence fixture must lock")
            return
        }
        _ = coordinator.cancel(reason: "cancel_before_evidence_commit")
        var staleBodyRan = false
        let staleAccepted = coordinator.performEvidenceCommitIfCurrent(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 20.2,
            priorMapGeneration:
                capturePriorMapAuthority.priorMapGeneration) {
                staleBodyRan = true
            }
        require(
            !staleAccepted && !staleBodyRan,
            "cancel-wins must reject the stale durable append body")
    }
    do {
        let (coordinator, generation) = startCoordinator(now: 25)
        _ = submit(
            coordinator,
            generation: generation,
            timestamp: 25,
            candidates: [activeA])
        let locked = submit(
            coordinator,
            generation: generation,
            timestamp: 25.2,
            candidates: [activeA])
        guard case .candidateLocked(let captureID, _) = locked else {
            require(false, "prior-map authority fixture must lock")
            return
        }
        var bodyRan = false
        let accepted = coordinator.performEvidenceCommitIfCurrent(
            generation: generation,
            captureID: captureID,
            frameTimestamp: 25.2,
            priorMapGeneration: UUID()) {
                bodyRan = true
            }
        require(
            !accepted && !bodyRan,
            "a changed prior-map generation must not enter the durable append")
        _ = coordinator.cancel(reason: "prior_map_authority_test_complete")
    }
    do {
        let (coordinator, generation) = startCoordinator(now: 30)
        _ = submit(
            coordinator,
            generation: generation,
            timestamp: 30,
            candidates: [activeA])
        let locked = submit(
            coordinator,
            generation: generation,
            timestamp: 30.2,
            candidates: [activeA])
        guard case .candidateLocked(let captureID, _) = locked else {
            require(false, "append-wins evidence fixture must lock")
            return
        }
        let appendEntered = DispatchSemaphore(value: 0)
        let releaseAppend = DispatchSemaphore(value: 0)
        let appendFinished = DispatchSemaphore(value: 0)
        let cancelStarted = DispatchSemaphore(value: 0)
        let cancelFinished = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var appendAccepted = false
        var appendBodyCount = 0
        var cancellation: PriceTagCaptureCancellation?
        DispatchQueue.global(qos: .userInitiated).async {
            let accepted = coordinator.performEvidenceCommitIfCurrent(
                generation: generation,
                captureID: captureID,
                frameTimestamp: 30.2,
                priorMapGeneration:
                    capturePriorMapAuthority.priorMapGeneration) {
                    resultLock.lock()
                    appendBodyCount += 1
                    resultLock.unlock()
                    appendEntered.signal()
                    _ = releaseAppend.wait(timeout: .now() + 2)
                }
            resultLock.lock()
            appendAccepted = accepted
            resultLock.unlock()
            appendFinished.signal()
        }
        require(
            appendEntered.wait(timeout: .now() + 1) == .success,
            "append-wins fixture must enter the linearized append body")
        DispatchQueue.global(qos: .userInitiated).async {
            cancelStarted.signal()
            let value = coordinator.cancel(
                reason: "cancel_during_evidence_commit")
            resultLock.lock()
            cancellation = value
            resultLock.unlock()
            cancelFinished.signal()
        }
        require(
            cancelStarted.wait(timeout: .now() + 1) == .success
                && cancelFinished.wait(timeout: .now() + 0.05) == .timedOut,
            "append-wins must keep cancellation behind the durable append boundary")
        releaseAppend.signal()
        require(
            appendFinished.wait(timeout: .now() + 1) == .success
                && cancelFinished.wait(timeout: .now() + 1) == .success,
            "append-wins append and following cancellation must both finish")
        resultLock.lock()
        let observedAppendAccepted = appendAccepted
        let observedAppendBodyCount = appendBodyCount
        let observedCancellation = cancellation
        resultLock.unlock()
        require(
            observedAppendAccepted
                && observedAppendBodyCount == 1
                && observedCancellation?.captureID == captureID
                && coordinator.currentState() == .idle,
            "append-wins must append exactly once before cancellation finalizes the capture")
    }

    func shelfCandidate(
        segmentID: String,
        side: String,
        confidence: Double = 0.9
    ) -> PriceTagShelfCandidate {
        let origin = segmentID == "shelf-A" ? 0.0 : 3.0
        return PriceTagShelfCandidate(
            shelfSegmentId: segmentID,
            shelfCode: segmentID == "shelf-A" ? "A-01" : "B-01",
            rowFlag: "R1",
            crossCode: "C1",
            side: side,
            distanceFromStartCm: segmentID == "shelf-A" ? 120 : 80,
            distanceToShelfM: 0.1,
            associationConfidence: confidence,
            occluded: false,
            blockedByOtherStructure: false,
            snappedPosition: PriorMapTagPoint3D(
                xM: origin + 1, yM: 0, heightM: 1.2),
            outline: [
                PriceTagShelfPreviewPoint(xM: origin, yM: 0),
                PriceTagShelfPreviewPoint(xM: origin + 2, yM: 0),
                PriceTagShelfPreviewPoint(xM: origin + 2, yM: 1),
                PriceTagShelfPreviewPoint(xM: origin, yM: 1),
            ])
    }
    let shelfA = shelfCandidate(segmentID: "shelf-A", side: "L")
    let shelfB = shelfCandidate(segmentID: "shelf-B", side: "R")
    func localizedTag(
        observationID: String,
        segmentID: String,
        side: String,
        version: Int = 2,
        includeV2: Bool = true,
        needsReview: Bool = false
    ) -> LocalizedPriceTag {
        let isA = segmentID == "shelf-A"
        return LocalizedPriceTag(
            format: "MarketScannerLocalizedPriceTag",
            version: version,
            tagId: "tag-\(observationID)",
            observationId: observationID,
            payload: "ACTIVE-A",
            symbology: "EAN13",
            floorId: "F1",
            timestamp: 100,
            trackingSessionId: "SESSION-ESL",
            priorMapId: "MAP-ESL",
            priorMapSha256: String(repeating: "a", count: 64),
            shelfSegmentId: segmentID,
            shelfCode: isA ? "A-01" : "B-01",
            rowFlag: "R1",
            crossCode: "C1",
            shelfSide: side,
            distanceFromShelfStartCm: isA ? 120 : 80,
            heightCm: 120,
            rawMapPosition: PriorMapTagPoint3D(xM: 1, yM: 0.1, heightM: 1.2),
            snappedMapPosition: PriorMapTagPoint3D(xM: 1, yM: 0, heightM: 1.2),
            localizationConfidence: 0.92,
            measurementConfidence: 0.90,
            associationConfidence: 0.88,
            measurementMethod: "scene_depth",
            needsReview: needsReview,
            userConfirmed: false,
            algorithmShelfSegmentId: includeV2 ? segmentID : nil,
            algorithmShelfCode: includeV2 ? (isA ? "A-01" : "B-01") : nil,
            algorithmSide: includeV2 ? side : nil,
            algorithmDistanceFromShelfStartCm: includeV2 ? (isA ? 120 : 80) : nil,
            algorithmAssociationConfidence: includeV2 ? 0.88 : nil,
            confirmationStatus: includeV2 ? "ALGORITHM_ONLY" : nil)
    }
    func association(
        observationID: String,
        segmentID: String,
        side: String,
        algorithmCandidateReliable: Bool = true,
        needsReview: Bool = false
    ) -> PriceTagShelfAssociationResult {
        return PriceTagShelfAssociationResult(
            tag: localizedTag(
                observationID: observationID,
                segmentID: segmentID,
                side: side,
                needsReview: needsReview),
            candidates: [shelfA, shelfB],
            algorithmCandidateReliable: algorithmCandidateReliable)
    }

    // Multi-frame shelf resolution must use a stable modal group and retain
    // fail-closed reliability when frames disagree or ids are duplicated.
    let modalFrames = [
        association(observationID: "frame-1", segmentID: "shelf-A", side: "L"),
        association(observationID: "frame-2", segmentID: "shelf-A", side: "L"),
        association(observationID: "frame-3", segmentID: "shelf-A", side: "L"),
        association(observationID: "frame-4", segmentID: "shelf-B", side: "R"),
    ]
    guard let modalResolution = PriceTagCaptureResolver.resolve(
            modalFrames, minimumEvidenceFrames: 3) else {
        require(false, "resolver must accept a three-frame stable shelf mode")
        return
    }
    require(
        modalResolution.algorithmCandidateReliable
            && modalResolution.tag.algorithmShelfSegmentId == "shelf-A",
        "resolver must select the stable modal shelf group")
    let splitFrames = [
        association(observationID: "split-1", segmentID: "shelf-A", side: "L"),
        association(observationID: "split-2", segmentID: "shelf-A", side: "L"),
        association(observationID: "split-3", segmentID: "shelf-B", side: "R"),
        association(observationID: "split-4", segmentID: "shelf-B", side: "R"),
    ]
    require(
        PriceTagCaptureResolver.resolve(
            splitFrames, minimumEvidenceFrames: 3)?.algorithmCandidateReliable == false,
        "shelf disagreement must remain fail-closed")
    let mixedReliabilityFrames = [
        association(
            observationID: "weak-1",
            segmentID: "shelf-A",
            side: "L",
            algorithmCandidateReliable: false,
            needsReview: true),
        association(
            observationID: "weak-2",
            segmentID: "shelf-A",
            side: "L",
            algorithmCandidateReliable: false,
            needsReview: true),
        association(
            observationID: "strong-1",
            segmentID: "shelf-A",
            side: "L",
            algorithmCandidateReliable: true,
            needsReview: false),
    ]
    require(
        PriceTagCaptureResolver.resolve(
            mixedReliabilityFrames,
            minimumEvidenceFrames: 3)?.algorithmCandidateReliable == false,
        "two weak frames plus one strong frame on the same shelf/side "
            + "must not become reliably confirmable")
    let duplicateObservationFrames = [
        association(observationID: "duplicate", segmentID: "shelf-A", side: "L"),
        association(observationID: "duplicate", segmentID: "shelf-A", side: "L"),
        association(observationID: "unique", segmentID: "shelf-A", side: "L"),
    ]
    require(
        PriceTagCaptureResolver.resolve(
            duplicateObservationFrames, minimumEvidenceFrames: 3) == nil,
        "resolver must reject repeated observation ids as non-independent frames")

    // SC-01..05 plus v1/v2 compatibility: confirmation is explicit, bounded
    // to selectable candidates, and never overwrites algorithm evidence.
    let captureID = UUID()
    let boundTag = modalResolution.tag.bindingCapture(
        captureID: captureID,
        observationIDs: ["frame-1", "frame-2", "frame-3"])
    guard let confirmed = boundTag.applyingConfirmation(
            decision: .confirmedAlgorithmCandidate,
            candidates: [shelfA, shelfB],
            confirmedAtUTC: 1_700_000_000,
            confirmedAtMonotonic: 10) else {
        require(false, "SC-01 a reliable algorithm candidate must be confirmable")
        return
    }
    require(
        confirmed.confirmationStatus == "USER_CONFIRMED"
            && confirmed.userConfirmedShelfSegmentId == "shelf-A"
            && confirmed.algorithmShelfSegmentId == "shelf-A"
            && confirmed.userConfirmed,
        "SC-01 correct/save must persist explicit user confirmation")
    func priorMapConfiguration(
        mapID: String = "MAP-ESL",
        sha256: String = String(repeating: "a", count: 64),
        floorID: String = "F1"
    ) -> PriorMapScanConfiguration {
        return PriorMapScanConfiguration(
            formatVersion: 1,
            workflowMode: .priorMapLocalized,
            packageDirectory: URL(fileURLWithPath: "/private/tmp/esl-map"),
            priorMapId: mapID,
            priorMapSha256: sha256,
            floorId: floorID,
            storeID: "STORE-ESL",
            initialMapPose: PriorMapPose2D(xM: 0, yM: 0, yawRad: 0))
    }
    let validCommitAuthority = PriceTagConfirmationCommitAuthority(
        captureGeneration: UUID(),
        captureID: captureID,
        priorMapGeneration: capturePriorMapAuthority.priorMapGeneration,
        trackingSessionID: "SESSION-ESL",
        priorMapID: "MAP-ESL",
        priorMapSHA256: String(repeating: "a", count: 64),
        floorID: "F1")
    require(
        PriceTagConfirmationIdentityValidator.matches(
            tag: confirmed,
            authority: validCommitAuthority,
            configuration: priorMapConfiguration(),
            trackingSessionID: "SESSION-ESL"),
        "confirmation persistence must accept the exact scan identity")
    require(
        !PriceTagConfirmationIdentityValidator.matches(
            tag: confirmed,
            authority: validCommitAuthority,
            configuration: priorMapConfiguration(mapID: "MAP-OTHER"),
            trackingSessionID: "SESSION-ESL"),
        "confirmation persistence must reject a different prior-map id")
    require(
        !PriceTagConfirmationIdentityValidator.matches(
            tag: confirmed,
            authority: validCommitAuthority,
            configuration: priorMapConfiguration(
                sha256: String(repeating: "b", count: 64)),
            trackingSessionID: "SESSION-ESL"),
        "confirmation persistence must reject a different prior-map SHA")
    require(
        !PriceTagConfirmationIdentityValidator.matches(
            tag: confirmed,
            authority: validCommitAuthority,
            configuration: priorMapConfiguration(floorID: "F2"),
            trackingSessionID: "SESSION-ESL"),
        "confirmation persistence must reject a different floor")
    require(
        !PriceTagConfirmationIdentityValidator.matches(
            tag: confirmed,
            authority: validCommitAuthority,
            configuration: priorMapConfiguration(),
            trackingSessionID: "SESSION-OTHER"),
        "confirmation persistence must reject a different tracking session")
    require(
        !PriceTagConfirmationIdentityValidator.matches(
            tag: confirmed,
            authority: validCommitAuthority,
            configuration: .freeMapping,
            trackingSessionID: "SESSION-ESL"),
        "confirmation persistence must reject the free-mapping workflow")
    let wrongCaptureAuthority = PriceTagConfirmationCommitAuthority(
        captureGeneration: validCommitAuthority.captureGeneration,
        captureID: UUID(),
        priorMapGeneration: validCommitAuthority.priorMapGeneration,
        trackingSessionID: validCommitAuthority.trackingSessionID,
        priorMapID: validCommitAuthority.priorMapID,
        priorMapSHA256: validCommitAuthority.priorMapSHA256,
        floorID: validCommitAuthority.floorID)
    require(
        !PriceTagConfirmationIdentityValidator.matches(
            tag: confirmed,
            authority: wrongCaptureAuthority,
            configuration: priorMapConfiguration(),
            trackingSessionID: "SESSION-ESL"),
        "confirmation persistence must reject a different burst identity")
    guard let overridden = boundTag.applyingConfirmation(
            decision: .selectedAlternative(segmentID: "shelf-B", side: "R"),
            candidates: [shelfA, shelfB],
            confirmedAtUTC: 1_700_000_001,
            confirmedAtMonotonic: 11) else {
        require(false, "SC-02 a bounded selectable alternative must be overridable")
        return
    }
    require(
        overridden.confirmationStatus == "USER_OVERRIDDEN"
            && overridden.algorithmShelfSegmentId == "shelf-A"
            && overridden.shelfSegmentId == "shelf-A"
            && overridden.userConfirmedShelfSegmentId == "shelf-B"
            && overridden.confirmationSource == "on_device_operator",
        "SC-02 override must preserve algorithm evidence and audit the user choice")
    let shelfAOtherSide = shelfCandidate(segmentID: "shelf-A", side: "R")
    guard let sameSegmentOtherSide = boundTag.applyingConfirmation(
            decision: .selectedAlternative(segmentID: "shelf-A", side: "R"),
            candidates: [shelfA, shelfAOtherSide],
            confirmedAtUTC: 1_700_000_002,
            confirmedAtMonotonic: 12) else {
        require(false, "SC-02 a bounded same-segment opposite side must be selectable")
        return
    }
    require(
        sameSegmentOtherSide.confirmationStatus == "USER_OVERRIDDEN"
            && sameSegmentOtherSide.userConfirmedShelfSegmentId == "shelf-A"
            && sameSegmentOtherSide.userConfirmedSide == "R"
            && sameSegmentOtherSide.algorithmSide == "L",
        "SC-02 override identity must include segment id and side")
    require(
        boundTag.applyingConfirmation(
            decision: .rescan,
            candidates: [shelfA, shelfB],
            confirmedAtUTC: 1,
            confirmedAtMonotonic: 1) == nil,
        "SC-03 rescan must not create a finalized tag")
    require(
        boundTag.applyingConfirmation(
            decision: .observationOnly,
            candidates: [shelfA, shelfB],
            confirmedAtUTC: 1,
            confirmedAtMonotonic: 1) == nil,
        "SC-03 observation-only must not create a finalized tag")
    require(
        boundTag.applyingConfirmation(
            decision: .confirmedAlgorithmCandidate,
            candidates: [],
            confirmedAtUTC: 1,
            confirmedAtMonotonic: 1) == nil,
        "SC-04 no candidate must fail closed")
    let weakShelfA = shelfCandidate(
        segmentID: "shelf-A", side: "L", confidence: 0.4)
    require(
        boundTag.applyingConfirmation(
            decision: .confirmedAlgorithmCandidate,
            candidates: [weakShelfA],
            confirmedAtUTC: 1,
            confirmedAtMonotonic: 1) == nil,
        "SC-05 a non-selectable weak candidate must fail closed")

    do {
        let legacy = localizedTag(
            observationID: "legacy-v1",
            segmentID: "shelf-A",
            side: "L",
            version: 1,
            includeV2: false)
        let legacyData = try JSONEncoder().encode(legacy)
        let legacyObject = try JSONSerialization.jsonObject(
            with: legacyData) as? [String: Any]
        require(
            legacyObject?["capture_id"] == nil
                && legacyObject?["algorithm_shelf_segment_id"] == nil,
            "v1 encoder fixture must omit additive v2 fields")
        let decodedLegacy = try JSONDecoder().decode(
            LocalizedPriceTag.self, from: legacyData)
        require(
            decodedLegacy.version == 1
                && decodedLegacy.captureId == nil
                && decodedLegacy.confirmationStatus == nil,
            "legacy v1 LocalizedPriceTag must remain decodable")

        let v2Data = try JSONEncoder().encode(overridden)
        let decodedV2 = try JSONDecoder().decode(
            LocalizedPriceTag.self, from: v2Data)
        require(
            decodedV2 == overridden
                && decodedV2.frameObservationIds == ["frame-1", "frame-2", "frame-3"],
            "v2 capture/confirmation audit must round-trip without losing evidence")
    } catch {
        require(false, "LocalizedPriceTag v1/v2 Codable compatibility failed: \(error)")
    }

    print("ESL barcode capture focused tests passed")
}

func runSnapshotStableCommittedFileFocusedTests() {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "marketscanner-stable-committed-focused-"
            + UUID().uuidString.lowercased(),
        isDirectory: true)
    do {
        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: true)
    } catch {
        require(false, "cannot create stable committed-file fixture: \(error)")
    }
    defer {
        SessionSnapshotTransaction.faultInjector = nil
        try? fileManager.removeItem(at: root)
    }

    func makeCommittedFile(_ name: String, _ bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        guard chmod(url.path, mode_t(0o444)) == 0 else {
            throw NSError(
                domain: "StableCommittedFixture",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                    "cannot freeze \(name)"])
        }
        return url
    }

    func rewriteInPlace(_ url: URL, bytes: Data) throws {
        guard chmod(url.path, mode_t(0o644)) == 0 else {
            throw NSError(
                domain: "StableCommittedFixture",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                    "cannot thaw \(url.lastPathComponent)"])
        }
        let descriptor = open(
            url.path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw NSError(
                domain: "StableCommittedFixture",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                    "cannot open \(url.lastPathComponent) for rewrite"])
        }
        defer { _ = close(descriptor) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else {
                throw NSError(
                    domain: "StableCommittedFixture",
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey:
                        "cannot rewrite \(url.lastPathComponent)"])
            }
            offset += count
        }
        guard fsync(descriptor) == 0,
              chmod(url.path, mode_t(0o444)) == 0 else {
            throw NSError(
                domain: "StableCommittedFixture",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                    "cannot refreeze \(url.lastPathComponent)"])
        }
    }

    do {
        let expected = Data("{\"ctime\":\"stable\"}\n".utf8)
        let url = try makeCommittedFile("ctime-only.json", expected)
        var injected = false
        var confirmedCTimeOnlyDrift = false
        SessionSnapshotTransaction.faultInjector = { point in
            guard !injected,
                  case let .afterCommittedFileAuthorityReadBeforeOpen(name)
                    = point,
                  name == url.lastPathComponent else { return }
            var before = stat()
            var after = stat()
            guard lstat(url.path, &before) == 0 else {
                throw NSError(
                    domain: "StableCommittedFixture", code: 10)
            }
            usleep(20_000)
            guard chmod(url.path, mode_t(0o644)) == 0,
                  chmod(url.path, mode_t(0o444)) == 0,
                  lstat(url.path, &after) == 0 else {
                throw NSError(
                    domain: "StableCommittedFixture", code: 11)
            }
            confirmedCTimeOnlyDrift =
                before.st_dev == after.st_dev
                && before.st_ino == after.st_ino
                && before.st_mode == after.st_mode
                && before.st_nlink == after.st_nlink
                && before.st_size == after.st_size
                && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
                && (before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec
                    || before.st_ctimespec.tv_nsec
                        != after.st_ctimespec.tv_nsec)
            injected = true
        }
        let actual = try SessionSnapshotTransaction
            .readStableCommittedFileForTests(
                url, maximumBytes: 1024)
        SessionSnapshotTransaction.faultInjector = nil
        require(injected, "ctime-only fault point must execute")
        require(
            confirmedCTimeOnlyDrift,
            "fixture must change only ctime before the stable open")
        require(
            actual == expected,
            "same immutable inode with pre-open ctime advance must be readable")

        let mtimeURL = try makeCommittedFile(
            "mtime-change.json", Data("{\"value\":\"before\"}\n".utf8))
        SessionSnapshotTransaction.faultInjector = { point in
            guard case let .afterCommittedFileAuthorityReadBeforeOpen(name)
                    = point,
                  name == mtimeURL.lastPathComponent else { return }
            usleep(20_000)
            try rewriteInPlace(
                mtimeURL,
                bytes: Data("{\"value\":\"after!\"}\n".utf8))
        }
        var mtimeRejected = false
        var mtimeFailure = ""
        do {
            _ = try SessionSnapshotTransaction
                .readStableCommittedFileForTests(
                    mtimeURL, maximumBytes: 1024)
        } catch {
            mtimeRejected = true
            mtimeFailure = error.localizedDescription
        }
        SessionSnapshotTransaction.faultInjector = nil
        require(
            mtimeRejected && mtimeFailure.contains("mtime"),
            "pre-open content/mtime change must remain fail-closed")

        let replacementURL = try makeCommittedFile(
            "atomic-replacement.json", Data("{\"value\":1}\n".utf8))
        let replacement = try makeCommittedFile(
            "atomic-replacement.prepared", Data("{\"value\":2}\n".utf8))
        let displaced = root.appendingPathComponent(
            "atomic-replacement.displaced")
        SessionSnapshotTransaction.faultInjector = { point in
            guard case let .afterCommittedFileAuthorityReadBeforeOpen(name)
                    = point,
                  name == replacementURL.lastPathComponent else { return }
            guard rename(replacementURL.path, displaced.path) == 0,
                  rename(replacement.path, replacementURL.path) == 0 else {
                throw NSError(
                    domain: "StableCommittedFixture", code: 12)
            }
        }
        var replacementRejected = false
        var replacementFailure = ""
        do {
            _ = try SessionSnapshotTransaction
                .readStableCommittedFileForTests(
                    replacementURL, maximumBytes: 1024)
        } catch {
            replacementRejected = true
            replacementFailure = error.localizedDescription
        }
        SessionSnapshotTransaction.faultInjector = nil
        require(
            replacementRejected && replacementFailure.contains("inode"),
            "pre-open atomic inode replacement must remain fail-closed")

        let duringReadURL = try makeCommittedFile(
            "during-read-ctime.json", Data("{\"value\":3}\n".utf8))
        SessionSnapshotTransaction.faultInjector = { point in
            guard case let .afterCommittedFileOpenBeforeRead(name) = point,
                  name == duringReadURL.lastPathComponent else { return }
            usleep(20_000)
            guard chmod(duringReadURL.path, mode_t(0o644)) == 0,
                  chmod(duringReadURL.path, mode_t(0o444)) == 0 else {
                throw NSError(
                    domain: "StableCommittedFixture", code: 13)
            }
        }
        var duringReadCTimeRejected = false
        do {
            _ = try SessionSnapshotTransaction
                .readStableCommittedFileForTests(
                    duringReadURL, maximumBytes: 1024)
        } catch {
            duringReadCTimeRejected = true
        }
        SessionSnapshotTransaction.faultInjector = nil
        require(
            duringReadCTimeRejected,
            "ctime changes after descriptor binding must remain fail-closed")

        let postOpenURL = try makeCommittedFile(
            "post-open-replacement.json", Data("{\"value\":4}\n".utf8))
        let postOpenReplacement = try makeCommittedFile(
            "post-open-replacement.prepared", Data("{\"value\":5}\n".utf8))
        let postOpenDisplaced = root.appendingPathComponent(
            "post-open-replacement.displaced")
        SessionSnapshotTransaction.faultInjector = { point in
            guard case let .afterCommittedFileOpenBeforeRead(name) = point,
                  name == postOpenURL.lastPathComponent else { return }
            guard rename(postOpenURL.path, postOpenDisplaced.path) == 0,
                  rename(postOpenReplacement.path, postOpenURL.path) == 0 else {
                throw NSError(
                    domain: "StableCommittedFixture", code: 14)
            }
        }
        var postOpenReplacementRejected = false
        do {
            _ = try SessionSnapshotTransaction
                .readStableCommittedFileForTests(
                    postOpenURL, maximumBytes: 1024)
        } catch {
            postOpenReplacementRejected = true
        }
        SessionSnapshotTransaction.faultInjector = nil
        require(
            postOpenReplacementRejected,
            "post-open pathname replacement must remain fail-closed")

        let artifactBytes = Data(repeating: 0x61, count: 128 * 1024)
        let artifactExpectedSHA = SHA256.hash(data: artifactBytes).map {
            String(format: "%02x", $0)
        }.joined()
        let artifactURL = try makeCommittedFile(
            "artifact-ctime-settlement.bin", artifactBytes)
        var artifactSettlementCount = 0
        SessionSnapshotTransaction.faultInjector = { point in
            guard artifactSettlementCount == 0,
                  case let .afterArtifactOpenBeforeHash(name) = point,
                  name == artifactURL.lastPathComponent else { return }
            usleep(20_000)
            guard chmod(artifactURL.path, mode_t(0o644)) == 0,
                  chmod(artifactURL.path, mode_t(0o444)) == 0 else {
                throw NSError(
                    domain: "StableCommittedFixture", code: 18)
            }
            artifactSettlementCount += 1
        }
        let artifactActualSHA = try SessionSnapshotTransaction
            .sha256StableCommittedFileForTests(
                artifactURL, expectedBytes: Int64(artifactBytes.count))
        SessionSnapshotTransaction.faultInjector = nil
        require(
            artifactSettlementCount == 1
                && artifactActualSHA == artifactExpectedSHA,
            "one-time artifact ctime settlement must retry and preserve SHA")

        let repeatedArtifactURL = try makeCommittedFile(
            "artifact-continuing-ctime.bin", artifactBytes)
        var repeatedArtifactSettlementCount = 0
        SessionSnapshotTransaction.faultInjector = { point in
            guard case let .afterArtifactOpenBeforeHash(name) = point,
                  name == repeatedArtifactURL.lastPathComponent else { return }
            usleep(20_000)
            guard chmod(repeatedArtifactURL.path, mode_t(0o644)) == 0,
                  chmod(repeatedArtifactURL.path, mode_t(0o444)) == 0 else {
                throw NSError(
                    domain: "StableCommittedFixture", code: 19)
            }
            repeatedArtifactSettlementCount += 1
        }
        var repeatedArtifactRejected = false
        do {
            _ = try SessionSnapshotTransaction
                .sha256StableCommittedFileForTests(
                    repeatedArtifactURL,
                    expectedBytes: Int64(artifactBytes.count))
        } catch {
            repeatedArtifactRejected = true
        }
        SessionSnapshotTransaction.faultInjector = nil
        require(
            repeatedArtifactRejected
                && repeatedArtifactSettlementCount == 2,
            "continuing artifact ctime changes must remain fail-closed")

        let changedArtifactURL = try makeCommittedFile(
            "artifact-content-change.bin", artifactBytes)
        var changedArtifactInjected = false
        SessionSnapshotTransaction.faultInjector = { point in
            guard !changedArtifactInjected,
                  case let .afterArtifactOpenBeforeHash(name) = point,
                  name == changedArtifactURL.lastPathComponent else { return }
            try rewriteInPlace(
                changedArtifactURL,
                bytes: Data(repeating: 0x62, count: artifactBytes.count))
            changedArtifactInjected = true
        }
        var changedArtifactRejected = false
        do {
            _ = try SessionSnapshotTransaction
                .sha256StableCommittedFileForTests(
                    changedArtifactURL,
                    expectedBytes: Int64(artifactBytes.count))
        } catch {
            changedArtifactRejected = true
        }
        SessionSnapshotTransaction.faultInjector = nil
        require(
            changedArtifactInjected
                && changedArtifactRejected,
            "artifact content/mtime mutation must remain fail-closed")

        let hardlinkURL = try makeCommittedFile(
            "hardlink-authority.json", Data("{\"value\":6}\n".utf8))
        let hardlinkAlias = root.appendingPathComponent("hardlink-alias.json")
        guard link(hardlinkURL.path, hardlinkAlias.path) == 0 else {
            throw NSError(
                domain: "StableCommittedFixture", code: 15)
        }
        var hardlinkRejected = false
        do {
            _ = try SessionSnapshotTransaction
                .readStableCommittedFileForTests(
                    hardlinkURL, maximumBytes: 1024)
        } catch {
            hardlinkRejected = true
        }
        require(
            hardlinkRejected,
            "multi-link committed authority must remain fail-closed")

        let symlinkTarget = try makeCommittedFile(
            "symlink-target.json", Data("{\"value\":7}\n".utf8))
        let symlinkURL = root.appendingPathComponent("symlink-authority.json")
        guard symlink(symlinkTarget.lastPathComponent, symlinkURL.path) == 0 else {
            throw NSError(
                domain: "StableCommittedFixture", code: 16)
        }
        var symlinkRejected = false
        do {
            _ = try SessionSnapshotTransaction
                .readStableCommittedFileForTests(
                    symlinkURL, maximumBytes: 1024)
        } catch {
            symlinkRejected = true
        }
        require(
            symlinkRejected,
            "symlink committed authority must remain fail-closed")

        let modeURL = root.appendingPathComponent("mode-authority.json")
        try Data("{\"value\":8}\n".utf8).write(to: modeURL)
        guard chmod(modeURL.path, mode_t(0o644)) == 0 else {
            throw NSError(
                domain: "StableCommittedFixture", code: 17)
        }
        var modeRejected = false
        do {
            _ = try SessionSnapshotTransaction
                .readStableCommittedFileForTests(
                    modeURL, maximumBytes: 1024)
        } catch {
            modeRejected = true
        }
        require(
            modeRejected,
            "writable committed authority must remain fail-closed")
    } catch {
        SessionSnapshotTransaction.faultInjector = nil
        require(
            false,
            "snapshot stable committed-file focused tests failed: \(error)")
    }
    print("Snapshot stable committed-file focused tests passed")
}

if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "--esl-finalization-focused" {
    runESLFinalizationBindingFocusedTests()
    exit(0)
}
if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "--esl-capture-focused" {
    runESLBarcodeCaptureFocusedTests()
    exit(0)
}
if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "--snapshot-stable-read-focused" {
    runSnapshotStableCommittedFileFocusedTests()
    exit(0)
}
if (CommandLine.arguments.count == 4 || CommandLine.arguments.count == 5),
   CommandLine.arguments[1] == "--snapshot-real-session" {
    let segment = URL(
        fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let taskRoot = URL(
        fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    let ctimeSettlementTarget = CommandLine.arguments.count == 5
        ? CommandLine.arguments[4] : nil
    var ctimeSettlementInjected = false
    do {
        let metadataURL = segment.appendingPathComponent("metadata.json")
        let metadataData = try Data(contentsOf: metadataURL)
        guard let metadata = try StrictJSONDocumentParser.object(
                from: metadataData,
                limits: StrictJSONDocumentLimits(
                    maximumBytes: max(metadataData.count, 1)))
                as? [String: Any],
              let priorMapID = metadata["priorMapId"] as? String,
              let priorMapSHA256 = metadata["priorMapSha256"] as? String,
              let storeID = metadata["storeId"] as? String,
              let floorID = metadata["floorId"] as? String else {
            throw NSError(
                domain: "RealSessionSnapshot",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "formal session identity is missing"])
        }
        let databaseNames = try FileManager.default.contentsOfDirectory(
            atPath: segment.path).filter { $0.hasSuffix(".db") }
        guard databaseNames.count == 1 else {
            throw NSError(
                domain: "RealSessionSnapshot",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "real session must contain exactly one database"])
        }
        if let ctimeSettlementTarget {
            guard ctimeSettlementTarget == "metadata.json"
                    || ctimeSettlementTarget == databaseNames[0] else {
                throw NSError(
                    domain: "RealSessionSnapshot",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "ctime settlement target must be metadata or database"])
            }
            SessionSnapshotTransaction.faultInjector = { point in
                guard !ctimeSettlementInjected,
                      case let .afterArtifactOpenBeforeHash(name) = point,
                      name == ctimeSettlementTarget else { return }
                let artifact = taskRoot
                    .appendingPathComponent(
                        "input_snapshot.staging", isDirectory: true)
                    .appendingPathComponent(name)
                guard chmod(artifact.path, mode_t(0o644)) == 0,
                      chmod(artifact.path, mode_t(0o444)) == 0 else {
                    throw NSError(
                        domain: "RealSessionSnapshot",
                        code: Int(errno),
                        userInfo: [NSLocalizedDescriptionKey:
                            "cannot inject one-time artifact ctime settlement"])
                }
                ctimeSettlementInjected = true
            }
        }
        let snapshot = try SessionSnapshotTransaction.snapshot(
            finalizedSession: segment,
            sourceDatabase: segment.appendingPathComponent(databaseNames[0]),
            taskRoot: taskRoot,
            eligibility: SessionSnapshotTransaction.Eligibility(
                priorMapID: priorMapID,
                priorMapSHA256: priorMapSHA256,
                storeID: storeID,
                floorID: floorID,
                appGitSHA: "real-session-host-validation"))
        try SessionSnapshotTransaction.revalidateSnapshot(
            snapshot.snapshotDirectory)
        SessionSnapshotTransaction.faultInjector = nil
        if ctimeSettlementTarget != nil && !ctimeSettlementInjected {
            throw NSError(
                domain: "RealSessionSnapshot",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey:
                    "requested ctime settlement fault point did not execute"])
        }
        let generation = snapshot.inputManifest["generation"] as? String
            ?? "unknown"
        print(
            "Real session snapshot passed: "
                + "bundle=\(snapshot.bundleSHA256) "
                + "generation=\(generation)")
        exit(0)
    } catch {
        SessionSnapshotTransaction.faultInjector = nil
        FileHandle.standardError.write(
            Data("Real session snapshot failed: \(error)\n".utf8))
        exit(12)
    }
}
if (CommandLine.arguments.count == 6 || CommandLine.arguments.count == 7),
   CommandLine.arguments[1] == "--mapcase02-suite" {
    runMapCase02Suite(
        workbookPath: CommandLine.arguments[2],
        outputPath: CommandLine.arguments[3],
        expectedCanonicalSHA256: CommandLine.arguments[4],
        expectedPackageSHA256: CommandLine.arguments[5],
        legacyWorkbookPath: CommandLine.arguments.count == 7
            ? CommandLine.arguments[6] : nil)
    exit(0)
}
if CommandLine.arguments.count >= 3,
   CommandLine.arguments[1] == "--xlsx-library-smoke" {
    runXLSXLibrarySmoke(
        workbookPaths: Array(CommandLine.arguments.dropFirst(2)))
    exit(0)
}
if CommandLine.arguments.count == 4,
   CommandLine.arguments[1] == "--shelf-segment-parity" {
    runShelfSegmentParity(
        workbookPath: CommandLine.arguments[2],
        expectedPath: CommandLine.arguments[3])
    exit(0)
}
if CommandLine.arguments.count <= 1 {
    runESLBarcodeCaptureFocusedTests()
}

func permissions(_ url: URL) throws -> Int {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        throw NSError(
            domain: "MarketScannerTestPermissions",
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey:
                "cannot lstat \(url.path): \(String(cString: strerror(errno)))"])
    }
    return Int(metadata.st_mode & mode_t(0o777))
}

func processCPUSeconds(_ usage: rusage) -> Double {
    let user = Double(usage.ru_utime.tv_sec)
        + Double(usage.ru_utime.tv_usec) / 1_000_000.0
    let system = Double(usage.ru_stime.tv_sec)
        + Double(usage.ru_stime.tv_usec) / 1_000_000.0
    return user + system
}

func regularFileBytes(in directory: URL) throws -> Int64 {
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [],
        errorHandler: { _, error in
            enumerationError = error
            return false
        }) else {
        throw NSError(domain: "MarketScannerScaleMetrics", code: 1)
    }
    var total: Int64 = 0
    for case let url as URL in enumerator {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey])
        if values.isRegularFile == true {
            guard let size = values.fileSize, size >= 0 else {
                throw NSError(domain: "MarketScannerScaleMetrics", code: 2)
            }
            total += Int64(size)
        }
    }
    if let enumerationError { throw enumerationError }
    return total
}

// Dispatch the Result crash worker before the default/E2E host suites. Each
// crash phase is a standalone process and must reach its requested lock or
// fault boundary without first running unrelated tests.
runResultPublicationCrashWorkerIfRequested()
runMapQuarantineCrashWorkerIfRequested()

// The 100k-record finalization memory qualification runs in a dedicated
// process. `ru_maxrss` is a lifetime high-water mark, so measuring it at
// the end of the full host suite would include unrelated 60k clock,
// workbook, replay and crash-recovery workloads.
if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "--finalization-scale" {
    do {
        let scaleStartedAt = ProcessInfo.processInfo.systemUptime
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ms-finalization-scale-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recordCount = 100_000
        let mapHash = String(repeating: "b", count: 64)
        func writeEvidence(
            _ fileName: String,
            format: String,
            recordBody: (Int) -> String
        ) throws {
            let url = directory.appendingPathComponent(fileName)
            guard FileManager.default.createFile(
                atPath: url.path, contents: nil) else {
                throw NSError(
                    domain: "MarketScannerFinalizationScale", code: 1)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var batch = Data()
            batch.reserveCapacity(1024 * 1024)
            for index in 1...recordCount {
                let identity = "\"format\":\"\(format)\",\"version\":1,"
                    + "\"trackingSessionId\":\"session-long\","
                    + "\"priorMapId\":\"map-long\","
                    + "\"priorMapSha256\":\"\(mapHash)\","
                    + "\"floorId\":\"1\","
                batch.append(contentsOf:
                    ("{" + identity + recordBody(index) + "}\n").utf8)
                if batch.count >= 1024 * 1024 {
                    try handle.write(contentsOf: batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty { try handle.write(contentsOf: batch) }
            try handle.synchronize()
        }
        let poseJSON = "{\"x_m\":0,\"y_m\":0,\"yaw_rad\":0}"
        try writeEvidence(
            "localization_trace.jsonl",
            format: "MarketScannerLocalizationTrace"
        ) { index in
            "\"timestamp\":\(index),\"nodeTimebaseTimestamp\":\(index),"
                + "\"nodeTimebaseOffsetSeconds\":0,\"rawPose\":\(poseJSON),"
                + "\"estimatedPose\":\(poseJSON),\"trackingState\":\"normal\","
                + "\"localizationState\":\"stable\",\"confidence\":1"
        }
        try writeEvidence(
            "localization_constraints.jsonl",
            format: "MarketScannerLocalizationConstraint"
        ) { index in
            "\"timestamp\":\(index),\"nodeTimebaseTimestamp\":\(index),"
                + "\"nodeTimebaseOffsetSeconds\":0,\"accepted\":false,"
                + "\"predictedPose\":\(poseJSON),\"uniqueness\":0.9"
        }
        try writeEvidence(
            "localization_events.jsonl",
            format: "MarketScannerLocalizationStateEvent"
        ) { index in
            "\"timestamp\":\(index),\"nodeTimebaseTimestamp\":\(index),"
                + "\"nodeTimebaseOffsetSeconds\":0,\"state\":\"stable\","
                + "\"confidence\":1"
        }
        for name in [
            "manual_localization_events.jsonl", "tag_observations.jsonl",
            "tag_observation_bursts.jsonl",
            "localization_recovery_events.jsonl",
        ] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        try Data("[]".utf8).write(
            to: directory.appendingPathComponent("localized_price_tags.json"))
        let expectation = LocalizationEvidenceBundleExpectation(
            trackingSessionId: "session-long",
            priorMapId: "map-long",
            priorMapSha256: mapHash,
            floorId: "1",
            traceRecordCount: recordCount,
            constraintRecordCount: recordCount,
            stateEventCount: recordCount,
            lastDurableState: "stable",
            localizedPriceTagCount: 0)
        let blockers = LocalizationEvidenceBundleValidator.blockers(
            in: directory, expectation: expectation)
        guard blockers.isEmpty else {
            FileHandle.standardError.write(Data(
                "100k finalization validation failed: \(blockers)\n".utf8))
            exit(15)
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            FileHandle.standardError.write(
                Data("getrusage failed\n".utf8))
            exit(15)
        }
        let temporaryDiskBytes = try regularFileBytes(in: directory)
        print("Finalization test records: \(recordCount * 3)")
        print("Finalization test input bytes: \(temporaryDiskBytes)")
        print("Finalization test temporary disk bytes: \(temporaryDiskBytes)")
        print("Finalization test wall seconds: \(ProcessInfo.processInfo.systemUptime - scaleStartedAt)")
        print("Finalization test CPU seconds: \(processCPUSeconds(usage))")
        print("Finalization test peak RSS bytes: \(usage.ru_maxrss)")
        exit(0)
    } catch {
        FileHandle.standardError.write(
            Data("100k finalization scale failed: \(error)\n".utf8))
        exit(15)
    }
}

// RC scale closeout: 48 hours at 10 Hz with a discrete state transition on
// every record must still retain at most one conservative record/second plus
// the exact final record. This dedicated process makes ru_maxrss attributable
// to the production compactor rather than the rest of the host suite.
if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "--trace-compaction-scale" {
    let scaleStartedAt = ProcessInfo.processInfo.systemUptime
    let recordCount = StrictLocalizationTraceParser
        .qualificationMaximumRecords
    let expectedSeconds = 48 * 60 * 60
    require(
        recordCount == expectedSeconds * 10,
        "trace scale contract must remain 48h at 10 Hz")
    var compactor = StrictLocalizationTraceParser.RetainedTraceCompactor(
        originNodeTimestamp: 1_000_000)
    for index in 0..<recordCount {
        let isExactFinal = index == recordCount - 1
        let lost = !isExactFinal && index % 2 == 1
        let timestamp = 1_000_000 + Double(index) / 10.0
        compactor.consume(StrictLocalizationTraceParser.TraceRecord(
            timestamp: Double(index) / 10.0,
            xM: 0, yM: 0, yawRad: 0,
            localizationState: lost ? "lost" : "stable",
            trackingState: lost ? "notAvailable" : "normal",
            floorID: "1",
            nodeTimebaseOffsetSeconds: 1_000_000,
            nodeTimebaseTimestamp: timestamp,
            confidence: lost ? 0 : 1))
    }
    let retained = compactor.finish()
    require(
        retained.count == expectedSeconds + 1,
        "48h transition storm must retain one/second plus exact final; "
            + "got \(retained.count)")
    require(
        retained.dropLast().allSatisfy {
            $0.localizationState == "lost"
                && $0.trackingState == "notAvailable"
        },
        "per-second compaction must conservatively retain lost evidence")
    require(
        retained.last?.localizationState == "stable",
        "trace compactor must retain the exact final sample")
    var usage = rusage()
    require(getrusage(RUSAGE_SELF, &usage) == 0, "trace scale getrusage failed")
    print("Trace compaction input records: \(recordCount)")
    print("Trace compaction temporary disk bytes: 0")
    print("Trace compaction wall seconds: \(ProcessInfo.processInfo.systemUptime - scaleStartedAt)")
    print("Trace compaction CPU seconds: \(processCPUSeconds(usage))")
    print("Trace compaction retained records: \(retained.count)")
    print("Trace compaction peak RSS bytes: \(usage.ru_maxrss)")
    exit(0)
}

// RC scale closeout: exercise the real strict burst parser, exact observation
// consumer and retained production DTOs at the qualified 200k observation
// ceiling. The fixture is streamed to disk in bounded batches.
if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "--tag-evidence-scale" {
    do {
        let scaleStartedAt = ProcessInfo.processInfo.systemUptime
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ms-tag-evidence-scale-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let observationCount = GeneratedMobileEvidenceContracts.ProductScale
            .maxTagObservations
        let framesPerBurst = 100
        require(
            observationCount == 200_000
                && observationCount % framesPerBurst == 0,
            "tag scale contract must remain exactly 200k")
        let burstCount = observationCount / framesPerBurst
        let mapID = "scale-map"
        let mapSHA = String(repeating: "a", count: 64)
        let sessionID = "scale-session"
        let floorID = "1"

        func writeBatched(
            to url: URL,
            count: Int,
            line: (Int) -> String
        ) throws {
            guard FileManager.default.createFile(
                atPath: url.path, contents: nil) else {
                throw NSError(domain: "TagEvidenceScale", code: 1)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var batch = Data()
            batch.reserveCapacity(1024 * 1024)
            for index in 0..<count {
                batch.append(contentsOf: line(index).utf8)
                if batch.count >= 1024 * 1024 {
                    try handle.write(contentsOf: batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty { try handle.write(contentsOf: batch) }
            try handle.synchronize()
        }

        let burstURL = directory.appendingPathComponent(
            "tag_observation_bursts.jsonl")
        try writeBatched(to: burstURL, count: burstCount) { burstIndex in
            let first = burstIndex * framesPerBurst
            var frames = ""
            frames.reserveCapacity(framesPerBurst * 190)
            for offset in 0..<framesPerBurst {
                let index = first + offset
                if offset > 0 { frames.append(",") }
                frames += "{\"bound_node_id\":1,\"confidence\":0.9,"
                    + "\"depth\":0.95,\"frame_id\":\"frame-\(index)\","
                    + "\"frame_timestamp\":1000,"
                    + "\"node_timestamp\":1000,"
                    + "\"observation_id\":\"OBS-\(index)\","
                    + "\"tracking\":\"stable\",\"view\":\"front\"}"
            }
            let burstID = "BURST-\(burstIndex + 1)"
            return "{\"barcode\":\"6901234567890\","
                + "\"bound_node_id_max\":1,\"bound_node_id_min\":1,"
                + "\"burst_id\":\"\(burstID)\",\"complete\":true,"
                + "\"depth_quality\":0.95,\"first_frame_timestamp\":1000,"
                + "\"floor_id\":\"\(floorID)\",\"format\":"
                + "\"MarketScannerPriceTagBurst\",\"frame_count\":"
                + "\(framesPerBurst),\"frames\":[\(frames)],"
                + "\"last_frame_timestamp\":1000,"
                + "\"localization_confidence_mean\":0.9,"
                + "\"prior_map_id\":\"\(mapID)\","
                + "\"prior_map_sha256\":\"\(mapSHA)\","
                + "\"sequence\":\(burstIndex + 1),"
                + "\"symbology\":\"EAN13\","
                + "\"tracking_quality\":\"stable\","
                + "\"tracking_session_id\":\"\(sessionID)\","
                + "\"version\":2,\"view_angle\":\"front\"}\n"
        }

        let observationURL = directory.appendingPathComponent(
            "tag_observations.jsonl")
        try writeBatched(
            to: observationURL, count: observationCount
        ) { index in
            let burstID = "BURST-\(index / framesPerBurst + 1)"
            return "{\"alignment_age_ms\":2,"
                + "\"alignment_freshness\":\"fresh\","
                + "\"alignment_snapshot_timestamp\":999.998,"
                + "\"alignment_version\":3,\"alignment_version_lag\":0,"
                + "\"burst_id\":\"\(burstID)\","
                + "\"depth_inlier_count\":38,\"depth_inlier_ratio\":0.95,"
                + "\"depth_mad_m\":0.1,\"depth_median_m\":1.2,"
                + "\"depth_sample_count\":40,\"floor_id\":\"\(floorID)\","
                + "\"format\":\"MarketScannerPriceTagObservation\","
                + "\"frame_id\":\"frame-\(index)\","
                + "\"frame_timestamp\":1000,\"localization_confidence\":0.9,"
                + "\"localization_state\":\"stable\","
                + "\"measurement_confidence\":0.9,"
                + "\"measurement_method\":\"scene_depth\","
                + "\"needs_review\":false,"
                + "\"node_timebase_frame_timestamp\":1000,"
                + "\"node_timebase_offset_seconds\":0,"
                + "\"normalized_bounds\":[0.1,0.2,0.3,0.4],"
                + "\"observation_id\":\"OBS-\(index)\","
                + "\"payload\":\"6901234567890\",\"plane_residual_m\":0.02,"
                + "\"pose_timestamp_delta_ms\":2,"
                + "\"prior_map_id\":\"\(mapID)\","
                + "\"prior_map_sha256\":\"\(mapSHA)\","
                + "\"raw_map_position\":{\"height_m\":0,\"x_m\":5,\"y_m\":-0.1},"
                + "\"bound_node_id\":1,\"bound_node_map_id\":0,"
                + "\"bound_node_stamp\":1000,"
                + "\"coordinate_frame\":\"RTABMAP_BOUND_NODE_LOCAL\","
                + "\"measurement_height_m\":0,"
                + "\"point_in_bound_node_frame\":{\"x_m\":5,\"y_m\":-0.1,\"z_m\":0},"
                + "\"surface_normal_camera\":[0,0,-1],"
                + "\"symbology\":\"EAN13\",\"timestamp\":100,"
                + "\"tracking_session_id\":\"\(sessionID)\",\"version\":2}\n"
        }

        let nodes = [AbsolutePriorEvidenceNode(nodeID: 1, stamp: 1000)]
        require(
            TagObservationBurstEvidenceParser.recomputeSummary([]) == nil,
            "an empty burst summary must fail closed without terminating")
        let bursts = try TagObservationBurstEvidenceParser.parse(
            snapshotDirectory: directory,
            nodes: nodes,
            priorMapID: mapID,
            priorMapSHA256: mapSHA,
            trackingSessionID: sessionID,
            floorID: floorID,
            expectedBurstCount: burstCount,
            expectedLastBurstID: "BURST-\(burstCount)")
        require(
            bursts.clean && bursts.frameCount == observationCount,
            "200k burst evidence did not parse cleanly")
        let observations = try TagObservationEvidenceParser.parse(
            snapshotDirectory: directory,
            nodes: nodes,
            priorMapID: mapID,
            priorMapSHA256: mapSHA,
            trackingSessionID: sessionID,
            floorID: floorID,
            verifiedBursts: bursts)
        require(
            observations.clean
                && observations.observations.count == observationCount
                && observations.boundNodeIDs == [1]
                && bursts.remainingFrameCount == 0,
            "200k observation exact-consumption contract failed")
        require(
            bursts.releaseConsumedFrames(),
            "200k consumed burst index must be releasable before optimization")

        // Continue through the production resolver, shelf association,
        // evidence-weighted fusion and automatic tag quality gate. This
        // closes the previous gap where only clustering (not strict parsing
        // plus the downstream pipeline) was exercised at 200k.
        let finalNode = TagObservationResolver.FinalNodePose(
            id: 1,
            monotonicSeconds: 1000,
            pose: .identity,
            floorID: floorID,
            uncertaintyM: 0.1)
        let resolverIndex = TagObservationResolver.NodeIndex(
            finalNodes: [finalNode], rawNodeStamps: [1: 1000])
        let shelf = ShelfAssociationEngine.ShelfSegment(
            shelfSegmentID: "scale-shelf-segment",
            shelfCode: "SCALE-SHELF",
            floorID: floorID,
            startM: (0, 0), endM: (10, 0),
            axisM: (1, 0), frontNormalM: (0, -1),
            boundsMinM: (0, -0.5), boundsMaxM: (10, 0.5),
            polygonM: nil,
            orientationProvenance: "scale_fixture")
        let priorMap = MobileMapLibrary.MapEntry(
            priorMapID: mapID,
            name: "Scale Map",
            packageSHA256: mapSHA,
            packageDirectory: directory,
            floorCount: 1,
            elementCount: 1,
            compiledAtUTC: 0,
            compilerVersion: "scale-test",
            canonicalSourceSHA256: String(repeating: "b", count: 64))
        let finalized = try MobileProcessingPipeline.finalizeTags(
            observations: observations.observations,
            resolverIndex: resolverIndex,
            shelves: [shelf],
            shelfIndex: ShelfAssociationEngine.ShelfSpatialIndex(
                shelves: [shelf]),
            structures: [],
            sessionID: sessionID,
            storeID: "SCALE-STORE",
            priorMap: priorMap,
            floorID: floorID,
            graphQualityPassed: true,
            minimumAssociationMarginM: 0.5,
            sourceBursts: bursts.bursts)
        require(
            finalized.0.count == burstCount && finalized.1.isEmpty
                && finalized.0.allSatisfy { $0.qualityStatus == "ACCEPTED" },
            "200k full tag pipeline must retain exactly one accepted row per durable burst")
        var usage = rusage()
        require(getrusage(RUSAGE_SELF, &usage) == 0, "tag scale getrusage failed")
        let inputBytes = try regularFileBytes(in: directory)
        print("Tag evidence input records: \(observationCount * 2)")
        print("Tag evidence input bytes: \(inputBytes)")
        print("Tag evidence temporary disk bytes: \(inputBytes)")
        print("Tag evidence wall seconds: \(ProcessInfo.processInfo.systemUptime - scaleStartedAt)")
        print("Tag evidence CPU seconds: \(processCPUSeconds(usage))")
        print("Tag evidence accepted observations: \(observations.observations.count)")
        print("Tag evidence peak RSS bytes: \(usage.ru_maxrss)")
        exit(0)
    } catch {
        FileHandle.standardError.write(
            Data("200k tag evidence scale failed: \(error)\n".utf8))
        exit(24)
    }
}

let injectedFailure = NSError(
    domain: "MarketScannerFinalizationTests",
    code: 1,
    userInfo: [NSLocalizedDescriptionKey: "injected failure"])
let metadataURL = URL(fileURLWithPath: "/tmp/metadata.json")
let checkpointURL = URL(fileURLWithPath: "/tmp/live_checkpoint.json")
let metadataData = Data("{\"finalized\":true}".utf8)

let metadataFailureWriter = InjectedSidecarWriter()
metadataFailureWriter.storage[checkpointURL] = Data("checkpoint".utf8)
metadataFailureWriter.writeError = injectedFailure
var metadataFailureObserved = false
do {
    _ = try SidecarFinalizationCoordinator.commitMetadata(
        metadataData,
        metadataURL: metadataURL,
        finalized: true,
        checkpointURL: checkpointURL,
        writer: metadataFailureWriter)
}
catch {
    metadataFailureObserved = true
}
require(metadataFailureObserved, "metadata write failure must remain pre-commit")
require(
    !metadataFailureWriter.fileExists(at: metadataURL),
    "failed metadata must not become visible")
require(
    SidecarFinalizationCoordinator.disposition(
        saveSucceeded: true,
        expectedFinalizedMetadata: true,
        commitResult: nil,
        preCommitError: "injected",
        eligibilityError: nil) == .resumeRecording,
    "pre-commit metadata failure may resume recording")

let cleanupFailureWriter = InjectedSidecarWriter()
cleanupFailureWriter.storage[checkpointURL] = Data("checkpoint".utf8)
cleanupFailureWriter.removeError = injectedFailure
let cleanupFailure = try SidecarFinalizationCoordinator.commitMetadata(
    metadataData,
    metadataURL: metadataURL,
    finalized: true,
    checkpointURL: checkpointURL,
    writer: cleanupFailureWriter)
require(cleanupFailure.metadataCommitted, "metadata must be committed before cleanup")
require(
    cleanupFailure.phase == .finalizedNeedsCleanup,
    "cleanup failure must enter terminal needs-cleanup")
require(
    cleanupFailureWriter.fileExists(at: checkpointURL),
    "failed cleanup must preserve checkpoint")
require(
    SidecarFinalizationCoordinator.disposition(
        saveSucceeded: true,
        expectedFinalizedMetadata: true,
        commitResult: cleanupFailure,
        preCommitError: nil,
        eligibilityError: nil) == .terminalFinalizedNeedsCleanup,
    "post-commit cleanup failure must never resume recording")

let successfulWriter = InjectedSidecarWriter()
successfulWriter.storage[checkpointURL] = Data("checkpoint".utf8)
let committed = try SidecarFinalizationCoordinator.commitMetadata(
    metadataData,
    metadataURL: metadataURL,
    finalized: true,
    checkpointURL: checkpointURL,
    writer: successfulWriter)
require(committed.phase == .checkpointCleaned, "successful cleanup phase")
require(
    !successfulWriter.fileExists(at: checkpointURL),
    "successful commit must remove the old checkpoint")
require(
    SidecarFinalizationCoordinator.disposition(
        saveSucceeded: true,
        expectedFinalizedMetadata: true,
        commitResult: committed,
        preCommitError: nil,
        eligibilityError: nil) == .terminalFinalized,
    "successful finalized metadata must end recording")

let invalidEvidenceWriter = InjectedSidecarWriter()
invalidEvidenceWriter.storage[checkpointURL] = Data("checkpoint".utf8)
let invalidMetadataCommit = try SidecarFinalizationCoordinator.commitMetadata(
    Data("{\"finalized\":false}".utf8),
    metadataURL: metadataURL,
    finalized: false,
    checkpointURL: checkpointURL,
    writer: invalidEvidenceWriter)
require(
    SidecarFinalizationCoordinator.disposition(
        saveSucceeded: true,
        expectedFinalizedMetadata: false,
        commitResult: invalidMetadataCommit,
        preCommitError: nil,
        eligibilityError: "required evidence failed")
        == .terminalIneligibleEvidence,
    "saved ineligible evidence must stop as a recovery package, not resume")
require(
    invalidEvidenceWriter.fileExists(at: checkpointURL),
    "ineligible recovery package must retain its checkpoint")

let resumeEffects = ScanFinalizationEffectPlanner.effects(
    for: .resumeRecording)
require(
    resumeEffects.resumesCameraAndMapping && !resumeEffects.closesSession,
    "only pre-commit failure may resume camera and mapping")
let finalizedEffects = ScanFinalizationEffectPlanner.effects(
    for: .terminalFinalized)
require(
    finalizedEffects.closesSession
        && finalizedEffects.allowsExternalCopy
        && !finalizedEffects.preservesCheckpoint
        && finalizedEffects.processingEligible,
    "normal finalization must close, clean and allow verified copy")
let cleanupEffects = ScanFinalizationEffectPlanner.effects(
    for: .terminalFinalizedNeedsCleanup)
require(
    cleanupEffects.closesSession
        && !cleanupEffects.resumesCameraAndMapping
        && !cleanupEffects.allowsExternalCopy
        && cleanupEffects.preservesCheckpoint,
    "post-commit cleanup failure must stay closed and local")
let ineligibleEffects = ScanFinalizationEffectPlanner.effects(
    for: .terminalIneligibleEvidence)
require(
    ineligibleEffects.closesSession
        && !ineligibleEffects.resumesCameraAndMapping
        && ineligibleEffects.preservesCheckpoint
        && !ineligibleEffects.processingEligible,
    "ineligible recovery package must close and retain checkpoint")

let traceURL = URL(fileURLWithPath: "/tmp/localization_trace.jsonl")
let constraintURL = URL(fileURLWithPath: "/tmp/localization_constraints.jsonl")
let stateURL = URL(fileURLWithPath: "/tmp/localization_events.jsonl")
let traceRecord = EncodedLocalizationSidecarRecord(
    fileName: "localization_trace.jsonl",
    data: Data("trace\n".utf8),
    url: traceURL)
let constraintRecord = EncodedLocalizationSidecarRecord(
    fileName: "localization_constraints.jsonl",
    data: Data("constraint\n".utf8),
    url: constraintURL)
let stateRecord = EncodedLocalizationSidecarRecord(
    fileName: "localization_events.jsonl",
    data: Data("state\n".utf8),
    url: stateURL)
for failedURL in [traceURL, constraintURL, stateURL] {
    let partialWriter = InjectedSidecarWriter()
    partialWriter.appendErrors[failedURL] = injectedFailure
    let result = LocalizationEvidenceWriteCoordinator.write(
        trace: traceRecord,
        constraint: constraintRecord,
        state: stateRecord,
        writer: partialWriter)
    require(!result.succeeded, "each required sidecar failure must be visible")
    require(
        result.failedRequiredFiles.count == 1,
        "partial success must identify exactly the failed required file")
    if failedURL == stateURL {
        require(!result.stateWritten, "failed state event must not be durable")
    }
}
let noStateWriter = InjectedSidecarWriter()
let noStateResult = LocalizationEvidenceWriteCoordinator.write(
    trace: traceRecord,
    constraint: constraintRecord,
    state: nil,
    writer: noStateWriter)
require(noStateResult.succeeded, "unchanged state must not require a state event")
require(!noStateResult.stateWriteRequired, "state write requirement must be explicit")

let cleanupMetadata = Data(
    "{\"finalized\":true,\"trackingSessionId\":\"session-a\",\"finalizedAtUnix\":20}".utf8)
let olderCheckpoint = Data(
    "{\"trackingSessionId\":\"session-a\",\"updatedAtUnix\":10}".utf8)
try FinalizedCheckpointCleanupValidator.validate(
    metadataData: cleanupMetadata,
    checkpointData: olderCheckpoint)
var newerCheckpointRejected = false
do {
    try FinalizedCheckpointCleanupValidator.validate(
        metadataData: cleanupMetadata,
        checkpointData: Data(
            "{\"trackingSessionId\":\"session-a\",\"updatedAtUnix\":21}".utf8))
}
catch FinalizedCheckpointCleanupValidationError.checkpointNewerThanCommit {
    newerCheckpointRejected = true
}
require(newerCheckpointRejected, "newer checkpoint cleanup must fail closed")

let finalizationTemp = FileManager.default.temporaryDirectory.appendingPathComponent(
    "MarketScannerFinalization-\(UUID().uuidString)",
    isDirectory: true)
try FileManager.default.createDirectory(
    at: finalizationTemp,
    withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: finalizationTemp) }
let foundationWriter = FoundationScanSidecarWriter()
let appendURL = finalizationTemp.appendingPathComponent("events.jsonl")
try foundationWriter.writeAtomic(Data("first\n".utf8), to: appendURL)
try foundationWriter.append(Data("second\n".utf8), to: appendURL)
let appendedContents = try String(contentsOf: appendURL, encoding: .utf8)
require(
    appendedContents == "first\nsecond\n",
    "Foundation writer must append complete records")
for failedStage in [
    AtomicWriteStage.write,
    AtomicWriteStage.flush,
    AtomicWriteStage.rename,
] {
    let stagedURL = finalizationTemp.appendingPathComponent(
        "atomic-\(failedStage.rawValue).json")
    try Data("old".utf8).write(to: stagedURL)
    let failingWriter = FoundationScanSidecarWriter(
        atomicWriteFault: { stage, _ in
            if stage == failedStage { throw injectedFailure }
        })
    var failureObserved = false
    do {
        try failingWriter.writeAtomic(Data("new".utf8), to: stagedURL)
    }
    catch {
        failureObserved = true
    }
    require(failureObserved, "each atomic write stage must be injectable")
    let retainedBytes = try Data(contentsOf: stagedURL)
    require(
        retainedBytes == Data("old".utf8),
        "pre-rename write/flush/rename failures must preserve old bytes")
    let temporaryFiles = try FileManager.default.contentsOfDirectory(
        at: finalizationTemp,
        includingPropertiesForKeys: nil).filter {
            $0.lastPathComponent.contains("atomic-\(failedStage.rawValue).json.")
                && $0.pathExtension == "tmp"
        }
    require(temporaryFiles.isEmpty, "failed atomic writes must clean temp files")
}

let evidenceDirectory = finalizationTemp.appendingPathComponent(
    "evidence",
    isDirectory: true)
try FileManager.default.createDirectory(
    at: evidenceDirectory,
    withIntermediateDirectories: true)
func evidenceRecord(format: String, state: String? = nil) throws -> Data {
    var value: [String: Any] = [
        "format": format,
        "version": 1,
        "trackingSessionId": "session-a",
        "priorMapId": "map-a",
        "priorMapSha256": String(repeating: "a", count: 64),
        "floorId": "1",
    ]
    value["timestamp"] = 1.0
    value["nodeTimebaseTimestamp"] = 1.0
    value["nodeTimebaseOffsetSeconds"] = 0.0
    let pose: [String: Any] = ["x_m": 0.0, "y_m": 0.0, "yaw_rad": 0.0]
    switch format {
    case "MarketScannerLocalizationTrace":
        value["rawPose"] = pose
        value["estimatedPose"] = pose
        value["trackingState"] = "normal"
        value["localizationState"] = "stable"
        value["confidence"] = 1.0
    case "MarketScannerLocalizationConstraint":
        value["accepted"] = false
        value["predictedPose"] = pose
        value["uniqueness"] = 0.9
    case "MarketScannerLocalizationStateEvent":
        value["state"] = state ?? "stable"
        value["confidence"] = 1.0
    default:
        if let state { value["state"] = state }
    }
    var data = try JSONSerialization.data(withJSONObject: value)
    data.append(0x0A)
    return data
}
let evidenceExpectation = LocalizationEvidenceBundleExpectation(
    trackingSessionId: "session-a",
    priorMapId: "map-a",
    priorMapSha256: String(repeating: "a", count: 64),
    floorId: "1",
    traceRecordCount: 1,
    constraintRecordCount: 1,
    stateEventCount: 1,
    lastDurableState: "stable",
    localizedPriceTagCount: 0)
let traceEvidenceURL = evidenceDirectory.appendingPathComponent(
    "localization_trace.jsonl")
let constraintEvidenceURL = evidenceDirectory.appendingPathComponent(
    "localization_constraints.jsonl")
let stateEvidenceURL = evidenceDirectory.appendingPathComponent(
    "localization_events.jsonl")
try evidenceRecord(format: "MarketScannerLocalizationTrace")
    .write(to: traceEvidenceURL)
try evidenceRecord(format: "MarketScannerLocalizationConstraint")
    .write(to: constraintEvidenceURL)
try evidenceRecord(
    format: "MarketScannerLocalizationStateEvent",
    state: "stable").write(to: stateEvidenceURL)
try Data().write(to: evidenceDirectory.appendingPathComponent(
    "manual_localization_events.jsonl"))
try Data().write(to: evidenceDirectory.appendingPathComponent(
    "tag_observations.jsonl"))
try Data().write(to: evidenceDirectory.appendingPathComponent(
    "tag_observation_bursts.jsonl"))
try Data().write(to: evidenceDirectory.appendingPathComponent(
    "localization_recovery_events.jsonl"))
try Data("[]".utf8).write(to: evidenceDirectory.appendingPathComponent(
    "localized_price_tags.json"))
let initialEvidenceBlockers = LocalizationEvidenceBundleValidator.blockers(
    in: evidenceDirectory,
    expectation: evidenceExpectation)
require(
    initialEvidenceBlockers.isEmpty,
    "a complete persisted evidence bundle must validate: \(initialEvidenceBlockers)")

// J-07: manual evidence uses an exact raw-line watermark just like recovery.
let manualEvidenceURL = evidenceDirectory.appendingPathComponent(
    "manual_localization_events.jsonl")
var manualEvidenceData = try JSONSerialization.data(withJSONObject: [
    "format": "MarketScannerManualLocalizationEvent",
    "version": 3,
    "tracking_session_id": "session-a",
    "prior_map_id": "map-a",
    "prior_map_sha256": String(repeating: "a", count: 64),
    "floor_id": "1",
    "frame_timestamp": 1.0,
    "node_timebase_frame_timestamp": 1.0,
    "node_timebase_offset_seconds": 0.0,
])
manualEvidenceData.append(0x0A)
try manualEvidenceData.write(to: manualEvidenceURL)
let manualEvidenceExpectation = LocalizationEvidenceBundleExpectation(
    trackingSessionId: "session-a",
    priorMapId: "map-a",
    priorMapSha256: String(repeating: "a", count: 64),
    floorId: "1",
    traceRecordCount: 1,
    constraintRecordCount: 1,
    manualLocalizationEventCount: 1,
    stateEventCount: 1,
    lastDurableState: "stable",
    localizedPriceTagCount: 0)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: manualEvidenceExpectation).isEmpty,
    "a manual event with an exact count watermark must validate")
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("manual_localization_events.jsonl_count_mismatch")
        },
    "a manual event without its exact watermark must fail closed")
try Data().write(to: manualEvidenceURL)

// P7R6: recovery lifecycle records are reconciled against an exact
// expected-count watermark. A valid terminal record validates only when the
// expectation carries the matching watermark; an identity mismatch still
// fails closed.
let recoveryEvidenceURL = evidenceDirectory.appendingPathComponent(
    "localization_recovery_events.jsonl")
let recoveryLifecycleRecord: [String: Any] = [
    "format": "MarketScannerRecoveryLifecycleEvent",
    "version": 2,
    "tracking_session_id": "session-a",
    "prior_map_id": "map-a",
    "prior_map_sha256": String(repeating: "a", count: 64),
    "floor_id": "1",
    "episode_id": 1,
    "reason": "reliable_rtabmap_loop",
    "outcome": "cancelled",
    "cancellation_reason": "scan_stopped",
    "episode_automatic": false,
    "started_at_uptime": 10.0,
    "deadline_uptime": 70.0,
    "finished_at_uptime": 14.5,
    "elapsed_ms": 4500.0,
    "maximum_valid_attempts": 40,
    "valid_matcher_attempts": 7,
    "accepted_corrections": 2,
    "trigger_count": 1,
    "automatic_trigger_count": 0,
    "reliable_loop_trigger_count": 1,
    "last_trigger_reason": "reliable_rtabmap_loop",
    "last_trigger_at_uptime": 10.0,
    "trigger_records": [
        [
            "reason": "reliable_rtabmap_loop",
            "automatic": false,
            "at_uptime": 10.0,
        ],
    ],
    "fresh_support_frames": 4,
    "completion_frame_step_applied": false,
]
var recoveryLifecycleData = try JSONSerialization.data(
    withJSONObject: recoveryLifecycleRecord)
recoveryLifecycleData.append(0x0A)
try recoveryLifecycleData.write(to: recoveryEvidenceURL)
let recoveryExpectation = LocalizationEvidenceBundleExpectation(
    trackingSessionId: "session-a",
    priorMapId: "map-a",
    priorMapSha256: String(repeating: "a", count: 64),
    floorId: "1",
    traceRecordCount: 1,
    constraintRecordCount: 1,
    stateEventCount: 1,
    lastDurableState: "stable",
    localizedPriceTagCount: 0,
    recoveryEventCount: 1,
    lastRecoveryEpisodeId: 1,
    lastRecoveryFinishedAtUptime: 14.5)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: recoveryExpectation).isEmpty,
    "a valid recovery lifecycle record must validate")
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("localization_recovery_events.jsonl_count_mismatch")
        },
    "a recovery record without watermark expectation must fail closed")
let watermarkedMismatchExpectation = LocalizationEvidenceBundleExpectation(
    trackingSessionId: "session-a",
    priorMapId: "map-a",
    priorMapSha256: String(repeating: "a", count: 64),
    floorId: "1",
    traceRecordCount: 1,
    constraintRecordCount: 1,
    stateEventCount: 1,
    lastDurableState: "stable",
    localizedPriceTagCount: 0,
    recoveryEventCount: 1,
    lastRecoveryEpisodeId: 2,
    lastRecoveryFinishedAtUptime: 14.5)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: watermarkedMismatchExpectation).contains(
            "evidence_bundle_recovery_watermark_mismatch"),
    "a wrong recovery episode watermark must fail closed")
var corruptedRecoveryRecord = recoveryLifecycleRecord
corruptedRecoveryRecord["tracking_session_id"] = "session-other"
var corruptedRecoveryData = try JSONSerialization.data(
    withJSONObject: corruptedRecoveryRecord)
corruptedRecoveryData.append(0x0A)
try corruptedRecoveryData.write(to: recoveryEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: recoveryExpectation).contains(
            "evidence_bundle_localization_recovery_events.jsonl_identity_mismatch"),
    "a recovery lifecycle identity mismatch must fail closed")

// P7R6: the strict lifecycle schema rejects illegal evidence fail-closed,
// while legacy v1 records remain readable.
func recoverySchemaBlockers(mutating: (inout [String: Any]) -> Void) throws
    -> [String] {
    var record = recoveryLifecycleRecord
    mutating(&record)
    var data = try JSONSerialization.data(withJSONObject: record)
    data.append(0x0A)
    try data.write(to: recoveryEvidenceURL)
    return LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: recoveryExpectation)
}
func requireRecoveryRejected(
    _ mutating: (inout [String: Any]) -> Void,
    reason: String,
    _ message: String
) throws {
    let blockers = try recoverySchemaBlockers(mutating: mutating)
    require(
        blockers.contains(
            "evidence_bundle_localization_recovery_events.jsonl_\(reason)"),
        "\(message): \(blockers)")
}
try requireRecoveryRejected(
    { $0["outcome"] = "banana" },
    reason: "recovery_outcome_invalid",
    "an unknown outcome must fail closed")
try requireRecoveryRejected(
    {
        $0["outcome"] = "converged"
    },
    reason: "recovery_cancellation_reason_invalid",
    "a converged episode must not carry a cancellation reason")
try requireRecoveryRejected(
    { $0["cancellation_reason"] = NSNull() },
    reason: "recovery_cancellation_reason_invalid",
    "a cancelled episode must carry an explicit cancellation reason")
try requireRecoveryRejected(
    { $0["elapsed_ms"] = -999.0 },
    reason: "recovery_business_schema_invalid",
    "a negative elapsed time must fail closed")
try requireRecoveryRejected(
    { $0["valid_matcher_attempts"] = -4 },
    reason: "recovery_business_schema_invalid",
    "a negative attempts counter must fail closed")
try requireRecoveryRejected(
    { $0["accepted_corrections"] = 999999 },
    reason: "recovery_business_schema_invalid",
    "corrections above the attempts budget must fail closed")
try requireRecoveryRejected(
    { $0["trigger_count"] = -1 },
    reason: "recovery_business_schema_invalid",
    "a negative trigger count must fail closed")
try requireRecoveryRejected(
    { $0["automatic_trigger_count"] = 1 },
    reason: "recovery_business_schema_invalid",
    "trigger classification sums must reconcile")
try requireRecoveryRejected(
    { $0["reason"] = 42 },
    reason: "recovery_business_schema_invalid",
    "a non-string episode reason must fail closed without terminating")
try requireRecoveryRejected(
    { $0["last_trigger_reason"] = ["bad"] },
    reason: "recovery_business_schema_invalid",
    "a non-string trigger summary must fail closed without terminating")
try requireRecoveryRejected(
    { $0["trigger_records"] = [
        ["reason": false, "automatic": false, "at_uptime": 10.0],
    ] },
    reason: "recovery_trigger_records_invalid",
    "a non-string trigger record reason must fail closed without terminating")
try requireRecoveryRejected(
    { $0["injected_unknown_field"] = true },
    reason: "recovery_unknown_field",
    "unknown lifecycle fields must fail closed")
try requireRecoveryRejected(
    { $0["version"] = 3 },
    reason: "format_or_version_mismatch",
    "an unsupported lifecycle version must fail closed")
try requireRecoveryRejected(
    { $0["trigger_records"] = [] },
    reason: "recovery_trigger_records_invalid",
    "empty trigger records must fail closed for v2")
try requireRecoveryRejected(
    { $0["trigger_records"] = [
        ["reason": "other", "automatic": false, "at_uptime": 10.0],
    ] },
    reason: "recovery_trigger_records_invalid",
    "trigger records must reconcile with the trigger summary")
var legacyRecoveryRecord = recoveryLifecycleRecord
legacyRecoveryRecord["version"] = 1
legacyRecoveryRecord["deadline_uptime"] = nil
legacyRecoveryRecord["maximum_valid_attempts"] = nil
legacyRecoveryRecord["trigger_records"] = nil
var legacyRecoveryData = try JSONSerialization.data(
    withJSONObject: legacyRecoveryRecord)
legacyRecoveryData.append(0x0A)
try legacyRecoveryData.write(to: recoveryEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: recoveryExpectation).isEmpty,
    "a legacy v1 recovery lifecycle record must remain readable")
try recoveryLifecycleData.write(to: recoveryEvidenceURL)
try Data().write(to: recoveryEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: recoveryExpectation).contains {
            $0.contains("localization_recovery_events.jsonl_empty")
        },
    "an emptied recovery sidecar must not mask the watermark")

let localizedTagsURL = evidenceDirectory.appendingPathComponent(
    "localized_price_tags.json")
try Data(repeating: 0x20, count: 16 * 1024 * 1024 + 1).write(to: localizedTagsURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("localized_price_tags")
        },
    "the V1 production localized-tag memory budget must fail closed")
try Data("[]".utf8).write(to: localizedTagsURL)

let originalTrace = try Data(contentsOf: traceEvidenceURL)
try FileManager.default.removeItem(at: traceEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("localization_trace.jsonl")
        },
    "a deleted required trace must block finalization")
try originalTrace.write(to: traceEvidenceURL)
try Data("{\"format\":".utf8).write(to: constraintEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("localization_constraints.jsonl")
        },
    "a truncated required constraint must block finalization")
try evidenceRecord(format: "MarketScannerLocalizationConstraint")
    .write(to: constraintEvidenceURL)
try Data().write(to: stateEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("localization_events.jsonl")
        },
    "an empty required state file must block finalization")
try evidenceRecord(
    format: "MarketScannerLocalizationStateEvent",
    state: "stable").write(to: stateEvidenceURL)
var wrongIdentity = try JSONSerialization.jsonObject(
    with: originalTrace) as! [String: Any]
wrongIdentity["trackingSessionId"] = "other-session"
var wrongIdentityData = try JSONSerialization.data(withJSONObject: wrongIdentity)
wrongIdentityData.append(0x0A)
try wrongIdentityData.write(to: traceEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("identity_mismatch")
        },
    "identity mismatch must block finalization")
try originalTrace.write(to: traceEvidenceURL)
let linkedTrace = evidenceDirectory.appendingPathComponent("linked-trace")
try FileManager.default.moveItem(at: traceEvidenceURL, to: linkedTrace)
try FileManager.default.createSymbolicLink(
    at: traceEvidenceURL,
    withDestinationURL: linkedTrace)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("localization_trace.jsonl")
        },
    "a linked required sidecar must block finalization")
try FileManager.default.removeItem(at: traceEvidenceURL)
try FileManager.default.moveItem(at: linkedTrace, to: traceEvidenceURL)

try Data([0xFF, 0x0A]).write(to: traceEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("invalid_utf8_or_partial_line")
        },
    "invalid UTF-8 must block finalization")
try originalTrace.write(to: traceEvidenceURL)
var oversizedRecord = Data(repeating: 0x61, count: 1_000_001)
oversizedRecord.append(0x0A)
try oversizedRecord.write(to: traceEvidenceURL)
require(
    LocalizationEvidenceBundleValidator.blockers(
        in: evidenceDirectory,
        expectation: evidenceExpectation).contains {
            $0.contains("record_too_large")
        },
    "a record over 1 MB must block finalization")
try originalTrace.write(to: traceEvidenceURL)

let replacementDirectory = finalizationTemp.appendingPathComponent(
    "descriptor-replacement",
    isDirectory: true)
try FileManager.default.createDirectory(
    at: replacementDirectory,
    withIntermediateDirectories: true)
let replacementTarget = replacementDirectory.appendingPathComponent("target.jsonl")
let replacementCandidate = replacementDirectory.appendingPathComponent("new.jsonl")
try Data(repeating: 0x31, count: 128 * 1024).write(to: replacementTarget)
try Data("replacement\n".utf8).write(to: replacementCandidate)
var replacementRejected = false
var replaced = false
do {
    try SafeSessionPath.streamRegularFile(
        replacementTarget,
        within: finalizationTemp,
        maximumBytes: 1024 * 1024,
        chunkBytes: 4096
    ) { _ in
        if !replaced {
            replaced = true
            try FileManager.default.removeItem(at: replacementTarget)
            try FileManager.default.moveItem(
                at: replacementCandidate,
                to: replacementTarget)
        }
    }
}
catch {
    replacementRejected = true
}
require(replacementRejected, "a path inode replacement during streaming must fail closed")

let cleanupRoot = finalizationTemp.appendingPathComponent(
    "SupermarketSession-Cleanup",
    isDirectory: true)
let cleanupSegment = cleanupRoot.appendingPathComponent(
    "segment_0001",
    isDirectory: true)
try FileManager.default.createDirectory(
    at: cleanupSegment,
    withIntermediateDirectories: true)
try SafeSessionPath.validateDirectory(cleanupSegment, within: cleanupRoot)
require(
    !SafeSessionPath.isStrictlyContained(
        finalizationTemp.appendingPathComponent("SupermarketSession-Cleanup-Other"),
        in: cleanupRoot),
    "path-component containment must reject adjacent prefixes")
let safeCheckpointURL = cleanupSegment.appendingPathComponent(
    "live_checkpoint.json")
try olderCheckpoint.write(to: safeCheckpointURL)
let safeCheckpoint = try SafeSessionPath.readRegularFile(
    safeCheckpointURL,
    within: cleanupRoot)
try SafeSessionPath.append(
    Data("audit\n".utf8),
    to: cleanupSegment.appendingPathComponent("scan_events.jsonl"),
    within: cleanupRoot)
let outsideCheckpoint = finalizationTemp.appendingPathComponent(
    "outside-checkpoint.json")
try olderCheckpoint.write(to: outsideCheckpoint)
try FileManager.default.removeItem(at: safeCheckpointURL)
try FileManager.default.createSymbolicLink(
    at: safeCheckpointURL,
    withDestinationURL: outsideCheckpoint)
var linkedCheckpointRejected = false
do {
    _ = try SafeSessionPath.readRegularFile(
        safeCheckpointURL,
        within: cleanupRoot)
}
catch {
    linkedCheckpointRejected = true
}
require(linkedCheckpointRejected, "checkpoint no-follow must reject symlinks")
try FileManager.default.removeItem(at: safeCheckpointURL)
try safeCheckpoint.data.write(to: safeCheckpointURL)
let restoredCheckpoint = try SafeSessionPath.readRegularFile(
    safeCheckpointURL,
    within: cleanupRoot)
try SafeSessionPath.removeRegularFile(
    safeCheckpointURL,
    within: cleanupRoot,
    expected: restoredCheckpoint)
require(
    !FileManager.default.fileExists(atPath: safeCheckpointURL.path),
    "descriptor-validated checkpoint removal must delete the expected file")

let captureSource = finalizationTemp.appendingPathComponent(
    "capture-source",
    isDirectory: true)
let captureCopy = finalizationTemp.appendingPathComponent(
    "capture-copy",
    isDirectory: true)
try FileManager.default.createDirectory(
    at: captureSource,
    withIntermediateDirectories: true)
try Data("database-a".utf8).write(
    to: captureSource.appendingPathComponent("rtabmap_segment_0001.db"))
try Data("metadata-a".utf8).write(
    to: captureSource.appendingPathComponent("metadata.json"))
let sourceManifestBefore = try CaptureDirectoryIntegrity.manifest(for: captureSource)
try FileManager.default.copyItem(at: captureSource, to: captureCopy)
let copiedManifest = try CaptureDirectoryIntegrity.manifest(for: captureCopy)
require(
    sourceManifestBefore == copiedManifest,
    "per-file SHA-256 manifests must verify an unchanged capture copy")
try Data("database-b".utf8).write(
    to: captureSource.appendingPathComponent("rtabmap_segment_0001.db"))
let sourceManifestAfter = try CaptureDirectoryIntegrity.manifest(for: captureSource)
require(
    sourceManifestBefore != sourceManifestAfter,
    "same-size source mutation must be detected by per-file SHA-256")

require(PriorMapScanConfiguration.freeMapping.isReadyToStart, "free mapping must remain startable")
require(
    PriorMapScanConfiguration(
        formatVersion: 1,
        workflowMode: .priorMapLocalized,
        packageDirectory: nil,
        priorMapId: nil,
        priorMapSha256: nil,
        floorId: nil,
        storeID: nil,
        initialMapPose: nil
    ).isReadyToStart == false,
    "incomplete prior-map setup must not start")

let ready = PriorMapScanConfiguration(
    formatVersion: 1,
    workflowMode: .priorMapLocalized,
    packageDirectory: URL(fileURLWithPath: "/tmp/PriorMap-fixture"),
    priorMapId: "fixture",
    priorMapSha256: String(repeating: "a", count: 64),
    floorId: "1",
    storeID: "STORE-1",
    initialMapPose: PriorMapPose2D(xM: 2, yM: 3, yawRad: .pi / 2))
require(ready.isReadyToStart, "complete prior-map setup must start")

let northFacing = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: 0,
    forwardX: 0,
    forwardZ: -1)
require(close(northFacing.xM, 0), "north-facing map x")
require(close(northFacing.yM, 0), "north-facing map y")
require(
    close(northFacing.yawRad, .pi / 2),
    "ARKit -z forward must be canonical map north (+pi/2)")

let forward = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: -1,
    forwardX: 0,
    forwardZ: -1)
require(close(forward.xM, 0), "forward x")
require(close(forward.yM, 1), "ARKit -z forward must be map +y")

let backward = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: 1,
    forwardX: 0,
    forwardZ: 1)
require(close(backward.yM, -1), "ARKit +z backward must be map -y")
require(
    close(backward.yawRad, -.pi / 2),
    "ARKit +z forward must be canonical map south (-pi/2)")

let right = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 1,
    positionZ: 0,
    forwardX: 1,
    forwardZ: 0)
require(close(right.xM, 1), "ARKit +x must be map +x")
require(close(right.yawRad, 0), "ARKit +x forward must be canonical map east")

let leftTurn = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: 0,
    forwardX: -1,
    forwardZ: 0)
require(
    close(abs(leftTurn.yawRad), .pi),
    "ARKit -x forward must be canonical map west")

let rightTurn = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: 0,
    forwardX: 1,
    forwardZ: 0)
require(close(rightTurn.yawRad, 0), "ARKit +x forward must be canonical map east")

// The first ARKit frame is the alignment origin. Walking straight ahead
// after choosing a cardinal start heading must advance in that exact map
// direction, not in a frame shifted by 90 degrees.
let arkitOrigin = PriorMapPose2D(xM: 0, yM: 0, yawRad: .pi / 2)
let arkitOneMetreForward = PriorMapPose2D(xM: 0, yM: 1, yawRad: .pi / 2)
let cardinalStarts: [(Double, Double, Double, String)] = [
    (0, 1, 0, "east"),
    (.pi / 2, 0, 1, "north"),
    (.pi, -1, 0, "west"),
    (-.pi / 2, 0, -1, "south"),
]
for (startYaw, expectedDX, expectedDY, name) in cardinalStarts {
    let start = PriorMapPose2D(xM: 10, yM: 20, yawRad: startYaw)
    let first = PriorMapStageOneMath.project(
        arkitPose: arkitOrigin,
        arkitOrigin: arkitOrigin,
        initialMapPose: start)
    require(close(first.yawRad, startYaw), "\(name) first-frame yaw")
    let advanced = PriorMapStageOneMath.project(
        arkitPose: arkitOneMetreForward,
        arkitOrigin: arkitOrigin,
        initialMapPose: start)
    require(close(advanced.xM, start.xM + expectedDX), "\(name) forward x")
    require(close(advanced.yM, start.yM + expectedDY), "\(name) forward y")
    require(close(advanced.yawRad, startYaw), "\(name) forward yaw")
}

let projected = PriorMapStageOneMath.project(
    arkitPose: PriorMapPose2D(xM: 11, yM: 20, yawRad: 0),
    arkitOrigin: PriorMapPose2D(xM: 10, yM: 20, yawRad: 0),
    initialMapPose: PriorMapPose2D(xM: 2, yM: 3, yawRad: .pi / 2))
require(close(projected.xM, 2), "rotated map x")
require(close(projected.yM, 4), "rotated map y")
require(close(projected.yawRad, .pi / 2), "map yaw")

let nonzeroOrigin = PriorMapStageOneMath.project(
    arkitPose: PriorMapPose2D(xM: 3, yM: 6, yawRad: .pi / 2),
    arkitOrigin: PriorMapPose2D(xM: 3, yM: 5, yawRad: .pi / 2),
    initialMapPose: PriorMapPose2D(xM: 10, yM: 20, yawRad: -.pi / 2))
require(close(nonzeroOrigin.xM, 10), "nonzero origin x")
require(close(nonzeroOrigin.yM, 19), "nonzero origin y")
require(close(nonzeroOrigin.yawRad, -.pi / 2), "nonzero origin yaw")

require(
    close(PriorMapStageOneMath.normalizeAngle(3 * .pi), .pi),
    "angle normalization")

let updateGate = PriorMapUpdateGate(minimumInterval: 0.5)
guard case .accepted(let firstTicket) = updateGate.begin(timestamp: 10.0) else {
    require(false, "first update must be accepted")
    exit(1)
}
require(
    updateGate.begin(timestamp: 10.1) == .throttled,
    "updates inside the interval must be throttled")
require(
    updateGate.begin(timestamp: 10.6) == .busy(droppedCount: 1),
    "a new update must be dropped while one is in flight")
updateGate.reset()
guard case .accepted(let secondTicket) = updateGate.begin(timestamp: 1.0) else {
    require(false, "reset must accept a new generation")
    exit(1)
}
updateGate.finish(ticket: firstTicket)
require(
    updateGate.begin(timestamp: 2.0) == .busy(droppedCount: 1),
    "a stale completion must not release a newer update")
updateGate.finish(ticket: secondTicket)
guard case .accepted = updateGate.begin(timestamp: 2.0) else {
    require(false, "the active ticket completion must release the gate")
    exit(1)
}

let confidenceManager = PriorMapConfidenceManager()
confidenceManager.reset()
let initializing = confidenceManager.update(
    timestamp: 1,
    observation: PriorMapConfidenceObservation(
        trackingState: "normal",
        measurementAccepted: false,
        correctionStepApplied: false,
        recoveryActive: false,
        recoveryConvergedThisUpdate: false,
        recoveryFailedThisUpdate: false,
        validPointCount: 0,
        coverageAngleRad: 0,
        uniqueness: 0,
        residualCost: 0.15,
        mapMismatch: false))
require(initializing.phase == .initializing, "first unmatched frame must stay initializing")
confidenceManager.reset()
for timestamp in 1...3 {
    _ = confidenceManager.update(
        timestamp: Double(timestamp),
        observation: PriorMapConfidenceObservation(
            trackingState: "normal",
            measurementAccepted: true,
            correctionStepApplied: true,
            recoveryActive: false,
            recoveryConvergedThisUpdate: false,
            recoveryFailedThisUpdate: false,
            validPointCount: 100,
            coverageAngleRad: 1.2,
            uniqueness: 0.3,
            residualCost: 0.02,
            mapMismatch: false))
}
require(confidenceManager.phase == .stable, "three trusted observations must enter stable")
let weak = confidenceManager.update(
    timestamp: 4,
    observation: PriorMapConfidenceObservation(
        trackingState: "limited",
        measurementAccepted: false,
        correctionStepApplied: false,
        recoveryActive: false,
        recoveryConvergedThisUpdate: false,
        recoveryFailedThisUpdate: false,
        validPointCount: 40,
        coverageAngleRad: 0.2,
        uniqueness: 0,
        residualCost: 0.15,
        mapMismatch: false))
require(weak.phase == .weak, "limited tracking must degrade to weak")

func requirePoseClose(
    _ actual: PriorMapPose2D,
    _ expected: PriorMapPose2D,
    _ message: String
) {
    require(close(actual.xM, expected.xM), "\(message) x")
    require(close(actual.yM, expected.yM), "\(message) y")
    require(
        close(
            PriorMapStageOneMath.normalizeAngle(actual.yawRad - expected.yawRad),
            0),
        "\(message) yaw")
}

func requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D,
    expectedMapFromArkit: PriorMapAlignmentTransform,
    _ message: String
) {
    let candidate = PriorMapAlignmentMath.apply(
        mapFromArkit: expectedMapFromArkit,
        arkitPose: arkitPose)
    let derived = PriorMapAlignmentMath.mapFromArkit(
        arkitPose: arkitPose,
        candidateMapPose: candidate)
    let reconstructed = PriorMapAlignmentMath.apply(
        mapFromArkit: derived,
        arkitPose: arkitPose)
    requirePoseClose(reconstructed, candidate, message)
    require(close(derived.translationXM, expectedMapFromArkit.translationXM), "\(message) tx")
    require(close(derived.translationYM, expectedMapFromArkit.translationYM), "\(message) ty")
    require(
        close(
            PriorMapStageOneMath.normalizeAngle(
                derived.yawRad - expectedMapFromArkit.yawRad),
            0),
        "\(message) alignment yaw")
}

// P7R2 T1-T6: exact SE(2) reconstruction across identity, translation,
// quarter-turn, combined motion, half-turn and the +/-pi wrap boundary.
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: 0, yM: 0, yawRad: 0),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: 0, translationYM: 0, yawRad: 0),
    "T1 identity")
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: 2, yM: -3, yawRad: 0),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: 4, translationYM: 1, yawRad: 0),
    "T2 translation at zero yaw")
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: 2, yM: -3, yawRad: .pi / 2),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: 4, translationYM: 1, yawRad: 0),
    "T2 translation at ninety degrees")
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: 3, yM: 2, yawRad: 0),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: 8, translationYM: -2, yawRad: .pi / 2),
    "T3 zero to ninety degree alignment")
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: -2.5, yM: 7.25, yawRad: -.pi / 3),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: 12.5, translationYM: -8.75, yawRad: .pi / 4),
    "T4 turn and translation")
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: 5, yM: 9, yawRad: .pi),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: -4, translationYM: 6, yawRad: .pi),
    "T5 one hundred eighty degrees")
requireAlignmentReconstruction(
    arkitPose: PriorMapPose2D(xM: 1, yM: 1, yawRad: .pi - 1.0e-10),
    expectedMapFromArkit: PriorMapAlignmentTransform(
        translationXM: 2, translationYM: 3, yawRad: -.pi + 2.0e-10),
    "T6 angle wrap")

let fixedAlignment = PriorMapAlignmentTransform(
    translationXM: 2.4,
    translationYM: -1.3,
    yawRad: 18.0 * .pi / 180.0)
let wrongAisleAlignment = PriorMapAlignmentTransform(
    translationXM: 2.4,
    translationYM: 1.7,
    yawRad: 18.0 * .pi / 180.0)
let hypothesisTracker = PriorMapHypothesisTracker()
func productionMatcherScore(_ cost: Double) -> Double {
    exp(-cost / 0.08)
}
var trackedDecision: PriorMapHypothesisDecision?
let serpentineArkitPoses = [
    PriorMapPose2D(xM: 0, yM: 0, yawRad: 0),
    PriorMapPose2D(xM: 1, yM: 0, yawRad: 0),
    PriorMapPose2D(xM: 2, yM: 0.5, yawRad: .pi / 4),
    PriorMapPose2D(xM: 2, yM: 1.5, yawRad: .pi / 2),
    PriorMapPose2D(xM: 1.5, yM: 2.5, yawRad: 3 * .pi / 4),
]
for (frame, arkitPose) in serpentineArkitPoses.enumerated() {
    let correct = PriorMapAlignmentMath.apply(
        mapFromArkit: fixedAlignment,
        arkitPose: arkitPose)
    let wrong = PriorMapAlignmentMath.apply(
        mapFromArkit: wrongAisleAlignment,
        arkitPose: arkitPose)
    // T8: during the turn, a fresh wrong aisle may have the higher frame
    // score, but it must not steal the established global-alignment track.
    let wrongCost = frame == 2 ? 0.005 : 0.055
    let correctCost = 0.02
    trackedDecision = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [
            PriorMapScanMatchCandidate(
                pose: wrong,
                cost: wrongCost,
                score: productionMatcherScore(wrongCost)),
            PriorMapScanMatchCandidate(
                pose: correct,
                cost: correctCost,
                score: productionMatcherScore(correctCost)),
        ],
        uniqueness: 0.25,
        recoverySearch: false)
}
guard let serpentineDecision = trackedDecision,
      let trackedAlignment = serpentineDecision.mapFromArkit else {
    require(false, "S1 must retain a global-alignment hypothesis")
    exit(1)
}
require(serpentineDecision.trusted, "S1 serpentine alignment must become trusted")
require(serpentineDecision.supportFrames == serpentineArkitPoses.count,
        "S1 turns must not split the correct track")
require(close(trackedAlignment.translationXM, fixedAlignment.translationXM),
        "T8 wrong high-score aisle must not replace tx")
require(close(trackedAlignment.translationYM, fixedAlignment.translationYM),
        "T8 wrong high-score aisle must not replace ty")

// S4: short dynamic occlusion produces no candidates; the bounded tracker may
// retain history but cannot authorize a correction until evidence returns.
let occludedOne = hypothesisTracker.observe(
    arkitPose: serpentineArkitPoses.last!,
    candidates: [], uniqueness: 0, recoverySearch: false)
let occludedTwo = hypothesisTracker.observe(
    arkitPose: serpentineArkitPoses.last!,
    candidates: [], uniqueness: 0, recoverySearch: false)
require(!occludedOne.trusted && !occludedTwo.trusted,
        "S4 occlusion must fail closed")
let returnedPose = PriorMapPose2D(xM: 1, yM: 3, yawRad: .pi)
let returnedCandidate = PriorMapAlignmentMath.apply(
    mapFromArkit: fixedAlignment,
    arkitPose: returnedPose)
let afterOcclusion = hypothesisTracker.observe(
    arkitPose: returnedPose,
    candidates: [PriorMapScanMatchCandidate(
        pose: returnedCandidate,
        cost: 0.02,
        score: productionMatcherScore(0.02))],
    uniqueness: 0.3,
    recoverySearch: false)
require(afterOcclusion.trusted, "S4 stable evidence may resume the retained track")

// T9: equal parallel hypotheses remain ambiguous regardless of support.
hypothesisTracker.reset()
var ambiguousDecision: PriorMapHypothesisDecision?
let parallelA = PriorMapAlignmentTransform(
    translationXM: 0.3, translationYM: -0.6, yawRad: 0)
let parallelB = PriorMapAlignmentTransform(
    translationXM: 0.3, translationYM: 0.6, yawRad: 0)
for frame in 0..<4 {
    let arkitPose = PriorMapPose2D(xM: Double(frame), yM: 0, yawRad: 0)
    ambiguousDecision = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [parallelA, parallelB].map {
            PriorMapScanMatchCandidate(
                pose: PriorMapAlignmentMath.apply(
                    mapFromArkit: $0, arkitPose: arkitPose),
                cost: 0.02,
                score: productionMatcherScore(0.02))
        },
        uniqueness: 0,
        recoverySearch: false)
}
require(ambiguousDecision?.trusted == false,
        "T9 equal parallel aisles must never silently switch")
require(ambiguousDecision?.activeTrackCount == 2,
        "T9 both ambiguous tracks must remain visible in diagnostics")

// T10/S2: unique recovery needs four frames; 5 m/30 degrees is inclusive,
// while either 5.01 m or 30.1 degrees is rejected by the safety contract.
hypothesisTracker.reset()
hypothesisTracker.beginRecoveryEpisode(id: 1)
let recoveryAlignment = PriorMapAlignmentTransform(
    translationXM: 4.8,
    translationYM: 0,
    yawRad: 29.0 * .pi / 180.0)
var recoveryDecision: PriorMapHypothesisDecision?
for frame in 0..<4 {
    let arkitPose = PriorMapPose2D(xM: Double(frame), yM: 0, yawRad: 0)
    recoveryDecision = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [PriorMapScanMatchCandidate(
            pose: PriorMapAlignmentMath.apply(
                mapFromArkit: recoveryAlignment, arkitPose: arkitPose),
            cost: 0.02,
            score: productionMatcherScore(0.02))],
        uniqueness: 0.8,
        recoverySearch: true)
}
require(recoveryDecision?.trusted == true && recoveryDecision?.supportFrames == 4,
        "S2 unique recovery must require and pass four consistent frames")
hypothesisTracker.endRecoveryEpisode(id: 1, outcome: .converged)
let safetyOrigin = PriorMapPose2D(xM: 0, yM: 0, yawRad: 0)
require(PriorMapCorrectionSafety.isWithinGate(
    current: safetyOrigin,
    target: PriorMapPose2D(xM: 5, yM: 0, yawRad: 30 * .pi / 180),
    recoverySearch: true), "T10 inclusive recovery boundary")
require(!PriorMapCorrectionSafety.isWithinGate(
    current: safetyOrigin,
    target: PriorMapPose2D(xM: 5.01, yM: 0, yawRad: 0),
    recoverySearch: true), "T10 reject 5.01 m")
require(!PriorMapCorrectionSafety.isWithinGate(
    current: safetyOrigin,
    target: PriorMapPose2D(xM: 5, yM: 0, yawRad: 30.1 * .pi / 180),
    recoverySearch: true), "T10 reject 30.1 degrees")
let boundedRecoveryStep = PriorMapCorrectionSafety.boundedStep(
    current: safetyOrigin,
    target: PriorMapPose2D(xM: 4.8, yM: 0, yawRad: 29 * .pi / 180))
require(close(boundedRecoveryStep.xM, 0.35), "S2 recovery step translation cap")
require(close(boundedRecoveryStep.yawRad, 8 * .pi / 180),
        "S2 recovery step yaw cap")

// Reset (the same operation used by manual confirmation) clears track history.
hypothesisTracker.reset()
let postReset = hypothesisTracker.observe(
    arkitPose: safetyOrigin,
    candidates: [PriorMapScanMatchCandidate(
        pose: PriorMapPose2D(xM: 0.2, yM: 0, yawRad: 0),
        cost: 0.02,
        score: productionMatcherScore(0.02))],
    uniqueness: 0.5,
    recoverySearch: false)
require(!postReset.trusted && postReset.supportFrames == 1,
        "manual reset must require fresh temporal support")

// P7R3 R1: lifetime local support remains dormant at episode start, while the
// same alignment must still earn four new observations before Recovery trusts
// it. This lets a reliable loop reactivate an old shelf hypothesis without
// turning old support into authority.
let staleAlignment = PriorMapAlignmentTransform(
    translationXM: 1.5, translationYM: -2.0, yawRad: 0.1)
hypothesisTracker.reset()
for frame in 0..<100 {
    let arkitPose = PriorMapPose2D(xM: Double(frame) * 0.05, yM: 0, yawRad: 0)
    let candidate = PriorMapAlignmentMath.apply(
        mapFromArkit: staleAlignment, arkitPose: arkitPose)
    _ = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [PriorMapScanMatchCandidate(
            pose: candidate,
            cost: 0.02,
            score: productionMatcherScore(0.02))],
        uniqueness: 0.5,
        recoverySearch: false)
}
hypothesisTracker.beginRecoveryEpisode(id: 41)
var freshRecoveryDecision: PriorMapHypothesisDecision?
for frame in 1...4 {
    let arkitPose = PriorMapPose2D(xM: Double(frame), yM: 0, yawRad: 0)
    let candidate = PriorMapAlignmentMath.apply(
        mapFromArkit: staleAlignment, arkitPose: arkitPose)
    freshRecoveryDecision = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [PriorMapScanMatchCandidate(
            pose: candidate,
            cost: 0.02,
            score: productionMatcherScore(0.02))],
        uniqueness: 0.5,
        recoverySearch: true)
    require(
        freshRecoveryDecision?.trusted == (frame == 4),
        "R1 Recovery trust must use exactly four fresh episode observations")
    require(
        freshRecoveryDecision?.supportFrames == frame,
        "R1 historical local support must not enter Recovery diagnostics")
}

// P7R3 R2: after local A has saturated support, a new episode ranks only its
// fresh evidence. Better B wins on the fourth Recovery observation.
hypothesisTracker.endRecoveryEpisode(id: 41, outcome: .cancelled)
let wrongHistoricalAlignment = PriorMapAlignmentTransform(
    translationXM: 0, translationYM: 3, yawRad: 0)
let correctRecoveryAlignment = PriorMapAlignmentTransform(
    translationXM: 0.2, translationYM: 0.1, yawRad: 0)
for frame in 0..<100 {
    let arkitPose = PriorMapPose2D(xM: Double(frame) * 0.02, yM: 0, yawRad: 0)
    let candidate = PriorMapAlignmentMath.apply(
        mapFromArkit: wrongHistoricalAlignment, arkitPose: arkitPose)
    _ = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [PriorMapScanMatchCandidate(
            pose: candidate,
            cost: 0.04,
            score: productionMatcherScore(0.04))],
        uniqueness: 0.4,
        recoverySearch: false)
}
hypothesisTracker.beginRecoveryEpisode(id: 42)
var replacementDecision: PriorMapHypothesisDecision?
for frame in 0..<4 {
    let arkitPose = PriorMapPose2D(xM: Double(frame), yM: 0, yawRad: 0)
    replacementDecision = hypothesisTracker.observe(
        arkitPose: arkitPose,
        candidates: [
            PriorMapScanMatchCandidate(
                pose: PriorMapAlignmentMath.apply(
                    mapFromArkit: wrongHistoricalAlignment,
                    arkitPose: arkitPose),
                cost: 0.05,
                score: productionMatcherScore(0.05)),
            PriorMapScanMatchCandidate(
                pose: PriorMapAlignmentMath.apply(
                    mapFromArkit: correctRecoveryAlignment,
                    arkitPose: arkitPose),
                cost: 0.01,
                score: productionMatcherScore(0.01)),
        ],
        uniqueness: 0.5,
        recoverySearch: true)
}
require(replacementDecision?.trusted == true,
        "R2 the replacement hypothesis must become trusted on fresh frame four")
requirePoseClose(
    replacementDecision!.candidate!.pose,
    PriorMapAlignmentMath.apply(
        mapFromArkit: correctRecoveryAlignment,
        arkitPose: PriorMapPose2D(xM: 3, yM: 0, yawRad: 0)),
    "R2 stale historical A must not suppress better Recovery B")

// P7R3 R3-R5: only real matcher searches consume the bounded attempt budget,
// and a repeated trigger preserves identity, deadline, attempts, and support.
let recoveryController = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
require(recoveryController.request(reason: "loop", now: 100),
        "R3 first request must start an episode")
let initialRecoveryEpisode = recoveryController.activeEpisode!
let invalidRecoveryDispositions: [PriorMapRecoveryFrameDisposition] = [
    .trackingLimited,
    .noDepth,
    .observationUnavailable,
    .insufficientPoints,
    .busy,
    .throttled,
]
for frame in 0..<20 {
    require(
        !recoveryController.recordFrameDisposition(
            invalidRecoveryDispositions[
                frame % invalidRecoveryDispositions.count]),
        "R3 invalid/dropped frames must not be recorded as searches")
}
require(recoveryController.activeEpisode?.validMatcherAttempts == 0,
        "R3 invalid frames must not consume attempts")
recoveryController.recordValidMatcherAttempt()
recoveryController.recordValidMatcherAttempt()
require(!recoveryController.request(reason: "another_loop", now: 110),
        "R5 repeated request must not create an episode")
require(recoveryController.activeEpisode?.id == initialRecoveryEpisode.id,
        "R5 repeated request must preserve episode ID")
require(recoveryController.activeEpisode?.deadlineUptime
        == initialRecoveryEpisode.deadlineUptime,
        "R5 repeated request must not extend the deadline")
require(recoveryController.activeEpisode?.validMatcherAttempts == 2,
        "R4/R5 valid attempt progress must survive a repeated trigger")
require(recoveryController.activeEpisode?.triggerCount == 2,
        "R5 repeated trigger must be bounded diagnostic evidence")

// P7R3 R6/R7/R10: a timed-out wide-search track remains a bounded dormant
// candidate, but local mode must still require three fresh frames before it
// can authorize another correction.
hypothesisTracker.endRecoveryEpisode(id: 42, outcome: .timedOut)
let localAfterTimeout = hypothesisTracker.observe(
    arkitPose: safetyOrigin,
    candidates: [PriorMapScanMatchCandidate(
        pose: PriorMapAlignmentMath.apply(
            mapFromArkit: correctRecoveryAlignment,
            arkitPose: safetyOrigin),
        cost: 0.01,
        score: productionMatcherScore(0.01))],
    uniqueness: 0.5,
    recoverySearch: false)
require(!localAfterTimeout.trusted && localAfterTimeout.supportFrames == 1,
        "R6 local mode must require fresh support after a timed-out recovery")
_ = recoveryController.finish(.manualReset, now: 112)
require(recoveryController.activeEpisode == nil,
        "R10 manual reset must terminate the active episode")

// P7R3 R8: the inclusive 5 m/30 degree boundary converges within the 40 valid
// attempt budget, while inserted nil-observation frames consume nothing.
let worstPathController = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
_ = worstPathController.request(reason: "worst_path", now: 200)
var boundedPose = PriorMapPose2D(xM: 0, yM: 0, yawRad: 0)
let worstTarget = PriorMapPose2D(
    xM: 5, yM: 0, yawRad: 30 * .pi / 180)
var maximumStepTranslation = 0.0
var maximumStepYaw = 0.0
for validAttempt in 1...40 {
    if validAttempt % 3 == 0 {
        require(
            !worstPathController.recordFrameDisposition(
                .observationUnavailable),
            "R8 an intervening nil observation must not consume an attempt")
    }
    worstPathController.recordFrameDisposition(.searched)
    if validAttempt >= 4 {
        let next = PriorMapCorrectionSafety.boundedStep(
            current: boundedPose, target: worstTarget)
        let step = PriorMapCorrectionSafety.difference(
            from: boundedPose, to: next)
        maximumStepTranslation = max(maximumStepTranslation, step.translationM)
        maximumStepYaw = max(maximumStepYaw, step.yawRad)
        boundedPose = next
        let residual = PriorMapCorrectionSafety.difference(
            from: boundedPose, to: worstTarget)
        if residual.translationM <= 0.5,
           residual.yawRad <= 10 * .pi / 180 {
            worstPathController.recordAcceptedCorrection()
            _ = worstPathController.finish(.converged, now: 220)
            break
        }
    }
}
require(worstPathController.lastCompletion?.outcome == .converged,
        "R8 worst-path Recovery must converge within the valid-attempt budget")
require((worstPathController.lastCompletion?.episode.validMatcherAttempts ?? 41) <= 40,
        "R8 convergence must remain inside the configured budget")
require(maximumStepTranslation <= 0.35 + 1.0e-9,
        "R8 no Recovery translation step may exceed 0.35 m")
require(maximumStepYaw <= 8 * .pi / 180 + 1.0e-9,
        "R8 no Recovery yaw step may exceed 8 degrees")

// P7R4 T1/T2: accepting a 5 m Recovery hypothesis applies only a bounded,
// provisional step. It cannot become confidence-bearing or formally accepted.
let intermediateRecovery = PriorMapRecoveryDecisionEngine.evaluate(
    PriorMapRecoveryDecisionInput(
        recoveryActive: true,
        hypothesisTrusted: true,
        geometryAndSafetyAccepted: true,
        residualTranslationM: 5,
        residualYawRad: 30 * .pi / 180,
        wallClockExpired: false))
require(intermediateRecovery.measurementAccepted,
        "P7R4 T1 trusted Recovery measurement must remain observable")
require(intermediateRecovery.correctionStepApplied,
        "P7R4 T1 one bounded Recovery step may be applied")
require(!intermediateRecovery.recoveryConvergedThisUpdate,
        "P7R4 T1 a 5 m residual cannot be converged")
require(!intermediateRecovery.confidenceAccepted,
        "P7R4 T1 an intermediate Recovery step cannot raise confidence")
require(intermediateRecovery.constraintDisposition == .provisionalRecoveryStep,
        "P7R4 T1 an intermediate step must be provisional")

let recoveryConfidence = PriorMapConfidenceManager()
recoveryConfidence.reset()
for timestamp in 1...10 {
    let result = recoveryConfidence.update(
        timestamp: Double(timestamp),
        observation: PriorMapConfidenceObservation(
            trackingState: "normal",
            measurementAccepted: true,
            correctionStepApplied: true,
            recoveryActive: true,
            recoveryConvergedThisUpdate: false,
            recoveryFailedThisUpdate: false,
            validPointCount: 120,
            coverageAngleRad: 1.4,
            uniqueness: 0.5,
            residualCost: 0.01,
            mapMismatch: false))
    require(result.phase == .recovering,
            "P7R4 T2 every intermediate step must remain recovering")
    require(result.confidence <= 0.55,
            "P7R4 T2 Recovery confidence must stay capped")
}

// P7R4 T3/T4: convergence is at most usable, followed by three ordinary
// trusted Local observations; any rejection resets that post-Recovery gate.
let convergedRecovery = PriorMapRecoveryDecisionEngine.evaluate(
    PriorMapRecoveryDecisionInput(
        recoveryActive: true,
        hypothesisTrusted: true,
        geometryAndSafetyAccepted: true,
        residualTranslationM: 0.5,
        residualYawRad: 10 * .pi / 180,
        wallClockExpired: false))
require(convergedRecovery.recoveryConvergedThisUpdate,
        "P7R4 T3 inclusive convergence thresholds must converge")
let convergenceConfidence = recoveryConfidence.update(
    timestamp: 11,
    observation: PriorMapConfidenceObservation(
        trackingState: "normal",
        measurementAccepted: true,
        correctionStepApplied: true,
        recoveryActive: false,
        recoveryConvergedThisUpdate: true,
        recoveryFailedThisUpdate: false,
        validPointCount: 120,
        coverageAngleRad: 1.4,
        uniqueness: 0.5,
        residualCost: 0.01,
        mapMismatch: false))
require(convergenceConfidence.phase == .usable,
        "P7R4 T3 convergence frame must not be stable")

func trustedLocalObservation(_ accepted: Bool = true) -> PriorMapConfidenceObservation {
    PriorMapConfidenceObservation(
        trackingState: "normal",
        measurementAccepted: accepted,
        correctionStepApplied: accepted,
        recoveryActive: false,
        recoveryConvergedThisUpdate: false,
        recoveryFailedThisUpdate: false,
        validPointCount: accepted ? 120 : 0,
        coverageAngleRad: accepted ? 1.4 : 0,
        uniqueness: accepted ? 0.5 : 0,
        residualCost: accepted ? 0.01 : 0.15,
        mapMismatch: false)
}
_ = recoveryConfidence.update(
    timestamp: 12, observation: trustedLocalObservation())
_ = recoveryConfidence.update(
    timestamp: 13, observation: trustedLocalObservation())
let rejectedPostRecovery = recoveryConfidence.update(
    timestamp: 14, observation: trustedLocalObservation(false))
require(rejectedPostRecovery.phase != .stable
        && recoveryConfidence.postRecoveryTrustedLocalFrames == 0,
        "P7R4 T4 rejection must reset post-Recovery Local trust")
for timestamp in 15...16 {
    let result = recoveryConfidence.update(
        timestamp: Double(timestamp), observation: trustedLocalObservation())
    require(result.phase != .stable,
            "P7R4 T4 fewer than three fresh Local frames cannot be stable")
}
let stableAfterRecovery = recoveryConfidence.update(
    timestamp: 17, observation: trustedLocalObservation())
require(stableAfterRecovery.phase == .stable,
        "P7R4 T4 three consecutive ordinary Local frames may restore stable")

final class FakeMonotonicClock: PriorMapMonotonicClock {
    var now: TimeInterval
    init(_ now: TimeInterval) { self.now = now }
}

func recoveryUpdateInput(
    timestamp: TimeInterval,
    preMatchNow: TimeInterval,
    postMatchNow: TimeInterval,
    recoveryActive: Bool,
    disposition: PriorMapRecoveryFrameDisposition,
    trusted: Bool = false,
    geometryAccepted: Bool = false,
    residualTranslationM: Double = 0,
    residualYawRad: Double = 0,
    pendingCompletion: PriorMapRecoveryOutcome? = nil
) -> PriorMapRecoveryUpdateInput {
    PriorMapRecoveryUpdateInput(
        timestamp: timestamp,
        preMatchNow: preMatchNow,
        postMatchNow: postMatchNow,
        recoveryWasActiveAtUpdateStart: recoveryActive,
        recoveryActiveForMatch: recoveryActive,
        pendingCompletionOutcome: pendingCompletion,
        frameDisposition: disposition,
        hypothesisTrusted: trusted,
        geometryAndSafetyAccepted: geometryAccepted,
        residualTranslationM: residualTranslationM,
        residualYawRad: residualYawRad,
        trackingState: "normal",
        validPointCount: trusted ? 120 : 0,
        coverageAngleRad: trusted ? 1.4 : 0,
        uniqueness: trusted ? 0.5 : 0,
        residualCost: trusted ? 0.01 : 0.15,
        mapMismatch: false)
}

// P7R4 T5: a safe final-attempt step remains provisional when the episode
// times out; immutable completion evidence preserves the episode hypothesis.
let finalAttemptController = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
_ = finalAttemptController.request(reason: "persistent_weak_or_lost", now: 0,
                                   automatic: true)
for _ in 0..<39 { finalAttemptController.recordFrameDisposition(.searched) }
let finalAttemptConfidence = PriorMapConfidenceManager()
finalAttemptConfidence.reset()
let finalAttemptUpdate = PriorMapRecoveryUpdateReducer.reduce(
    recoveryUpdateInput(
        timestamp: 10,
        preMatchNow: 10,
        postMatchNow: 10,
        recoveryActive: true,
        disposition: .searched,
        trusted: true,
        geometryAccepted: true,
        residualTranslationM: 4.2,
        residualYawRad: 0.2),
    recoveryController: finalAttemptController,
    confidenceManager: finalAttemptConfidence)
require(finalAttemptController.activeEpisode?.validMatcherAttempts == 40,
        "P7R4 T5 the production reducer must record attempt 40/40")
require(finalAttemptUpdate.action == .timedOut
        && finalAttemptUpdate.decision.correctionStepApplied,
        "P7R4 T5 attempt 40 may retain one safe step but must time out")
require(!finalAttemptUpdate.decision.confidenceAccepted
        && !finalAttemptUpdate.finalConstraintAccepted
        && finalAttemptUpdate.decision.constraintDisposition
            == .provisionalRecoveryStep,
        "P7R4 T5 the final step must remain provisional and non-confidence-bearing")
require(finalAttemptUpdate.nextConfidence.phase == .weak
        && finalAttemptUpdate.reason.contains("timed_out"),
        "P7R4 T5 timeout must emit weak phase and explicit timed_out diagnostics")
let finalAttemptCompletion = finalAttemptController.finish(
    .timedOut,
    now: 10,
    selectedHypothesisId: 77,
    finalFreshSupportFrames: 4,
    finalResidualTranslationM: 4.2,
    finalResidualYawRad: 0.2,
    correctionStepAppliedOnCompletionFrame:
        finalAttemptUpdate.decision.correctionStepApplied)
require(finalAttemptCompletion?.outcome == .timedOut
        && finalAttemptCompletion?.correctionStepAppliedOnCompletionFrame == true,
        "P7R4 T5 timeout must not reinterpret a provisional step as success")
require(finalAttemptCompletion?.selectedHypothesisId == 77,
        "P7R4 T10 completion must bind the episode hypothesis")
let completionIsolation = PriorMapHypothesisTraceBinder.bind(
    completion: finalAttemptCompletion,
    currentSelectedHypothesisId: 901)
require(!completionIsolation.currentHypothesisVisible
        && completionIsolation.currentSelectedHypothesisId == nil,
        "P7R4 T10 a new Local candidate cannot enter flat fields on an old completion frame")
require(completionIsolation.recoverySelectedHypothesisId == 77,
        "P7R4 T10 completion diagnostics must retain the old episode hypothesis")

// P7R4 T6/T7: a matcher crossing the deadline records a real attempt but the
// post-match decision cannot mutate the alignment. Equality is expired too.
let fakeClock = FakeMonotonicClock(0)
let deadlineController = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
_ = deadlineController.request(reason: "deadline", now: fakeClock.now)
let deadlineConfidence = PriorMapConfidenceManager()
deadlineConfidence.reset()
let deadlineAnchor = PriorMapLocalizationAnchor(
    initialMapPose: PriorMapPose2D(xM: 4, yM: 5, yawRad: 0.1))
let deadlineArkitPose = PriorMapPose2D(xM: 1, yM: 2, yawRad: 0.2)
let anchorBeforeExpiredMatch = deadlineAnchor.project(
    arkitPose: deadlineArkitPose)
fakeClock.now = 29.8
require(!deadlineController.isWallClockExpired(now: fakeClock.now),
        "P7R4 T6 matcher may start before deadline")
fakeClock.now = 31.3
let expiredUpdate = PriorMapRecoveryUpdateReducer.reduce(
    recoveryUpdateInput(
        timestamp: fakeClock.now,
        preMatchNow: 29.8,
        postMatchNow: fakeClock.now,
        recoveryActive: true,
        disposition: .searched,
        trusted: true,
        geometryAccepted: true,
        residualTranslationM: 1),
    recoveryController: deadlineController,
    confidenceManager: deadlineConfidence)
require(deadlineController.activeEpisode?.validMatcherAttempts == 1,
        "P7R4 T6 a deadline-crossing real search still counts")
require(expiredUpdate.action == .timedOut
        && !expiredUpdate.decision.correctionStepApplied,
        "P7R4 T6 no post-deadline Recovery correction may be applied")
let deadlineCompletion = deadlineController.finish(
    .timedOut,
    now: fakeClock.now,
    correctionStepAppliedOnCompletionFrame:
        expiredUpdate.decision.correctionStepApplied)
require(deadlineCompletion?.outcome == .timedOut
        && expiredUpdate.nextConfidence.phase == .weak,
        "P7R4 T6 deadline crossing must finish timed_out and enter weak")
requirePoseClose(
    deadlineAnchor.project(arkitPose: deadlineArkitPose),
    anchorBeforeExpiredMatch,
    "P7R4 T6 an expired matcher result cannot mutate the localizer anchor")
require(!deadlineController.isWallClockExpired(now: 30),
        "P7R4 T7 completed controller no longer has an active deadline")

let exactDeadlineController = PriorMapRecoveryController()
_ = exactDeadlineController.request(reason: "exact_deadline", now: 0)
let exactDeadlineConfidence = PriorMapConfidenceManager()
exactDeadlineConfidence.reset()
let exactDeadlineUpdate = PriorMapRecoveryUpdateReducer.reduce(
    recoveryUpdateInput(
        timestamp: 30,
        preMatchNow: 30,
        postMatchNow: 30,
        recoveryActive: true,
        disposition: .observationUnavailable),
    recoveryController: exactDeadlineController,
    confidenceManager: exactDeadlineConfidence)
require(exactDeadlineUpdate.action == .timedOut
        && !exactDeadlineUpdate.searchedAttemptRecorded,
        "P7R4 T7 now equal to deadline expires before search/correction")

// P7R4 T12: every production frame disposition goes through the same attempt
// reducer. Invalid/dropped frames advance the FakeClock but never the attempt
// counter, and wall-clock expiry remains fail-closed.
let dispositionClock = FakeMonotonicClock(0)
let dispositionController = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
_ = dispositionController.request(
    reason: "invalid_frame_timeout", now: dispositionClock.now,
    automatic: true)
let dispositionConfidence = PriorMapConfidenceManager()
dispositionConfidence.reset()
let dispositionGate = PriorMapUpdateGate(minimumInterval: 0.5)
let acceptedGateDecision = dispositionGate.begin(timestamp: 1.0)
guard case .accepted(let dispositionTicket) = acceptedGateDecision else {
    fatalError("P7R4 T12 first gate update must be accepted")
}
let busyGateDecision = dispositionGate.begin(timestamp: 2.0)
require(busyGateDecision.recoveryFrameDisposition == .busy,
        "P7R4 T12 a busy gate must expose the production busy disposition")
dispositionGate.finish(ticket: dispositionTicket)
let throttledGateDecision = dispositionGate.begin(timestamp: 1.1)
require(throttledGateDecision.recoveryFrameDisposition == .throttled,
        "P7R4 T12 a throttled gate must expose the production throttled disposition")
for (index, disposition) in invalidRecoveryDispositions.enumerated() {
    dispositionClock.now = Double(index + 1) * 4.9
    let invalidUpdate = PriorMapRecoveryUpdateReducer.reduce(
        recoveryUpdateInput(
            timestamp: dispositionClock.now,
            preMatchNow: dispositionClock.now,
            postMatchNow: dispositionClock.now,
            recoveryActive: true,
            disposition: disposition),
        recoveryController: dispositionController,
        confidenceManager: dispositionConfidence)
    require(!invalidUpdate.searchedAttemptRecorded
            && invalidUpdate.action == .none,
            "P7R4 T12 \(disposition.rawValue) must consume wall time but not an attempt")
}
require(dispositionController.activeEpisode?.validMatcherAttempts == 0,
        "P7R4 T12 all invalid/dropped paths must leave attempts at zero")
dispositionClock.now = 30
let invalidTimeoutUpdate = PriorMapRecoveryUpdateReducer.reduce(
    recoveryUpdateInput(
        timestamp: dispositionClock.now,
        preMatchNow: dispositionClock.now,
        postMatchNow: dispositionClock.now,
        recoveryActive: true,
        disposition: .observationUnavailable),
    recoveryController: dispositionController,
    confidenceManager: dispositionConfidence)
require(invalidTimeoutUpdate.action == .timedOut
        && !invalidTimeoutUpdate.searchedAttemptRecorded
        && invalidTimeoutUpdate.recoveryFailedThisUpdate
        && invalidTimeoutUpdate.nextConfidence.phase == .weak,
        "P7R4 T12 invalid frames must reach timed_out/weak without a searched attempt")
_ = dispositionController.finish(.timedOut, now: dispositionClock.now)
for weakTimestamp in [30.1, 35.0, 49.9] {
    let cooldownWeakUpdate = PriorMapRecoveryUpdateReducer.reduce(
        recoveryUpdateInput(
            timestamp: weakTimestamp,
            preMatchNow: weakTimestamp,
            postMatchNow: weakTimestamp,
            recoveryActive: false,
            disposition: .observationUnavailable),
        recoveryController: dispositionController,
        confidenceManager: dispositionConfidence)
    require(cooldownWeakUpdate.nextConfidence.phase == .weak,
            "P7R4 T12 timeout must remain weak throughout automatic cooldown")
    require(!dispositionController.request(
        reason: "persistent_weak_or_lost",
        now: weakTimestamp,
        automatic: true),
        "P7R4 T12 continuous weak frames cannot start Recovery during cooldown")
}

// P7R4 T8/T9: automatic timeout creates a bounded cooldown. A reliable loop
// may bypass it, while a repeated trigger only merges into the active episode.
let cooldownController = PriorMapRecoveryController()
_ = cooldownController.request(
    reason: "persistent_weak_or_lost", now: 100, automatic: true)
_ = cooldownController.finish(.timedOut, now: 130)
require(!cooldownController.request(
    reason: "persistent_weak_or_lost", now: 149, automatic: true),
    "P7R4 T8 automatic Recovery must be suppressed during cooldown")
require(cooldownController.isAutomaticTriggerSuppressed(now: 149),
        "P7R4 T8 cooldown suppression must be diagnostic")
require(cooldownController.request(reason: "reliable_rtabmap_loop", now: 149),
        "P7R4 T9 reliable loop may bypass automatic cooldown")
let bypassEpisode = cooldownController.activeEpisode!
require(!cooldownController.request(reason: "reliable_rtabmap_loop", now: 150),
        "P7R4 T9 an active loop trigger must merge")
require(cooldownController.activeEpisode?.id == bypassEpisode.id
        && cooldownController.activeEpisode?.deadlineUptime
            == bypassEpisode.deadlineUptime,
        "P7R4 T9 merged trigger must not reset identity or deadline")
_ = cooldownController.finish(.cancelled, now: 150)
require(cooldownController.request(
    reason: "persistent_weak_or_lost", now: 150, automatic: true),
    "P7R4 T8 a new automatic episode must be allowed exactly when cooldown expires")

// P7R4 T11: exercise the production localizer anchor with competing Recovery
// hypotheses. B wins fresh evidence, advances through multiple bounded steps,
// survives tracker cleanup, and remains the basis of the next ordinary Local
// frame; historical A has neither support nor authority to move the anchor.
let retainedAnchor = PriorMapLocalizationAnchor(
    initialMapPose: PriorMapPose2D(xM: 0, yM: 0, yawRad: 0))
let anchorTracker = PriorMapHypothesisTracker()
anchorTracker.beginRecoveryEpisode(id: 700)
let historicalA = PriorMapAlignmentTransform(
    translationXM: -2, translationYM: 0, yawRad: 0)
let selectedB = PriorMapAlignmentTransform(
    translationXM: 2, translationYM: 0.4, yawRad: 6 * .pi / 180)
var retainedStepCount = 0
var retainedRecoveryConverged = false
var lastAnchorArkitPose = PriorMapPose2D(xM: 0, yM: 0, yawRad: 0)
for attempt in 0..<20 {
    let arkitPose = PriorMapPose2D(
        xM: Double(attempt) * 0.1,
        yM: Double(attempt) * 0.02,
        yawRad: Double(attempt) * 0.002)
    lastAnchorArkitPose = arkitPose
    let rawAnchorPose = retainedAnchor.project(arkitPose: arkitPose)
    let anchorDecision = anchorTracker.observe(
        arkitPose: arkitPose,
        candidates: [
            PriorMapScanMatchCandidate(
                pose: PriorMapAlignmentMath.apply(
                    mapFromArkit: historicalA,
                    arkitPose: arkitPose),
                cost: 0.08,
                score: productionMatcherScore(0.08)),
            PriorMapScanMatchCandidate(
                pose: PriorMapAlignmentMath.apply(
                    mapFromArkit: selectedB,
                    arkitPose: arkitPose),
                cost: 0.01,
                score: productionMatcherScore(0.01)),
        ],
        uniqueness: 0.5,
        recoverySearch: true)
    guard anchorDecision.trusted,
          let trustedB = anchorDecision.mapFromArkit else {
        continue
    }
    require(trustedB.translationXM > 1.5,
            "P7R4 T11 fresh Recovery evidence must select B rather than historical A")
    let targetB = PriorMapAlignmentMath.apply(
        mapFromArkit: trustedB,
        arkitPose: arkitPose)
    let residual = PriorMapCorrectionSafety.difference(
        from: rawAnchorPose,
        to: targetB)
    let boundedAnchorPose = PriorMapCorrectionSafety.boundedStep(
        current: rawAnchorPose,
        target: targetB)
    retainedAnchor.retainAppliedCorrection(
        arkitPose: arkitPose,
        estimatedMapPose: boundedAnchorPose)
    retainedStepCount += 1
    if residual.translationM
            <= PriorMapRecoveryDecisionEngine.convergenceTranslationM,
       residual.yawRad <= PriorMapRecoveryDecisionEngine.convergenceYawRad {
        retainedRecoveryConverged = true
        break
    }
}
require(retainedRecoveryConverged && retainedStepCount > 1,
        "P7R4 T11 B must converge through multiple bounded anchor steps")
anchorTracker.endRecoveryEpisode(id: 700, outcome: .converged)
let nextAnchorArkitPose = PriorMapPose2D(
    xM: lastAnchorArkitPose.xM + 0.2,
    yM: lastAnchorArkitPose.yM + 0.04,
    yawRad: lastAnchorArkitPose.yawRad + 0.004)
let projectedFromRetainedB = retainedAnchor.project(
    arkitPose: nextAnchorArkitPose)
let expectedFromB = PriorMapAlignmentMath.apply(
    mapFromArkit: selectedB,
    arkitPose: nextAnchorArkitPose)
let expectedFromA = PriorMapAlignmentMath.apply(
    mapFromArkit: historicalA,
    arkitPose: nextAnchorArkitPose)
let distanceToB = PriorMapCorrectionSafety.difference(
    from: projectedFromRetainedB,
    to: expectedFromB).translationM
let distanceToA = PriorMapCorrectionSafety.difference(
    from: projectedFromRetainedB,
    to: expectedFromA).translationM
require(distanceToB <= 0.5 && distanceToA > 3.0,
        "P7R4 T11 next Local frame must continue from retained B without jumping to A")
let freshLocalB = anchorTracker.observe(
    arkitPose: nextAnchorArkitPose,
    candidates: [PriorMapScanMatchCandidate(
        pose: expectedFromB,
        cost: 0.01,
        score: productionMatcherScore(0.01))],
    uniqueness: 0.5,
    recoverySearch: false)
require(!freshLocalB.trusted && freshLocalB.supportFrames == 1,
        "P7R4 T11 tracker cleanup must require fresh Local support")
requirePoseClose(
    retainedAnchor.project(arkitPose: nextAnchorArkitPose),
    projectedFromRetainedB,
    "P7R4 T11 untrusted fresh Local evidence cannot move retained B anchor")

// Legacy coordinate reconstruction coverage, including arbitrary turns.
var randomState: UInt64 = 0x5eed5eed
func deterministicUnit() -> Double {
    randomState = randomState &* 6364136223846793005 &+ 1442695040888963407
    return Double(randomState >> 11) / Double(UInt64.max >> 11)
}
for index in 0..<100 {
    let arkitPose = PriorMapPose2D(
        xM: deterministicUnit() * 200 - 100,
        yM: deterministicUnit() * 200 - 100,
        yawRad: deterministicUnit() * 2 * .pi - .pi)
    let alignment = PriorMapAlignmentTransform(
        translationXM: deterministicUnit() * 200 - 100,
        translationYM: deterministicUnit() * 200 - 100,
        yawRad: deterministicUnit() * 2 * .pi - .pi)
    requireAlignmentReconstruction(
        arkitPose: arkitPose,
        expectedMapFromArkit: alignment,
        "T11 randomized case \(index)")
}

let orientedBounds = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
let rightBounds = PriorMapImageGeometry.nativeSensorBounds(
    visionBounds: orientedBounds,
    orientation: .right)
require(close(rightBounds.origin.x, 0.4), "right orientation x mapping")
require(close(rightBounds.origin.y, 0.1), "right orientation y mapping")
require(close(rightBounds.width, 0.4), "right orientation width mapping")
require(close(rightBounds.height, 0.3), "right orientation height mapping")
let leftBounds = PriorMapImageGeometry.nativeSensorBounds(
    visionBounds: orientedBounds,
    orientation: .left)
require(close(leftBounds.origin.x, 0.2), "left orientation x mapping")
require(close(leftBounds.origin.y, 0.6), "left orientation y mapping")
let downBounds = PriorMapImageGeometry.nativeSensorBounds(
    visionBounds: orientedBounds,
    orientation: .down)
require(close(downBounds.origin.x, 0.6), "down orientation x mapping")
require(close(downBounds.origin.y, 0.4), "down orientation y mapping")
let upBounds = PriorMapImageGeometry.nativeSensorBounds(
    visionBounds: orientedBounds,
    orientation: .up)
require(close(upBounds.origin.x, 0.1), "up orientation x mapping")
require(close(upBounds.origin.y, 0.2), "up orientation y mapping")

let floorEstimator = PriorMapFloorPlaneEstimator()
let floorSamples = (0..<80).map {
    PriorMapFloorSample(
        heightWorldM: -1.5 + Double($0 % 5 - 2) * 0.002,
        relativeHeightM: -1.5,
        upAlignment: 0.98)
}
let firstFloor = floorEstimator.update(samples: floorSamples)
var stableFloor = firstFloor
for _ in 0..<5 {
    stableFloor = floorEstimator.update(samples: floorSamples)
}
require(firstFloor != nil, "a supported horizontal floor plane must be estimated")
require(
    (stableFloor?.confidence ?? 0) > (firstFloor?.confidence ?? 1),
    "floor confidence must depend on temporal stability")
floorEstimator.reset()
require(
    floorEstimator.update(
        samples: floorSamples.map { sample in
            PriorMapFloorSample(
                heightWorldM: sample.heightWorldM,
                relativeHeightM: sample.relativeHeightM,
                upAlignment: 0.3)
        }) == nil,
    "non-horizontal low objects must not become the floor")
floorEstimator.reset()
require(
    floorEstimator.update(
        samples: floorSamples.map { _ in
            PriorMapFloorSample(
                heightWorldM: -0.7,
                relativeHeightM: -0.7,
                upAlignment: 0.99)
        }) == nil,
    "a horizontal low shelf or cart must not become the floor")

let shelf = PriorMapShelf(
    id: "shelf-1",
    floorId: "1",
    code: "S1",
    crossCode: "C1",
    rowFlag: "R1",
    geometry: PriorMapShelfGeometry(
        type: "Polygon",
        coordinates: [[0, 0], [4, 0], [4, 1], [0, 1], [0, 0]]))
let localized = ShelfAssociation.localizedTag(
    observationId: "observation",
    payload: "6900000000000",
    symbology: "EAN13",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: -0.1, heightM: 1.4),
    cameraPosition: SIMD2<Double>(2, -2),
    shelves: [shelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(localized.shelfCode == "S1", "tag must associate with the expected shelf")
require(localized.distanceFromShelfStartCm != nil, "tag must retain along-shelf offset")
require(localized.heightCm == 140, "tag height must be expressed in centimetres")
let justConvergedUsableTag = ShelfAssociation.localizedTag(
    observationId: "just-converged",
    payload: "6900000000001",
    symbology: "EAN13",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: -0.1, heightM: 1.4),
    cameraPosition: SIMD2<Double>(2, -2),
    shelves: [shelf],
    localizationState: "usable",
    localizationConfidence: 0.79,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(justConvergedUsableTag.needsReview,
        "P7R4 T14 usable/just-converged tags cannot auto-confirm")

func tagForLocalizationState(
    observationId: String,
    state: String
) -> LocalizedPriceTag {
    ShelfAssociation.localizedTag(
        observationId: observationId,
        payload: "6900000000099",
        symbology: "EAN13",
        floorId: "1",
        rawPosition: PriorMapTagPoint3D(
            xM: 2, yM: -0.1, heightM: 1.4),
        cameraPosition: SIMD2<Double>(2, -2),
        shelves: [shelf],
        localizationState: state,
        localizationConfidence: 0.95,
        measurementConfidence: 0.95,
        measurementMethod: "scene_depth",
        userConfirmed: false)
}
let tagConfidenceMatrix: [
    (label: String, state: String, mustNeedReview: Bool)
] = [
    ("recovery_active", "recovering", true),
    ("recovery_timed_out", "weak", true),
    ("just_converged", "usable", true),
    ("usable", "usable", true),
    ("stable", "stable", false),
]
for matrixCase in tagConfidenceMatrix {
    let result = tagForLocalizationState(
        observationId: matrixCase.label,
        state: matrixCase.state)
    require(result.needsReview == matrixCase.mustNeedReview,
            "P7R4 T14 \(matrixCase.label) auto-confirm safety matrix")
}
require(!localized.needsReview,
        "P7R4 T14 a fully qualified stable tag must retain the positive auto-confirm path")

let oppositeSide = ShelfAssociation.localizedTag(
    observationId: "opposite",
    payload: "opposite",
    symbology: "EAN13",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: 1.1, heightM: 1.2),
    cameraPosition: SIMD2<Double>(2, 2),
    shelves: [shelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(
    localized.shelfSide != oppositeSide.shelfSide,
    "opposite long faces must retain different shelf sides")

let backside = ShelfAssociation.localizedTag(
    observationId: "backside",
    payload: "backside",
    symbology: "EAN13",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: 0.9, heightM: 1.2),
    cameraPosition: SIMD2<Double>(2, -2),
    shelves: [shelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(backside.needsReview, "a shelf face hidden behind the near face requires review")

let rearShelf = PriorMapShelf(
    id: "rear",
    floorId: "1",
    code: "REAR",
    crossCode: nil,
    rowFlag: nil,
    geometry: PriorMapShelfGeometry(
        type: "Polygon",
        coordinates: [[0, 2], [4, 2], [4, 3], [0, 3], [0, 2]]))
let blockedRear = ShelfAssociation.localizedTag(
    observationId: "blocked-rear",
    payload: "blocked-rear",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: 1.95, heightM: 1.2),
    cameraPosition: SIMD2<Double>(2, -2),
    shelves: [shelf, rearShelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(blockedRear.shelfCode == nil, "a rear shelf hidden by another shelf must not be preselected")
require(blockedRear.needsReview, "cross-shelf occlusion must require review")

let counter = PriorMapFixedStructure(
    id: "counter",
    floorId: "1",
    shapeType: "MapTable",
    code: "COUNTER",
    crossCode: "C2",
    rowFlag: nil,
    geometry: PriorMapShelfGeometry(
        type: "Polygon",
        coordinates: [[6, 0], [10, 0], [10, 1], [8, 1.5], [6, 1], [6, 0]]))
let counterTag = ShelfAssociation.localizedTag(
    observationId: "counter",
    payload: "counter",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 8, yM: -0.1, heightM: 1.0),
    cameraPosition: SIMD2<Double>(8, -2),
    shelves: [],
    fixedStructures: [counter],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(counterTag.shelfCode == "COUNTER", "fixed counters must be associable")
let pillar = PriorMapFixedStructure(
    id: "pillar",
    floorId: "1",
    shapeType: "MapPillar",
    code: "P1",
    crossCode: nil,
    rowFlag: nil,
    geometry: PriorMapShelfGeometry(
        type: "Polygon",
        coordinates: [[7.7, -0.3], [8.3, -0.3], [8.3, 0.3], [7.7, 0.3], [7.7, -0.3]]))
let pillarTag = ShelfAssociation.localizedTag(
    observationId: "pillar",
    payload: "pillar",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 8, yM: 0, heightM: 1),
    cameraPosition: SIMD2<Double>(8, -2),
    shelves: [],
    fixedStructures: [pillar],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(pillarTag.shelfCode == nil, "pillars must remain blockers, not tag surfaces")
require(pillarTag.needsReview, "a pillar-only hit must require review")

let endpoint = ShelfAssociation.localizedTag(
    observationId: "endpoint",
    payload: "endpoint",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 0, yM: -0.05, heightM: 1),
    cameraPosition: SIMD2<Double>(0, -2),
    shelves: [shelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(endpoint.shelfCode == "S1", "shelf endpoint must remain associable")
require(endpoint.needsReview, "endpoint ambiguity must require review")

let duplicateShelf = PriorMapShelf(
    id: "shelf-duplicate",
    floorId: "1",
    code: "S2",
    crossCode: nil,
    rowFlag: nil,
    geometry: shelf.geometry)
let ambiguous = ShelfAssociation.localizedTag(
    observationId: "ambiguous",
    payload: "ambiguous",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: -0.1, heightM: 1),
    cameraPosition: SIMD2<Double>(2, -2),
    shelves: [shelf, duplicateShelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(ambiguous.needsReview, "overlapping shelves must be marked ambiguous")

let rotatedShelf = PriorMapShelf(
    id: "rotated",
    floorId: "1",
    code: "ROT",
    crossCode: nil,
    rowFlag: nil,
    geometry: PriorMapShelfGeometry(
        type: "Polygon",
        coordinates: [[0, 0], [2, 2], [1.5, 2.5], [-0.5, 0.5], [0, 0]]))
let rotated = ShelfAssociation.localizedTag(
    observationId: "rotated",
    payload: "rotated",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 0.8, yM: 1.3, heightM: 1),
    cameraPosition: SIMD2<Double>(-1, 2),
    shelves: [rotatedShelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(rotated.shelfCode == "ROT", "rotated shelf geometry must be supported")

let outOfRange = ShelfAssociation.localizedTag(
    observationId: "far",
    payload: "far",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 20, yM: 20, heightM: 1),
    cameraPosition: SIMD2<Double>(19, 19),
    shelves: [shelf],
    localizationState: "stable",
    localizationConfidence: 0.9,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(outOfRange.shelfCode == nil, "out-of-range observations must not snap")
require(outOfRange.needsReview, "out-of-range observations require review")

let unsafe = ShelfAssociation.localizedTag(
    observationId: "unsafe",
    payload: "unsafe",
    symbology: "QR",
    floorId: "1",
    rawPosition: PriorMapTagPoint3D(xM: 2, yM: -0.1, heightM: 1.4),
    cameraPosition: SIMD2<Double>(2, -2),
    shelves: [shelf],
    localizationState: "lost",
    localizationConfidence: 0,
    measurementConfidence: 0.9,
    measurementMethod: "scene_depth",
    userConfirmed: false)
require(unsafe.needsReview, "lost localization may never auto-confirm a tag")

func distanceLevel(
    resolution: Double,
    verticalLines: [Double]
) -> PriorMapDistanceFieldLevel {
    let origin = [-2.0, -2.0]
    let width = Int(4.0 / resolution)
    let height = Int(4.0 / resolution)
    let rowValues: [Int] = (0..<width).map { column in
        let center = origin[0] + (Double(column) + 0.5) * resolution
        let distance = verticalLines.map {
            max(0, abs(center - $0) - resolution / 2)
        }.min() ?? 2.55
        return min(255, Int((distance * 100).rounded()))
    }
    var encodedRow: [Int] = []
    for value in rowValues {
        if encodedRow.count >= 2, encodedRow[encodedRow.count - 1] == value {
            encodedRow[encodedRow.count - 2] += 1
        }
        else {
            encodedRow.append(1)
            encodedRow.append(value)
        }
    }
    let rows = Array(repeating: encodedRow, count: height)
    let canonical = "[" + rows.map {
        "[" + $0.map(String.init).joined(separator: ",") + "]"
    }.joined(separator: ",") + "]"
    let digest = SHA256.hash(data: Data(canonical.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    return PriorMapDistanceFieldLevel(
        resolutionM: resolution,
        originM: origin,
        width: width,
        height: height,
        encoding: "row_rle_u8_cm",
        dataSha256: digest,
        rows: rows)
}

do {
    let periodicFloor = PriorMapDistanceFieldFloor(
        levels: [0.4, 0.2, 0.1].map {
            distanceLevel(resolution: $0, verticalLines: [0, 0.6])
        })
    let periodicMatcher = try PriorMapScanMatcher(
        floor: periodicFloor,
        truncationM: 2.55)
    let observation = PriorMapStructureObservation(
        points: (0..<80).map {
            SIMD2<Double>(0, -1.5 + Double($0) * 3.0 / 79.0)
        },
        validPointCount: 80,
        coverageAngleRad: 1.2,
        floorEstimate: nil,
        source: "test")
    let periodic = periodicMatcher.match(
        predictedPose: PriorMapPose2D(xM: 0.3, yM: 0, yawRad: 0),
        observation: observation)
    require(
        !periodic.acceptedByGeometry,
        "periodic equal-cost structure basins must fail closed")
    require(
        periodic.uniqueness < 0.10,
        "uniqueness must compare independent global basins")
    let points29 = PriorMapStructureObservation(
        points: Array(observation.points.prefix(29)),
        validPointCount: 29,
        coverageAngleRad: 1.2,
        floorEstimate: nil,
        source: "test")
    let points30 = PriorMapStructureObservation(
        points: Array(observation.points.prefix(30)),
        validPointCount: 30,
        coverageAngleRad: 1.2,
        floorEstimate: nil,
        source: "test")
    let notSearched = periodicMatcher.match(
        predictedPose: PriorMapPose2D(xM: 0.3, yM: 0, yawRad: 0),
        observation: points29)
    let searched = periodicMatcher.match(
        predictedPose: PriorMapPose2D(xM: 0.3, yM: 0, yawRad: 0),
        observation: points30)
    require(!notSearched.searchPerformed
        && notSearched.attemptDisposition == .notSearchedInsufficientPoints,
        "P7R4 T13 29 points must not report a real search")
    require(searched.searchPerformed
        && searched.attemptDisposition == .searched,
        "P7R4 T13 30 points must use the matcher-owned threshold")
}
catch {
    require(false, "periodic matcher fixture must load: \(error)")
}

let coherentDepth = PriceTagDepthEvidence.evaluate(
    (0..<64).map { 1.20 + Float($0 % 5 - 2) * 0.002 })
require(coherentDepth.accepted, "dense coherent barcode depth must be accepted")
require(coherentDepth.inlierCount >= 48, "coherent depth must retain dense inliers")
require(coherentDepth.confidence >= 0.65, "high confidence must be evidence-derived")
let sparseDepth = PriceTagDepthEvidence.evaluate([1.0, 1.01, 0.99, 1.0])
require(!sparseDepth.accepted, "a few valid depth pixels must not imply confidence")
require(sparseDepth.confidence < 0.5, "sparse depth confidence must stay low")
let backgroundMajority = PriceTagDepthEvidence.evaluate(
    (0..<24).map { 0.9 + Float($0 % 3) * 0.002 }
        + (0..<57).map { 2.4 + Float($0 % 5) * 0.003 })
require(
    !backgroundMajority.accepted,
    "a foreground/background split with wrong-depth majority must fail closed")
require(
    backgroundMajority.rejectionReason == "ambiguous_depth_layers",
    "ambiguous depth layers must be auditable")
let fresh0 = PriorMapAlignmentFreshness.evaluate(
    ageMs: 0, versionLag: 0, localizationState: "stable", localizationConfidence: 0.9)
let fresh100 = PriorMapAlignmentFreshness.evaluate(
    ageMs: 100, versionLag: 0, localizationState: "stable", localizationConfidence: 0.9)
let aging300 = PriorMapAlignmentFreshness.evaluate(
    ageMs: 300, versionLag: 0, localizationState: "stable", localizationConfidence: 0.9)
let stale800 = PriorMapAlignmentFreshness.evaluate(
    ageMs: 800, versionLag: 0, localizationState: "stable", localizationConfidence: 0.9)
let versionStale = PriorMapAlignmentFreshness.evaluate(
    ageMs: 100, versionLag: 1, localizationState: "stable", localizationConfidence: 0.9)
require(fresh0.label == "fresh" && fresh100.label == "fresh", "0/100 ms must stay fresh")
require(aging300.label == "aging" && aging300.localizationState == "weak", "300 ms must be pending/weak")
require(stale800.label == "timestamp_stale" && stale800.localizationState == "lost", "800 ms must be stale")
require(versionStale.label == "version_stale", "alignment changes after scan must invalidate the snapshot")

let squareGeometry = PriorMapShelfGeometry(
    type: "Polygon",
    coordinates: [[0, 0], [2, 0], [2, 2], [0, 2]])
let reversedSquareGeometry = PriorMapShelfGeometry(
    type: "Polygon",
    coordinates: [[2, 2], [2, 0], [0, 0], [0, 2]])
let squareSource = PriorMapShelfSource(width: 200, height: 200)
let square = PriorMapShelf(
    id: "square",
    floorId: "1",
    code: "SQ",
    crossCode: nil,
    rowFlag: nil,
    geometry: squareGeometry,
    yawRad: 0,
    source: squareSource)
let reversedSquare = PriorMapShelf(
    id: "square",
    floorId: "1",
    code: "SQ",
    crossCode: nil,
    rowFlag: nil,
    geometry: reversedSquareGeometry,
    yawRad: 0,
    source: squareSource)
func squareTag(_ value: PriorMapShelf) -> LocalizedPriceTag {
    ShelfAssociation.localizedTag(
        observationId: "square",
        payload: "square",
        symbology: "QR",
        floorId: "1",
        rawPosition: PriorMapTagPoint3D(xM: 0.6, yM: -0.05, heightM: 1),
        cameraPosition: SIMD2<Double>(0.6, -2),
        shelves: [value],
        localizationState: "stable",
        localizationConfidence: 0.9,
        measurementConfidence: 0.9,
        measurementMethod: "scene_depth",
        userConfirmed: false)
}
let squareForward = squareTag(square)
let squareReversed = squareTag(reversedSquare)
require(squareForward.shelfSide == squareReversed.shelfSide, "square side ID must ignore ring order")
require(
    close(
        squareForward.distanceFromShelfStartCm ?? -1,
        squareReversed.distanceFromShelfStartCm ?? -2),
    "square offset start must be stable under reversed ring order")

// MARK: - P7R5 F-01: cooldown reconciles against the terminal outcome.

// C1: automatic timeout starts a cooldown, a reliable loop bypasses it and
// converges before expiry; the stale cooldown is cleared exactly at
// convergence so the next Local frames are never forced weak.
let p7r5C1Controller = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
_ = p7r5C1Controller.request(
    reason: "persistent_weak_or_lost", now: 0, automatic: true)
_ = p7r5C1Controller.finish(.timedOut, now: 5)
require(p7r5C1Controller.isAutomaticTriggerSuppressed(now: 6),
        "P7R5 C1 automatic timeout must suppress automatic triggers")
require(!p7r5C1Controller.request(
    reason: "persistent_weak_or_lost", now: 6, automatic: true),
        "P7R5 C1 automatic retry stays suppressed during cooldown")
require(p7r5C1Controller.request(
    reason: "reliable_rtabmap_loop", now: 6),
        "P7R5 C1 a reliable loop must bypass the automatic cooldown")
let p7r5C1Completion = p7r5C1Controller.finish(
    .converged, now: 8, selectedHypothesisId: 5, finalFreshSupportFrames: 4)
require(p7r5C1Completion?.outcome == .converged
        && p7r5C1Completion?.cancellationReason == nil,
        "P7R5 C1 convergence carries no cancellation reason")
require(p7r5C1Controller.nextAutomaticRecoveryAllowedAt == 0,
        "P7R5 C1 convergence must clear the stale cooldown exactly")
require(p7r5C1Controller.request(
    reason: "persistent_weak_or_lost", now: 9, automatic: true),
        "P7R5 C1 automatic triggers are allowed immediately after convergence")
_ = p7r5C1Controller.finish(.cancelled, now: 9)
let p7r5C1Confidence = PriorMapConfidenceManager()
p7r5C1Confidence.reset()
let p7r5C1Converged = p7r5C1Confidence.update(
    timestamp: 20,
    observation: PriorMapConfidenceObservation(
        trackingState: "normal",
        measurementAccepted: true,
        correctionStepApplied: true,
        recoveryActive: false,
        recoveryConvergedThisUpdate: true,
        recoveryFailedThisUpdate: false,
        validPointCount: 120,
        coverageAngleRad: 1.4,
        uniqueness: 0.5,
        residualCost: 0.01,
        mapMismatch: false))
require(p7r5C1Converged.phase == .usable,
        "P7R5 C1 a cleared-cooldown convergence stays usable")
for timestamp in 21...22 {
    let result = p7r5C1Confidence.update(
        timestamp: Double(timestamp), observation: trustedLocalObservation())
    require(result.phase != .weak,
            "P7R5 C1 a cleared cooldown must not force Local frames weak")
}
let p7r5C1Stable = p7r5C1Confidence.update(
    timestamp: 23, observation: trustedLocalObservation())
require(p7r5C1Stable.phase == .stable,
        "P7R5 C1 three Local frames restore stable after the cooldown clear")

// C2: a reliable-loop timeout also extends the cooldown, measured from the
// second failure, regardless of how the episode was triggered.
let p7r5C2Controller = PriorMapRecoveryController(
    maximumValidAttempts: 40,
    maximumWallClockSeconds: 30)
_ = p7r5C2Controller.request(
    reason: "persistent_weak_or_lost", now: 100, automatic: true)
_ = p7r5C2Controller.finish(.timedOut, now: 105)
require(!p7r5C2Controller.request(
    reason: "persistent_weak_or_lost", now: 110, automatic: true),
        "P7R5 C2 first timeout suppresses automatic retries")
require(p7r5C2Controller.request(reason: "reliable_rtabmap_loop", now: 110),
        "P7R5 C2 reliable loop bypasses the first cooldown")
_ = p7r5C2Controller.finish(.timedOut, now: 112)
require(p7r5C2Controller.nextAutomaticRecoveryAllowedAt == 132,
        "P7R5 C2 a reliable-loop timeout extends cooldown from its own finish")
require(!p7r5C2Controller.request(
    reason: "persistent_weak_or_lost", now: 131, automatic: true),
        "P7R5 C2 automatic retry stays suppressed before the second expiry")
require(p7r5C2Controller.request(
    reason: "persistent_weak_or_lost", now: 132, automatic: true),
        "P7R5 C2 automatic retry allowed exactly at the second expiry")
_ = p7r5C2Controller.finish(.cancelled, now: 132)

// C3: a successful Recovery clears the cooldown exactly at convergence.
let p7r5C3Controller = PriorMapRecoveryController()
_ = p7r5C3Controller.request(
    reason: "persistent_weak_or_lost", now: 0, automatic: true)
_ = p7r5C3Controller.finish(.timedOut, now: 10)
require(p7r5C3Controller.nextAutomaticRecoveryAllowedAt == 30,
        "P7R5 C3 timeout must set the 20 second cooldown")
_ = p7r5C3Controller.request(reason: "reliable_rtabmap_loop", now: 11)
_ = p7r5C3Controller.finish(.converged, now: 12)
require(p7r5C3Controller.nextAutomaticRecoveryAllowedAt == 0,
        "P7R5 C3 convergence clears the cooldown exactly at completion")

// C4: a manual correction clears the cooldown.
let p7r5C4Controller = PriorMapRecoveryController()
_ = p7r5C4Controller.request(
    reason: "persistent_weak_or_lost", now: 0, automatic: true)
_ = p7r5C4Controller.finish(.timedOut, now: 10)
_ = p7r5C4Controller.request(reason: "reliable_rtabmap_loop", now: 11)
_ = p7r5C4Controller.finish(.manualReset, now: 12)
require(p7r5C4Controller.nextAutomaticRecoveryAllowedAt == 0,
        "P7R5 C4 manual reset clears the cooldown")
require(p7r5C4Controller.request(
    reason: "persistent_weak_or_lost", now: 12, automatic: true),
        "P7R5 C4 automatic triggers allowed immediately after manual reset")

// C5 + F-04: a reliable loop bypasses cooldown but never duplicates the
// active episode; repeated triggers retain a bounded source summary.
let p7r5C5Controller = PriorMapRecoveryController()
_ = p7r5C5Controller.request(
    reason: "persistent_weak_or_lost", now: 0, automatic: true)
_ = p7r5C5Controller.finish(.timedOut, now: 5)
require(p7r5C5Controller.request(reason: "reliable_rtabmap_loop", now: 6),
        "P7R5 C5 reliable loop bypasses cooldown")
let p7r5C5EpisodeId = p7r5C5Controller.activeEpisode?.id
require(!p7r5C5Controller.request(reason: "reliable_rtabmap_loop", now: 7),
        "P7R5 C5 repeated triggers must not duplicate the active episode")
require(p7r5C5Controller.activeEpisode?.id == p7r5C5EpisodeId
        && p7r5C5Controller.activeEpisode?.deadlineUptime == 36,
        "P7R5 C5 episode identity and deadline survive repeated triggers")
if let p7r5C5Episode = p7r5C5Controller.activeEpisode {
    require(p7r5C5Episode.triggerCount == 2
            && p7r5C5Episode.automaticTriggerCount == 0
            && p7r5C5Episode.reliableLoopTriggerCount == 2,
            "P7R5 F-04 trigger source counts must be auditable")
    require(p7r5C5Episode.lastTriggerReason == "reliable_rtabmap_loop"
            && p7r5C5Episode.lastTriggerAtUptime == 7,
            "P7R5 F-04 last trigger reason and time must be retained")
    require(p7r5C5Episode.triggerRecords.count == 2
            && p7r5C5Episode.triggerRecords.first?.atUptime == 6
            && p7r5C5Episode.triggerRecords.last?.automatic == false,
            "P7R5 F-04 trigger records must keep ordered source evidence")
}
for index in 0..<12 {
    _ = p7r5C5Controller.request(
        reason: "reliable_rtabmap_loop_\(index)",
        now: 8 + Double(index))
}
if let p7r5C5CappedEpisode = p7r5C5Controller.activeEpisode {
    require(p7r5C5CappedEpisode.triggerRecords.count
                == PriorMapRecoveryEpisode.maximumRetainedTriggerRecords,
            "P7R5 F-04 trigger records must be capped at eight")
    require(p7r5C5CappedEpisode.triggerRecords.last?.reason
                == "reliable_rtabmap_loop_11",
            "P7R5 F-04 the newest trigger must survive record eviction")
    require(p7r5C5CappedEpisode.triggerCount == 14,
            "P7R5 F-04 triggerCount keeps counting beyond the record cap")
}
let p7r5TriggerBoundController = PriorMapRecoveryController(
    maximumTriggerCount: 3)
_ = p7r5TriggerBoundController.request(reason: "initial", now: 0)
for _ in 0..<10 {
    _ = p7r5TriggerBoundController.request(reason: "repeat", now: 1)
}
require(p7r5TriggerBoundController.activeEpisode?.triggerCount == 3,
        "P7R5 F-04 triggerCount must stay bounded by maximumTriggerCount")

// MARK: - P7R5 F-02: cancellations persist terminal evidence and reconcile.

// E1: scan-stop cancellation persists its reason and suppresses automatic
// retry; E2: map unload persists its reason without throttling retries.
let p7r5E1Controller = PriorMapRecoveryController()
_ = p7r5E1Controller.request(
    reason: "persistent_weak_or_lost", now: 0, automatic: true)
let p7r5E1Completion = p7r5E1Controller.finish(
    .cancelled, now: 4, cancellationReason: .scanStopped)
require(p7r5E1Completion?.outcome == .cancelled
        && p7r5E1Completion?.cancellationReason == .scanStopped,
        "P7R5 E1 scan-stop cancellation must persist the terminal reason")
require(p7r5E1Controller.nextAutomaticRecoveryAllowedAt == 24,
        "P7R5 E1 scan-stopped cancellation suppresses automatic retry")
let p7r5E2Controller = PriorMapRecoveryController()
_ = p7r5E2Controller.request(reason: "reliable_rtabmap_loop", now: 0)
let p7r5E2Completion = p7r5E2Controller.finish(
    .cancelled, now: 4, cancellationReason: .mapUnloaded)
require(p7r5E2Completion?.cancellationReason == .mapUnloaded,
        "P7R5 E2 map-unload cancellation must persist the terminal reason")
require(p7r5E2Controller.nextAutomaticRecoveryAllowedAt == 0,
        "P7R5 E2 map unload must not throttle future automatic triggers")

// E4: no active episode means no fake completion.
let p7r5E4Controller = PriorMapRecoveryController()
require(p7r5E4Controller.finish(
    .cancelled, now: 0, cancellationReason: .scanStopped) == nil,
        "P7R5 E4 cancellation without an active episode returns nil")

// Lifecycle record builder: snake_case contract fields and bounded elapsed.
if let p7r5E1Completion {
    let p7r5LifecycleRecord = PriorMapRecoveryLifecycleRecord(
        trackingSessionId: "session-1",
        priorMapId: "map-1",
        priorMapSha256: "sha-1",
        floorId: "1",
        completion: p7r5E1Completion)
    require(p7r5LifecycleRecord.format
                == PriorMapRecoveryLifecycleRecord.formatName
            && p7r5LifecycleRecord.version
                == PriorMapRecoveryLifecycleRecord.formatVersion,
            "P7R5 lifecycle record must carry the current contract identity")
    require(p7r5LifecycleRecord.outcome == "cancelled"
            && p7r5LifecycleRecord.cancellationReason == "scan_stopped",
            "P7R5 lifecycle record must expose terminal outcome and reason")
    require(p7r5LifecycleRecord.elapsedMs == 4000
            && p7r5LifecycleRecord.finishedAtUptime == 4,
            "P7R5 lifecycle elapsed must be bound to the finish time")
    require(p7r5LifecycleRecord.episodeAutomatic
            && p7r5LifecycleRecord.triggerCount == 1
            && p7r5LifecycleRecord.lastTriggerReason
                == "persistent_weak_or_lost",
            "P7R5 lifecycle record must retain the trigger summary")
    if let encoded = try? JSONEncoder().encode(p7r5LifecycleRecord),
       let json = (try? JSONSerialization.jsonObject(with: encoded))
            as? [String: Any] {
        require(json["cancellation_reason"] as? String == "scan_stopped"
                && json["finished_at_uptime"] != nil
                && json["episode_automatic"] as? Bool == true,
                "P7R5 lifecycle record must encode snake_case contract keys")
    }
    else {
        require(false, "P7R5 lifecycle record must encode as JSON")
    }
}

// MARK: - P7R5 F-03: pending completion elapsed binds to finishedAt.
let p7r5F03Controller = PriorMapRecoveryController()
_ = p7r5F03Controller.request(reason: "deadline", now: 100)
let p7r5F03Completion = p7r5F03Controller.finish(.manualReset, now: 110)
if let p7r5F03Completion {
    require(PriorMapRecoveryDiagnostics.elapsedMs(
        episode: p7r5F03Completion.episode,
        completion: p7r5F03Completion,
        now: 200) == 10000,
            "P7R5 F-03 a consumed completion must not extend elapsed time")
    require(PriorMapRecoveryDiagnostics.elapsedMs(
        episode: p7r5F03Completion.episode,
        completion: nil,
        now: 130) == 30000,
            "P7R5 F-03 an active episode still uses the frame clock")
}

// MARK: - P7R6: peek/ack persistence coordinator transactions.

final class P7R6FakeRecoverySource: RecoveryCompletionDraining {
    var pending: [PriorMapRecoveryCompletion] = []
    var cancelledReasons: [PriorMapRecoveryCancellationReason] = []

    func cancelRecovery(
        reason: PriorMapRecoveryCancellationReason,
        now: TimeInterval
    ) -> PriorMapRecoveryCompletion? {
        cancelledReasons.append(reason)
        return nil
    }

    func pendingTerminalRecoveryCompletions()
        -> [PriorMapRecoveryCompletion] {
        return pending
    }

    func acknowledgeTerminalRecoveryCompletion(episodeId: Int) {
        pending.removeAll { $0.episode.id == episodeId }
    }

    func discardTerminalRecoveryCompletionsForInvalidatedSession() {
        pending.removeAll()
    }
}

final class P7R6FakeRecoveryWriter: RecoveryLifecycleWriting {
    var appendedEpisodeIds: [Int] = []
    var failingEpisodeIds: Set<Int> = []
    var allowDuringFinalizationValues: [Bool] = []

    func appendRecoveryLifecycleEvent(
        _ completion: PriorMapRecoveryCompletion,
        expectedTrackingSessionId: String,
        allowDuringFinalization: Bool = false
    ) -> Bool {
        guard !failingEpisodeIds.contains(completion.episode.id) else {
            return false
        }
        allowDuringFinalizationValues.append(allowDuringFinalization)
        appendedEpisodeIds.append(completion.episode.id)
        return true
    }
}

let p7r6Controller = PriorMapRecoveryController()
_ = p7r6Controller.request(
    reason: "persistent_weak_or_lost", now: 0, automatic: true)
let p7r6FirstCompletion = p7r6Controller.finish(.converged, now: 1)
_ = p7r6Controller.request(reason: "reliable_rtabmap_loop", now: 30)
let p7r6SecondCompletion = p7r6Controller.finish(.timedOut, now: 31)
require(p7r6FirstCompletion?.episode.id == 1
        && p7r6SecondCompletion?.episode.id == 2,
        "P7R6 coordinator tests require two sequential episodes")
let p7r6FakeSha256 = String(repeating: "b", count: 64)
if let p7r6FirstCompletion, let p7r6SecondCompletion {
    // P7R6B B3: the pending queue carries finish order and is never
    // sorted. A deliberately reversed queue must fail closed with nothing
    // attempted, appended or acknowledged.
    let source = P7R6FakeRecoverySource()
    source.pending = [p7r6SecondCompletion, p7r6FirstCompletion]
    let writer = P7R6FakeRecoveryWriter()
    let coordinator = RecoveryLifecyclePersistenceCoordinator(
        source: source,
        writer: writer,
        trackingSessionId: "session-1",
        priorMapId: "map-1",
        priorMapSha256: p7r6FakeSha256,
        floorId: "1",
        persistedEvidenceSnapshot: { Data() })
    let reversed = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 40)
    require(!reversed.allPersisted
            && reversed.attemptedEpisodeIds.isEmpty
            && reversed.persistedEpisodeIds.isEmpty
            && reversed.failedEpisodeId == 1
            && reversed.failureReason == "pending_episode_order_invalid"
            && writer.appendedEpisodeIds.isEmpty
            && source.pending.map { $0.episode.id } == [2, 1],
            "P7R6B a reversed pending queue must fail closed without sorting")

    // A correctly ordered queue persists in finish order.
    source.pending = [p7r6FirstCompletion, p7r6SecondCompletion]
    let success = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 41)
    require(success.allPersisted
            && success.attemptedEpisodeIds == [1, 2]
            && success.persistedEpisodeIds == [1, 2]
            && writer.appendedEpisodeIds == [1, 2],
            "P7R6 the coordinator must persist episodes in finish order")
    require(source.pending.isEmpty,
            "P7R6 every persisted episode must be acknowledged")

    // Cancellation pass-through.
    _ = coordinator.persistTerminalEvidence(
        cancellationReason: .scanStopped, now: 42)
    require(source.cancelledReasons == [.scanStopped],
            "P7R6 teardown cancellation must run before peeking")

    // A failed append stops the transaction and keeps state retryable.
    source.pending = [p7r6FirstCompletion, p7r6SecondCompletion]
    writer.failingEpisodeIds = [2]
    let failure = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 50)
    require(!failure.allPersisted
            && failure.failedEpisodeId == 2
            && failure.failureReason == "durable_append_failed"
            && failure.persistedEpisodeIds == [1],
            "P7R6 the coordinator must stop at the first failed episode")
    require(source.pending.map { $0.episode.id } == [2],
            "P7R6 a failed episode must stay queued for retry")

    // Retry persists the failed episode exactly once.
    writer.failingEpisodeIds = []
    let appendedBeforeRetry = writer.appendedEpisodeIds.count
    let retry = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 60)
    require(retry.allPersisted
            && writer.appendedEpisodeIds.count == appendedBeforeRetry + 1
            && writer.appendedEpisodeIds.last == 2
            && source.pending.isEmpty,
            "P7R6 retry must persist the failed episode exactly once")

    // Idempotence strategy A: identical persisted canonical bytes count as
    // success without rewriting; conflicting bytes fail closed.
    let persistedRecord = PriorMapRecoveryLifecycleRecord(
        trackingSessionId: "session-1",
        priorMapId: "map-1",
        priorMapSha256: p7r6FakeSha256,
        floorId: "1",
        completion: p7r6FirstCompletion)
    let persistedEncoder = JSONEncoder()
    persistedEncoder.outputFormatting = [.sortedKeys]
    let persistedRecordData = try persistedEncoder.encode(persistedRecord)
    var persistedLine = persistedRecordData
    persistedLine.append(0x0A)
    let idempotentSource = P7R6FakeRecoverySource()
    idempotentSource.pending = [p7r6FirstCompletion]
    let idempotentWriter = P7R6FakeRecoveryWriter()
    let idempotentCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: idempotentSource,
        writer: idempotentWriter,
        trackingSessionId: "session-1",
        priorMapId: "map-1",
        priorMapSha256: p7r6FakeSha256,
        floorId: "1",
        persistedEvidenceSnapshot: { persistedLine })
    let idempotent = idempotentCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 70)
    require(idempotent.allPersisted
            && idempotentWriter.appendedEpisodeIds.isEmpty
            && idempotentSource.pending.isEmpty,
            "P7R6 identical persisted bytes must ack without rewriting")
    // Same episode identity but different terminal content: the canonical
    // bytes disagree, so the transaction must fail closed.
    var conflictingObject = try JSONSerialization.jsonObject(
        with: persistedRecordData) as! [String: Any]
    conflictingObject["outcome"] = "timed_out"
    var conflictingLine = try JSONSerialization.data(
        withJSONObject: conflictingObject)
    conflictingLine.append(0x0A)
    let conflictSource = P7R6FakeRecoverySource()
    conflictSource.pending = [p7r6FirstCompletion]
    let conflictWriter = P7R6FakeRecoveryWriter()
    let conflictCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: conflictSource,
        writer: conflictWriter,
        trackingSessionId: "session-1",
        priorMapId: "map-1",
        priorMapSha256: p7r6FakeSha256,
        floorId: "1",
        persistedEvidenceSnapshot: { conflictingLine })
    let conflict = conflictCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 80)
    require(!conflict.allPersisted
            && conflict.failureReason == "persisted_episode_bytes_conflict"
            && conflictWriter.appendedEpisodeIds.isEmpty
            && conflictSource.pending.map { $0.episode.id } == [1],
            "P7R6 conflicting persisted bytes must fail closed")

    // Invalidated sessions drop queued completions.
    let discardSource = P7R6FakeRecoverySource()
    discardSource.pending = [p7r6FirstCompletion, p7r6SecondCompletion]
    discardSource.discardTerminalRecoveryCompletionsForInvalidatedSession()
    require(discardSource.pending.isEmpty,
            "P7R6 invalidated sessions must discard queued completions")
}

// P7R6 W1-W11 / I1-I15: executable teardown-to-finalization transactions.
// The Swift host cannot link the UIKit session types, so these tests run the
// exact production persistence chain on a real file system: controller ->
// peek/ack coordinator -> durable sidecar writer -> finalization validator.
func makePositions(_ count: Int) -> [FinalTrajectory.DevicePositionRow] {
    var positions: [FinalTrajectory.DevicePositionRow] = []
    for index in 0..<count {
        positions.append(FinalTrajectory.DevicePositionRow(
            sequence: index + 1,
            localTimestamp: "2026-08-05 21:00:00.000 +08:00",
            utcTimestamp: "2026-08-05T13:00:00.000Z",
            unixTimeS: 1_785_762_000 + Int64(index),
            timezoneID: "Asia/Shanghai", utcOffset: 28_800,
            sessionElapsedS: Double(index), storeID: "s1", floorID: "1",
            mapXM: 1.5, mapYM: -2.5, yawDeg: 90.0,
            positionStatus: "AVAILABLE", positionSource: "final_trajectory",
            beforeNodeID: Int64(index), afterNodeID: Int64(index + 1),
            interpolationRatio: 0.5, localizationConfidence: 0.9,
            estimatedUncertaintyM: 0.05, trackingState: "tracking",
            graphQualityStatus: "connected", priorMapID: "m",
            priorMapSha256: "a", trackingSessionID: "s", appGitSHA: "g"))
    }
    return positions
}
func makeInput(positions: [FinalTrajectory.DevicePositionRow]) -> MobileResultExporter.Input {
    return MobileResultExporter.Input(
        devicePositions: positions,
        priceTags: [
            FinalPriceTag(
                tagInstanceID: "t1", barcode: "=HYPERLINK(\"x\")", symbology: "CODE128",
                storeID: "s1", floorID: "1", mapVersion: 1,
                priorMapSha256: "a", trackingSessionID: "s",
                shelfCode: "A1", shelfSegmentID: "segment-a1-main",
                shelfSide: "front",
                distanceFromShelfStartCm: 123.4, positionRatio: 0.62,
                mapXM: 1.5, mapYM: -2.5, observationCount: 12,
                positionSpreadCm: 3.2, localizationConfidence: 0.95,
                associationConfidence: 0.9, qualityStatus: "ACCEPTED", reason: ""),
        ],
        rescanTasks: [
            RescanTask(taskID: "r1", taskType: .tagRescan, floorID: "1",
                       barcode: "123", tagInstanceID: "t2", shelfCode: "B2",
                       shelfSegmentID: "segment-b2-main",
                       regionStartCm: 10, regionEndCm: 40,
                       localStartTime: "2026-08-05 21:00:00.000 +08:00",
                       localEndTime: "2026-08-05 21:00:05.000 +08:00",
                       reasonCode: "position_spread", humanMessage: "位置分散",
                       suggestedAction: "重新扫描", priority: 1),
        ],
        runSummary: ["app_git_sha": "g", "store_id": "s1"],
        appGitSHA: "g", appVersion: "1.0", deviceModel: "iPhone",
        osVersion: "iOS 18")
}

func p7r6FreshDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "p7r6-\(label)-\(UUID().uuidString)",
            isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    return directory
}

func p7r6WriteBaseBundle(
    in directory: URL,
    createRecoveryFile: Bool = true
) throws -> URL {
    try evidenceRecord(format: "MarketScannerLocalizationTrace")
        .write(to: directory.appendingPathComponent("localization_trace.jsonl"))
    try evidenceRecord(format: "MarketScannerLocalizationConstraint")
        .write(to: directory.appendingPathComponent(
            "localization_constraints.jsonl"))
    try evidenceRecord(
        format: "MarketScannerLocalizationStateEvent",
        state: "stable")
        .write(to: directory.appendingPathComponent("localization_events.jsonl"))
    try Data().write(to: directory.appendingPathComponent(
        "manual_localization_events.jsonl"))
    try Data().write(to: directory.appendingPathComponent(
        "tag_observations.jsonl"))
    try Data().write(to: directory.appendingPathComponent(
        "tag_observation_bursts.jsonl"))
    try Data("[]".utf8).write(to: directory.appendingPathComponent(
        "localized_price_tags.json"))
    let recoveryURL = directory.appendingPathComponent(
        PriorMapRecoveryLifecycleRecord.fileName)
    if createRecoveryFile {
        try Data().write(to: recoveryURL)
    }
    return recoveryURL
}

func p7r6BundleExpectation(
    recoveryCount: Int,
    lastEpisodeId: Int? = nil,
    lastFinishedAtUptime: TimeInterval? = nil,
    localizedPriceTagCount: Int = 0,
    tagBurstCount: Int = 0,
    tagBurstLastID: String? = nil,
    tagBurstComplete: Bool = true
) -> LocalizationEvidenceBundleExpectation {
    return LocalizationEvidenceBundleExpectation(
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: String(repeating: "a", count: 64),
        floorId: "1",
        traceRecordCount: 1,
        constraintRecordCount: 1,
        stateEventCount: 1,
        lastDurableState: "stable",
        localizedPriceTagCount: localizedPriceTagCount,
        recoveryEventCount: recoveryCount,
        lastRecoveryEpisodeId: lastEpisodeId,
        lastRecoveryFinishedAtUptime: lastFinishedAtUptime,
        tagBurstCount: tagBurstCount,
        tagBurstLastID: tagBurstLastID,
        tagBurstComplete: tagBurstComplete)
}

func p7r6JSONLine(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys])
    data.append(0x0A)
    return data
}

func p7r6WriteTagBurstBindingFixture(
    in directory: URL,
    observationFrameID: String = "frame-1",
    includeUnlistedBoundObservation: Bool = false
) throws {
    let observation: [String: Any] = [
        "format": "MarketScannerPriceTagObservation",
        "version": 1,
        "observation_id": "obs-1",
        "timestamp": 100.0,
        "payload": "6901234567890",
        "symbology": "EAN13",
        "frame_timestamp": 100.0,
        "node_timebase_frame_timestamp": 100.0,
        "node_timebase_offset_seconds": 0.0,
        "raw_map_position": ["x_m": 1.0, "y_m": 2.0],
        "tracking_session_id": "session-a",
        "prior_map_id": "map-a",
        "prior_map_sha256": p7r6aIdentitySha(),
        "floor_id": "1",
        "burst_id": "burst-1",
        "frame_id": observationFrameID,
    ]
    let frame: [String: Any] = [
        "frame_id": "frame-1",
        "observation_id": "obs-1",
        "bound_node_id": 1,
        "frame_timestamp": 100.0,
        "node_timestamp": 100.0,
        "depth": 0.9,
        "view": "front",
        "tracking": "stable",
        "confidence": 0.9,
    ]
    let burst: [String: Any] = [
        "format": "MarketScannerPriceTagBurst",
        "version": 2,
        "burst_id": "burst-1",
        "sequence": 1,
        "barcode": "6901234567890",
        "symbology": "EAN13",
        "tracking_session_id": "session-a",
        "prior_map_id": "map-a",
        "prior_map_sha256": p7r6aIdentitySha(),
        "floor_id": "1",
        "frame_count": 1,
        "first_frame_timestamp": 100.0,
        "last_frame_timestamp": 100.0,
        "bound_node_id_min": 1,
        "bound_node_id_max": 1,
        "depth_quality": 0.9,
        "view_angle": "front",
        "tracking_quality": "stable",
        "localization_confidence_mean": 0.9,
        "complete": true,
        "frames": [frame],
    ]
    var observationData = try p7r6JSONLine(observation)
    if includeUnlistedBoundObservation {
        var extraObservation = observation
        extraObservation["observation_id"] = "obs-extra"
        extraObservation["timestamp"] = 101.0
        extraObservation["frame_timestamp"] = 101.0
        extraObservation["node_timebase_frame_timestamp"] = 101.0
        extraObservation["frame_id"] = "frame-extra"
        observationData.append(try p7r6JSONLine(extraObservation))
    }
    try observationData.write(
        to: directory.appendingPathComponent("tag_observations.jsonl"))
    try p7r6JSONLine(burst).write(
        to: directory.appendingPathComponent("tag_observation_bursts.jsonl"))
}

func p7r6WriteBurstSequenceFixture(
    in directory: URL,
    sequences: [Int]
) throws -> String? {
    var observations = Data()
    var bursts = Data()
    for (index, sequence) in sequences.enumerated() {
        let suffix = index + 1
        let burstID = "sequence-burst-\(suffix)"
        let observationID = "sequence-observation-\(suffix)"
        let frameID = "sequence-frame-\(suffix)"
        let timestamp = 100.0 + Double(index)
        observations.append(try p7r6JSONLine([
            "format": "MarketScannerPriceTagObservation",
            "version": 1,
            "observation_id": observationID,
            "timestamp": timestamp,
            "payload": "PAYLOAD-\(suffix)",
            "symbology": "EAN13",
            "frame_timestamp": timestamp,
            "node_timebase_frame_timestamp": timestamp,
            "node_timebase_offset_seconds": 0.0,
            "raw_map_position": ["x_m": 1.0, "y_m": 2.0],
            "tracking_session_id": "session-a",
            "prior_map_id": "map-a",
            "prior_map_sha256": p7r6aIdentitySha(),
            "floor_id": "1",
            "burst_id": burstID,
            "frame_id": frameID,
        ]))
        bursts.append(try p7r6JSONLine([
            "format": "MarketScannerPriceTagBurst",
            "version": 2,
            "burst_id": burstID,
            "sequence": sequence,
            "barcode": "PAYLOAD-\(suffix)",
            "symbology": "EAN13",
            "tracking_session_id": "session-a",
            "prior_map_id": "map-a",
            "prior_map_sha256": p7r6aIdentitySha(),
            "floor_id": "1",
            "frame_count": 1,
            "first_frame_timestamp": timestamp,
            "last_frame_timestamp": timestamp,
            "bound_node_id_min": suffix,
            "bound_node_id_max": suffix,
            "depth_quality": 0.9,
            "view_angle": "front",
            "tracking_quality": "stable",
            "localization_confidence_mean": 0.9,
            "complete": true,
            "frames": [[
                "frame_id": frameID,
                "observation_id": observationID,
                "bound_node_id": suffix,
                "frame_timestamp": timestamp,
                "node_timestamp": timestamp,
                "depth": 0.9,
                "view": "front",
                "tracking": "stable",
                "confidence": 0.9,
            ]],
        ]))
    }
    try observations.write(
        to: directory.appendingPathComponent("tag_observations.jsonl"))
    try bursts.write(
        to: directory.appendingPathComponent("tag_observation_bursts.jsonl"))
    return sequences.indices.last.map { "sequence-burst-\($0 + 1)" }
}

func p7r6WriteConfirmedTagBurstFixture(
    in directory: URL,
    tagPayload: String = "6901234567890",
    tagSymbology: String = "EAN13"
) throws -> String {
    let captureID = UUID().uuidString.lowercased()
    let observationIDs = ["confirmed-obs-1", "confirmed-obs-2", "confirmed-obs-3"]
    var observations = Data()
    var frames: [[String: Any]] = []
    for (index, observationID) in observationIDs.enumerated() {
        let timestamp = 200.0 + Double(index) * 0.2
        let frameID = "confirmed-frame-\(index + 1)"
        observations.append(try p7r6JSONLine([
            "format": "MarketScannerPriceTagObservation",
            "version": 1,
            "observation_id": observationID,
            "timestamp": timestamp,
            "payload": "6901234567890",
            "symbology": "EAN13",
            "frame_timestamp": timestamp,
            "node_timebase_frame_timestamp": timestamp,
            "node_timebase_offset_seconds": 0.0,
            "raw_map_position": [
                "x_m": 1.0,
                "y_m": 2.0,
                "height_m": 1.2,
            ],
            "tracking_session_id": "session-a",
            "prior_map_id": "map-a",
            "prior_map_sha256": p7r6aIdentitySha(),
            "floor_id": "1",
            "burst_id": captureID,
            "frame_id": frameID,
        ]))
        frames.append([
            "frame_id": frameID,
            "observation_id": observationID,
            "bound_node_id": index + 1,
            "frame_timestamp": timestamp,
            "node_timestamp": timestamp,
            "depth": 0.9,
            "view": "front",
            "tracking": "stable",
            "confidence": 0.9,
        ])
    }
    let burst = try p7r6JSONLine([
        "format": "MarketScannerPriceTagBurst",
        "version": 2,
        "burst_id": captureID,
        "sequence": 1,
        "barcode": "6901234567890",
        "symbology": "EAN13",
        "tracking_session_id": "session-a",
        "prior_map_id": "map-a",
        "prior_map_sha256": p7r6aIdentitySha(),
        "floor_id": "1",
        "frame_count": 3,
        "first_frame_timestamp": 200.0,
        "last_frame_timestamp": 200.4,
        "bound_node_id_min": 1,
        "bound_node_id_max": 3,
        "depth_quality": 0.9,
        "view_angle": "front",
        "tracking_quality": "stable",
        "localization_confidence_mean": 0.9,
        "complete": true,
        "frames": frames,
    ])
    let tag: [String: Any] = [
        "format": "MarketScannerLocalizedPriceTag",
        "version": 2,
        "tag_id": "confirmed-tag-1",
        "observation_id": observationIDs[0],
        "payload": tagPayload,
        "symbology": tagSymbology,
        "floor_id": "1",
        "timestamp": 200.0,
        "tracking_session_id": "session-a",
        "prior_map_id": "map-a",
        "prior_map_sha256": p7r6aIdentitySha(),
        "shelf_segment_id": "shelf-1",
        "shelf_code": "S1",
        "shelf_side": "L",
        "distance_from_shelf_start_cm": 120.0,
        "height_cm": 120.0,
        "raw_map_position": [
            "x_m": 1.0,
            "y_m": 2.0,
            "height_m": 1.2,
        ],
        "snapped_map_position": [
            "x_m": 1.0,
            "y_m": 2.0,
            "height_m": 1.2,
        ],
        "localization_confidence": 0.9,
        "measurement_confidence": 0.9,
        "association_confidence": 0.9,
        "measurement_method": "scene_depth",
        "needs_review": false,
        "user_confirmed": true,
        "capture_id": captureID,
        "frame_observation_ids": observationIDs,
        "algorithm_shelf_segment_id": "shelf-1",
        "algorithm_shelf_code": "S1",
        "algorithm_side": "L",
        "algorithm_distance_from_shelf_start_cm": 120.0,
        "algorithm_association_confidence": 0.9,
        "confirmation_status": "USER_CONFIRMED",
        "user_confirmed_shelf_segment_id": "shelf-1",
        "user_confirmed_shelf_code": "S1",
        "user_confirmed_side": "L",
        "user_confirmed_distance_from_shelf_start_cm": 120.0,
        "confirmed_at_utc": 1_700_000_000.0,
        "confirmed_at_monotonic": 20.0,
        "confirmation_source": "on_device_operator",
    ]
    try observations.write(
        to: directory.appendingPathComponent("tag_observations.jsonl"))
    try burst.write(
        to: directory.appendingPathComponent("tag_observation_bursts.jsonl"))
    try JSONSerialization.data(
        withJSONObject: [tag],
        options: [.sortedKeys]).write(
            to: directory.appendingPathComponent("localized_price_tags.json"))
    return captureID
}

func p7r6WriteV2LocalizedTagFixture(
    in directory: URL,
    mutateTag: (inout [String: Any]) -> Void = { _ in }
) throws {
    let captureID = "12345678-1234-4234-8234-123456789abc"
    var observationData = Data()
    var frames: [[String: Any]] = []
    var observationIDs: [String] = []
    for index in 1...3 {
        let observationID = "obs-\(index)"
        let frameID = "frame-\(index)"
        let timestamp = 99.0 + Double(index)
        observationIDs.append(observationID)
        observationData.append(try p7r6JSONLine([
            "format": "MarketScannerPriceTagObservation",
            "version": 1,
            "observation_id": observationID,
            "timestamp": timestamp,
            "payload": "6901234567890",
            "symbology": "EAN13",
            "frame_timestamp": timestamp,
            "node_timebase_frame_timestamp": timestamp,
            "node_timebase_offset_seconds": 0.0,
            "raw_map_position": ["x_m": 1.0, "y_m": 2.0],
            "tracking_session_id": "session-a",
            "prior_map_id": "map-a",
            "prior_map_sha256": p7r6aIdentitySha(),
            "floor_id": "1",
            "burst_id": captureID,
            "frame_id": frameID,
        ]))
        frames.append([
            "frame_id": frameID,
            "observation_id": observationID,
            "bound_node_id": 1,
            "frame_timestamp": timestamp,
            "node_timestamp": timestamp,
            "depth": 0.9,
            "view": "front",
            "tracking": "stable",
            "confidence": 0.9,
        ])
    }
    let burst: [String: Any] = [
        "format": "MarketScannerPriceTagBurst",
        "version": 2,
        "burst_id": captureID,
        "sequence": 1,
        "barcode": "6901234567890",
        "symbology": "EAN13",
        "tracking_session_id": "session-a",
        "prior_map_id": "map-a",
        "prior_map_sha256": p7r6aIdentitySha(),
        "floor_id": "1",
        "frame_count": 3,
        "first_frame_timestamp": 100.0,
        "last_frame_timestamp": 102.0,
        "bound_node_id_min": 1,
        "bound_node_id_max": 1,
        "depth_quality": 0.9,
        "view_angle": "front",
        "tracking_quality": "stable",
        "localization_confidence_mean": 0.9,
        "complete": true,
        "frames": frames,
    ]
    var tag: [String: Any] = [
        "format": "MarketScannerLocalizedPriceTag",
        "version": 2,
        "tag_id": "tag-1",
        "observation_id": "obs-1",
        "payload": "6901234567890",
        "symbology": "EAN13",
        "floor_id": "1",
        "timestamp": 100.0,
        "tracking_session_id": "session-a",
        "prior_map_id": "map-a",
        "prior_map_sha256": p7r6aIdentitySha(),
        "shelf_segment_id": "shelf-A",
        "shelf_code": "A-01",
        "shelf_side": "A",
        "distance_from_shelf_start_cm": 120.0,
        "raw_map_position": ["x_m": 1.0, "y_m": 2.0],
        "snapped_map_position": ["x_m": 1.0, "y_m": 1.9],
        "localization_confidence": 0.9,
        "measurement_confidence": 0.9,
        "association_confidence": 0.8,
        "measurement_method": "scene_depth",
        "needs_review": false,
        "user_confirmed": true,
        "capture_id": captureID,
        "frame_observation_ids": observationIDs,
        "algorithm_shelf_segment_id": "shelf-A",
        "algorithm_shelf_code": "A-01",
        "algorithm_side": "A",
        "algorithm_distance_from_shelf_start_cm": 120.0,
        "algorithm_association_confidence": 0.8,
        "confirmation_status": "USER_CONFIRMED",
        "user_confirmed_shelf_segment_id": "shelf-A",
        "user_confirmed_shelf_code": "A-01",
        "user_confirmed_side": "A",
        "user_confirmed_distance_from_shelf_start_cm": 120.0,
        "confirmed_at_utc": 1_700_000_000.0,
        "confirmed_at_monotonic": 123.0,
        "confirmation_source": "on_device_operator",
    ]
    mutateTag(&tag)
    try observationData.write(
        to: directory.appendingPathComponent("tag_observations.jsonl"))
    try p7r6JSONLine(burst).write(
        to: directory.appendingPathComponent("tag_observation_bursts.jsonl"))
    try JSONSerialization.data(
        withJSONObject: [tag], options: [.sortedKeys])
        .write(to: directory.appendingPathComponent(
            "localized_price_tags.json"))
}

func p7r6EncodedLifecycleLine(
    _ record: PriorMapRecoveryLifecycleRecord
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    var line = try encoder.encode(record)
    line.append(0x0A)
    return line
}

func p7r6PersistedEvidenceLines(in directory: URL) throws -> [Data] {
    let url = directory.appendingPathComponent(
        PriorMapRecoveryLifecycleRecord.fileName)
    // Mirrors the session snapshot: a missing sidecar is an empty evidence
    // snapshot, not a read failure.
    guard FileManager.default.fileExists(atPath: url.path) else {
        return []
    }
    return try Data(contentsOf: url).split(separator: 0x0A).map { Data($0) }
}

/// P7R6A: mirrors SupermarketScanSession.persistedRecoveryLifecycleSnapshot.
/// One stable read of the whole file; a missing sidecar is an empty
/// snapshot. Line splitting and JSONL semantics belong to the parser.
func p7r6PersistedEvidenceSnapshot(in directory: URL) throws -> Data {
    let url = directory.appendingPathComponent(
        PriorMapRecoveryLifecycleRecord.fileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return Data()
    }
    return try Data(contentsOf: url)
}

func p7r6LifecycleObjects(in directory: URL) throws -> [[String: Any]] {
    return try p7r6PersistedEvidenceLines(in: directory).map { line in
        guard let object = try JSONSerialization.jsonObject(with: line)
            as? [String: Any] else {
            throw NSError(domain: "P7R6Tests", code: 1)
        }
        return object
    }
}

/// Durable Recovery lifecycle writer mirroring SupermarketScanSession:
/// session identity gate -> strict record validation -> sortedKeys JSONL
/// append -> watermark advance only after the durable write, otherwise a
/// counted required-write failure.
final class P7R6DurableRecoveryWriter: RecoveryLifecycleWriting {
    let directory: URL
    let trackingSessionId: String
    private let sidecarWriter: FoundationScanSidecarWriter
    private(set) var localizationRecoveryEventCount = 0
    private(set) var lastRecoveryEpisodeId: Int?
    private(set) var lastRecoveryFinishedAtUptime: TimeInterval?
    private(set) var requiredWriteFailureCount = 0

    init(
        directory: URL,
        trackingSessionId: String,
        sidecarWriter: FoundationScanSidecarWriter
    ) {
        self.directory = directory
        self.trackingSessionId = trackingSessionId
        self.sidecarWriter = sidecarWriter
    }

    var recoveryURL: URL {
        return directory.appendingPathComponent(
            PriorMapRecoveryLifecycleRecord.fileName)
    }

    func appendRecoveryLifecycleEvent(
        _ completion: PriorMapRecoveryCompletion,
        expectedTrackingSessionId: String,
        allowDuringFinalization: Bool = false
    ) -> Bool {
        guard expectedTrackingSessionId == trackingSessionId,
              completion.episode.startedAtUptime.isFinite,
              completion.finishedAtUptime.isFinite,
              completion.finishedAtUptime
                  >= completion.episode.startedAtUptime,
              !completion.episode.reason.isEmpty,
              !completion.episode.lastTriggerReason.isEmpty,
              completion.episode.triggerCount >= 1 else {
            requiredWriteFailureCount += 1
            return false
        }
        let record = PriorMapRecoveryLifecycleRecord(
            trackingSessionId: trackingSessionId,
            priorMapId: "map-a",
            priorMapSha256: String(repeating: "a", count: 64),
            floorId: "1",
            completion: completion)
        do {
            try sidecarWriter.append(
                try p7r6EncodedLifecycleLine(record),
                to: recoveryURL)
        }
        catch {
            requiredWriteFailureCount += 1
            return false
        }
        localizationRecoveryEventCount += 1
        lastRecoveryEpisodeId = completion.episode.id
        lastRecoveryFinishedAtUptime = completion.finishedAtUptime
        return true
    }

    /// Mirrors the session's manual-localization append on reset.
    func appendManualLocalizationLine(_ data: Data) throws {
        try sidecarWriter.append(
            data,
            to: directory.appendingPathComponent(
                "manual_localization_events.jsonl"))
    }
}

/// Peek/ack source mirroring the localizer: teardown cancellation finishes
/// the active episode into the queue; completions stay queued until acked.
final class P7R6BundleSource: RecoveryCompletionDraining {
    let controller: PriorMapRecoveryController
    var pending: [PriorMapRecoveryCompletion] = []

    init(controller: PriorMapRecoveryController) {
        self.controller = controller
    }

    func cancelRecovery(
        reason: PriorMapRecoveryCancellationReason,
        now: TimeInterval
    ) -> PriorMapRecoveryCompletion? {
        guard let completion = controller.finish(
            .cancelled,
            now: now,
            cancellationReason: reason) else {
            return nil
        }
        pending.append(completion)
        return completion
    }

    func pendingTerminalRecoveryCompletions()
        -> [PriorMapRecoveryCompletion] {
        return pending
    }

    func acknowledgeTerminalRecoveryCompletion(episodeId: Int) {
        pending.removeAll { $0.episode.id == episodeId }
    }

    func discardTerminalRecoveryCompletionsForInvalidatedSession() {
        pending.removeAll()
    }
}

func p7r6Coordinator(
    source: RecoveryCompletionDraining,
    writer: RecoveryLifecycleWriting,
    trackingSessionId: String = "session-a",
    persistedEvidenceSnapshot: @escaping () throws -> Data
) -> RecoveryLifecyclePersistenceCoordinator {
    return RecoveryLifecyclePersistenceCoordinator(
        source: source,
        writer: writer,
        trackingSessionId: trackingSessionId,
        priorMapId: "map-a",
        priorMapSha256: String(repeating: "a", count: 64),
        floorId: "1",
        persistedEvidenceSnapshot: persistedEvidenceSnapshot)
}

// W1: expected watermark 0 with an empty sidecar validates.
do {
    let directory = try p7r6FreshDirectory("w1")
    _ = try p7r6WriteBaseBundle(in: directory)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(recoveryCount: 0)).isEmpty,
        "W1 expected 0 + empty file must validate")
}

// W2: expected watermark 1 with one valid record validates.
do {
    let directory = try p7r6FreshDirectory("w2")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    try recoveryLifecycleData.write(to: recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).isEmpty,
        "W2 expected 1 + one valid record must validate")
}

// W3/W4: exact-count watermark mismatches fail closed.
do {
    let directory = try p7r6FreshDirectory("w3")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).contains {
                    $0.contains("localization_recovery_events.jsonl_empty")
                },
        "W3 expected 1 + empty file must fail closed")
    try recoveryLifecycleData.write(to: recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 2,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).contains {
                    $0.contains("localization_recovery_events.jsonl_count_mismatch")
                },
        "W4 expected 2 + one record must fail count_mismatch")
}

// W5: a deleted sidecar fails closed and is never rebuilt silently.
do {
    let directory = try p7r6FreshDirectory("w5")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    try FileManager.default.removeItem(at: recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).contains {
                    $0.contains("localization_recovery_events.jsonl")
                },
        "W5 a deleted recovery sidecar must fail validation")
}

// W6: finalization must not mask a lost watermark by rebuilding an empty
// file. The session policy only creates the sidecar while zero episodes are
// expected; otherwise the missing file stays a blocker.
do {
    let directory = try p7r6FreshDirectory("w6")
    let recoveryURL = try p7r6WriteBaseBundle(
        in: directory,
        createRecoveryFile: false)
    let expectedRecoveryEventCount = 1
    var finalizationBlockers: [String] = []
    if !FileManager.default.fileExists(atPath: recoveryURL.path) {
        if expectedRecoveryEventCount == 0 {
            try Data().write(to: recoveryURL)
        }
        else {
            finalizationBlockers.append(
                "evidence_bundle_recovery_file_missing_blocker")
        }
    }
    finalizationBlockers += LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(
            recoveryCount: expectedRecoveryEventCount,
            lastEpisodeId: 1,
            lastFinishedAtUptime: 14.5))
    require(
        finalizationBlockers.contains(
            "evidence_bundle_recovery_file_missing_blocker")
            && finalizationBlockers.contains {
                $0.contains("localization_recovery_events.jsonl")
            },
        "W6 rebuilding lost recovery evidence as an empty file must stay"
            + " blocked: \(finalizationBlockers)")
}

// W7: a partial final line fails closed.
do {
    let directory = try p7r6FreshDirectory("w7")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    var partial = recoveryLifecycleData
    partial.append(contentsOf: Data("{\"format\":\"MarketSc".utf8))
    try partial.write(to: recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).contains {
                    $0.contains("invalid_utf8_or_partial_line")
                },
        "W7 a partial final line must fail closed")
}

// W8: a symlinked sidecar fails the stable-read check.
do {
    let directory = try p7r6FreshDirectory("w8")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    let outside = directory.deletingLastPathComponent()
        .appendingPathComponent("p7r6-w8-target-\(UUID().uuidString).jsonl")
    try recoveryLifecycleData.write(to: outside)
    try FileManager.default.removeItem(at: recoveryURL)
    try FileManager.default.createSymbolicLink(
        at: recoveryURL,
        withDestinationURL: outside)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).contains {
                    $0.contains("localization_recovery_events.jsonl")
                },
        "W8 a symlinked recovery sidecar must fail closed")
    try? FileManager.default.removeItem(at: outside)
}

// W9: a file swapped during the stable read fails closed.
do {
    let directory = try p7r6FreshDirectory("w9")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    try recoveryLifecycleData.write(to: recoveryURL)
    var swapped = false
    var swapObserved = false
    do {
        _ = try SafeSessionPath.streamRegularFile(
            recoveryURL,
            within: directory.deletingLastPathComponent(),
            maximumBytes: 1024 * 1024,
            chunkBytes: 64 * 1024
        ) { _ in
            guard !swapped else { return }
            swapped = true
            try Data("{}".utf8).write(to: recoveryURL)
        }
    }
    catch {
        swapObserved = (error as NSError).localizedDescription
            .contains("stream_file_identity_changed_during_read")
    }
    require(
        swapObserved,
        "W9 a recovery sidecar swapped during read must fail closed")
}

// W10: a successful durable append increments the watermark exactly once
// and the resulting bundle validates against finalization.
do {
    let directory = try p7r6FreshDirectory("w10")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.converged, now: 12)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 13)
    require(
        result.allPersisted
            && writer.localizationRecoveryEventCount == 1
            && writer.requiredWriteFailureCount == 0,
        "W10 a successful append must increment the count exactly once")
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: writer.localizationRecoveryEventCount,
                lastEpisodeId: writer.lastRecoveryEpisodeId,
                lastFinishedAtUptime: writer.lastRecoveryFinishedAtUptime))
            .isEmpty,
        "W10 the appended lifecycle record must validate")
}

// W11: a failed durable append leaves the watermark unchanged and counts a
// required-write failure.
do {
    let directory = try p7r6FreshDirectory("w11")
    // No pre-created sidecar: the first durable append must take the atomic
    // create path so the injected rename fault really fires.
    _ = try p7r6WriteBaseBundle(in: directory, createRecoveryFile: false)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter(atomicWriteFault: {
            stage, _ in
            if stage == .rename {
                throw injectedFailure
            }
        }))
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.converged, now: 12)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 13)
    require(
        !result.allPersisted
            && result.failureReason == "durable_append_failed"
            && writer.localizationRecoveryEventCount == 0
            && writer.requiredWriteFailureCount == 1
            && source.pending.count == 1,
        "W11 a failed append must keep the count and the completion")
}

// I1: scan-stop teardown persists exactly one cancelled record and the
// finalized bundle validates.
do {
    let directory = try p7r6FreshDirectory("i1")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "persistent_weak_or_lost", now: 10, automatic: true)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: .scanStopped, now: 20)
    let records = try p7r6LifecycleObjects(in: directory)
    require(
        result.allPersisted
            && records.count == 1
            && (records[0]["outcome"] as? String) == "cancelled"
            && (records[0]["cancellation_reason"] as? String) == "scan_stopped"
            && writer.localizationRecoveryEventCount == 1
            && source.pending.isEmpty,
        "I1 scan stop must persist one cancelled record: \(records)")
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: writer.lastRecoveryEpisodeId,
                lastFinishedAtUptime: writer.lastRecoveryFinishedAtUptime))
            .isEmpty,
        "I1 the finalized bundle must validate after scan stop")
}

// I2: map-unload teardown persists one cancelled record.
do {
    let directory = try p7r6FreshDirectory("i2")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "persistent_weak_or_lost", now: 10, automatic: true)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: .mapUnloaded, now: 20)
    let records = try p7r6LifecycleObjects(in: directory)
    require(
        result.allPersisted
            && records.count == 1
            && (records[0]["cancellation_reason"] as? String) == "map_unloaded"
            && writer.localizationRecoveryEventCount == 1,
        "I2 map unload must persist one cancelled record: \(records)")
}

// I3: a converged episode persists exactly once with bounded diagnostics.
do {
    let directory = try p7r6FreshDirectory("i3")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.converged, now: 15)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 16)
    let records = try p7r6LifecycleObjects(in: directory)
    require(
        result.allPersisted && records.count == 1,
        "I3 a converged episode must persist exactly one record")
    require(
        (records[0]["outcome"] as? String) == "converged"
            && close(records[0]["elapsed_ms"] as? Double ?? -1, 5000),
        "I3 completion diagnostics must bind to the finish time: \(records)")
    // A repeated transaction must not duplicate the record (strategy A).
    source.pending = controller.lastCompletion.map { [$0] } ?? []
    let repeated = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 17)
    let replayedRecords = try p7r6LifecycleObjects(in: directory)
    require(
        repeated.allPersisted
            && replayedRecords.count == 1
            && source.pending.isEmpty,
        "I3 a replayed converged episode must not duplicate the record")
}

// I4: a timed-out episode persists the timed_out outcome and the cooldown
// summary suppresses the next automatic trigger.
do {
    let directory = try p7r6FreshDirectory("i4")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.timedOut, now: 45)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 46)
    let records = try p7r6LifecycleObjects(in: directory)
    require(
        result.allPersisted
            && records.count == 1
            && (records[0]["outcome"] as? String) == "timed_out",
        "I4 a timed-out episode must persist the timed_out outcome")
    require(
        controller.isAutomaticTriggerSuppressed(now: 50)
            && !controller.request(
                reason: "persistent_weak_or_lost", now: 50, automatic: true),
        "I4 the cooldown summary must suppress the next automatic trigger")
}

// I5: a manual reset persists the lifecycle event and both the manual event
// and the lifecycle record carry the matching session identity.
do {
    let directory = try p7r6FreshDirectory("i5")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "persistent_weak_or_lost", now: 10, automatic: true)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.manualReset, now: 18)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 19)
    // The session also appends the manual localization event on reset.
    var manualLine = try JSONSerialization.data(withJSONObject: [
        "format": "MarketScannerManualLocalizationEvent",
        "version": 3,
        "tracking_session_id": "session-a",
        "episode_id": 1,
        "outcome": "manual_reset",
    ])
    manualLine.append(0x0A)
    try writer.appendManualLocalizationLine(manualLine)
    let lifecycleRecords = try p7r6LifecycleObjects(in: directory)
    let manualRecords = try Data(contentsOf: directory.appendingPathComponent(
        "manual_localization_events.jsonl"))
        .split(separator: 0x0A)
        .compactMap { try? JSONSerialization.jsonObject(with: Data($0))
            as? [String: Any] }
    require(
        result.allPersisted
            && lifecycleRecords.count == 1
            && (lifecycleRecords[0]["outcome"] as? String) == "manual_reset"
            && manualRecords.count == 1,
        "I5 a manual reset must persist the lifecycle event")
    require(
        (lifecycleRecords[0]["tracking_session_id"] as? String)
            == (manualRecords[0]["tracking_session_id"] as? String)
            && (lifecycleRecords[0]["episode_id"] as? Int)
                == (manualRecords[0]["episode_id"] as? Int),
        "I5 the manual event and lifecycle record identities must match")
}

// I6: an injected durable-append fault leaves the queue unacknowledged,
// keeps the watermark, counts a required-write failure, and leaves the
// bundle invalid for finalization.
do {
    let directory = try p7r6FreshDirectory("i6")
    _ = try p7r6WriteBaseBundle(in: directory, createRecoveryFile: false)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "persistent_weak_or_lost", now: 10, automatic: true)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter(atomicWriteFault: {
            stage, _ in
            if stage == .rename {
                throw injectedFailure
            }
        }))
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.converged, now: 12)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 13)
    require(
        !result.allPersisted
            && result.failureReason == "durable_append_failed"
            && source.pending.count == 1
            && writer.localizationRecoveryEventCount == 0
            && writer.requiredWriteFailureCount == 1,
        "I6 an append fault must keep the queue and the watermark")
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 12)).contains {
                    $0.contains("localization_recovery_events.jsonl")
                },
        "I6 a failed append must leave finalization invalid")

    // I7: the retry persists the same episode exactly once.
    let retryWriter = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let retryCoordinator = p7r6Coordinator(
        source: source,
        writer: retryWriter,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let retry = retryCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 14)
    let records = try p7r6LifecycleObjects(in: directory)
    require(
        retry.allPersisted
            && records.count == 1
            && retryWriter.localizationRecoveryEventCount == 1
            && source.pending.isEmpty,
        "I7 the retry must persist the same episode exactly once")
}

// I8: a stale tracking session identity rejects the write without counting.
do {
    let directory = try p7r6FreshDirectory("i8")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "persistent_weak_or_lost", now: 10, automatic: true)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-b",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.converged, now: 12)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 13)
    let staleFileData = try Data(contentsOf: writer.recoveryURL)
    require(
        !result.allPersisted
            && result.failureReason == "durable_append_failed"
            && writer.localizationRecoveryEventCount == 0
            && writer.requiredWriteFailureCount == 1
            && source.pending.count == 1
            && staleFileData.isEmpty,
        "I8 a stale session identity must reject the write")
}

// I9: a generation change discards old completions before they can enter the
// new session.
do {
    let directory = try p7r6FreshDirectory("i9")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "persistent_weak_or_lost", now: 10, automatic: true)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    _ = controller.finish(.converged, now: 12)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    // The session generation changed: queued completions are discarded.
    source.discardTerminalRecoveryCompletionsForInvalidatedSession()
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 13)
    let generationFileData = try Data(contentsOf: writer.recoveryURL)
    require(
        result.allPersisted
            && result.attemptedEpisodeIds.isEmpty
            && writer.localizationRecoveryEventCount == 0
            && generationFileData.isEmpty,
        "I9 a generation change must keep old completions out")
}

// I10: deleting the lifecycle file after the watermark advanced blocks
// finalization.
do {
    let directory = try p7r6FreshDirectory("i10")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    _ = controller.finish(.converged, now: 12)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    _ = coordinator.persistTerminalEvidence(cancellationReason: nil, now: 13)
    require(writer.localizationRecoveryEventCount == 1,
            "I10 requires one persisted episode")
    try FileManager.default.removeItem(at: writer.recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: writer.lastRecoveryEpisodeId,
                lastFinishedAtUptime: writer.lastRecoveryFinishedAtUptime))
            .contains {
                $0.contains("localization_recovery_events.jsonl")
            },
        "I10 deleting the lifecycle file must block finalization")
}

// I11: truncating the final line blocks finalization.
do {
    let directory = try p7r6FreshDirectory("i11")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    try recoveryLifecycleData.write(to: recoveryURL)
    var truncated = recoveryLifecycleData
    truncated.removeLast()
    try truncated.write(to: recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).contains {
                    $0.contains("localization_recovery_events.jsonl")
                },
        "I11 truncating the final line must block finalization")
}

// I12: a duplicated episode line blocks finalization.
do {
    let directory = try p7r6FreshDirectory("i12")
    let recoveryURL = try p7r6WriteBaseBundle(in: directory)
    var duplicated = recoveryLifecycleData
    duplicated.append(recoveryLifecycleData)
    try duplicated.write(to: recoveryURL)
    require(
        !LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 1,
                lastEpisodeId: 1,
                lastFinishedAtUptime: 14.5)).isEmpty,
        "I12 a duplicated episode line must block finalization")
}

// I13: no episodes validate with an empty file and watermark zero.
do {
    let directory = try p7r6FreshDirectory("i13")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: .scanStopped, now: 20)
    require(
        result.allPersisted
            && result.attemptedEpisodeIds.isEmpty
            && writer.localizationRecoveryEventCount == 0,
        "I13 a teardown without episodes must persist nothing")
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(recoveryCount: 0)).isEmpty,
        "I13 no episodes must validate with expected count 0")
}

// I14: pending completions persist on the prior-map queue in strict
// serialized order and none is lost.
do {
    let directory = try p7r6FreshDirectory("i14")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    _ = controller.finish(.converged, now: 11)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 12)
    _ = controller.finish(.timedOut, now: 13)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    // P7R6B: the queue already carries finish order; the coordinator never
    // sorts it, so two serialized transactions on one in-order queue must
    // persist every completion exactly once in that order.
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let queue = DispatchQueue(label: "p7r6.i14.prior-map")
    let group = DispatchGroup()
    queue.async(group: group) {
        _ = coordinator.persistTerminalEvidence(
            cancellationReason: nil, now: 20)
    }
    queue.async(group: group) {
        _ = coordinator.persistTerminalEvidence(
            cancellationReason: nil, now: 21)
    }
    require(
        group.wait(timeout: .now() + 10) == .success,
        "I14 serialized persistence must complete")
    let serializedRecords = try p7r6LifecycleObjects(in: directory)
    require(
        writer.localizationRecoveryEventCount == 2
            && serializedRecords
                .compactMap { $0["episode_id"] as? Int } == [1, 2]
            && source.pending.isEmpty,
        "I14 strict serialized order must persist every completion once")
}

// I15: invoking the teardown coordinator from a wrong queue must not
// deadlock; the coordinator holds no locks so the caller's dispatch policy
// decides ordering.
do {
    let directory = try p7r6FreshDirectory("i15")
    _ = try p7r6WriteBaseBundle(in: directory)
    let controller = PriorMapRecoveryController()
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let source = P7R6BundleSource(controller: controller)
    _ = controller.request(reason: "reliable_rtabmap_loop", now: 10)
    _ = controller.finish(.converged, now: 11)
    if let completion = controller.lastCompletion {
        source.pending.append(completion)
    }
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    let priorMapQueue = DispatchQueue(label: "p7r6.i15.prior-map")
    let wrongQueue = DispatchQueue(label: "p7r6.i15.wrong")
    let done = DispatchSemaphore(value: 0)
    wrongQueue.async {
        _ = coordinator.persistTerminalEvidence(
            cancellationReason: nil, now: 20)
        done.signal()
    }
    require(
        done.wait(timeout: .now() + 10) == .success,
        "I15 a wrong-queue teardown invocation must not deadlock")
    let second = DispatchSemaphore(value: 0)
    priorMapQueue.async {
        _ = coordinator.persistTerminalEvidence(
            cancellationReason: nil, now: 21)
        second.signal()
    }
    require(
        second.wait(timeout: .now() + 10) == .success
            && writer.localizationRecoveryEventCount == 1
            && source.pending.isEmpty,
        "I15 the prior-map queue transaction must still persist exactly once")
}

// P7R6A: attemptedEpisodeIds must list only the episodes the transaction
// actually entered. Pre-transaction failures (identity, snapshot read,
// snapshot parse) happen before any pending episode is attempted and must
// report an empty list instead of disguising the failure as an attempt on
// the first episode.
do {
    func threeEpisodeSource() -> (P7R6FakeRecoverySource,
        [PriorMapRecoveryCompletion]) {
        let controller = PriorMapRecoveryController()
        var completions: [PriorMapRecoveryCompletion] = []
        for index in 0..<3 {
            _ = controller.request(
                reason: "persistent_weak_or_lost",
                now: TimeInterval(index * 10),
                automatic: true)
            if let completion = controller.finish(
                .converged, now: TimeInterval(index * 10 + 1)) {
                completions.append(completion)
            }
        }
        let source = P7R6FakeRecoverySource()
        source.pending = completions
        return (source, completions)
    }

    // First episode fails: only episode 1 was attempted.
    let (firstFailureSource, _) = threeEpisodeSource()
    let firstFailureWriter = P7R6FakeRecoveryWriter()
    firstFailureWriter.failingEpisodeIds = [1]
    let firstFailureCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: firstFailureSource,
        writer: firstFailureWriter,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: String(repeating: "a", count: 64),
        floorId: "1",
        persistedEvidenceSnapshot: { Data() })
    let firstFailure = firstFailureCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 40)
    require(
        !firstFailure.allPersisted
            && firstFailure.attemptedEpisodeIds == [1]
            && firstFailure.persistedEpisodeIds.isEmpty
            && firstFailure.failedEpisodeId == 1
            && firstFailure.failureReason == "durable_append_failed"
            && firstFailureSource.pending.map { $0.episode.id } == [1, 2, 3],
        "P7R6A attempted IDs must stop at the first failed episode")

    // Second episode fails: episodes 1 and 2 were attempted, 1 persisted.
    let (secondFailureSource, _) = threeEpisodeSource()
    let secondFailureWriter = P7R6FakeRecoveryWriter()
    secondFailureWriter.failingEpisodeIds = [2]
    let secondFailureCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: secondFailureSource,
        writer: secondFailureWriter,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: String(repeating: "a", count: 64),
        floorId: "1",
        persistedEvidenceSnapshot: { Data() })
    let secondFailure = secondFailureCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 50)
    require(
        !secondFailure.allPersisted
            && secondFailure.attemptedEpisodeIds == [1, 2]
            && secondFailure.persistedEpisodeIds == [1]
            && secondFailure.failedEpisodeId == 2
            && secondFailureSource.pending.map { $0.episode.id } == [2, 3],
        "P7R6A attempted IDs must cover exactly the processed episodes")

    // Unparsable snapshot: no pending episode was attempted at all.
    let (parseFailureSource, _) = threeEpisodeSource()
    let parseFailureWriter = P7R6FakeRecoveryWriter()
    let parseFailureCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: parseFailureSource,
        writer: parseFailureWriter,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: String(repeating: "a", count: 64),
        floorId: "1",
        persistedEvidenceSnapshot: { Data("{\"format\":".utf8) })
    let parseFailure = parseFailureCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 60)
    require(
        !parseFailure.allPersisted
            && parseFailure.attemptedEpisodeIds.isEmpty
            && parseFailure.persistedEpisodeIds.isEmpty
            && parseFailure.failedEpisodeId == 1
            && (parseFailure.failureReason?.hasPrefix("existing_evidence_")
                == true)
            && parseFailureWriter.appendedEpisodeIds.isEmpty
            && parseFailureSource.pending.map { $0.episode.id } == [1, 2, 3],
        "P7R6A a snapshot parse failure must attempt no episode")

    // Missing identity: also a pre-transaction failure, attempted stays
    // empty and nothing is acknowledged.
    let (identitySource, _) = threeEpisodeSource()
    let identityWriter = P7R6FakeRecoveryWriter()
    let identityCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: identitySource,
        writer: identityWriter,
        trackingSessionId: "session-a",
        priorMapId: nil,
        priorMapSha256: nil,
        floorId: nil,
        persistedEvidenceSnapshot: { Data() })
    let identityFailure = identityCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 70)
    require(
        !identityFailure.allPersisted
            && identityFailure.attemptedEpisodeIds.isEmpty
            && identityFailure.failedEpisodeId == 1
            && identityFailure.failureReason == "missing_prior_map_identity"
            && identityWriter.appendedEpisodeIds.isEmpty
            && identitySource.pending.map { $0.episode.id } == [1, 2, 3],
        "P7R6A a missing identity must attempt no episode")
}

// MARK: - P7R6A P-A1..P-A20: strict parser and acknowledgement contracts.

func p7r6aIdentitySha() -> String {
    return String(repeating: "a", count: 64)
}

/// Builds one canonical lifecycle line. v1 records carry no deadline,
/// attempts budget, or trigger sequence; the builder never fabricates them.
func p7r6aLifecycleRecordData(
    version: Int,
    episode: Int,
    started: Double = 10,
    finished: Double = 14.5,
    outcome: String = "converged",
    cancellationReason: String? = nil,
    validAttempts: Int = 7,
    accepted: Int = 2,
    trailingNewline: Bool = true,
    identity: [String: String]? = nil,
    extra: [String: Any] = [:]
) throws -> Data {
    var object: [String: Any] = [
        "format": "MarketScannerRecoveryLifecycleEvent",
        "version": version,
        "tracking_session_id": "session-a",
        "prior_map_id": "map-a",
        "prior_map_sha256": p7r6aIdentitySha(),
        "floor_id": "1",
        "episode_id": episode,
        "reason": "reliable_rtabmap_loop",
        "outcome": outcome,
        "episode_automatic": false,
        "started_at_uptime": started,
        "finished_at_uptime": finished,
        "elapsed_ms": (finished - started) * 1000,
        "valid_matcher_attempts": validAttempts,
        "accepted_corrections": accepted,
        "trigger_count": 1,
        "automatic_trigger_count": 0,
        "reliable_loop_trigger_count": 1,
        "last_trigger_reason": "reliable_rtabmap_loop",
        "last_trigger_at_uptime": started,
        "fresh_support_frames": 4,
        "completion_frame_step_applied": false,
    ]
    if version == 2 {
        object["deadline_uptime"] = started + 60
        object["maximum_valid_attempts"] = 40
        object["trigger_records"] = [[
            "reason": "reliable_rtabmap_loop",
            "automatic": false,
            "at_uptime": started,
        ]]
    }
    if let cancellationReason {
        object["cancellation_reason"] = cancellationReason
    }
    if let identity {
        for (key, value) in identity {
            object[key] = value
        }
    }
    for (key, value) in extra {
        object[key] = value
    }
    var data = try JSONSerialization.data(withJSONObject: object)
    if trailingNewline {
        data.append(0x0A)
    }
    return data
}

func p7r6aParseExpectation(
    expectedRecordCount: Int? = nil,
    expectedLastEpisodeId: Int? = nil,
    expectedLastFinishedAtUptime: TimeInterval? = nil
) -> RecoveryLifecycleEvidenceExpectation {
    return RecoveryLifecycleEvidenceExpectation(
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: p7r6aIdentitySha(),
        floorId: "1",
        expectedRecordCount: expectedRecordCount,
        expectedLastEpisodeId: expectedLastEpisodeId,
        expectedLastFinishedAtUptime: expectedLastFinishedAtUptime)
}

func p7r6aParseFailureCode(_ snapshot: Data) throws -> String {
    do {
        _ = try RecoveryLifecyclePersistedEvidenceParser.parse(
            snapshot: snapshot,
            expectation: p7r6aParseExpectation())
        return "PASS"
    }
    catch let error as RecoveryLifecycleEvidenceParseError {
        return error.stableCode
    }
}

func p7r6aCoordinatorWithPending(
    in directory: URL,
    episodes: [(reason: String, start: Double, finish: Double)],
    writer: P7R6DurableRecoveryWriter
) throws -> (RecoveryLifecyclePersistenceCoordinator, P7R6BundleSource) {
    let controller = PriorMapRecoveryController()
    let source = P7R6BundleSource(controller: controller)
    for episode in episodes {
        _ = controller.request(reason: episode.reason, now: episode.start)
        _ = controller.finish(.converged, now: episode.finish)
        if let completion = controller.lastCompletion {
            source.pending.append(completion)
        }
    }
    let coordinator = p7r6Coordinator(
        source: source,
        writer: writer,
        persistedEvidenceSnapshot: {
            try p7r6PersistedEvidenceSnapshot(in: directory)
        })
    return (coordinator, source)
}

// P-A1: a legal historical v1 episode plus a fresh pending v2 episode form a
// mixed file that the coordinator appends once and finalization accepts.
do {
    let directory = try p7r6FreshDirectory("pa1")
    let recoveryURL = try p7r6WriteBaseBundle(
        in: directory, createRecoveryFile: false)
    try p7r6aLifecycleRecordData(version: 1, episode: 1)
        .write(to: recoveryURL)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    // Burn episode 1 in the controller so the pending completion is 2.
    let (coordinator, source) = try p7r6aCoordinatorWithPending(
        in: directory,
        episodes: [
            (reason: "initial_warmup", start: 0, finish: 1),
            (reason: "reliable_rtabmap_loop", start: 20, finish: 22),
        ],
        writer: writer)
    source.pending.removeFirst()
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 23)
    let objects = try p7r6LifecycleObjects(in: directory)
    require(
        result.allPersisted
            && result.attemptedEpisodeIds == [2]
            && result.persistedEpisodeIds == [2]
            && writer.localizationRecoveryEventCount == 1
            && objects.count == 2
            && (objects[0]["version"] as? Int) == 1
            && (objects[1]["version"] as? Int) == 2,
        "P-A1 a legal v1 record plus a new v2 episode must append once")
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 2,
                lastEpisodeId: 2,
                lastFinishedAtUptime:
                    writer.lastRecoveryFinishedAtUptime)).isEmpty,
        "P-A1 mixed v1/v2 evidence must pass finalization")
}

// P-A2: the same episode as v1 on disk and v2 pending is never one fact.
do {
    let directory = try p7r6FreshDirectory("pa2")
    let recoveryURL = try p7r6WriteBaseBundle(
        in: directory, createRecoveryFile: false)
    try p7r6aLifecycleRecordData(version: 1, episode: 1)
        .write(to: recoveryURL)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let (coordinator, source) = try p7r6aCoordinatorWithPending(
        in: directory,
        episodes: [(reason: "reliable_rtabmap_loop", start: 20, finish: 22)],
        writer: writer)
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 23)
    let remainingObjects = try p7r6LifecycleObjects(in: directory)
    require(
        !result.allPersisted
            && result.attemptedEpisodeIds == [1]
            && result.persistedEpisodeIds.isEmpty
            && result.failedEpisodeId == 1
            && result.failureReason == "persisted_episode_version_conflict"
            && writer.localizationRecoveryEventCount == 0
            && source.pending.count == 1
            && remainingObjects.count == 1,
        "P-A2 a v1/v2 same-episode pair must conflict without appending")
}

// P-A3..P-A9: file-level and ordering contracts refuse acknowledgement.
do {
    func coordinatorOverSnapshot(
        _ snapshot: Data
    ) throws -> (RecoveryLifecyclePersistenceResult, P7R6FakeRecoverySource,
        P7R6FakeRecoveryWriter) {
        let controller = PriorMapRecoveryController()
        let source = P7R6FakeRecoverySource()
        _ = controller.request(reason: "reliable_rtabmap_loop", now: 20)
        if let completion = controller.finish(.converged, now: 22) {
            source.pending = [completion]
        }
        let writer = P7R6FakeRecoveryWriter()
        let coordinator = RecoveryLifecyclePersistenceCoordinator(
            source: source,
            writer: writer,
            trackingSessionId: "session-a",
            priorMapId: "map-a",
            priorMapSha256: p7r6aIdentitySha(),
            floorId: "1",
            persistedEvidenceSnapshot: { snapshot })
        return (coordinator.persistTerminalEvidence(
            cancellationReason: nil, now: 23), source, writer)
    }
    func expectNoAck(
        _ snapshot: Data,
        reasonSuffix: String,
        _ message: String
    ) throws {
        let (result, source, writer) = try coordinatorOverSnapshot(snapshot)
        require(
            !result.allPersisted
                && result.attemptedEpisodeIds.isEmpty
                && result.persistedEpisodeIds.isEmpty
                && result.failedEpisodeId == 1
                && result.failureReason == reasonSuffix
                && writer.appendedEpisodeIds.isEmpty
                && source.pending.count == 1,
            "\(message): \(result.failureReason ?? "nil")")
    }

    // P-A3: a complete JSON record without its final newline.
    try expectNoAck(
        p7r6aLifecycleRecordData(
            version: 2, episode: 1, trailingNewline: false),
        reasonSuffix: "existing_evidence_missing_final_newline",
        "P-A3 a missing final newline must refuse acknowledgement")

    // P-A4: blank lines are never records.
    var blankLineSnapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 1)
    blankLineSnapshot.append(0x0A)
    blankLineSnapshot.append(
        try p7r6aLifecycleRecordData(version: 2, episode: 2))
    try expectNoAck(
        blankLineSnapshot,
        reasonSuffix: "existing_evidence_blank_record",
        "P-A4 a blank line must refuse acknowledgement")

    // P-A5: a partial JSON tail.
    var partialTailSnapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 1)
    partialTailSnapshot.append(Data("{\"format\":".utf8))
    try expectNoAck(
        partialTailSnapshot,
        reasonSuffix: "existing_evidence_missing_final_newline",
        "P-A5 a partial tail must refuse acknowledgement")

    // P-A6: unknown fields.
    try expectNoAck(
        try p7r6aLifecycleRecordData(
            version: 2, episode: 1, extra: ["unexpected": true]),
        reasonSuffix: "existing_evidence_unknown_field",
        "P-A6 an unknown field must refuse acknowledgement")

    // P-A7: duplicated episodes.
    var duplicateSnapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 1)
    duplicateSnapshot.append(
        try p7r6aLifecycleRecordData(version: 2, episode: 1))
    try expectNoAck(
        duplicateSnapshot,
        reasonSuffix: "existing_evidence_duplicate_episode",
        "P-A7 a duplicate episode must refuse acknowledgement")

    // P-A8: episode IDs must strictly increase.
    var orderSnapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 2)
    orderSnapshot.append(
        try p7r6aLifecycleRecordData(version: 2, episode: 1))
    try expectNoAck(
        orderSnapshot,
        reasonSuffix: "existing_evidence_episode_order_invalid",
        "P-A8 out-of-order episodes must refuse acknowledgement")

    // P-A9: terminal finish uptimes never move backwards.
    var finishSnapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 1, started: 10, finished: 20)
    finishSnapshot.append(
        try p7r6aLifecycleRecordData(
            version: 2, episode: 2, started: 10, finished: 19))
    try expectNoAck(
        finishSnapshot,
        reasonSuffix: "existing_evidence_finish_order_invalid",
        "P-A9 finish-time regression must refuse acknowledgement")
}

// P-A10: every identity field must match exactly.
do {
    for (key, value) in [
        ("tracking_session_id", "session-other"),
        ("prior_map_id", "map-other"),
        ("prior_map_sha256", String(repeating: "b", count: 64)),
        ("floor_id", "2"),
    ] {
        let code = try p7r6aParseFailureCode(
            p7r6aLifecycleRecordData(
                version: 2, episode: 1, identity: [key: value]))
        require(
            code == "identity_mismatch",
            "P-A10 identity field \(key) must reject: \(code)")
    }
}

// P-A11: exact same v2 canonical record acknowledges without rewriting.
do {
    let directory = try p7r6FreshDirectory("pa11")
    let recoveryURL = try p7r6WriteBaseBundle(
        in: directory, createRecoveryFile: false)
    let writer = P7R6DurableRecoveryWriter(
        directory: directory,
        trackingSessionId: "session-a",
        sidecarWriter: FoundationScanSidecarWriter())
    let (coordinator, source) = try p7r6aCoordinatorWithPending(
        in: directory,
        episodes: [(reason: "reliable_rtabmap_loop", start: 20, finish: 22)],
        writer: writer)
    // Persist the exact pending record first (production canonical bytes).
    guard let completion = source.pending.first else {
        require(false, "P-A11 requires one pending completion")
        fatalError()
    }
    require(
        writer.appendRecoveryLifecycleEvent(
            completion, expectedTrackingSessionId: "session-a"),
        "P-A11 setup must persist the pending record")
    let watermarkAfterSetup = writer.localizationRecoveryEventCount
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 23)
    let idempotentObjects = try p7r6LifecycleObjects(in: directory)
    require(
        result.allPersisted
            && result.attemptedEpisodeIds == [1]
            && result.persistedEpisodeIds == [1]
            && writer.localizationRecoveryEventCount == watermarkAfterSetup
            && source.pending.isEmpty
            && idempotentObjects.count == 1,
        "P-A11 identical v2 canonical bytes must ack without rewriting")
    _ = recoveryURL
}

// P-A12: same episode with any differing business bytes conflicts.
do {
    let variants: [(String, (Double, Double, String, Int))] = [
        ("outcome", (20, 22, "timed_out", 2)),
        ("finished time", (20, 23, "converged", 2)),
        ("accepted corrections", (20, 22, "converged", 1)),
    ]
    for (label, variant) in variants {
        let directory = try p7r6FreshDirectory("pa12")
        let recoveryURL = try p7r6WriteBaseBundle(
            in: directory, createRecoveryFile: false)
        try p7r6aLifecycleRecordData(
            version: 2,
            episode: 1,
            started: variant.0,
            finished: variant.1,
            outcome: variant.2,
            accepted: variant.3).write(to: recoveryURL)
        let writer = P7R6DurableRecoveryWriter(
            directory: directory,
            trackingSessionId: "session-a",
            sidecarWriter: FoundationScanSidecarWriter())
        // Pending episode 1 with the canonical production timeline.
        let controller = PriorMapRecoveryController()
        let source = P7R6BundleSource(controller: controller)
        _ = controller.request(
            reason: "reliable_rtabmap_loop", now: variant.0)
        if let completion = controller.finish(
            .converged, now: variant.1) {
            source.pending.append(completion)
        }
        let coordinator = p7r6Coordinator(
            source: source,
            writer: writer,
            persistedEvidenceSnapshot: {
                try p7r6PersistedEvidenceSnapshot(in: directory)
            })
        let result = coordinator.persistTerminalEvidence(
            cancellationReason: nil, now: variant.1 + 1)
        // Every mutated variant differs from the pending canonical bytes, so
        // the transaction must conflict without appending or acknowledging.
        let conflictObjects = try p7r6LifecycleObjects(in: directory)
        require(
            !result.allPersisted
                && result.failedEpisodeId == 1
                && result.failureReason
                    == "persisted_episode_bytes_conflict"
                && writer.localizationRecoveryEventCount == 0
                && source.pending.count == 1
                && conflictObjects.count == 1,
            "P-A12 a \(label) mutation must conflict without appending")
    }
}

// P-A13/P-A14: attempted IDs stop exactly at the failing episode.
do {
    func threePending() -> (P7R6FakeRecoverySource) {
        let controller = PriorMapRecoveryController()
        let source = P7R6FakeRecoverySource()
        for index in 0..<3 {
            _ = controller.request(
                reason: "persistent_weak_or_lost",
                now: TimeInterval(index * 10),
                automatic: true)
            if let completion = controller.finish(
                .converged, now: TimeInterval(index * 10 + 1)) {
                source.pending.append(completion)
            }
        }
        return source
    }
    let firstWriter = P7R6FakeRecoveryWriter()
    firstWriter.failingEpisodeIds = [1]
    let firstCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: threePending(),
        writer: firstWriter,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: p7r6aIdentitySha(),
        floorId: "1",
        persistedEvidenceSnapshot: { Data() })
    let first = firstCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 40)
    require(
        first.attemptedEpisodeIds == [1]
            && first.persistedEpisodeIds.isEmpty
            && first.failedEpisodeId == 1,
        "P-A13 a first-episode failure must attempt only episode 1")
    let secondSource = threePending()
    let secondWriter = P7R6FakeRecoveryWriter()
    secondWriter.failingEpisodeIds = [2]
    let secondCoordinator = RecoveryLifecyclePersistenceCoordinator(
        source: secondSource,
        writer: secondWriter,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: p7r6aIdentitySha(),
        floorId: "1",
        persistedEvidenceSnapshot: { Data() })
    let second = secondCoordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 50)
    require(
        second.attemptedEpisodeIds == [1, 2]
            && second.persistedEpisodeIds == [1]
            && second.failedEpisodeId == 2
            && secondSource.pending.map { $0.episode.id } == [2, 3],
        "P-A14 a second-episode failure must keep episodes 2 and 3 queued")
}

// P-A15: an invalid existing snapshot attempts no pending episode.
do {
    let controller = PriorMapRecoveryController()
    let source = P7R6FakeRecoverySource()
    for index in 0..<2 {
        _ = controller.request(
            reason: "persistent_weak_or_lost",
            now: TimeInterval(index * 10),
            automatic: true)
        if let completion = controller.finish(
            .converged, now: TimeInterval(index * 10 + 1)) {
            source.pending.append(completion)
        }
    }
    let writer = P7R6FakeRecoveryWriter()
    let coordinator = RecoveryLifecyclePersistenceCoordinator(
        source: source,
        writer: writer,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: p7r6aIdentitySha(),
        floorId: "1",
        persistedEvidenceSnapshot: { Data("{\"format\":".utf8) })
    let result = coordinator.persistTerminalEvidence(
        cancellationReason: nil, now: 30)
    require(
        !result.allPersisted
            && result.attemptedEpisodeIds.isEmpty
            && result.persistedEpisodeIds.isEmpty
            && result.failedEpisodeId == 1
            && writer.appendedEpisodeIds.isEmpty
            && source.pending.map { $0.episode.id } == [1, 2],
        "P-A15 snapshot parse failure must keep every completion queued")
}

// P-A16/P-A17/P-A18: watermark expectations on an empty snapshot.
do {
    let empty = Data()
    let pass = try RecoveryLifecyclePersistedEvidenceParser.parse(
        snapshot: empty,
        expectation: p7r6aParseExpectation(expectedRecordCount: 0))
    require(pass.recordCount == 0,
            "P-A16 zero episodes with an empty snapshot must pass")
    do {
        _ = try RecoveryLifecyclePersistedEvidenceParser.parse(
            snapshot: empty,
            expectation: p7r6aParseExpectation(expectedRecordCount: 1))
        require(false, "P-A17 must fail closed")
    }
    catch let error as RecoveryLifecycleEvidenceParseError {
        require(error == .expectedCountMismatch,
                "P-A17 a positive watermark with an empty snapshot must fail")
    }
    do {
        _ = try RecoveryLifecyclePersistedEvidenceParser.parse(
            snapshot: empty,
            expectation: p7r6aParseExpectation(
                expectedRecordCount: 0,
                expectedLastEpisodeId: 1))
        require(false, "P-A18 must fail closed")
    }
    catch let error as RecoveryLifecycleEvidenceParseError {
        require(error == .lastEpisodeWatermarkMismatch,
                "P-A18 a zero watermark with a tail ID must fail")
    }
}

// P-A19: stable-read contracts fail closed under swap/truncate/link attacks.
do {
    let directory = try p7r6FreshDirectory("pa19")
    let target = directory.appendingPathComponent("recovery.jsonl")
    let candidate = directory.appendingPathComponent("replacement.jsonl")
    try Data("aaaaa\n".utf8).write(to: target)
    try Data("bbbbb\n".utf8).write(to: candidate)
    var swapped = false
    var swapFailed = false
    do {
        try SafeSessionPath.streamRegularFile(
            target,
            within: directory,
            maximumBytes: 1024,
            chunkBytes: 2
        ) { _ in
            if !swapped {
                swapped = true
                try FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(
                    at: candidate, to: target)
            }
        }
    }
    catch {
        swapFailed = true
    }
    require(swapFailed, "P-A19 a same-size swap must fail closed")
    try Data("aaaaa\nbbbbb\n".utf8).write(to: target)
    var truncated = false
    var truncateFailed = false
    do {
        try SafeSessionPath.streamRegularFile(
            target,
            within: directory,
            maximumBytes: 1024,
            chunkBytes: 2
        ) { _ in
            if !truncated {
                truncated = true
                try Data("a\n".utf8).write(to: target)
            }
        }
    }
    catch {
        truncateFailed = true
    }
    require(truncateFailed, "P-A19 a mid-read truncate must fail closed")
    try FileManager.default.removeItem(at: target)
    let linkedSource = directory.appendingPathComponent("source.jsonl")
    try Data("ccccc\n".utf8).write(to: linkedSource)
    try FileManager.default.createSymbolicLink(
        at: target, withDestinationURL: linkedSource)
    var symlinkFailed = false
    do {
        _ = try SafeSessionPath.readRegularFile(
            target, within: directory, maximumBytes: 1024)
    }
    catch {
        symlinkFailed = true
    }
    require(symlinkFailed, "P-A19 a symlink replacement must fail closed")
    try FileManager.default.removeItem(at: target)
    try Data("ddddd\n".utf8).write(to: target)
    let linkURL = directory.appendingPathComponent("alias.jsonl")
    try FileManager.default.linkItem(at: target, to: linkURL)
    var hardLinkFailed = false
    do {
        _ = try SafeSessionPath.readRegularFile(
            target, within: directory, maximumBytes: 1024)
    }
    catch {
        hardLinkFailed = true
    }
    require(hardLinkFailed,
            "P-A19 a hard-linked replacement must fail closed")
}

// P-A20: a mixed v1/v2 file validates under the exact watermark.
do {
    let directory = try p7r6FreshDirectory("pa20")
    let recoveryURL = try p7r6WriteBaseBundle(
        in: directory, createRecoveryFile: false)
    var mixed = try p7r6aLifecycleRecordData(
        version: 1, episode: 1, started: 5, finished: 8)
    mixed.append(
        try p7r6aLifecycleRecordData(
            version: 2, episode: 2, started: 10, finished: 14.5))
    try mixed.write(to: recoveryURL)
    require(
        LocalizationEvidenceBundleValidator.blockers(
            in: directory,
            expectation: p7r6BundleExpectation(
                recoveryCount: 2,
                lastEpisodeId: 2,
                lastFinishedAtUptime: 14.5)).isEmpty,
        "P-A20 mixed v1/v2 evidence must validate under the exact watermark")
    let parsed = try RecoveryLifecyclePersistedEvidenceParser.parse(
        snapshot: mixed,
        expectation: p7r6aParseExpectation(
            expectedRecordCount: 2,
            expectedLastEpisodeId: 2,
            expectedLastFinishedAtUptime: 14.5))
    require(
        parsed.recordCount == 2
            && parsed.records[0].isVersionOne
            && !parsed.records[1].isVersionOne
            && parsed.records[0].deadlineUptime == nil
            && parsed.records[0].maximumValidAttempts == nil
            && parsed.records[0].triggerRecords == nil
            && parsed.records[1].deadlineUptime != nil,
        "P-A20 v1 records must keep their missing v2 facts un-fabricated")
}

// MARK: - P7R6B P-B1..P-B15: strict JSON scalars, duplicate keys, pending
// queue order and unified limits.

/// Builds sequential Recovery completions from one controller, mirroring
/// the canonical v2 record shape used by the shared fixtures
/// (60 s deadline window, 7 valid attempts, 2 accepted corrections).
func p7r6bCompletions(
    _ episodes: [(start: Double, finish: Double)]
) -> [PriorMapRecoveryCompletion] {
    let controller = PriorMapRecoveryController(maximumWallClockSeconds: 60)
    var completions: [PriorMapRecoveryCompletion] = []
    for episode in episodes {
        _ = controller.request(
            reason: "reliable_rtabmap_loop", now: episode.start)
        for _ in 0..<7 {
            _ = controller.recordValidMatcherAttempt()
        }
        for _ in 0..<2 {
            controller.recordAcceptedCorrection()
        }
        if let completion = controller.finish(
            .converged,
            now: episode.finish,
            finalFreshSupportFrames: 4) {
            completions.append(completion)
        }
    }
    return completions
}

func p7r6bCoordinator(
    source: P7R6FakeRecoverySource,
    writer: P7R6FakeRecoveryWriter,
    snapshot: @escaping () -> Data
) -> RecoveryLifecyclePersistenceCoordinator {
    return RecoveryLifecyclePersistenceCoordinator(
        source: source,
        writer: writer,
        trackingSessionId: "session-a",
        priorMapId: "map-a",
        priorMapSha256: p7r6aIdentitySha(),
        floorId: "1",
        persistedEvidenceSnapshot: snapshot)
}

// P-B1: a numeric episode_automatic is not a JSON boolean.
do {
    let snapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 1, extra: ["episode_automatic": 1])
    let failureCode = try p7r6aParseFailureCode(snapshot)

    require(

        failureCode == "business_schema_invalid",

        "P-B1 numeric episode_automatic must be rejected (SB1)")
}

// P-B2: a numeric completion_frame_step_applied is not a JSON boolean.
do {
    let snapshot = try p7r6aLifecycleRecordData(
        version: 2, episode: 1, extra: ["completion_frame_step_applied": 0])
    let failureCode = try p7r6aParseFailureCode(snapshot)

    require(

        failureCode == "business_schema_invalid",

        "P-B2 numeric completion_frame_step_applied must be rejected (SB2)")
}

// P-B3: a numeric trigger-record automatic is not a JSON boolean.
do {
    let snapshot = try p7r6aLifecycleRecordData(
        version: 2,
        episode: 1,
        extra: ["trigger_records": [
            ["reason": "loop", "automatic": 1, "at_uptime": 10.0],
        ]])
    let failureCode = try p7r6aParseFailureCode(snapshot)

    require(

        failureCode == "trigger_records_invalid",

        "P-B3 numeric trigger automatic must be rejected (SB3)")
}

// P-B4: duplicate top-level object key.
do {
    let snapshot = Data("{\"episode_id\":999,\"episode_id\":1}\n".utf8)
    let failureCode = try p7r6aParseFailureCode(snapshot)

    require(

        failureCode == "duplicate_json_key",

        "P-B4 a duplicate top-level key must be rejected (DK1)")
}

// P-B5: duplicate nested object key inside trigger_records.
do {
    let snapshot = Data((
        "{\"trigger_records\":[{\"reason\":\"a\",\"reason\":\"b\","
            + "\"automatic\":true,\"at_uptime\":10.0}]}\n").utf8)
    let failureCode = try p7r6aParseFailureCode(snapshot)

    require(

        failureCode == "duplicate_json_key",

        "P-B5 a duplicate nested key must be rejected (DK2)")
}

// P-B6: an escaped-equivalent duplicate key is still a duplicate.
do {
    let snapshot = Data("{\"episode_id\":1,\"\\u0065pisode_id\":2}\n".utf8)
    let failureCode = try p7r6aParseFailureCode(snapshot)

    require(

        failureCode == "duplicate_json_key",

        "P-B6 an escaped-equivalent duplicate key must be rejected (DK3)")
}

// P-B7 (PQ1/PQ7): duplicate pending episodes are rejected before any
// append or acknowledgement; the coordinator never writes a duplicate.
do {
    let completions = p7r6bCompletions([(10, 14.5)])
    let source = P7R6FakeRecoverySource()
    source.pending = [completions[0], completions[0]]
    let writer = P7R6FakeRecoveryWriter()
    let result = p7r6bCoordinator(
        source: source, writer: writer, snapshot: { Data() })
        .persistTerminalEvidence(cancellationReason: nil, now: 30)
    require(
        !result.allPersisted
            && result.attemptedEpisodeIds.isEmpty
            && result.persistedEpisodeIds.isEmpty
            && result.failedEpisodeId == 1
            && result.failureReason == "pending_episode_duplicate"
            && writer.appendedEpisodeIds.isEmpty
            && source.pending.count == 2,
        "P-B7 a duplicate pending episode must fail before append/ack (PQ1)")
}

// P-B8 (PQ2): a reversed pending queue is rejected, never sorted.
do {
    let completions = p7r6bCompletions([(10, 14.5), (20, 24.5)])
    let source = P7R6FakeRecoverySource()
    source.pending = [completions[1], completions[0]]
    let writer = P7R6FakeRecoveryWriter()
    let result = p7r6bCoordinator(
        source: source, writer: writer, snapshot: { Data() })
        .persistTerminalEvidence(cancellationReason: nil, now: 30)
    require(
        !result.allPersisted
            && result.attemptedEpisodeIds.isEmpty
            && result.failedEpisodeId == 1
            && result.failureReason == "pending_episode_order_invalid"
            && writer.appendedEpisodeIds.isEmpty
            && source.pending.map { $0.episode.id } == [2, 1],
        "P-B8 a reversed pending queue must fail closed (PQ2)")
}

// P-B9 (PQ3): finish uptimes in the pending queue never regress.
do {
    let completions = p7r6bCompletions([(0, 20), (18, 19)])
    let source = P7R6FakeRecoverySource()
    source.pending = completions
    let writer = P7R6FakeRecoveryWriter()
    let result = p7r6bCoordinator(
        source: source, writer: writer, snapshot: { Data() })
        .persistTerminalEvidence(cancellationReason: nil, now: 30)
    require(
        !result.allPersisted
            && result.attemptedEpisodeIds.isEmpty
            && result.failedEpisodeId == 2
            && result.failureReason == "pending_finish_order_invalid"
            && writer.appendedEpisodeIds.isEmpty,
        "P-B9 a finish-time regression in the pending queue must fail (PQ3)")
}

// P-B10 (PQ5): an identical persisted episode acks without rewriting and a
// later episode appends once, using the same transaction.
do {
    let completions = p7r6bCompletions([(10, 14.5), (20, 24.5)])
    let existingSnapshot = try p7r6aLifecycleRecordData(version: 2, episode: 1)
    let source = P7R6FakeRecoverySource()
    source.pending = completions
    let writer = P7R6FakeRecoveryWriter()
    let result = p7r6bCoordinator(
        source: source, writer: writer, snapshot: { existingSnapshot })
        .persistTerminalEvidence(cancellationReason: nil, now: 30)
    require(
        result.allPersisted
            && result.attemptedEpisodeIds == [1, 2]
            && result.persistedEpisodeIds == [1, 2]
            && writer.appendedEpisodeIds == [2]
            && source.pending.isEmpty,
        "P-B10 an identical existing episode acks and the next appends once (PQ5)")
}

// P-B11 (SB4): finalization rejects a numeric constraint `accepted`.
do {
    let directory = try p7r6FreshDirectory("pb11")
    _ = try p7r6WriteBaseBundle(in: directory)
    let constraintsURL = directory.appendingPathComponent(
        "localization_constraints.jsonl")
    let identity = "\"trackingSessionId\":\"session-a\","
        + "\"priorMapId\":\"map-a\","
        + "\"priorMapSha256\":\"\(p7r6aIdentitySha())\","
        + "\"floorId\":\"1\","
    let pose = "{\"x_m\":0,\"y_m\":0,\"yaw_rad\":0}"
    let line = "{\"format\":\"MarketScannerLocalizationConstraint\","
        + "\"version\":1," + identity
        + "\"timestamp\":1,\"nodeTimebaseTimestamp\":1,"
        + "\"nodeTimebaseOffsetSeconds\":0,\"accepted\":1,"
        + "\"predictedPose\":\(pose),\"uniqueness\":0.9}\n"
    try Data(line.utf8).write(to: constraintsURL)
    let blockers = LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(recoveryCount: 0))
    require(
        blockers.contains(
            "evidence_bundle_localization_constraints.jsonl_"
                + "constraint_business_schema_invalid"),
        "P-B11 numeric constraint accepted must block finalization (SB4): "
            + "\(blockers)")
}

// P-B12 (SB5): finalization rejects numeric localized-tag booleans.
do {
    let directory = try p7r6FreshDirectory("pb12")
    _ = try p7r6WriteBaseBundle(in: directory)
    let identity = "\"tracking_session_id\":\"session-a\","
        + "\"prior_map_id\":\"map-a\","
        + "\"prior_map_sha256\":\"\(p7r6aIdentitySha())\","
        + "\"floor_id\":\"1\","
    let tag = "[{\"format\":\"MarketScannerLocalizedPriceTag\","
        + "\"version\":1," + identity
        + "\"tag_id\":\"t1\",\"observation_id\":\"o1\","
        + "\"payload\":\"p\",\"symbology\":\"CODE128\","
        + "\"timestamp\":1.0,\"localization_confidence\":0.9,"
        + "\"measurement_confidence\":0.9,\"association_confidence\":0.9,"
        + "\"measurement_method\":\"manual\","
        + "\"needs_review\":0,\"user_confirmed\":1}]\n"
    try Data(tag.utf8).write(to: directory.appendingPathComponent(
        "localized_price_tags.json"))
    let blockers = LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(recoveryCount: 0))
    require(
        blockers.contains(
            "evidence_bundle_localized_price_tags_"
                + "tag_business_schema_invalid"),
        "P-B12 numeric tag booleans must block finalization (SB5): "
            + "\(blockers)")
}

// ESL-F1/F2/F3: a syntactically valid complete burst is only verified when
// the durable observation and burst-frame bindings are exactly equal in both
// directions. Internal burst consistency or a one-way subset is insufficient.
do {
    let cleanDirectory = try p7r6FreshDirectory("esl-f1")
    _ = try p7r6WriteBaseBundle(in: cleanDirectory)
    try p7r6WriteTagBurstBindingFixture(in: cleanDirectory)
    let cleanBlockers = LocalizationEvidenceBundleValidator.blockers(
        in: cleanDirectory,
        expectation: p7r6BundleExpectation(
            recoveryCount: 0,
            tagBurstCount: 1,
            tagBurstLastID: "burst-1"))
    require(
        cleanBlockers.isEmpty,
        "ESL-F1 exact durable observation/burst binding must finalize: "
            + "\(cleanBlockers)")

    let mismatchedDirectory = try p7r6FreshDirectory("esl-f2")
    _ = try p7r6WriteBaseBundle(in: mismatchedDirectory)
    try p7r6WriteTagBurstBindingFixture(
        in: mismatchedDirectory,
        observationFrameID: "different-frame")
    let mismatchedBlockers = LocalizationEvidenceBundleValidator.blockers(
        in: mismatchedDirectory,
        expectation: p7r6BundleExpectation(
            recoveryCount: 0,
            tagBurstCount: 1,
            tagBurstLastID: "burst-1"))
    require(
        mismatchedBlockers.contains(
            "evidence_bundle_tag_burst_observation_binding_mismatch"),
        "ESL-F2 mismatched durable observation/burst binding must block: "
            + "\(mismatchedBlockers)")

    let extraDirectory = try p7r6FreshDirectory("esl-f3")
    _ = try p7r6WriteBaseBundle(in: extraDirectory)
    try p7r6WriteTagBurstBindingFixture(
        in: extraDirectory,
        includeUnlistedBoundObservation: true)
    let extraBlockers = LocalizationEvidenceBundleValidator.blockers(
        in: extraDirectory,
        expectation: p7r6BundleExpectation(
            recoveryCount: 0,
            tagBurstCount: 1,
            tagBurstLastID: "burst-1"))
    require(
        extraBlockers.contains(
            "evidence_bundle_tag_burst_observation_binding_mismatch"),
        "ESL-F3 an unlisted durable burst-bound observation must block: "
            + "\(extraBlockers)")
}

// ESL-F4/F5: additive v2 localized tags remain version-specific and can only
// finalize when their confirmation fields bind the exact verified burst.
do {
    let cleanDirectory = try p7r6FreshDirectory("esl-f4")
    _ = try p7r6WriteBaseBundle(in: cleanDirectory)
    try p7r6WriteV2LocalizedTagFixture(in: cleanDirectory)
    let cleanBlockers = LocalizationEvidenceBundleValidator.blockers(
        in: cleanDirectory,
        expectation: p7r6BundleExpectation(
            recoveryCount: 0,
            localizedPriceTagCount: 1,
            tagBurstCount: 1,
            tagBurstLastID: "12345678-1234-4234-8234-123456789abc"))
    require(
        cleanBlockers.isEmpty,
        "ESL-F4 exact v2 confirmation evidence must finalize: "
            + "\(cleanBlockers)")

    let unknownDirectory = try p7r6FreshDirectory("esl-f5")
    _ = try p7r6WriteBaseBundle(in: unknownDirectory)
    try p7r6WriteV2LocalizedTagFixture(in: unknownDirectory) {
        $0["future_confirmation_field"] = true
    }
    let unknownBlockers = LocalizationEvidenceBundleValidator.blockers(
        in: unknownDirectory,
        expectation: p7r6BundleExpectation(
            recoveryCount: 0,
            localizedPriceTagCount: 1,
            tagBurstCount: 1,
            tagBurstLastID: "12345678-1234-4234-8234-123456789abc"))
    require(
        unknownBlockers.contains(
            "evidence_bundle_localized_price_tags_tag_contract_mismatch"),
        "ESL-F5 unknown v2 confirmation fields must fail closed: "
            + "\(unknownBlockers)")
}

// P-B13/P-B14: the frozen 16 MB file limit is exact on both sides of the
// boundary, mirroring the Python reader's pre-read size check.
do {
    let exact = Data(
        repeating: 0x61,
        count: RecoveryLifecycleEvidenceLimits.maximumFileBytes)
    let exactCode = try p7r6aParseFailureCode(exact)
    require(
        exactCode == "missing_final_newline",
        "P-B13 an exact-limit snapshot passes the size gate (B4)")
    let over = Data(
        repeating: 0x61,
        count: RecoveryLifecycleEvidenceLimits.maximumFileBytes + 1)
    let overCode = try p7r6aParseFailureCode(over)
    require(
        overCode == "file_too_large",
        "P-B14 a file one byte over the limit fails closed (B4)")
}

// P-B15: record-byte and nesting-depth boundaries use the shared limits.
do {
    var exactRecord = Data(
        repeating: 0x61,
        count: RecoveryLifecycleEvidenceLimits.maximumRecordBytes)
    exactRecord.append(0x0A)
    let exactRecordCode = try p7r6aParseFailureCode(exactRecord)
    require(
        exactRecordCode == "invalid_json",
        "P-B15 an exact-limit record passes the size gate (B4)")
    var overRecord = Data(
        repeating: 0x61,
        count: RecoveryLifecycleEvidenceLimits.maximumRecordBytes + 1)
    overRecord.append(0x0A)
    let overRecordCode = try p7r6aParseFailureCode(overRecord)
    require(
        overRecordCode == "record_too_large",
        "P-B15 a record one byte over the limit fails closed (B4)")
    let allowedDepth = String(repeating: "{\"a\":", count: 32)
        + "null" + String(repeating: "}", count: 32) + "\n"
    let allowedDepthCode = try p7r6aParseFailureCode(
        Data(allowedDepth.utf8))
    require(
        allowedDepthCode == "format_mismatch",
        "P-B15 depth 32 passes the nesting gate (B4)")
    let overDepth = String(
        repeating: "{\"a\":",
        count: RecoveryLifecycleEvidenceLimits.maximumJSONNestingDepth + 1)
        + "null"
        + String(
            repeating: "}",
            count: RecoveryLifecycleEvidenceLimits.maximumJSONNestingDepth + 1)
        + "\n"
    let overDepthCode = try p7r6aParseFailureCode(
        Data(overDepth.utf8))
    require(
        overDepthCode == "invalid_json",
        "P-B15 depth 33 must fail the nesting gate (B4)")
}

// =====================================================================
// P7R6C-C1: the strict JSON validator is a total function. Any Data input
// either validates or throws a typed error; it must never crash, never
// force-unwrap, never read out of bounds.
//
// C1/C2 run only in the default host-test mode (no arguments). The
// --recovery-fixtures and package-integrity modes below invoke this same
// executable repeatedly; re-running the 16 MiB catalog tests on every
// call would blow past CI wall-clock budgets.
// CommandLine.arguments always contains the executable path, so the
// default mode is "no arguments beyond the program path".
// =====================================================================
if CommandLine.arguments.count <= 1 {

// U1: a scalar above U+10FFFF encoded as UTF-8 (F4 BF BF BF) inside a
// JSON string must be rejected without trapping.
do {
    var u1 = Data("{\"value\":\"".utf8)
    u1.append(contentsOf: [0xF4, 0xBF, 0xBF, 0xBF])
    u1.append(Data("\"}".utf8))
    do {
        try StrictJSONKeyUniquenessValidator.validate(u1)
        require(false, "C1-U1 scalar above U+10FFFF must be rejected")
    }
    catch let error as StrictJSONValidationError {
        switch error {
        case .invalidUTF8, .scalarOutOfRange:
            break
        default:
            require(false, "C1-U1 unexpected error code: \(error)")
        }
    }
}

// U2: a UTF-16 surrogate encoded as UTF-8 (ED A0 80) must be rejected.
do {
    var u2 = Data("{\"value\":\"".utf8)
    u2.append(contentsOf: [0xED, 0xA0, 0x80])
    u2.append(Data("\"}".utf8))
    do {
        try StrictJSONKeyUniquenessValidator.validate(u2)
        require(false, "C1-U2 surrogate UTF-8 must be rejected")
    }
    catch let error as StrictJSONValidationError {
        switch error {
        case .invalidUTF8, .scalarOutOfRange:
            break
        default:
            require(false, "C1-U2 unexpected error code: \(error)")
        }
    }
}

// U3: overlong encodings (C0 AF and E0 80 AF) must be rejected.
do {
    for bytes in [[0xC0, 0xAF] as [UInt8], [0xE0, 0x80, 0xAF] as [UInt8]] {
        var u3 = Data("{\"value\":\"".utf8)
        u3.append(contentsOf: bytes)
        u3.append(Data("\"}".utf8))
        do {
            try StrictJSONKeyUniquenessValidator.validate(u3)
            require(false, "C1-U3 overlong encoding must be rejected")
        }
        catch let error as StrictJSONValidationError {
            switch error {
            case .invalidUTF8, .scalarOutOfRange:
                break
            default:
                require(false, "C1-U3 unexpected error code: \(error)")
            }
        }
    }
}

// U4: a bad continuation byte (E2 28 A1) must be rejected.
do {
    var u4 = Data("{\"value\":\"".utf8)
    u4.append(contentsOf: [0xE2, 0x28, 0xA1])
    u4.append(Data("\"}".utf8))
    do {
        try StrictJSONKeyUniquenessValidator.validate(u4)
        require(false, "C1-U4 bad continuation must be rejected")
    }
    catch let error as StrictJSONValidationError {
        switch error {
        case .invalidUTF8:
            break
        default:
            require(false, "C1-U4 unexpected error code: \(error)")
        }
    }
}

// U5: truncated 2/3/4-byte sequences must be rejected.
do {
    for bytes in [[0xC2] as [UInt8], [0xE2, 0x82] as [UInt8],
                  [0xF0, 0x9F, 0x92] as [UInt8]] {
        var u5 = Data("{\"value\":\"".utf8)
        u5.append(contentsOf: bytes)
        u5.append(Data("\"}".utf8))
        do {
            try StrictJSONKeyUniquenessValidator.validate(u5)
            require(false, "C1-U5 truncated sequence must be rejected")
        }
        catch let error as StrictJSONValidationError {
            switch error {
            case .invalidUTF8:
                break
            default:
                require(false, "C1-U5 unexpected error code: \(error)")
            }
        }
    }
}

// U6: an unpaired high surrogate escape must not crash the scanner.
do {
    let u6 = Data("{\"value\":\"\\uD800\"}".utf8)
    do {
        try StrictJSONKeyUniquenessValidator.validate(u6)
    }
    catch let error as StrictJSONValidationError {
        switch error {
        case .unpairedHighSurrogate, .invalidUnicodeEscape, .invalidUTF8:
            break
        default:
            require(false, "C1-U6 unexpected error code: \(error)")
        }
    }
}

// U7: an unpaired low surrogate escape must not crash the scanner.
do {
    let u7 = Data("{\"value\":\"\\uDC00\"}".utf8)
    do {
        try StrictJSONKeyUniquenessValidator.validate(u7)
    }
    catch let error as StrictJSONValidationError {
        switch error {
        case .unpairedLowSurrogate, .invalidUnicodeEscape, .invalidUTF8:
            break
        default:
            require(false, "C1-U7 unexpected error code: \(error)")
        }
    }
}

// U8: a legal surrogate pair passes the duplicate-key scanner.
do {
    let u8 = Data("{\"value\":\"\\uD83D\\uDE00\"}".utf8)
    try StrictJSONKeyUniquenessValidator.validate(u8)
}

// U10/TJ9: deterministic fuzz. 10,000 random byte arrays of length 0..4096
// must only ever return or throw; the process must never crash.
do {
    var state: UInt64 = 0x9E3779B97F4A7C15
    func nextRandom() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    for _ in 0..<10_000 {
        let length = Int(nextRandom() % 4097)
        var data = Data(capacity: length)
        for _ in 0..<length {
            data.append(UInt8(truncatingIfNeeded: nextRandom()))
        }
        do {
            try StrictJSONKeyUniquenessValidator.validate(data)
        }
        catch {
            // Any typed error is acceptable; a crash is not.
        }
    }
}

// U9/TJ10: an invalid UTF-8 localized_price_tags.json must become a stable
// finalization blocker, never a process crash, and finalization must fail
// closed.
do {
    let directory = try p7r6FreshDirectory("c1-u9")
    _ = try p7r6WriteBaseBundle(in: directory)
    var invalidTags = Data("[\"value\":\"".utf8)
    invalidTags.append(contentsOf: [0xF4, 0xBF, 0xBF, 0xBF])
    invalidTags.append(Data("\"]".utf8))
    try invalidTags.write(
        to: directory.appendingPathComponent("localized_price_tags.json"))
    let blockers = LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(recoveryCount: 0))
    require(
        blockers.contains {
            $0.contains("localized_price_tags")
                && $0.contains("invalid_json_array")
        },
        "C1-U9 invalid UTF-8 tag file must become a stable blocker: "
            + "\(blockers)")
}

// =====================================================================
// P7R6C-C2: the strict scanner must not reject a large legal tag array.
// The old fixed 1,000,000-token cap wrongly rejected legal catalogs; the
// new progress bound is derived from the byte count.
// =====================================================================

/// Writes a valid localized_price_tags.json array with the given tag
/// count and returns the finalization blockers for that bundle.
func p7r6TagsBlockers(tagCount: Int, mutateLast: (inout String) -> Void = { _ in })
    throws -> [String] {
    let directory = try p7r6FreshDirectory("c2-tags")
    _ = try p7r6WriteBaseBundle(in: directory)
    var lines: [String] = []
    lines.reserveCapacity(tagCount)
    for index in 0..<tagCount {
        var tag = "{\"format\":\"MarketScannerLocalizedPriceTag\","
            + "\"version\":1,"
            + "\"tracking_session_id\":\"session-a\","
            + "\"prior_map_id\":\"map-a\","
            + "\"prior_map_sha256\":\"\(p7r6aIdentitySha())\","
            + "\"floor_id\":\"1\","
            + "\"tag_id\":\"t\(index)\",\"observation_id\":\"o\(index)\","
            + "\"payload\":\"p\",\"symbology\":\"CODE128\","
            + "\"timestamp\":\(1.0 + Double(index)),"
            + "\"localization_confidence\":0.9,"
            + "\"measurement_confidence\":0.9,"
            + "\"association_confidence\":0.9,"
            + "\"measurement_method\":\"manual\","
            + "\"needs_review\":false,\"user_confirmed\":true}"
        if index == tagCount - 1 {
            mutateLast(&tag)
        }
        lines.append(tag)
    }
    let payload = Data(("[" + lines.joined(separator: ",") + "]").utf8)
    try payload.write(
        to: directory.appendingPathComponent("localized_price_tags.json"))
    return LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(
            recoveryCount: 0,
            localizedPriceTagCount: tagCount))
}

// L1: 10,000 tags must finalize cleanly (no token-cap rejection).
do {
    let blockers = try p7r6TagsBlockers(tagCount: 10_000)
    require(
        blockers.isEmpty,
        "C2-L1 10,000 tags must finalize cleanly: \(blockers)")
}

// L2: 30,000 tags must finalize cleanly.
do {
    let blockers = try p7r6TagsBlockers(tagCount: 30_000)
    require(
        blockers.isEmpty,
        "C2-L2 30,000 tags must finalize cleanly: \(blockers)")
}

// L3: the largest legal tag catalog that fits inside the frozen 16 MiB
// file limit must not be rejected by any scanner token cap. A per-byte
// progress bound replaced the old fixed 1,000,000-token cap.
do {
    let directory = try p7r6FreshDirectory("c2-l3")
    _ = try p7r6WriteBaseBundle(in: directory)
    func minimalTag(_ index: Int) -> String {
        return "{\"format\":\"MarketScannerLocalizedPriceTag\","
            + "\"version\":1,"
            + "\"tracking_session_id\":\"session-a\","
            + "\"prior_map_id\":\"map-a\","
            + "\"prior_map_sha256\":\"\(p7r6aIdentitySha())\","
            + "\"floor_id\":\"1\","
            + "\"tag_id\":\"t\(index)\",\"observation_id\":\"o\(index)\","
            + "\"payload\":\"p\",\"symbology\":\"CODE128\","
            + "\"timestamp\":\(1.0 + Double(index)),"
            + "\"localization_confidence\":0.9,"
            + "\"measurement_confidence\":0.9,"
            + "\"association_confidence\":0.9,"
            + "\"measurement_method\":\"manual\","
            + "\"needs_review\":false,\"user_confirmed\":true}"
    }
    // Accumulate records until the next one would exceed 16 MiB: the
    // largest count that still fits the frozen file limit, accounting for
    // the array brackets and inter-record commas.
    var payload = Data("[".utf8)
    var fittingCount = 0
    while payload.count < RecoveryLifecycleEvidenceLimits.maximumFileBytes {
        let candidate = minimalTag(fittingCount)
        let candidateCount = payload.count
            + candidate.utf8.count
            + (fittingCount == 0 ? 1 : 2) // "[" or "," before the record
        if candidateCount >= RecoveryLifecycleEvidenceLimits.maximumFileBytes {
            break
        }
        if fittingCount > 0 {
            payload.append(Data(",".utf8))
        }
        payload.append(Data(candidate.utf8))
        fittingCount += 1
    }
    payload.append(Data("]".utf8))
    try payload.write(
        to: directory.appendingPathComponent("localized_price_tags.json"))
    require(
        fittingCount >= 30_000,
        "C2-L3 the 16 MiB budget must hold at least 30,000 minimal tags "
            + "(fits \(fittingCount))")
    let blockers = LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(
            recoveryCount: 0,
            localizedPriceTagCount: fittingCount))
    require(
        blockers.isEmpty,
        "C2-L3 \(fittingCount) tags within the 16 MiB limit "
            + "must finalize cleanly: \(blockers)")
}

// L5: a duplicate key in the LAST tag must still be detected; the scanner
// must never stop scanning early just because the file is large.
do {
    let blockers = try p7r6TagsBlockers(tagCount: 10_000) { tag in
        tag = "{\"format\":\"MarketScannerLocalizedPriceTag\","
            + "\"format\":\"MarketScannerLocalizedPriceTag\","
            + "\"version\":1,"
            + "\"tracking_session_id\":\"session-a\","
            + "\"prior_map_id\":\"map-a\","
            + "\"prior_map_sha256\":\"\(p7r6aIdentitySha())\","
            + "\"floor_id\":\"1\","
            + "\"tag_id\":\"t-last\",\"observation_id\":\"o-last\","
            + "\"payload\":\"p\",\"symbology\":\"CODE128\","
            + "\"timestamp\":1.0,\"localization_confidence\":0.9,"
            + "\"measurement_confidence\":0.9,"
            + "\"association_confidence\":0.9,"
            + "\"measurement_method\":\"manual\","
            + "\"needs_review\":false,\"user_confirmed\":true}"
    }
    require(
        blockers.contains {
            $0.contains("localized_price_tags")
                && $0.contains("duplicate_json_key")
        },
        "C2-L5 duplicate key in the last tag must be detected: \(blockers)")
}

// L6: a numeric boolean in the LAST tag must be rejected.
do {
    let blockers = try p7r6TagsBlockers(tagCount: 10_000) { tag in
        tag = "{\"format\":\"MarketScannerLocalizedPriceTag\","
            + "\"version\":1,"
            + "\"tracking_session_id\":\"session-a\","
            + "\"prior_map_id\":\"map-a\","
            + "\"prior_map_sha256\":\"\(p7r6aIdentitySha())\","
            + "\"floor_id\":\"1\","
            + "\"tag_id\":\"t-last\",\"observation_id\":\"o-last\","
            + "\"payload\":\"p\",\"symbology\":\"CODE128\","
            + "\"timestamp\":1.0,\"localization_confidence\":0.9,"
            + "\"measurement_confidence\":0.9,"
            + "\"association_confidence\":0.9,"
            + "\"measurement_method\":\"manual\","
            + "\"needs_review\":1,\"user_confirmed\":true}"
    }
    require(
        blockers.contains {
            $0.contains("localized_price_tags")
                && $0.contains("tag_business_schema_invalid")
        },
        "C2-L6 numeric boolean in the last tag must be rejected: \(blockers)")
}

// L4: a 16 MiB + 1 byte tag file must fail the frozen file-size limit
// instead of being scanned or parsed.
do {
    let directory = try p7r6FreshDirectory("c2-l4")
    _ = try p7r6WriteBaseBundle(in: directory)
    var oversized = Data(
        repeating: 0x20,
        count: RecoveryLifecycleEvidenceLimits.maximumFileBytes + 1)
    oversized.append(Data("[0]".utf8))
    try oversized.write(
        to: directory.appendingPathComponent("localized_price_tags.json"))
    let blockers = LocalizationEvidenceBundleValidator.blockers(
        in: directory,
        expectation: p7r6BundleExpectation(recoveryCount: 0))
    require(
        blockers.contains {
            $0.contains("localized_price_tags")
                && ($0.contains("file_identity_changed_or_size_limit")
                    || $0.contains("file_size_limit")
                    || $0.contains("invalid_json_array"))
        },
        "C2-L4 a 16 MiB+1 tag file must fail the size limit: \(blockers)")
}

// =====================================================================
// Mobile-Only V1: map-source import (CSV / JSON in default mode; the
// XLSX and three-format parity suite runs through --import-suite because
// real .xlsx fixtures are produced by the Python harness).
// =====================================================================

// I2/I14: CSV baseline with two floors imports cleanly and preserves the
// complete canonical source inventory. Hidden source elements remain in the
// import result for audit and are filtered only by the compiler's active
// element stage.
do {
    let csv = """
    floor,element
    1,"{""shapeType"":""MapShelf"",""x"":100,""y"":200,""width"":300,""height"":100,""code"":""S1"",""visible"":true}"
    1,"{""shapeType"":""MapCross"",""points"":[0,500,1000,500],""lineWidth"":200,""code"":""C1"",""visible"":true}"
    2,"{""shapeType"":""MapRoadPoint"",""x"":100,""y"":500,""width"":20,""height"":20,""code"":1,""crossCodes"":[""C1""]}"
    1,"{""shapeType"":""MapCross"",""points"":[100,700,900,700],""lineWidth"":180,""code"":""C-hidden"",""visible"":false}"
    1,"{""shapeType"":""MapRoadPoint"",""x"":100,""y"":700,""width"":20,""height"":20,""code"":""A"",""crossCodes"":[""C-hidden""]}"
    1,"{""shapeType"":""MapRoadPoint"",""x"":900,""y"":700,""width"":20,""height"":20,""code"":""B"",""crossCodes"":[""C-hidden""]}"
    """
    let outcome = try CSVMapSourceImporter.importSource(
        data: Data(csv.utf8),
        contract: .topLeft)
    require(
        outcome.elements.count == 6,
        "I2 CSV must import 6 source elements, got \(outcome.elements.count)")
    let floors = Set(outcome.elements.map { $0.floorId })
    require(
        floors == ["1", "2"],
        "I2 CSV floors must be [1, 2], got \(floors.sorted())")
    require(
        outcome.elements.allSatisfy { $0.id == "f\($0.floorId)-r\($0.sourceRow)" },
        "I2 element ids must follow the frozen f<floor>-r<row> contract")
    // Road-graph warnings (missing_cross / road_point_without_cross) are
    // produced by the compiler stage, not the importer; the importer only
    // reports geometry/visibility observations.
    require(
        outcome.warnings.allSatisfy {
            $0.code == "unknown_shape_type"
                || $0.code == "invalid_geometry"
                || $0.code == "hidden_element_ignored"
        },
        "I2 importer warnings must be normalization-only, got \(outcome.warnings.map { $0.code })")
    // Shelf normalization: x=100,y=200,w=300,h=100 -> CCW map polygon
    // whose first corner is the bottom-left source corner (1.0, -3.0)
    // under the top-left contract.
    let shelf = outcome.elements.first { $0.shapeType == "MapShelf" }
    require(shelf != nil, "I2 shelf must exist")
    if let geometry = shelf?.geometry,
       let coordinates = geometry["coordinates"] as? [[Double]] {
        require(
            coordinates.count == 4,
            "I2 shelf polygon must have 4 points")
        require(
            close(coordinates[0][0], 1.0) && close(coordinates[0][1], -3.0),
            "I2 shelf first corner must be (1.0, -3.0), got \(coordinates[0])")
        require(
            close(coordinates[1][0], 4.0) && close(coordinates[1][1], -3.0),
            "I2 shelf second corner must be (4.0, -3.0), got \(coordinates[1])")
    }
    else {
        require(false, "I2 shelf must carry geometry")
    }
}
catch {
    require(false, "I2 CSV baseline failed: \(error)")
}

// I8: quoted newline inside a field is preserved (RFC 4180).
do {
    let csv = "floor,element\n1,\"{ \"\"shapeType\"\": \"\"MapShelf\"\"}\"\n"
    let outcome = try CSVMapSourceImporter.importSource(
        data: Data(csv.utf8),
        contract: .topLeft,
        strict: false)
    require(
        outcome.elements.count == 1,
        "I8 quoted-newline CSV must import 1 element, got \(outcome.elements.count)")
}
catch {
    require(false, "I8 quoted newline failed: \(error)")
}

// I9: an unclosed quoted field must fail closed.
do {
    let csv = "floor,element\n1,\"{quoted-never-closed"
    _ = try CSVMapSourceImporter.importSource(
        data: Data(csv.utf8),
        contract: .topLeft)
    require(false, "I9 unclosed quote must be rejected")
}
catch let error as MapSourceImportError {
    require(
        error == .malformedRow(row: 2, reason: "引号字段未闭合。"),
        "I9 unclosed quote must report malformed row, got \(error.stableCode)")
}
catch {
    require(false, "I9 unclosed quote error type: \(error)")
}

// CSV NUL byte must be rejected.
do {
    var bad = Data("floor,element\n1,\"{\"".utf8)
    bad.append(0)
    bad.append(Data("\"}\"\n".utf8))
    _ = try CSVMapSourceImporter.importSource(
        data: bad,
        contract: .topLeft)
    require(false, "I-csv-nul must be rejected")
}
catch let error as MapSourceImportError {
    require(
        error.stableCode == "map_source_csv_contains_nul",
        "CSV NUL must map to csv_contains_nul, got \(error.stableCode)")
}
catch {
    require(false, "CSV NUL error type: \(error)")
}

// I11: invalid UTF-8 bytes must be rejected.
do {
    var bad = Data("floor,element\n1,\"{}\"".utf8)
    bad.append(0xC3) // truncated UTF-8 sequence
    bad.append(Data("\n".utf8))
    _ = try CSVMapSourceImporter.importSource(
        data: bad,
        contract: .topLeft)
    require(false, "I11 invalid UTF-8 CSV must be rejected")
}
catch let error as MapSourceImportError {
    require(
        error.stableCode == "invalid_utf8",
        "I11 invalid UTF-8 must map to invalid_utf8, got \(error.stableCode)")
}
catch {
    require(false, "I11 invalid UTF-8 error type: \(error)")
}

// I3/I10: JSON baseline imports; duplicate keys are rejected by the
// strict parser.
do {
    let json = """
    {
      "format": "MarketScannerPriorMapSource",
      "version": 1,
      "storeId": "s1",
      "mapName": "sample",
      "source": {
        "originalFormat": "json",
        "originalFilename": "sample.json",
        "sourceFileSha256": "abc",
        "canonicalSourceSha256": ""
      },
      "coordinateContract": {
        "unit": "centimetre", "origin": "top_left", "x_axis": "right",
        "y_axis": "down", "rotation_direction": "clockwise_degrees"
      },
      "elements": [
        {
          "id": "f1-r2", "source_row": 2, "floor_id": "1",
          "shape_type": "MapShelf", "visible": true, "locked": false,
          "code": "S1", "cross_code": "", "row_flag": "",
          "geometry": {"type": "polygon", "coordinates": [[1.0, -2.0], [4.0, -2.0], [4.0, -1.0], [1.0, -1.0]]},
          "bounds": {"min_x_m": 1.0, "min_y_m": -2.0, "max_x_m": 4.0, "max_y_m": -1.0},
          "center_m": [2.5, -1.5], "yaw_rad": 0.0,
          "source": {"shapeType": "MapShelf", "x": 100, "y": 200, "width": 300, "height": 100}
        }
      ],
      "warnings": []
    }
    """
    let outcome = try JSONMapSourceImporter.importSource(data: Data(json.utf8))
    require(
        outcome.elements.count == 1,
        "I3 JSON baseline must import 1 element, got \(outcome.elements.count)")
    require(
        outcome.sourceIdentity?.originalFilename == "sample.json",
        "I3 JSON identity must preserve originalFilename")
    require(
        outcome.elements[0].shapeType == "MapShelf",
        "I3 JSON element shape_type must be preserved")
}
catch {
    require(false, "I3 JSON baseline failed: \(error)")
}

do {
    let json = """
    {"format": "MarketScannerPriorMapSource", "version": 1,
     "storeId": "s", "mapName": "m",
     "coordinateContract": {"unit": "centimetre", "origin": "top_left",
       "x_axis": "right", "y_axis": "down", "rotation_direction": "clockwise_degrees"},
     "elements": [{"id": "f1-r2", "source_row": 2, "floor_id": "1",
       "shape_type": "MapShelf", "visible": true, "locked": false, "code": "S1",
       "cross_code": "", "row_flag": "", "source": {"x": 1, "x": 2}}],
     "warnings": []}
    """
    _ = try JSONMapSourceImporter.importSource(data: Data(json.utf8))
    require(false, "I10 duplicate JSON key must be rejected")
}
catch let error as MapSourceImportError {
    require(
        error.stableCode == "invalid_json",
        "I10 duplicate key must map to invalid_json, got \(error.stableCode)")
}
catch {
    require(false, "I10 duplicate key error type: \(error)")
}

// I13: the bottom-left coordinate preset flips the y axis.
do {
    let csv = """
    floor,element
    1,"{""shapeType"":""MapRoadPoint"",""x"":100,""y"":200,""code"":""P1""}"
    """
    let outcome = try CSVMapSourceImporter.importSource(
        data: Data(csv.utf8),
        contract: .bottomLeft)
    require(
        outcome.elements.count == 1,
        "I13 bottom-left CSV must import 1 element")
    if let coordinates = outcome.elements[0].geometry?["coordinates"] as? [Double] {
        require(
            close(coordinates[0], 1.0) && close(coordinates[1], 2.0),
            "I13 bottom-left must map y=200cm to +2.0m, got \(coordinates)")
    }
    else {
        require(false, "I13 road point must carry point geometry")
    }
}
catch {
    require(false, "I13 bottom-left preset failed: \(error)")
}

// V1R4 §14.1: canonical v2 self round trip — the canonical payload is a
// valid v2 document that re-imports to the same business payload,
// document identity and digest; elements are emitted in stable business
// order; duplicate official identity fails closed.
do {
    func businessEqual(_ lhs: PriorMapSourceElement, _ rhs: PriorMapSourceElement) -> Bool {
        guard lhs.floorId == rhs.floorId, lhs.shapeType == rhs.shapeType,
              lhs.visible == rhs.visible, lhs.locked == rhs.locked,
              lhs.code == rhs.code, lhs.crossCode == rhs.crossCode,
              lhs.rowFlag == rhs.rowFlag,
              lhs.bounds == rhs.bounds, lhs.centerM == rhs.centerM,
              lhs.yawRad == rhs.yawRad else { return false }
        return JSONValueComparer.equal(lhs.subsection, rhs.subsection)
            && JSONValueComparer.equal(lhs.geometry, rhs.geometry)
    }

    let csv = """
    floor,element
    1,"{ ""shapeType"": ""MapShelf"", ""x"": 100, ""y"": 200, ""width"": 300, ""height"": 100, ""code"": ""S1"", ""visible"": true}"
    2,"{ ""shapeType"": ""MapRoadPoint"", ""x"": 100, ""y"": 500, ""width"": 20, ""height"": 20, ""code"": 1}"
    """
    let imported = try CSVMapSourceImporter.importSource(
        data: Data(csv.utf8), contract: .topLeft)
    let source = MarketScannerPriorMapSource(
        format: MarketScannerPriorMapSource.formatValue,
        version: MarketScannerPriorMapSource.versionValue,
        storeId: "round-trip-store", mapName: "round-trip-map",
        source: MapSourceIdentity(
            originalFormat: "csv", originalFilename: "round-trip.csv",
            sourceFileSha256: "a", canonicalSourceSha256: ""),
        coordinateContract: .topLeft,
        elements: imported.elements, warnings: imported.warnings)
    let payload = source.canonicalPayload
    let payloadData = try CanonicalJSONEncoder.encode(payload)
    let originalDigest = CanonicalSourceHasher.sha256(payloadData)

    // Stable business order: payload element ids are sorted.
    if let payloadElements = payload["elements"] as? [[String: Any]] {
        let ids = payloadElements.compactMap { $0["id"] as? String }
        require(ids == ids.sorted(),
                "canonical elements must be in stable business order: \(ids)")
    }
    else {
        require(false, "canonical payload must carry an elements array")
    }

    // Self round trip through the strict v2 decoder.
    let roundTrip = try JSONMapSourceImporter.importSource(data: payloadData)
    require(roundTrip.documentVersion == 2, "canonical payload must decode as v2")
    require(roundTrip.storeId == "round-trip-store"
            && roundTrip.mapName == "round-trip-map",
            "canonical v2 must recover document store/map identity")
    require(roundTrip.coordinateContract == .topLeft,
            "canonical v2 must recover the coordinate contract")
    require(roundTrip.elements.count == 2,
            "canonical v2 round trip must keep element count")
    let originalByID = Dictionary(uniqueKeysWithValues: imported.elements.map {
        (CanonicalPriorMapBusinessSourceV2.stableElementID(
            for: $0, storeID: "round-trip-store", mapName: "round-trip-map"), $0)
    })
    var matched = 0
    for element in roundTrip.elements {
        let stableID = CanonicalPriorMapBusinessSourceV2.stableElementID(
            for: element, storeID: "round-trip-store", mapName: "round-trip-map")
        require(stableID == element.id,
                "round trip must keep stable identity, got \(stableID) != \(element.id)")
        if let original = originalByID[stableID] {
            require(businessEqual(element, original),
                    "round trip must preserve business fields for \(stableID)")
            matched += 1
        }
    }
    require(matched == 2, "round trip must preserve every element, matched \(matched)")

    // Full coordinator round trip: the v2 document is a first-class
    // input whose own contract wins over the wizard parameters and whose
    // canonical digest is byte-identical.
    let staged = try writeTemporary(payloadData, named: "round-trip.json")
    let report = try MapSourceImportCoordinator.importMap(
        stagedURL: staged,
        originalFilename: "round-trip.json",
        contract: .bottomLeft)
    require(report.mapName == "round-trip-map" && report.storeId == "round-trip-store",
            "canonical v2 must override wizard identity")
    require(report.coordinateContractOrigin == CoordinateContract.Origin.topLeft.rawValue,
            "canonical v2 must override the wizard contract")
    require(report.canonicalSourceSha256 == originalDigest,
            "canonical v2 coordinator round trip must be byte-identical")
    require(report.elementCount == 2,
            "canonical v2 coordinator round trip must keep element count")
}
catch {
    require(false, "V1R4 canonical v2 round trip failed: \(error)")
}

// V1R4 §14.1: duplicate official identity fails closed.
do {
    let json = """
    {"format": "MarketScannerPriorMapSource", "version": 2,
     "store_id": "s", "map_name": "m",
     "coordinate_contract": {"unit": "centimetre", "origin": "top_left",
       "x_axis": "right", "y_axis": "down", "rotation_direction": "clockwise_degrees"},
     "elements": [
       {"id": "shelf-1", "floor_id": "1", "shape_type": "MapShelf",
        "visible": true, "locked": false, "code": "S1",
        "source": {"sourceId": "dup"}},
       {"id": "shelf-2", "floor_id": "1", "shape_type": "MapShelf",
        "visible": true, "locked": false, "code": "S2",
        "source": {"sourceId": "dup"}}],
     "warnings": []}
    """
    _ = try MapSourceImportCoordinator.importMap(
        stagedURL: try writeTemporary(Data(json.utf8), named: "duplicate.json"),
        originalFilename: "duplicate.json",
        contract: .topLeft)
    require(false, "duplicate official identity must fail closed")
}
catch let error as MapSourceImportError {
    require(error.stableCode == "map_source_duplicate_element_identity",
            "duplicate identity must map to its frozen code, got \(error.stableCode)")
}
catch {
    require(false, "duplicate identity error type: \(error)")
}

// canonical-source digest is stable for the same business payload
// regardless of the source document bytes.
do {
    let csvA = "floor,element\n1,\"{ \"\"shapeType\"\": \"\"MapShelf\"\", \"\"x\"\": 100, \"\"y\"\": 200, \"\"width\"\": 300, \"\"height\"\": 100}\"\n"
    let csvB = "floor,element\n1,\"{ \"\"shapeType\"\":\"\"MapShelf\"\",\"\"x\"\":100,\"\"y\"\":200,\"\"width\"\":300,\"\"height\"\":100}\"\n"
    let outcomeA = try CSVMapSourceImporter.importSource(
        data: Data(csvA.utf8), contract: .topLeft)
    let outcomeB = try CSVMapSourceImporter.importSource(
        data: Data(csvB.utf8), contract: .topLeft)
    require(
        outcomeA.elements == outcomeB.elements,
        "I4 canonical elements must ignore non-business whitespace")
}
catch {
    require(false, "I4 whitespace-insensitive canonical test failed: \(error)")
}

// I4: canonical elements must ignore non-business whitespace (checked
// above); C7/C8/C10: the mobile compiler emits distance-field payloads
// byte-identical to the PC oracle (data_sha256) and road graphs with the
// same statistics.
do {
    let csv = """
    floor,element
    1,"{""shapeType"":""MapShelf"",""x"":100,""y"":200,""width"":300,""height"":100,""code"":""S1"",""visible"":true}"
    1,"{""shapeType"":""MapCross"",""points"":[0,500,1000,500],""lineWidth"":200,""code"":""C1"",""visible"":true}"
    2,"{""shapeType"":""MapRoadPoint"",""x"":100,""y"":500,""width"":20,""height"":20,""code"":1,""crossCodes"":[""C1""]}"
    1,"{""shapeType"":""MapCross"",""points"":[100,700,900,700],""lineWidth"":180,""code"":""C-hidden"",""visible"":false}"
    1,"{""shapeType"":""MapRoadPoint"",""x"":100,""y"":700,""width"":20,""height"":20,""code"":""A"",""crossCodes"":[""C-hidden""]}"
    1,"{""shapeType"":""MapRoadPoint"",""x"":900,""y"":700,""width"":20,""height"":20,""code"":""B"",""crossCodes"":[""C-hidden""]}"
    """
    let outcome = try CSVMapSourceImporter.importSource(
        data: Data(csv.utf8), contract: .topLeft)
    let source = MarketScannerPriorMapSource(
        format: "MarketScannerPriorMapSource", version: 1,
        storeId: "s1", mapName: "sample",
        source: MapSourceIdentity(
            originalFormat: "csv", originalFilename: "sample.csv",
            sourceFileSha256: "x", canonicalSourceSha256: "y"),
        coordinateContract: .topLeft,
        elements: outcome.elements, warnings: outcome.warnings)
    let output = try p7r6FreshDirectory("mobile-compile")
    let result = try MobilePriorMapCompiler.compile(
        canonicalSource: source, outputDirectory: output)
    require(
        result.floorCount == 2 && result.elementCount == 5,
        "C7 mobile compile must yield 2 floors / 5 active elements, got \(result.floorCount)/\(result.elementCount)")
    require(
        !result.packageSHA256.isEmpty,
        "C7 mobile compile must self-validate and return a package SHA")
    // The compiled package must load through the production snapshot
    // reader (C9 package self-load). The package manifest is carried
    // separately by the snapshot (not inside artifactNames).
    let snapshot = try PriorMapPackageSnapshotReader.read(directory: output)
    require(
        !snapshot.packageManifest.isEmpty
            && snapshot.artifactNames.contains("distance_fields.json")
            && snapshot.artifactNames.contains("preview.png")
            && snapshot.artifactNames.contains("road_graph.json"),
        "C9 compiled package must expose manifest/distance/preview/road artifacts")
    // RC-B01/B17: the production compiler writes shelves v2 with the
    // complete typed segment contract, and the production post-processing
    // loader reopens the exact compiled package using those directions.
    let shelvesData = try Data(contentsOf: output.appendingPathComponent("shelves.json"))
    let shelvesObject = try StrictJSONDocumentParser.object(
        from: shelvesData,
        limits: StrictJSONDocumentLimits(maximumBytes: shelvesData.count + 1))
    let shelvesDocument = try PriorMapShelvesSchema.parse(shelvesObject)
    require(
        shelvesDocument.version == 2 && shelvesDocument.segments.count == 1,
        "RC-B01 compiler must emit one shelves-v2 segment")
    if let compiled = shelvesDocument.segments.first {
        require(
            compiled.shelfSegmentID == shelvesDocument.rawShelves[0]["id"] as? String
                && compiled.shelfCode == "S1"
                && compiled.floorID == "1"
                && compiled.longitudinalStartM.count == 2
                && compiled.longitudinalEndM.count == 2
                && close(hypot(
                    compiled.longitudinalAxis[0],
                    compiled.longitudinalAxis[1]), 1.0, tolerance: 1.0e-6)
                && close(
                    compiled.frontNormal[0] + compiled.backNormal[0],
                    0, tolerance: 1.0e-6)
                && close(
                    compiled.frontNormal[1] + compiled.backNormal[1],
                    0, tolerance: 1.0e-6),
            "RC-B17 compiled shelf identity/direction relations must be complete")
    }
    let loaderEntry = MobileMapLibrary.MapEntry(
        priorMapID: result.priorMapID,
        name: "sample",
        packageSHA256: result.packageSHA256,
        packageDirectory: output,
        floorCount: result.floorCount,
        elementCount: result.elementCount,
        compiledAtUTC: 0,
        compilerVersion: "test",
        canonicalSourceSHA256: String(repeating: "a", count: 64))
    let reopenedShelves = try MobileProcessingPipeline.readShelves(from: loaderEntry)
    require(
        reopenedShelves.count == 1
            && reopenedShelves[0].shelfSegmentID
                == shelvesDocument.segments[0].shelfSegmentID
            && close(
                reopenedShelves[0].startM.0,
                shelvesDocument.segments[0].longitudinalStartM[0])
            && close(
                reopenedShelves[0].axisM.0,
                shelvesDocument.segments[0].longitudinalAxis[0]),
        "RC-B01 production readShelves must reopen compiler-authored v2 directions")

    // Legacy v1 remains readable; unknown versions and malformed v2
    // vectors/fields fail closed.
    var legacyShelves = shelvesObject
    legacyShelves["version"] = 1
    legacyShelves.removeValue(forKey: "shelf_segments")
    let parsedLegacyShelves = try PriorMapShelvesSchema.parse(legacyShelves)
    require(
        parsedLegacyShelves.version == 1,
        "RC-B01 shelves v1 legacy read must remain supported")
    func shelfSchemaRejects(_ object: [String: Any]) -> Bool {
        do {
            _ = try PriorMapShelvesSchema.parse(object)
            return false
        } catch {
            return true
        }
    }
    var unknownVersion = shelvesObject
    unknownVersion["version"] = 3
    require(
        shelfSchemaRejects(unknownVersion),
        "RC-B01 unknown shelves versions must be rejected")
    var invalidAxis = shelvesObject
    var invalidAxisSegments = invalidAxis["shelf_segments"] as! [[String: Any]]
    invalidAxisSegments[0]["longitudinal_axis"] = [0.5, 0.0]
    invalidAxis["shelf_segments"] = invalidAxisSegments
    require(
        shelfSchemaRejects(invalidAxis),
        "RC-B17 non-unit shelf axis must be rejected")
    var unknownSegmentField = shelvesObject
    var unknownFieldSegments = unknownSegmentField["shelf_segments"] as! [[String: Any]]
    unknownFieldSegments[0]["unexpected"] = true
    unknownSegmentField["shelf_segments"] = unknownFieldSegments
    require(
        shelfSchemaRejects(unknownSegmentField),
        "RC-B17 unknown v2 segment fields must be rejected")
    // Distance-field per-level digests are frozen PC-parity values.
    let distance = try MobilePackageManifestBuilder.requiredFilesPresent(directory: output)
    _ = distance
    let distanceData = try Data(contentsOf: output.appendingPathComponent("distance_fields.json"))
    let distanceObject = try StrictJSONDocumentParser.object(
        from: distanceData,
        limits: StrictJSONDocumentLimits(maximumBytes: distanceData.count + 1))
    if let floorsPayload = distanceObject["floors"] as? [String: Any],
       let floor1 = floorsPayload["1"] as? [String: Any],
       let levels = floor1["levels"] as? [[String: Any]],
       let level0 = levels.first,
       let sha = level0["data_sha256"] as? String {
        require(
            sha == "79b4d2bdb1469f45d629c686a633d4145b25ba1030dff1cfdc70ec82cbe85955",
            "C7 floor-1 level-0 distance field must match the PC oracle, got \(sha)")
    }
    else {
        require(false, "C7 distance field structure is invalid")
    }
    // Road graph statistics parity.
    let graphData = try Data(contentsOf: output.appendingPathComponent("road_graph.json"))
    let graphObject = try StrictJSONDocumentParser.object(
        from: graphData,
        limits: StrictJSONDocumentLimits(maximumBytes: graphData.count + 1))
    if let statistics = graphObject["statistics"] as? [String: Any] {
        require(
            (statistics["cross_count"] as? Int) == 2
                && (statistics["node_count"] as? Int) == 3
                && (statistics["edge_count"] as? Int) == 1
                && (statistics["isolated_node_count"] as? Int) == 1,
            "C5 road graph statistics must match the PC oracle: \(statistics)")
        let crosses = graphObject["crosses"] as? [[String: Any]] ?? []
        let inferred = crosses.first {
            ($0["id"] as? String) == "C-hidden"
        }
        require(
            (inferred?["element_id"] as? String) == ""
                && (inferred?["provenance"] as? String)
                    == "road_point_membership_v1"
                && (inferred?["points_m"] as? [[Double]])
                    == [[1.0, -7.0], [9.0, -7.0]],
            "C5 hidden MapCross topology must be recovered from visible road points")
    }
    else {
        require(false, "C5 road graph statistics missing")
    }
}
catch {
    require(false, "C5/C7/C9 mobile compiler tests failed: \(error)")
}

// =====================================================================
// Mobile-Only V1: clock correlation, final 1 Hz trajectory (T1-T12) and
// the four-sheet XLSX workbook (X1-X12).
// =====================================================================

// T1/T6/T7: 1 Hz resampling across a connected segment with one clock
// correlation pair; every UTC second in range gets a row. Nodes are
// placed at fractional monotonic times so the integer UTC seconds land
// between nodes and exercise interpolation.
do {
    var records: [ClockCorrelationRecord] = []
    records.append(ClockCorrelationRecord.make(
        trackingSessionID: "s", monotonicSeconds: 100.0,
        utcUnixSeconds: 1_785_762_000.0, timezoneID: "Asia/Shanghai",
        utcOffsetSeconds: 28_800, reason: "session_start"))
    records.append(ClockCorrelationRecord.make(
        trackingSessionID: "s", monotonicSeconds: 110.0,
        utcUnixSeconds: 1_785_762_010.0, timezoneID: "Asia/Shanghai",
        utcOffsetSeconds: 28_800, reason: "session_end"))
    let mapper = MonotonicUTCMapper(records: records)
    let nodes = [
        FinalTrajectory.Node(
            id: 1, monotonicSeconds: 100.0, xM: 0, yM: 0, yawRad: 0,
            uncertaintyM: 0.1, floorID: "1"),
        FinalTrajectory.Node(
            id: 2, monotonicSeconds: 101.5, xM: 1, yM: 0, yawRad: 0,
            uncertaintyM: 0.2, floorID: "1"),
        FinalTrajectory.Node(
            id: 3, monotonicSeconds: 102.5, xM: 1, yM: 1, yawRad: Double.pi / 2,
            uncertaintyM: 0.1, floorID: "1"),
    ]
    let rows = FinalTrajectory.resample(
        input: FinalTrajectory.Input(
            nodes: nodes, lostIntervals: [],
            sessionStartUTC: 1_785_762_000.0,
            sessionEndUTC: 1_785_762_002.0),
        utcMapper: mapper, storeID: "s1",
        priorMapID: "m", priorMapSha256: "a",
        trackingSessionID: "s", appGitSHA: "g")
    require(
        rows.count == 3,
        "T1 resample must emit one row per UTC second, got \(rows.count)")
    require(
        rows[0].positionStatus == "AVAILABLE"
            && rows[0].unixTimeS == 1_785_762_000,
        "T1 first row must be AVAILABLE at the start second")
    require(
        rows[0].timezoneID == "Asia/Shanghai" && rows[0].utcOffset == 28_800,
        "T1 row must carry the local timezone and offset")
    require(
        rows[0].localTimestamp.contains("+08:00"),
        "T1 local timestamp must include the offset, got \(rows[0].localTimestamp)")
    require(
        rows[0].beforeNodeID == 1 && rows[0].afterNodeID == 2,
        "T1 interpolation must bind before/after node ids")
    // Second 1785762001 -> monotonic 101.0, between node 1 (100.0) and
    // node 2 (101.5): ratio 2/3 -> x = 0.6667, y = 0.
    require(
        close(rows[1].mapXM ?? -1, 0.6666667, tolerance: 1.0e-4),
        "T1 second row must interpolate x to 0.6667m, got \(rows[1].mapXM ?? -1)")
    require(
        close(rows[1].mapYM ?? -1, 0.0),
        "T1 second row y must stay 0, got \(rows[1].mapYM ?? -1)")
    // Second 1785762002 -> monotonic 102.0, between node 2 (101.5) and
    // node 3 (102.5): ratio 0.5 -> x=1, y=0.5, yaw=45 deg.
    require(
        rows[2].positionStatus == "AVAILABLE"
            && close(rows[2].mapXM ?? -1, 1.0)
            && close(rows[2].mapYM ?? -1, 0.5),
        "T1 third row must interpolate across nodes 2->3")
    require(
        close(rows[2].yawDeg ?? -1, 45.0, tolerance: 1.0e-6),
        "T1 third row yaw must be shortest-angle interpolated to 45 deg, got \(rows[2].yawDeg ?? -1)")
    require(
        close(rows[1].estimatedUncertaintyM ?? -1, 0.2),
        "T1 uncertainty must be the conservative upper bound (0.2), got \(rows[1].estimatedUncertaintyM ?? -1)")
}
catch {
    require(false, "T1 basic 1 Hz resampling failed: \(error)")
}

// Partial-result coordinate contract: disconnected components never
// interpolate into each other; unaligned diagnostics populate local_* only;
// an initial-map pose may align one component for review without claiming it
// is a publishable AVAILABLE trajectory.
do {
    let mapper = MonotonicUTCMapper(samples: [
        .init(monotonicSeconds: 0, utcUnixSeconds: 1_785_762_100,
              utcOffsetSeconds: 28_800, timezoneID: "Asia/Shanghai"),
        .init(monotonicSeconds: 2, utcUnixSeconds: 1_785_762_102,
              utcOffsetSeconds: 28_800, timezoneID: "Asia/Shanghai"),
    ], discontinuityEdges: [])
    let localRows = FinalTrajectory.resample(
        input: FinalTrajectory.Input(
            nodes: [
                .init(id: 1, monotonicSeconds: 0, xM: 10, yM: 20,
                      yawRad: 0, uncertaintyM: nil, floorID: "1",
                      componentID: 1),
                .init(id: 2, monotonicSeconds: 2, xM: 12, yM: 20,
                      yawRad: 0, uncertaintyM: nil, floorID: "1",
                      componentID: 1),
            ],
            lostIntervals: [],
            sessionStartUTC: 1_785_762_100,
            sessionEndUTC: 1_785_762_102,
            graphQualityStatus: "RECOVERABLE_FAIL",
            positionSource: "native_local_frame_diagnostic",
            coordinatesArePriorMapFrame: false,
            allowUnverifiedCoordinatesWithoutUncertainty: true),
        utcMapper: mapper, storeID: "s1",
        priorMapID: "m", priorMapSha256: "a",
        trackingSessionID: "s", appGitSHA: "g")
    require(
        localRows.count == 3
            && localRows.allSatisfy {
                $0.positionStatus == "LOCAL_FRAME_ONLY"
                    && $0.mapXM == nil && $0.mapYM == nil && $0.yawDeg == nil
                    && $0.localXM != nil && $0.localYM != nil
                    && $0.coordinateFrame == "LOCAL_DIAGNOSTIC"
            },
        "partial local trajectory must never masquerade as prior-map coordinates")

    let componentRows = FinalTrajectory.resample(
        input: FinalTrajectory.Input(
            nodes: [
                .init(id: 1, monotonicSeconds: 0, xM: 0, yM: 0,
                      yawRad: 0, uncertaintyM: 0.1, floorID: "1",
                      componentID: 1),
                .init(id: 2, monotonicSeconds: 1, xM: 1, yM: 0,
                      yawRad: 0, uncertaintyM: 0.1, floorID: "1",
                      componentID: 1),
                .init(id: 3, monotonicSeconds: 1.5, xM: 50, yM: 50,
                      yawRad: 0, uncertaintyM: 0.1, floorID: "1",
                      componentID: 2),
            ],
            lostIntervals: [],
            sessionStartUTC: 1_785_762_100,
            sessionEndUTC: 1_785_762_102),
        utcMapper: mapper, storeID: "s1",
        priorMapID: "m", priorMapSha256: "a",
        trackingSessionID: "s", appGitSHA: "g")
    require(
        componentRows[2].positionStatus == "UNAVAILABLE",
        "final trajectory must not interpolate across disconnected components")

    let nativeRows = [
        MobileNativeTrajectoryRow(
            id: 1, stamp: 100, xM: 1, yM: 2, yawRad: 0,
            mapID: 0, componentID: 7, publishEligible: false,
            uncertaintyM: nil),
        MobileNativeTrajectoryRow(
            id: 2, stamp: 101, xM: 2, yM: 2, yawRad: 0,
            mapID: 0, componentID: 7, publishEligible: false,
            uncertaintyM: nil),
        MobileNativeTrajectoryRow(
            id: 3, stamp: 50, xM: 99, yM: 99, yawRad: 0,
            mapID: 0, componentID: 8, publishEligible: false,
            uncertaintyM: nil),
    ]
    let initial = MobileAbsolutePrior(
        nodeID: 1, mapXM: 10, mapYM: 20, mapYawRad: Double.pi / 2,
        information3x3: [1, 0, 0, 0, 1, 0, 0, 0, 1],
        kind: 3, episodeID: 0)
    let aligned = MobileProcessingPipeline.diagnosticTrajectorySelection(
        rows: nativeRows, graphQualityPassed: true,
        initialMapPose: initial, floorID: "1")
    require(
        aligned.rows.count == 2
            && aligned.rows.allSatisfy { $0.componentID == 7 }
            && aligned.coordinatesArePriorMapFrame
            && aligned.positionSource == "diagnostic_initial_map_pose"
            && close(aligned.rows[0].xM, 10)
            && close(aligned.rows[0].yM, 20)
            && !aligned.rows[0].publishEligible,
        "PASS without publish nodes must retain a non-publishable map-aligned diagnostic component")
    let alignedMapper = MonotonicUTCMapper(samples: [
        .init(monotonicSeconds: 0, utcUnixSeconds: 1_785_762_200,
              utcOffsetSeconds: 28_800, timezoneID: "Asia/Shanghai"),
        .init(monotonicSeconds: 1, utcUnixSeconds: 1_785_762_201,
              utcOffsetSeconds: 28_800, timezoneID: "Asia/Shanghai"),
    ], discontinuityEdges: [])
    let alignedRows = FinalTrajectory.resample(
        input: FinalTrajectory.Input(
            nodes: aligned.rows.map {
                FinalTrajectory.Node(
                    id: $0.id, monotonicSeconds: $0.stamp - 100,
                    xM: $0.xM, yM: $0.yM, yawRad: $0.yawRad,
                    uncertaintyM: $0.uncertaintyM, floorID: "1",
                    componentID: $0.componentID)
            },
            lostIntervals: [],
            sessionStartUTC: 1_785_762_200,
            sessionEndUTC: 1_785_762_201,
            graphQualityStatus: "PASS",
            positionSource: aligned.positionSource,
            coordinatesArePriorMapFrame: true,
            allowUnverifiedCoordinatesWithoutUncertainty: true),
        utcMapper: alignedMapper, storeID: "s1",
        priorMapID: "m", priorMapSha256: "a",
        trackingSessionID: "s", appGitSHA: "g")
    require(
        alignedRows.count == 2
            && alignedRows.allSatisfy {
                $0.positionStatus == "DEGRADED_MAP_ALIGNED"
                    && $0.mapXM != nil && $0.mapYM != nil
                    && $0.estimatedUncertaintyM == nil
            },
        "PASS without publish nodes must keep finite diagnostic coordinates even when covariance is unavailable")

    let localSelection = MobileProcessingPipeline.diagnosticTrajectorySelection(
        rows: nativeRows, graphQualityPassed: false,
        initialMapPose: nil, floorID: "1")
    require(
        localSelection.rows.count == 2
            && localSelection.rows.allSatisfy { $0.componentID == 7 }
            && !localSelection.coordinatesArePriorMapFrame,
        "local diagnostic selection must retain one deterministic primary component")

    let clockUnavailableRows = FinalTrajectory.resample(
        input: FinalTrajectory.Input(
            nodes: [
                .init(id: 1, monotonicSeconds: 0, xM: 0, yM: 0,
                      yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
                .init(id: 2, monotonicSeconds: 2, xM: 2, yM: 0,
                      yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
            ],
            lostIntervals: [],
            sessionStartUTC: 1_785_762_300,
            sessionEndUTC: 1_785_762_302),
        utcMapper: MonotonicUTCMapper(samples: [], discontinuityEdges: []),
        storeID: "s1", priorMapID: "m", priorMapSha256: "a",
        trackingSessionID: "s", appGitSHA: "g")
    require(
        clockUnavailableRows.count == 3
            && clockUnavailableRows.allSatisfy {
                $0.positionStatus == "UNAVAILABLE"
                    && $0.mapXM == nil && $0.mapYM == nil
            },
        "insufficient clock binding coverage must retain every session second as UNAVAILABLE")
}
catch {
    require(false, "partial-result coordinate contract failed: \(error)")
}

// T3: yaw crossing ±pi interpolates the shortest way.
do {
    var records: [ClockCorrelationRecord] = []
    records.append(ClockCorrelationRecord.make(
        trackingSessionID: "s", monotonicSeconds: 0,
        utcUnixSeconds: 1_000_000_000, timezoneID: "UTC",
        utcOffsetSeconds: 0, reason: "start"))
    records.append(ClockCorrelationRecord.make(
        trackingSessionID: "s", monotonicSeconds: 100,
        utcUnixSeconds: 1_000_000_100, timezoneID: "UTC",
        utcOffsetSeconds: 0, reason: "end"))
    let mapper = MonotonicUTCMapper(records: records)
    let nodes = [
        FinalTrajectory.Node(
            id: 1, monotonicSeconds: 0, xM: 0, yM: 0, yawRad: 3.0,
            uncertaintyM: 0.1, floorID: "1"),
        FinalTrajectory.Node(
            id: 2, monotonicSeconds: 2, xM: 1, yM: 0, yawRad: -3.0,
            uncertaintyM: 0.1, floorID: "1"),
    ]
    let rows = FinalTrajectory.resample(
        input: FinalTrajectory.Input(
            nodes: nodes, lostIntervals: [],
            sessionStartUTC: 1_000_000_000,
            sessionEndUTC: 1_000_000_001),
        utcMapper: mapper, storeID: "s1",
        priorMapID: "m", priorMapSha256: "a",
        trackingSessionID: "s", appGitSHA: "g")
    require(
        rows.count == 2 && rows[0].positionStatus == "AVAILABLE",
        "T3 yaw interpolation must produce accepted rows")
    // Shortest arc from +3.0 to -3.0 passes through +pi (not through 0).
    let interpolatedYaw = (rows[0].yawDeg ?? 0) * Double.pi / 180.0
    require(
        abs(interpolatedYaw - 3.0) < 0.01 || abs(interpolatedYaw - Double.pi) < 0.01,
        "T3 yaw must take the shortest arc through +pi, got \(rows[0].yawDeg ?? 0) deg")
}
catch {
    require(false, "T3 yaw shortest-arc failed: \(error)")
}

// T4/T5: lost intervals and floor changes emit UNAVAILABLE rows.
do {
    var records: [ClockCorrelationRecord] = []
    records.append(ClockCorrelationRecord.make(
        trackingSessionID: "s", monotonicSeconds: 0,
        utcUnixSeconds: 2_000_000_000, timezoneID: "UTC",
        utcOffsetSeconds: 0, reason: "start"))
    records.append(ClockCorrelationRecord.make(
        trackingSessionID: "s", monotonicSeconds: 100,
        utcUnixSeconds: 2_000_000_100, timezoneID: "UTC",
        utcOffsetSeconds: 0, reason: "end"))
    let mapper = MonotonicUTCMapper(records: records)
    // Nodes at 0-1s and 9-10s (monotonic); a lost interval covers 3-7s.
    let nodes = [
        FinalTrajectory.Node(id: 1, monotonicSeconds: 0, xM: 0, yM: 0, yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
        FinalTrajectory.Node(id: 2, monotonicSeconds: 1, xM: 1, yM: 0, yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
        FinalTrajectory.Node(id: 3, monotonicSeconds: 9, xM: 1, yM: 1, yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
        FinalTrajectory.Node(id: 4, monotonicSeconds: 10, xM: 2, yM: 1, yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
    ]
    let rows = FinalTrajectory.resample(
        input: FinalTrajectory.Input(
            nodes: nodes,
            lostIntervals: [FinalTrajectory.LostInterval(
                fromMonotonic: 3, toMonotonic: 7, reason: "tracking_lost")],
            sessionStartUTC: 2_000_000_000,
            sessionEndUTC: 2_000_000_009),
        utcMapper: mapper, storeID: "s1",
        priorMapID: "m", priorMapSha256: "a",
        trackingSessionID: "s", appGitSHA: "g")
    require(rows.count == 10, "T4 must emit 10 rows, got \(rows.count)")
    // Seconds 3..7 (0-indexed rows) fall inside the lost interval.
    let lostRows = rows.enumerated().filter { (3...7).contains($0.offset) }
    require(
        lostRows.allSatisfy { $0.element.positionStatus == "UNAVAILABLE" },
        "T4 lost-interval seconds must be UNAVAILABLE")
    // Seconds 8 falls between nodes at monotonic 1 and 9 (8s gap > 3s)
    // -> UNAVAILABLE; second 9 lands exactly on node 3 -> AVAILABLE.
    require(
        rows[8].positionStatus == "UNAVAILABLE",
        "T4 over-long node gaps must be UNAVAILABLE")
    require(
        rows[9].positionStatus == "AVAILABLE",
        "T4 a second landing on a node after a gap must be AVAILABLE")
    require(
        rows[0].positionStatus == "AVAILABLE",
        "T4 connected seconds must stay AVAILABLE")
    // Second 1 (monotonic 1) has no upper node within the interpolation
    // window (node at 9 is 8s away) -> UNAVAILABLE.
    require(
        rows[1].positionStatus == "UNAVAILABLE",
        "T4 a node isolated by an over-long forward gap must be UNAVAILABLE")
}
catch {
    require(false, "T4 lost interval failed: \(error)")
}

// RC-B22: an exact hit on the final node remains AVAILABLE, stale or
// wrong-floor trace state is not reused, and a discontinuity row chooses
// the nearest segment's timezone instead of the session's first timezone.
do {
    let exactMapper = MonotonicUTCMapper(samples: [
        .init(monotonicSeconds: 0, utcUnixSeconds: 3_000_000_000,
              utcOffsetSeconds: 0, timezoneID: "UTC"),
        .init(monotonicSeconds: 2, utcUnixSeconds: 3_000_000_002,
              utcOffsetSeconds: 0, timezoneID: "UTC"),
    ], discontinuityEdges: [])
    let exactRows = FinalTrajectory.resample(
        input: FinalTrajectory.Input(
            nodes: [
                .init(id: 1, monotonicSeconds: 0, xM: 0, yM: 0,
                      yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
                .init(id: 2, monotonicSeconds: 2, xM: 2, yM: 0,
                      yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
            ],
            lostIntervals: [],
            sessionStartUTC: 3_000_000_000,
            sessionEndUTC: 3_000_000_002,
            traceStates: [
                .init(timestamp: 0.2, trackingState: "normal",
                      localizationState: "stable", confidence: 0.9,
                      floorID: "1"),
                .init(timestamp: 2.0, trackingState: "normal",
                      localizationState: "stable", confidence: 1.0,
                      floorID: "2"),
            ]),
        utcMapper: exactMapper, storeID: "s1",
        priorMapID: "m", priorMapSha256: "a",
        trackingSessionID: "s", appGitSHA: "g")
    require(
        exactRows.count == 3
            && exactRows[2].positionStatus == "AVAILABLE"
            && exactRows[2].beforeNodeID == 2
            && exactRows[2].afterNodeID == 2,
        "RC-B22 exact final node must remain AVAILABLE")
    require(
        exactRows[2].trackingState == "unknown"
            && exactRows[2].localizationConfidence == nil,
        "RC-B22 stale/wrong-floor trace state must not contaminate final row")

    let jumpMapper = MonotonicUTCMapper(samples: [
        .init(monotonicSeconds: 0, utcUnixSeconds: 4_000_000_000,
              utcOffsetSeconds: 0, timezoneID: "UTC"),
        .init(monotonicSeconds: 1, utcUnixSeconds: 4_000_000_010,
              utcOffsetSeconds: 28_800, timezoneID: "Asia/Shanghai"),
    ], discontinuityEdges: [0])
    let jumpRows = FinalTrajectory.resample(
        input: FinalTrajectory.Input(
            nodes: [
                .init(id: 1, monotonicSeconds: 0, xM: 0, yM: 0,
                      yawRad: 0, uncertaintyM: 0.1, floorID: "1"),
            ],
            lostIntervals: [],
            sessionStartUTC: 4_000_000_006,
            sessionEndUTC: 4_000_000_006),
        utcMapper: jumpMapper, storeID: "s1",
        priorMapID: "m", priorMapSha256: "a",
        trackingSessionID: "s", appGitSHA: "g")
    require(
        jumpRows.count == 1
            && jumpRows[0].positionStatus == "UNAVAILABLE"
            && jumpRows[0].timezoneID == "Asia/Shanghai"
            && jumpRows[0].utcOffset == 28_800,
        "RC-B22 discontinuity row must use nearest post-change timezone")
}
catch {
    require(false, "RC-B22 final trajectory regression tests failed: \(error)")
}

// RC-B06: the clock writer is genuinely incremental and its durable
// watermark advances only after fsync. Exercise the production-scale
// 60k node-binding ceiling and deterministic fault stages.
do {
    let directory = try p7r6FreshDirectory("clock-writer")
    let url = directory.appendingPathComponent("clock_correlations.jsonl")
    let writer = try ClockCorrelationRecorder(
        trackingSessionID: "clock-writer-session", url: url)
    try writer.record(
        reason: .sessionStart,
        monotonicSeconds: 1,
        utcUnixSeconds: 2_000_000_001,
        timezoneID: "UTC",
        utcOffsetSeconds: 0)
    let bindingCount = GeneratedMobileEvidenceContracts.ProductScale
        .maxClockNodeBindings
    for nodeID in 1...bindingCount {
        let timestamp = Double(nodeID) + 1
        try writer.recordNodeBinding(
            nodeID: nodeID,
            nodeStamp: timestamp,
            sampledFrameTimestamp: timestamp,
            systemUptime: timestamp,
            utcUnixSeconds: 2_000_000_000 + timestamp,
            timezoneID: "UTC",
            utcOffsetSeconds: 0)
    }
    try writer.record(
        reason: .sessionEnd,
        monotonicSeconds: Double(bindingCount) + 2,
        utcUnixSeconds: 2_000_000_000 + Double(bindingCount) + 2,
        timezoneID: "UTC",
        utcOffsetSeconds: 0)
    let watermark = try writer.finish()
    require(
        watermark.correlationCount == 2
            && watermark.nodeBindingCount == bindingCount
            && watermark.evidenceComplete,
        "RC-B06 durable watermark must exactly match 2 correlations + \(bindingCount) bindings")
    require(
        writer.records.count == 2,
        "RC-B06 writer must not retain 60k node bindings in memory")
    let clockBytes = try Data(contentsOf: url)
    require(
        clockBytes.last == 0x0A,
        "RC-B06 clock sidecar must end in exactly a complete JSONL line")
    let clockSummary = try StrictJSONLStreamReader.forEachLine(
        from: url,
        limits: StrictJSONLStreamReader.Limits(
            maximumFileBytes: GeneratedMobileEvidenceContracts
                .File_clock_correlations_jsonl.max_file_bytes,
            maximumLineBytes: GeneratedMobileEvidenceContracts
                .File_clock_correlations_jsonl.max_record_bytes,
            maximumLineCount: GeneratedMobileEvidenceContracts
                .File_clock_correlations_jsonl.max_records),
        body: { _ in })
    require(
        clockSummary.lineCount == bindingCount + 2,
        "RC-B06 strict framing count must match every durable record")

    enum ClockInjectedFailure: Error { case injected }
    func throwsAt(
        _ injectedStage: ClockSidecarWriteStage,
        _ body: (URL, @escaping (ClockSidecarWriteStage) throws -> Void) throws -> Void
    ) throws {
        let failureURL = directory.appendingPathComponent(
            "\(UUID().uuidString)-clock_correlations.jsonl")
        // The production initializer requires the frozen basename.
        let caseDirectory = directory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: caseDirectory, withIntermediateDirectories: false)
        let exactURL = caseDirectory.appendingPathComponent(
            "clock_correlations.jsonl")
        _ = failureURL
        try body(exactURL) { stage in
            switch (stage, injectedStage) {
            case (.create, .create),
                 (.parentSync, .parentSync),
                 (.append, .append),
                 (.dataSync, .dataSync),
                 (.close, .close):
                throw ClockInjectedFailure.injected
            default:
                break
            }
        }
    }

    for stage in [ClockSidecarWriteStage.create, .parentSync] {
        try throwsAt(stage) { failureURL, injector in
            do {
                _ = try ClockCorrelationRecorder(
                    trackingSessionID: "fault", url: failureURL,
                    faultInjector: injector)
                require(false, "RC-B06 \(stage) fault must fail initialization")
            } catch {}
            require(
                !FileManager.default.fileExists(atPath: failureURL.path),
                "RC-B06 \(stage) fault must not leave a visible sidecar")
        }
    }

    try throwsAt(.append) { failureURL, injector in
        let failedWriter = try ClockCorrelationRecorder(
            trackingSessionID: "fault", url: failureURL,
            faultInjector: injector)
        do {
            try failedWriter.record(
                reason: .sessionStart, monotonicSeconds: 1,
                utcUnixSeconds: 2, timezoneID: "UTC",
                utcOffsetSeconds: 0)
            require(false, "RC-B06 append fault must throw")
        } catch {}
        do {
            try failedWriter.record(
                reason: .periodic, monotonicSeconds: 2,
                utcUnixSeconds: 3, timezoneID: "UTC",
                utcOffsetSeconds: 0)
            require(false, "RC-B06 failed writer must remain failed")
        } catch let error as ClockSidecarWriteError {
            if case .writerFailed = error {} else {
                require(false, "RC-B06 subsequent append must be writerFailed")
            }
        }
        failedWriter.cancel()
    }

    for stage in [ClockSidecarWriteStage.dataSync, .close] {
        try throwsAt(stage) { failureURL, injector in
            let failedWriter = try ClockCorrelationRecorder(
                trackingSessionID: "fault", url: failureURL,
                faultInjector: injector)
            try failedWriter.record(
                reason: .sessionStart, monotonicSeconds: 1,
                utcUnixSeconds: 2, timezoneID: "UTC",
                utcOffsetSeconds: 0)
            do {
                _ = try failedWriter.finish()
                require(false, "RC-B06 \(stage) fault must block watermark")
            } catch {}
            failedWriter.cancel()
        }
    }
    print("RC-B06 clock writer passed: bindings=\(bindingCount) fault-stages=5")
} catch {
    require(false, "RC-B06 clock writer tests failed: \(error)")
}

// T12: 100k rows export inside a real workbook (X6), plus formula
// injection and control-character sanitization (X8/X9). The 100k-scale
// run lives in the separate --xlsx-scale mode so the default host mode
// stays within the frozen peak-RSS gate.
do {

    // X1-X9 round-trip over a bounded workbook (10k rows keeps the
    // worksheet inside the frozen 64 MiB import-reader entry limit and
    // the default mode inside the peak-RSS gate).
    let output = try p7r6FreshDirectory("mobile-xlsx")
        .appendingPathComponent("result.xlsx")
    try MobileResultExporter.export(
        input: makeInput(positions: makePositions(10_000)), to: output)
    let data = try Data(contentsOf: output)
    let entries = try XLSXZipReader.readEntries(data: data)
    let names = Set(entries.map { $0.name })
    require(
        names.contains("xl/workbook.xml")
            && names.contains("[Content_Types].xml")
            && names.contains("xl/worksheets/sheet1.xml")
            && names.contains("xl/worksheets/sheet2.xml")
            && names.contains("xl/worksheets/sheet3.xml")
            && names.contains("xl/worksheets/sheet4.xml"),
        "X1/X4 workbook must be a real Open XML package with 4 sheets")
    let workbookXML = String(
        data: entries.first { $0.name == "xl/workbook.xml" }!.data,
        encoding: .utf8) ?? ""
    require(
        workbookXML.contains("PriceTags")
            && workbookXML.contains("DevicePositions")
            && workbookXML.contains("RunSummary")
            && workbookXML.contains("RescanRequired"),
        "X4 workbook must name the four required sheets")
    let sheet1 = String(
        data: entries.first { $0.name == "xl/worksheets/sheet1.xml" }!.data,
        encoding: .utf8) ?? ""
    require(
        sheet1.contains("=HYPERLINK"),
        "X8 formula-like barcode must keep its exact value (inline string)")
    require(
        !sheet1.contains("&apos;=HYPERLINK") && !sheet1.contains("'=HYPERLINK"),
        "X8 no apostrophe prefix may alter the barcode (V1R1 14.7)")
    require(
        !sheet1.contains("<f>"),
        "X8 the workbook must never contain formula elements")
    require(
        sheet1.contains("shelf_segment_id")
            && sheet1.contains("segment-a1-main"),
        "RC-B17 PriceTags XLSX must carry the physical shelf segment ID")
    let sheet4 = String(
        data: entries.first { $0.name == "xl/worksheets/sheet4.xml" }!.data,
        encoding: .utf8) ?? ""
    require(
        sheet4.contains("shelf_segment_id")
            && sheet4.contains("segment-b2-main"),
        "RC-B17 RescanRequired XLSX must carry the physical shelf segment ID")
    let sanitized = XLSXWorkbookWriter.sanitizeXML("a\u{0001}b\u{0008}c")
    require(
        sanitized == "abc",
        "X9 control characters must be stripped, got \(sanitized)")
    require(
        XLSXWorkbookWriter.sanitizeXML("&<>\"") == "&amp;&lt;&gt;&quot;",
        "X9 XML specials must be escaped")
    // V1R4 §16.2: the production reopen verifier streams the package
    // (central directory + required parts + per-sheet header/row/
    // no-formula) without materialising the sheets.
    let expectedWorkbookSheets = [
            XLSXWorkbookVerifier.SheetExpectation(
                partName: "xl/worksheets/sheet1.xml",
                sheetName: "PriceTags",
                headers: MobileWorksheets.priceTagsHeaders),
            XLSXWorkbookVerifier.SheetExpectation(
                partName: "xl/worksheets/sheet2.xml",
                sheetName: "DevicePositions",
                headers: MobileWorksheets.devicePositionsHeaders),
            XLSXWorkbookVerifier.SheetExpectation(
                partName: "xl/worksheets/sheet3.xml",
                sheetName: "RunSummary",
                headers: MobileWorksheets.runSummaryHeaders),
            XLSXWorkbookVerifier.SheetExpectation(
                partName: "xl/worksheets/sheet4.xml",
                sheetName: "RescanRequired",
                headers: MobileWorksheets.rescanRequiredHeaders),
        ]
    let verification = try XLSXWorkbookVerifier.verify(
        workbookURL: output,
        expectedSheets: expectedWorkbookSheets)
    require(
        verification.sheetRowCounts["xl/worksheets/sheet2.xml"] == 10_000,
        "X1 verifier must count 10k DevicePositions rows")
    require(
        verification.sheetRowCounts["xl/worksheets/sheet1.xml"] == 1,
        "X1 verifier must count the price-tag row")
    // RC-B28: required non-sheet parts are not accepted by central-name
    // presence alone. Corrupt the declared CRC in BOTH local and central
    // headers for styles.xml; header consistency still holds, so only an
    // actual payload CRC recomputation can reject it.
    func little16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }
    func little32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
    func write32(_ value: UInt32, _ bytes: inout [UInt8], _ offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
    var corruptedPackage = [UInt8](data)
    var centralCursor = 0
    var corruptedStyles = false
    while centralCursor + 46 <= corruptedPackage.count {
        if little32(corruptedPackage, centralCursor) != 0x02014B50 {
            centralCursor += 1
            continue
        }
        let nameLength = little16(corruptedPackage, centralCursor + 28)
        let extraLength = little16(corruptedPackage, centralCursor + 30)
        let commentLength = little16(corruptedPackage, centralCursor + 32)
        let nameStart = centralCursor + 46
        let nameEnd = nameStart + nameLength
        guard nameEnd <= corruptedPackage.count else { break }
        let name = String(bytes: corruptedPackage[nameStart..<nameEnd],
                          encoding: .utf8) ?? ""
        if name == "xl/styles.xml" {
            let localOffset = Int(little32(corruptedPackage, centralCursor + 42))
            let wrongCRC = little32(corruptedPackage, centralCursor + 16)
                ^ 0xFFFF_FFFF
            write32(wrongCRC, &corruptedPackage, centralCursor + 16)
            write32(wrongCRC, &corruptedPackage, localOffset + 14)
            let localNameLength = little16(corruptedPackage, localOffset + 26)
            let localExtraLength = little16(corruptedPackage, localOffset + 28)
            let compressedSize = Int(little32(
                corruptedPackage, centralCursor + 20))
            let descriptorOffset = localOffset + 30 + localNameLength
                + localExtraLength + compressedSize
            if little32(corruptedPackage, descriptorOffset) == 0x08074B50 {
                write32(wrongCRC, &corruptedPackage, descriptorOffset + 4)
            } else {
                write32(wrongCRC, &corruptedPackage, descriptorOffset)
            }
            corruptedStyles = true
            break
        }
        centralCursor = nameEnd + extraLength + commentLength
    }
    require(corruptedStyles, "RC-B28 styles.xml central entry must exist")
    let corruptOutput = output.deletingLastPathComponent()
        .appendingPathComponent("result-corrupt-styles.xlsx")
    try Data(corruptedPackage).write(to: corruptOutput)
    do {
        _ = try XLSXWorkbookVerifier.verify(
            workbookURL: corruptOutput,
            expectedSheets: expectedWorkbookSheets)
        require(false, "RC-B28 corrupt required styles.xml CRC must reject")
    } catch let error as XLSXWorkbookVerifier.VerifyError {
        if case .crcMismatch(let part) = error {
            require(part == "xl/styles.xml", "RC-B28 wrong CRC part: \(part)")
        } else {
            require(false, "RC-B28 expected styles CRC mismatch, got \(error)")
        }
    }
}
catch {
    require(false, "X6/X8/X9 workbook tests failed: \(error)")
}

// Formal XLSX interoperability: namespace prefixes are legal on workbook,
// relationship and shared-string elements, and ZIP bit-3 data descriptors
// may omit their optional signature.
do {
    let prefixedEntries = [
        XLSXZipReader.Entry(
            name: "xl/workbook.xml",
            data: Data((
                "<x:workbook xmlns:x=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
                    + "<x:sheets><x:sheet name=\"Element Info\" r:id=\"rId1\"/>"
                    + "</x:sheets></x:workbook>"
            ).utf8)),
        XLSXZipReader.Entry(
            name: "xl/_rels/workbook.xml.rels",
            data: Data((
                "<pr:Relationships xmlns:pr=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                    + "<pr:Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" "
                    + "Target=\"worksheets/sheet1.xml\"/>"
                    + "</pr:Relationships>"
            ).utf8)),
        XLSXZipReader.Entry(
            name: "xl/sharedStrings.xml",
            data: Data((
                "<x:sst xmlns:x=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><x:si><x:t>Element Info</x:t>"
                    + "</x:si></x:sst>"
            ).utf8)),
    ]
    let prefixedSheets = try XLSXWorkbookReader.readSheets(entries: prefixedEntries)
    let prefixedRelationships = try XLSXWorkbookReader.readRelationships(
        entries: prefixedEntries)
    let prefixedStrings = try XLSXWorkbookReader.readSharedStrings(
        entries: prefixedEntries)
    require(
        prefixedSheets.count == 1
            && prefixedSheets[0].name == "Element Info"
            && prefixedSheets[0].relationshipID == "rId1"
            && prefixedRelationships.count == 1
            && prefixedRelationships[0].target == "worksheets/sheet1.xml"
            && prefixedStrings == ["Element Info"],
        "formal XLSX prefixed workbook/rels/sharedStrings must parse by local name")

    func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }
    func append32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
    let memberName = Data("payload.bin".utf8)
    let memberPayload = Data("abc".utf8)
    let memberCRC: UInt32 = 0x3524_41C2
    var unsignedDescriptorZIP = Data()
    append32(0x0403_4B50, to: &unsignedDescriptorZIP)
    append16(20, to: &unsignedDescriptorZIP)
    append16(0x0008, to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    append32(0, to: &unsignedDescriptorZIP)
    append32(0, to: &unsignedDescriptorZIP)
    append32(0, to: &unsignedDescriptorZIP)
    append16(UInt16(memberName.count), to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    unsignedDescriptorZIP.append(memberName)
    unsignedDescriptorZIP.append(memberPayload)
    append32(memberCRC, to: &unsignedDescriptorZIP)
    append32(UInt32(memberPayload.count), to: &unsignedDescriptorZIP)
    append32(UInt32(memberPayload.count), to: &unsignedDescriptorZIP)
    let centralOffset = UInt32(unsignedDescriptorZIP.count)
    append32(0x0201_4B50, to: &unsignedDescriptorZIP)
    append16(20, to: &unsignedDescriptorZIP)
    append16(20, to: &unsignedDescriptorZIP)
    append16(0x0008, to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    append32(memberCRC, to: &unsignedDescriptorZIP)
    append32(UInt32(memberPayload.count), to: &unsignedDescriptorZIP)
    append32(UInt32(memberPayload.count), to: &unsignedDescriptorZIP)
    append16(UInt16(memberName.count), to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    append32(0, to: &unsignedDescriptorZIP)
    append32(0, to: &unsignedDescriptorZIP)
    unsignedDescriptorZIP.append(memberName)
    let centralSize = UInt32(unsignedDescriptorZIP.count) - centralOffset
    append32(0x0605_4B50, to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    append16(1, to: &unsignedDescriptorZIP)
    append16(1, to: &unsignedDescriptorZIP)
    append32(centralSize, to: &unsignedDescriptorZIP)
    append32(centralOffset, to: &unsignedDescriptorZIP)
    append16(0, to: &unsignedDescriptorZIP)
    let unsignedEntries = try XLSXZipReader.readEntries(
        data: unsignedDescriptorZIP)
    require(
        unsignedEntries.count == 1
            && unsignedEntries[0].name == "payload.bin"
            && unsignedEntries[0].data == memberPayload,
        "ZIP bit-3 unsigned data descriptor must be accepted and verified")
}
catch {
    require(false, "formal XLSX prefix/data-descriptor tests failed: \(error)")
}

// =====================================================================
// Mobile-Only V1: tag finalization (G1-G10): node/time binding, position
// propagation, burst fusion, shelf association and the quality gate.
// =====================================================================

// G1/G2: explicit snapshot-node binding, propagation and the strict
// time-delta / unlocalized gates (V1R4 §13.2, V1R5 §6.5: the parser
// binds the node; the resolver verifies the exact raw stamp via the
// O(1) index — the 5-second nearest fallback is gone).
do {
    let finalNodes = [
        TagObservationResolver.FinalNodePose(
            id: 10, monotonicSeconds: 500.0,
            pose: SE2Transform(xM: 2, yM: 3, yawRad: 0),
            floorID: "1"),
        TagObservationResolver.FinalNodePose(
            id: 11, monotonicSeconds: 501.5,
            pose: SE2Transform(xM: 2, yM: 4, yawRad: Double.pi / 2),
            floorID: "1"),
    ]
    let index = TagObservationResolver.NodeIndex(
        finalNodes: finalNodes,
        rawNodeStamps: [10: 500.0, 11: 501.5])
    // Explicit node 10 with node-local position (0, 0).
    let resolved = try TagObservationResolver.resolve(
        observation: TagObservationResolver.RawObservation(
            barcode: "6901", symbology: "CODE128", floorID: "1",
            nodeID: 10, nodeTimestamp: 500.0, frameMonotonicSeconds: 500.0,
            rawPositionM: (0, 0, 0),
            trackingSessionID: "s"),
        index: index, sessionID: "s")
    require(
        resolved.mapXM == 2 && resolved.mapYM == 3 && resolved.nodeID == 10
            && resolved.bindingMethod == "explicit_node",
        "G1 explicit-node binding must propagate to (2,3), got \(resolved.mapXM),\(resolved.mapYM)")
    // Node-local position is (-1, 0); T_final(node 11) = (2, 4, +90deg) rotates
    // (-1, 0) to (0, -1), so P_final = (2, 3).
    let resolved2 = try TagObservationResolver.resolve(
        observation: TagObservationResolver.RawObservation(
            barcode: "6902", symbology: "CODE128", floorID: "1",
            nodeID: 11, nodeTimestamp: 501.5, frameMonotonicSeconds: 501.5,
            rawPositionM: (-1, 0, 0),
            trackingSessionID: "s"),
        index: index, sessionID: "s")
    require(
        close(resolved2.mapXM, 2.0) && close(resolved2.mapYM, 3.0),
        "G1 position propagation must apply T_final*P_node once, got \(resolved2.mapXM),\(resolved2.mapYM)")
    let nonzeroGauge = try TagObservationResolver.resolve(
        observation: TagObservationResolver.RawObservation(
            barcode: "6902-gauge", symbology: "CODE128", floorID: "1",
            nodeID: 12, nodeTimestamp: 502.0,
            frameMonotonicSeconds: 502.0,
            rawPositionM: (1, 0, 0), trackingSessionID: "s"),
        index: TagObservationResolver.NodeIndex(
            finalNodes: [TagObservationResolver.FinalNodePose(
                id: 12, monotonicSeconds: 502.0,
                pose: SE2Transform(
                    xM: 100, yM: 50, yawRad: Double.pi / 2),
                floorID: "1")],
            rawNodeStamps: [12: 502.0]),
        sessionID: "s")
    require(
        close(nonzeroGauge.mapXM, 100) && close(nonzeroGauge.mapYM, 51),
        "nonzero 100m/50m/+90deg gauge must be applied exactly once")
    // Time-delta gate: the raw snapshot stamp must agree with the
    // parser-bound stamp within the frozen 1.0 s window (V1R5 §6.4).
    do {
        _ = try TagObservationResolver.resolve(
            observation: TagObservationResolver.RawObservation(
                barcode: "6903", symbology: "CODE128", floorID: "1",
                nodeID: 10, nodeTimestamp: 506.0, frameMonotonicSeconds: 506.0,
                rawPositionM: (0, 0, 0),
                trackingSessionID: "s"),
            index: index, sessionID: "s")
        require(false, "G2 time-delta gate must reject a stale binding")
    }
    catch let error as TagObservationResolver.ResolutionError {
        require(
            error == .timeDeltaTooLarge,
            "G2 time-delta error code must be timeDeltaTooLarge")
    }
    // Unlocalized evidence (no raw position) never reaches resolution.
    do {
        _ = try TagObservationResolver.resolve(
            observation: TagObservationResolver.RawObservation(
                barcode: "6904", symbology: "CODE128", floorID: "1",
                nodeID: 10, nodeTimestamp: 500.0, frameMonotonicSeconds: 500.0,
                rawPositionM: nil,
                trackingSessionID: "s"),
            index: index, sessionID: "s")
        require(false, "G2 unlocalized observations must be rejected")
    }
    catch let error as TagObservationResolver.ResolutionError {
        require(
            error == .unlocalized,
            "G2 unlocalized error code must be unlocalized")
    }
    // Session mismatch must reject.
    do {
        _ = try TagObservationResolver.resolve(
            observation: TagObservationResolver.RawObservation(
                barcode: "x", symbology: "CODE128", floorID: "1",
                nodeID: 10, nodeTimestamp: 500.0, frameMonotonicSeconds: 500.0,
                rawPositionM: (0, 0, 0),
                trackingSessionID: "other"),
            index: index, sessionID: "s")
        require(false, "G1 session mismatch must be rejected")
    }
    catch let error as TagObservationResolver.ResolutionError {
        require(
            error == .sessionMismatch,
            "G1 session mismatch error code must be sessionMismatch")
    }
}
catch {
    require(false, "G1/G2 tag binding failed: \(error)")
}

// G4/G5: burst fusion clusters same-barcode instances per floor; distant
// same-barcode observations stay separate instances.
do {
    let observations = [
        TagObservationResolver.ResolvedObservation(
            barcode: "B1", symbology: "CODE128", floorID: "1",
            mapXM: 1.0, mapYM: 2.0, mapZM: 0, nodeID: 1,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "s", bindingMethod: "explicit_node"),
        TagObservationResolver.ResolvedObservation(
            barcode: "B1", symbology: "CODE128", floorID: "1",
            mapXM: 1.02, mapYM: 2.01, mapZM: 0, nodeID: 1,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "s", bindingMethod: "explicit_node"),
        TagObservationResolver.ResolvedObservation(
            barcode: "B1", symbology: "CODE128", floorID: "1",
            mapXM: 1.01, mapYM: 1.99, mapZM: 0, nodeID: 1,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "s", bindingMethod: "explicit_node"),
        TagObservationResolver.ResolvedObservation(
            barcode: "B1", symbology: "CODE128", floorID: "2",
            mapXM: 30.0, mapYM: 30.0, mapZM: 0, nodeID: 2,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "s", bindingMethod: "explicit_node"),
        TagObservationResolver.ResolvedObservation(
            barcode: "B1", symbology: "CODE128", floorID: "2",
            mapXM: 30.02, mapYM: 30.01, mapZM: 0, nodeID: 2,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "s", bindingMethod: "explicit_node"),
        TagObservationResolver.ResolvedObservation(
            barcode: "B1", symbology: "CODE128", floorID: "2",
            mapXM: 30.01, mapYM: 29.99, mapZM: 0, nodeID: 2,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "s", bindingMethod: "explicit_node"),
    ]
    let instances = TagObservationResolver.clusterInstances(
        observations: observations, clusterRadiusM: 1.5)
    require(
        instances.count == 2,
        "G4/G5 same barcode on two floors must yield two instances, got \(instances.count)")
    let floor1 = instances.first { $0.floorID == "1" }
    let floor2 = instances.first { $0.floorID == "2" }
    require(
        floor1 != nil && floor1!.observationCount == 3,
        "G4 burst fusion must merge 3 samples into one instance")
    require(
        floor2 != nil && floor2!.observationCount == 3,
        "G5 floor-2 cluster must be independent")
    require(
        close(floor1?.mapXM ?? -1, 1.01, tolerance: 1.0e-6),
        "G4 fused position must be the burst centroid, got \(floor1?.mapXM ?? -1)")
}
catch {
    require(false, "G4/G5 burst fusion failed: \(error)")
}

// RC-B16/H-07: the clusterer must keep formal symbology/session identity
// separate and complete the former quadratic 200k worst case through the
// radius-sized spatial hash.
do {
    let identitySamples = [
        TagObservationResolver.ResolvedObservation(
            barcode: "SAME", symbology: "CODE128", floorID: "1",
            mapXM: 1, mapYM: 1, mapZM: 0, nodeID: 1,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "session-a", bindingMethod: "explicit_node"),
        TagObservationResolver.ResolvedObservation(
            barcode: "SAME", symbology: "QR", floorID: "1",
            mapXM: 1, mapYM: 1, mapZM: 0, nodeID: 1,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "session-a", bindingMethod: "explicit_node"),
        TagObservationResolver.ResolvedObservation(
            barcode: "SAME", symbology: "CODE128", floorID: "1",
            mapXM: 1, mapYM: 1, mapZM: 0, nodeID: 1,
            nodeTimestamp: 0, frameMonotonicSeconds: 0,
            trackingSessionID: "session-b", bindingMethod: "explicit_node"),
    ]
    let identityInstances = TagObservationResolver.clusterInstances(
        observations: identitySamples, clusterRadiusM: 1.5)
    require(
        identityInstances.count == 3,
        "H-07 symbology and tracking session must isolate tag clusters")

    let benchmarkCount = 200_000
    var worstCase: [TagObservationResolver.ResolvedObservation] = []
    worstCase.reserveCapacity(benchmarkCount)
    for index in 0..<benchmarkCount {
        worstCase.append(TagObservationResolver.ResolvedObservation(
            barcode: "WORST-CASE", symbology: "CODE128", floorID: "1",
            mapXM: Double(index) * 2.0, mapYM: 0, mapZM: 0,
            nodeID: Int64(index), nodeTimestamp: Double(index),
            frameMonotonicSeconds: Double(index),
            trackingSessionID: "benchmark", bindingMethod: "explicit_node"))
    }
    let benchmarkStarted = ProcessInfo.processInfo.systemUptime
    let benchmarkInstances = TagObservationResolver.clusterInstances(
        observations: worstCase, clusterRadiusM: 0.5)
    let benchmarkElapsed =
        ProcessInfo.processInfo.systemUptime - benchmarkStarted
    require(
        benchmarkInstances.count == benchmarkCount,
        "RC-B16 200k separated observations must remain distinct")
    require(
        benchmarkElapsed < 60.0,
        "RC-B16 200k spatial clustering exceeded 60 seconds: \(benchmarkElapsed)")
    print(String(
        format: "RC-B16 200k spatial clustering: %.3f seconds",
        benchmarkElapsed))
}

// G6/G7/G10: shelf association and the automatic quality gate.
do {
    let shelf = ShelfAssociationEngine.ShelfSegment(
        shelfSegmentID: "segment-a1-main",
        shelfCode: "A1", floorID: "1",
        startM: (0, 0), endM: (10, 0),
        axisM: (1, 0), frontNormalM: (0, -1),
        boundsMinM: (0, -0.5), boundsMaxM: (10, 0.5),
        polygonM: nil)
    guard let mid = ShelfAssociationEngine.associate(
        point: (5, 0.05), shelf: shelf, floorID: "1") else {
        require(false, "G6 shelf association must succeed at mid")
        throw MapSourceImportError.unknownFormat
    }
    require(
        close(mid.distanceFromShelfStartCm, 500.0, tolerance: 1.0e-6)
            && close(mid.positionRatio, 0.5, tolerance: 1.0e-6)
            && close(mid.distanceToSegmentM, 0.05, tolerance: 1.0e-6)
            && mid.shelfSide == "back",
        "G6 mid-shelf projection must be (500cm, 0.5) on the back side, got \(mid.distanceFromShelfStartCm),\(mid.positionRatio),\(mid.shelfSide)")
    require(!mid.atEndpoint, "G6 mid-shelf must not be endpoint-ambiguous")
    guard let front = ShelfAssociationEngine.associate(
        point: (5, -0.05), shelf: shelf, floorID: "1") else {
        require(false, "G6 front-side association must succeed")
        throw MapSourceImportError.unknownFormat
    }
    require(
        front.shelfSide == "front",
        "G6 negative-normal side must be front, got \(front.shelfSide)")
    guard let endpoint = ShelfAssociationEngine.associate(
        point: (0.05, 0.0), shelf: shelf, floorID: "1") else {
        require(false, "G6 endpoint association must succeed")
        throw MapSourceImportError.unknownFormat
    }
    require(endpoint.atEndpoint, "G7 endpoint zone must be flagged ambiguous")
    // Quality gate: accepted only with sufficient burst and geometry.
    func gateInput(
        count: Int,
        spread: Double,
        association: ShelfAssociationEngine.Association,
        graphOK: Bool = true,
        identityOK: Bool = true,
        depthQuality: Double = 0.9,
        localizationConfidence: Double = 0.9,
        measurementConfidence: Double = 0.9,
        needsReview: Bool = false,
        trackingOK: Bool = true,
        viewOK: Bool = true,
        nodeUncertaintyM: Double? = 0.1
    ) -> AutomaticQualityGate.TagQualityInput {
        return AutomaticQualityGate.TagQualityInput(
            observationCount: count,
            uniqueVerifiedFrameCount: count,
            effectiveSampleSize: Double(count),
            positionSpreadM: spread,
            minimumBurstSamples: 3, maximumSpreadM: 0.1,
            minimumDepthQuality: depthQuality,
            viewQualitySufficient: viewOK,
            trackingQualitySufficient: trackingOK,
            localizationConfidence: localizationConfidence,
            measurementConfidence: measurementConfidence,
            needsReview: needsReview,
            measurementMethodAccepted: true,
            maximumNodeUncertaintyM: nodeUncertaintyM,
            bindingMethod: "explicit_node",
            association: association,
            maximumEndpointDistanceM: 0.15,
            maximumAssociationDistanceM: 0.2,
            minimumAssociationMarginM: 0.5,
            graphQualityPassed: graphOK,
            mapSessionIdentityConsistent: identityOK)
    }
    let accepted = AutomaticQualityGate.evaluate(gateInput(
        count: 5, spread: 0.02, association: mid))
    require(
        accepted.0 == .accepted,
        "G10 a well-supported mid-shelf tag must be ACCEPTED, got \(accepted.0.rawValue)")
    let sparse = AutomaticQualityGate.evaluate(gateInput(
        count: 1, spread: 0.02, association: mid))
    require(
        sparse.0 == .rescanRequired,
        "G10 insufficient burst samples must be RESCAN_REQUIRED, got \(sparse.0.rawValue)")
    require(
        AutomaticQualityGate.evaluate(gateInput(
            count: 5, spread: 0.02, association: mid,
            needsReview: true)).0 == .lowConfidence,
        "G10 needs-review complete evidence must be retained as low confidence")
    require(
        AutomaticQualityGate.evaluate(gateInput(
            count: 5, spread: 0.02, association: mid,
            depthQuality: 0.2)).0 == .lowConfidence,
        "G10 low-depth complete burst must be retained as low confidence")
    require(
        AutomaticQualityGate.evaluate(gateInput(
            count: 5, spread: 0.02, association: mid,
            nodeUncertaintyM: nil)).0 == .lowConfidence,
        "G10 missing node uncertainty must be retained as low confidence")
    let endpointGate = AutomaticQualityGate.evaluate(gateInput(
        count: 5, spread: 0.02, association: endpoint))
    require(
        endpointGate.0 == .lowConfidence,
        "G7 endpoint-ambiguous tags must be LOW_CONFIDENCE, got \(endpointGate.0.rawValue)")
    // Parallel-aisle ambiguity: a second shelf nearly as close collapses
    // the margin and must be RESCAN_REQUIRED.
    let aisle = ShelfAssociationEngine.ShelfSegment(
        shelfSegmentID: "segment-a1-parallel",
        shelfCode: "A1", floorID: "1",
        startM: (0, 0.5), endM: (10, 0.5),
        axisM: (1, 0), frontNormalM: (0, -1),
        boundsMinM: (0, 0.25), boundsMaxM: (10, 0.75),
        polygonM: nil)
    let index = ShelfAssociationEngine.ShelfSpatialIndex(
        shelves: [shelf, aisle])
    guard let between = ShelfAssociationEngine.bestAssociation(
        point: (5, 0.15), shelves: [shelf, aisle], index: index,
        floorID: "1", occludedByStructure: { _ in false }) else {
        require(false, "G7 parallel-aisle association must succeed")
        throw MapSourceImportError.unknownFormat
    }
    require(
        between.shelfCode == "A1"
            && between.shelfSegmentID == "segment-a1-main"
            && between.marginM != nil
            && between.marginM! < 0.5,
        "RC-B18 same-code second segment must be retained by segment ID")
    let aisleGate = AutomaticQualityGate.evaluate(gateInput(
        count: 5, spread: 0.02, association: between))
    require(
        aisleGate.0 == .lowConfidence
            && aisleGate.1 == "shelf_association_margin_insufficient",
        "G7 parallel-aisle tags must be LOW_CONFIDENCE on margin, got \(aisleGate.0.rawValue)/\(aisleGate.1)")
    // Occlusion: a fixed structure between the tag and the shelf blocks
    // the sight line and must be RESCAN_REQUIRED.
    let structure = ShelfAssociationEngine.FixedStructure(
        structureCode: "P1", floorID: "1",
        polygonM: [(4, -0.4), (4, 0.4), (6, 0.4), (6, -0.4)],
        boundsMinM: (4, -0.4), boundsMaxM: (6, 0.4))
    let occluded = ShelfAssociationEngine.isOccluded(
        tagPoint: (5, 0.5), shelf: shelf, structures: [structure])
    require(
        occluded,
        "G7 a structure between tag and shelf must occlude the sight line")
    // RC-H07: a thin obstacle close to the shelf intersects the sight
    // segment even though the old midpoint probe would miss it.
    let thinPillar = ShelfAssociationEngine.FixedStructure(
        structureCode: "THIN", floorID: "1",
        polygonM: [
            (4.95, 0.04), (5.05, 0.04),
            (5.05, 0.08), (4.95, 0.08),
        ],
        boundsMinM: (4.95, 0.04), boundsMaxM: (5.05, 0.08))
    require(
        ShelfAssociationEngine.isOccluded(
            tagPoint: (5, 0.5), shelf: shelf,
            structures: [thinPillar]),
        "RC-H07 thin near-shelf pillar must intersect the full sight segment")
    let aabbFallback = ShelfAssociationEngine.FixedStructure(
        structureCode: "AABB", floorID: "1", polygonM: nil,
        boundsMinM: (4.9, 0.10), boundsMaxM: (5.1, 0.14))
    require(
        ShelfAssociationEngine.isOccluded(
            tagPoint: (5, 0.5), shelf: shelf,
            structures: [aabbFallback]),
        "RC-H07 explicit AABB fallback must participate in intersection")
    var otherFloor = thinPillar
    otherFloor.floorID = "2"
    require(
        !ShelfAssociationEngine.isOccluded(
            tagPoint: (5, 0.5), shelf: shelf,
            structures: [otherFloor]),
        "RC-H07 structures on another floor must not occlude")
    let offRay = ShelfAssociationEngine.FixedStructure(
        structureCode: "OFF-RAY", floorID: "1", polygonM: nil,
        boundsMinM: (6, 0.10), boundsMaxM: (6.2, 0.14))
    require(
        !ShelfAssociationEngine.isOccluded(
            tagPoint: (5, 0.5), shelf: shelf,
            structures: [offRay]),
        "RC-H07 non-intersecting structure must remain non-occluding")
    let farFromShelf = ShelfAssociationEngine.FixedStructure(
        structureCode: "FAR", floorID: "1", polygonM: nil,
        boundsMinM: (4.9, 0.35), boundsMaxM: (5.1, 0.40))
    require(
        !ShelfAssociationEngine.isOccluded(
            tagPoint: (5, 0.5), shelf: shelf,
            structures: [farFromShelf], maximumDistanceM: 0.05),
        "RC-H07 intersection outside the shelf-distance gate must be rejected")
    var occludedAssociation = mid
    occludedAssociation.occludedByStructure = occluded
    let occlusionGate = AutomaticQualityGate.evaluate(gateInput(
        count: 5, spread: 0.02, association: occludedAssociation))
    require(
        occlusionGate.0 == .lowConfidence
            && occlusionGate.1 == "shelf_occluded_by_structure",
        "G7 occluded tags must be LOW_CONFIDENCE, got \(occlusionGate.0.rawValue)/\(occlusionGate.1)")
    // Rotated shelf geometry: the polygon axis drives the association.
    if let rotated = ShelfAssociationEngine.makeSegment(
        shelfCode: "A3", floorID: "1",
        polygonM: [(1, 1), (1, 2), (4, 2), (4, 1)],
        boundsMinM: (1, 1), boundsMaxM: (4, 2),
        yawRad: 0) {
        require(
            close(rotated.axisM.0, 1.0, tolerance: 1.0e-6)
                && close(rotated.axisM.1, 0.0, tolerance: 1.0e-6),
            "G7 rotated shelf axis must follow the polygon main axis, got \(rotated.axisM)")
        guard let rotatedAssociation = ShelfAssociationEngine.associate(
            point: (2.5, 1.4), shelf: rotated, floorID: "1") else {
            require(false, "G7 rotated shelf association must succeed")
            throw MapSourceImportError.unknownFormat
        }
        require(
            close(rotatedAssociation.distanceFromShelfStartCm, 150.0, tolerance: 1.0e-6)
                && rotatedAssociation.shelfSide == "front",
            "G7 rotated shelf must project along its axis, got \(rotatedAssociation.distanceFromShelfStartCm),\(rotatedAssociation.shelfSide)")
    } else {
        require(false, "G7 rotated shelf geometry must build")
    }

    // RC-B17: v2 consumers must use compiler-authored direction, not a
    // conflicting polygon PCA/AABB direction.
    let compiled = try PriorMapShelfSegmentV2(
        shelfSegmentID: "compiled-vertical",
        shelfCode: "CV",
        floorID: "1",
        longitudinalStartM: [2, 0],
        longitudinalEndM: [2, 4],
        longitudinalAxis: [0, 1],
        frontNormal: [1, 0],
        backNormal: [-1, 0],
        sideSemanticsVersion: 1,
        orientationProvenance: "element_yaw")
    guard let compiledShelf = ShelfAssociationEngine.makeCompiledSegment(
        compiled,
        polygonM: [(0, 0), (5, 0), (5, 1), (0, 1)],
        boundsMinM: (0, 0),
        boundsMaxM: (5, 1)) else {
        require(false, "RC-B17 compiled segment must build")
        throw MapSourceImportError.unknownFormat
    }
    require(
        compiledShelf.shelfSegmentID == "compiled-vertical"
            && close(compiledShelf.axisM.0, 0)
            && close(compiledShelf.axisM.1, 1)
            && close(compiledShelf.startM.0, 2)
            && close(compiledShelf.endM.1, 4),
        "RC-B17 polygon envelope must not replace compiled direction")
}
catch {
    require(false, "G6/G7/G10 shelf/quality tests failed: \(error)")
}

// RC-B17/H-07/H-08: finalization keeps same-code physical segments and
// symbologies in separate buckets, then carries the exact segment ID into
// both the finalized tag and its RESCAN task/output model.
do {
    let segmentLow = ShelfAssociationEngine.ShelfSegment(
        shelfSegmentID: "segment-shared-low",
        shelfCode: "SHARED", floorID: "1",
        startM: (0, 0), endM: (10, 0),
        axisM: (1, 0), frontNormalM: (0, -1),
        boundsMinM: (0, -0.5), boundsMaxM: (10, 0.5),
        polygonM: nil, orientationProvenance: "element_yaw")
    let segmentHigh = ShelfAssociationEngine.ShelfSegment(
        shelfSegmentID: "segment-shared-high",
        shelfCode: "SHARED", floorID: "1",
        startM: (0, 1), endM: (10, 1),
        axisM: (1, 0), frontNormalM: (0, 1),
        boundsMinM: (0, 0.5), boundsMaxM: (10, 1.5),
        polygonM: nil, orientationProvenance: "element_yaw")
    let finalizerNode = TagObservationResolver.FinalNodePose(
        id: 77, monotonicSeconds: 10, pose: .identity, floorID: "1",
        uncertaintyM: 0.1)
    let finalizerIndex = TagObservationResolver.NodeIndex(
        finalNodes: [finalizerNode], rawNodeStamps: [77: 10])
    let finalizerMap = MobileMapLibrary.MapEntry(
        priorMapID: "bucket-map",
        name: "bucket-map",
        packageSHA256: String(repeating: "b", count: 64),
        packageDirectory: FileManager.default.temporaryDirectory,
        floorCount: 1,
        elementCount: 2,
        compiledAtUTC: 0,
        compilerVersion: "test",
        canonicalSourceSHA256: String(repeating: "c", count: 64))
    func finalizerEvidence(
        barcode: String,
        symbology: String,
        y: Double,
        count: Int,
        localizationState: String = "stable",
        localizationConfidence: Double = 1,
        measurementConfidence: Double = 1,
        needsReview: Bool = false,
        burstID: String? = nil
    ) -> [TagObservationEvidenceObservation] {
        return (0..<count).map { index in
            TagObservationEvidenceObservation(
                observationID: "\(barcode)-\(symbology)-\(y)-\(index)",
                barcode: barcode,
                symbology: symbology,
                floorID: "1",
                frameTimestamp: Double(index),
                nodeTimebaseTimestamp: 10,
                rawPositionM: (5, y, 0),
                measurementConfidence: measurementConfidence,
                localizationState: localizationState,
                localizationConfidence: localizationConfidence,
                needsReview: needsReview,
                trackingSessionID: "bucket-session",
                boundNodeID: 77,
                boundNodeDelta: 0,
                secondCandidateDelta: 2,
                burstID: burstID
                    ?? "burst-\(barcode)-\(symbology)-\(y)",
                frameID: "frame-\(y)-\(index)",
                measurementMethod: "scene_depth",
                depthSampleCount: 10,
                depthInlierCount: 9,
                depthInlierRatio: 0.9,
                depthMedianM: 1.0,
                depthMadM: 0.01,
                planeResidualM: 0.01,
                surfaceNormalCamera: [0, 0, -1])
        }
    }
    func finalizeBucketEvidence(
        _ observations: [TagObservationEvidenceObservation],
        shelves: [ShelfAssociationEngine.ShelfSegment],
        graphQualityPassed: Bool = true
    ) throws -> ([FinalPriceTag], [RescanTask]) {
        return try MobileProcessingPipeline.finalizeTags(
            observations: observations,
            resolverIndex: finalizerIndex,
            shelves: shelves,
            shelfIndex: ShelfAssociationEngine.ShelfSpatialIndex(
                shelves: shelves),
            structures: [],
            sessionID: "bucket-session",
            storeID: "STORE-BUCKET",
            priorMap: finalizerMap,
            floorID: "1",
            graphQualityPassed: graphQualityPassed,
            minimumAssociationMarginM: 0.5)
    }

    // These centroids are only 1.2 m apart (inside the 1.5 m cluster
    // radius). Segment-ID bucketing must keep them as two physical tags
    // even though both business shelves share code SHARED and side front.
    let segmentEvidence =
        finalizerEvidence(barcode: "SEGMENTED", symbology: "CODE128", y: -0.1, count: 3)
        + finalizerEvidence(barcode: "SEGMENTED", symbology: "CODE128", y: 1.1, count: 3)
    let (segmentTags, segmentRescans) = try finalizeBucketEvidence(
        segmentEvidence, shelves: [segmentLow, segmentHigh])
    require(
        segmentTags.count == 2 && segmentRescans.isEmpty
            && Set(segmentTags.map(\.shelfCode)) == ["SHARED"]
            && Set(segmentTags.map(\.shelfSegmentID))
                == ["segment-shared-low", "segment-shared-high"],
        "RC-B17 same-code physical segments must finalize independently")

    let ambiguousBurstEvidence =
        finalizerEvidence(
            barcode: "AMBIGUOUS-BURST",
            symbology: "CODE128",
            y: -0.1,
            count: 3,
            burstID: "burst-ambiguous")
        + finalizerEvidence(
            barcode: "AMBIGUOUS-BURST",
            symbology: "CODE128",
            y: 1.1,
            count: 3,
            burstID: "burst-ambiguous")
    let (ambiguousTags, ambiguousRescans) = try finalizeBucketEvidence(
        ambiguousBurstEvidence, shelves: [segmentLow, segmentHigh])
    require(
        ambiguousTags.count == 1
            && ambiguousTags[0].qualityStatus == "LOW_CONFIDENCE"
            && ambiguousRescans.isEmpty,
        "one burst that disagrees across shelf identities must remain one low-confidence tag")

    let symbologyEvidence =
        finalizerEvidence(barcode: "MULTI", symbology: "CODE128", y: -0.1, count: 3)
        + finalizerEvidence(barcode: "MULTI", symbology: "QR", y: -0.1, count: 3)
    let (symbologyTags, symbologyRescans) = try finalizeBucketEvidence(
        symbologyEvidence, shelves: [segmentLow])
    require(
        symbologyTags.count == 2 && symbologyRescans.isEmpty
            && Set(symbologyTags.map(\.symbology)) == ["CODE128", "QR"],
        "H-07 symbology must be part of the finalization bucket identity")

    let (sparseTags, sparseRescans) = try finalizeBucketEvidence(
        finalizerEvidence(
            barcode: "SPARSE", symbology: "CODE128", y: -0.1, count: 1),
        shelves: [segmentLow])
    require(
        sparseTags.count == 1
            && sparseTags[0].qualityStatus == "LOW_CONFIDENCE"
            && sparseTags[0].shelfSegmentID == "segment-shared-low"
            && sparseRescans.count == 1
            && sparseRescans[0].shelfSegmentID == "segment-shared-low",
        "RC-B17 associated low-confidence rows and rescan suggestions must carry shelf_segment_id")

    let (weakTags, weakRescans) = try finalizeBucketEvidence(
        finalizerEvidence(
            barcode: "WEAK-COMPLETE",
            symbology: "CODE128",
            y: -0.1,
            count: 3,
            localizationState: "recovering",
            localizationConfidence: 0.45,
            measurementConfidence: 0.55,
            needsReview: true),
        shelves: [segmentLow])
    require(
        weakTags.count == 1
            && weakTags[0].qualityStatus == "LOW_CONFIDENCE"
            && weakTags[0].reason == "measurement_needs_review"
            && weakRescans.isEmpty,
        "a complete exact-node burst with weak localization must be retained without an immediate rescan")

    var partialPositionEvidence = finalizerEvidence(
        barcode: "PARTIAL-POSITION",
        symbology: "CODE128",
        y: -0.1,
        count: 4,
        burstID: "burst-partial-position")
    partialPositionEvidence[3].rawPositionM = nil
    partialPositionEvidence[3].measurementMethod = "unavailable"
    let (partialPositionTags, partialPositionRescans) =
        try finalizeBucketEvidence(
            partialPositionEvidence,
            shelves: [segmentLow])
    require(
        partialPositionTags.count == 1
            && partialPositionTags[0].qualityStatus == "LOW_CONFIDENCE"
            && partialPositionTags[0].reason
                == "partial_burst_position_unavailable"
            && partialPositionRescans.isEmpty,
        "three recomputable frames must retain a complete burst even when one frame has no position")

    let (partialGraphFailureTags, partialGraphFailureRescans) =
        try finalizeBucketEvidence(
            partialPositionEvidence,
            shelves: [segmentLow],
            graphQualityPassed: false)
    require(
        partialGraphFailureTags.count == 1
            && partialGraphFailureTags[0].qualityStatus == "LOW_CONFIDENCE"
            && partialGraphFailureTags[0].reason == "graph_quality_failed"
            && partialGraphFailureRescans.count == 1
            && partialGraphFailureRescans[0].reasonCode
                == "graph_quality_failed",
        "a weak-frame quorum must retain a low-confidence row while the hard graph-quality gate adds a rescan suggestion")

    var insufficientPositionEvidence = finalizerEvidence(
        barcode: "INSUFFICIENT-POSITION",
        symbology: "CODE128",
        y: -0.1,
        count: 3,
        burstID: "burst-insufficient-position")
    insufficientPositionEvidence[2].rawPositionM = nil
    insufficientPositionEvidence[2].measurementMethod = "unavailable"
    let (insufficientPositionTags, insufficientPositionRescans) =
        try finalizeBucketEvidence(
            insufficientPositionEvidence,
            shelves: [segmentLow])
    require(
        insufficientPositionTags.count == 1
            && insufficientPositionTags[0].qualityStatus == "LOW_CONFIDENCE"
            && insufficientPositionTags[0].mapXM == nil
            && insufficientPositionTags[0].mapYM == nil
            && insufficientPositionTags[0].reason
                == "unlocalized_observation"
            && insufficientPositionRescans.count == 1
            && insufficientPositionRescans[0].reasonCode
                == "unlocalized_observation",
        "fewer than three recomputable frames must preserve a LOW_CONFIDENCE tag row plus a rescan suggestion")

    let (unassociatedTags, unassociatedRescans) = try finalizeBucketEvidence(
        finalizerEvidence(
            barcode: "NO-SHELF",
            symbology: "CODE128",
            y: -0.1,
            count: 3),
        shelves: [])
    require(
        unassociatedTags.count == 1
            && unassociatedTags[0].qualityStatus == "LOW_CONFIDENCE"
            && unassociatedTags[0].reason == "no_shelf_association"
            && unassociatedRescans.isEmpty,
        "a resolved complete burst without a shelf candidate must remain a low-confidence PriceTag")

    let (unassociatedGraphFailureTags, unassociatedGraphFailureRescans) =
        try finalizeBucketEvidence(
            finalizerEvidence(
                barcode: "NO-SHELF-GRAPH-FAIL",
                symbology: "CODE128",
                y: -0.1,
                count: 3),
            shelves: [],
            graphQualityPassed: false)
    require(
        unassociatedGraphFailureTags.count == 1
            && unassociatedGraphFailureTags[0].qualityStatus
                == "LOW_CONFIDENCE"
            && unassociatedGraphFailureTags[0].reason
                == "graph_quality_failed"
            && unassociatedGraphFailureRescans.count == 1
            && unassociatedGraphFailureRescans[0].reasonCode
                == "graph_quality_failed",
        "missing shelf association must never bypass the hard graph-quality gate")

    var legacyFrameEvidence = finalizerEvidence(
        barcode: "LEGACY-FRAME", symbology: "CODE128", y: -0.1,
        count: 3)
    for index in legacyFrameEvidence.indices {
        legacyFrameEvidence[index].legacyCoordinateFrame = true
        legacyFrameEvidence[index].rawPositionM = nil
    }
    let (legacyTags, legacyRescans) = try MobileProcessingPipeline.finalizeTags(
        observations: legacyFrameEvidence,
        resolverIndex: finalizerIndex,
        shelves: [segmentLow],
        shelfIndex: ShelfAssociationEngine.ShelfSpatialIndex(
            shelves: [segmentLow]),
        structures: [],
        sessionID: "bucket-session",
        storeID: "STORE-BUCKET",
        priorMap: finalizerMap,
        floorID: "1",
        graphQualityPassed: true,
        minimumAssociationMarginM: 0.5)
    require(
        legacyTags.count == 1
            && legacyTags[0].qualityStatus == "LOW_CONFIDENCE"
            && legacyTags[0].mapXM == nil && legacyTags[0].mapYM == nil
            && legacyRescans.count == 1
            && legacyRescans[0].reasonCode
                == "legacy_tag_coordinate_frame_rescan_required",
        "legacy v1 coordinates must retain the barcode and require rescan")
}
catch {
    require(false, "RC-B17/H-07 finalization bucket tests failed: \(error)")
}

// Publication is a single shared invariant. Every business blocker must
// independently prevent COMPLETE, including coordinate-contract v1 results.
do {
    func permits(
        low: Int = 0, unpositioned: Int = 0, unassociated: Int = 0,
        rescans: Int = 0, legacy: Int = 0
    ) -> Bool {
        MobileResultPublicationInvariant.permits(
            coordinatesArePriorMapFrame: true,
            graphQualityPassed: true,
            degradationCount: 0,
            coordinateFrameAuditPassed: legacy == 0,
            legacyCoordinateFrameCount: legacy,
            lowConfidenceTagCount: low,
            unpositionedTagCount: unpositioned,
            unassociatedTagCount: unassociated,
            rescanTaskCount: rescans)
    }
    require(permits(), "clean publication invariant must permit COMPLETE")
    require(!permits(low: 1), "low-confidence tag must block COMPLETE")
    require(!permits(unpositioned: 1), "unpositioned tag must block COMPLETE")
    require(!permits(unassociated: 1), "unassociated tag must block COMPLETE")
    require(!permits(rescans: 1), "rescan task must block COMPLETE")
    require(!permits(legacy: 1), "legacy coordinate frame must block COMPLETE")
    let tamperedComplete: [String: Any] = [
        "result_quality_status": "COMPLETE",
        "publish_permitted": true,
        "coordinate_contract_version": 2,
        "coordinate_frame_audit_passed": true,
        "legacy_tag_coordinate_frame_count": 0,
        "degradation_count": 0,
        "low_confidence_tag_count": 1,
        "unpositioned_tag_count": 0,
        "unassociated_tag_count": 0,
        "rescan_count": 0,
    ]
    require(
        !MobileResultPublicationInvariant.manifestIsConsistent(
            tamperedComplete),
        "reader must reject a tampered COMPLETE manifest with tag blockers")
}

// =====================================================================
// Mobile-Only V1: Fast Path factor graph (P1/P2), session snapshot
// transaction (P7) and the persistent task state machine (P8/P12).
// =====================================================================

// P1/P2: a small chain with a wrong odometry drift and a loop closure
// must converge to a residual near zero; anchor pose is preserved.
do {
    let nodes = [
        SE2FactorGraphCore.Node(id: 1, initialPose: .identity, isAnchor: true, floorID: "1"),
        SE2FactorGraphCore.Node(id: 2, initialPose: SE2Transform(xM: 1, yM: 0, yawRad: 0), isAnchor: false, floorID: "1"),
        SE2FactorGraphCore.Node(id: 3, initialPose: SE2Transform(xM: 2, yM: 0.5, yawRad: 0), isAnchor: false, floorID: "1"),
        SE2FactorGraphCore.Node(id: 4, initialPose: SE2Transform(xM: 3, yM: 0.5, yawRad: 0), isAnchor: false, floorID: "1"),
    ]
    let edges = [
        SE2FactorGraphCore.Edge(from: 1, to: 2, measurement: SE2Transform(xM: 1, yM: 0, yawRad: 0), weight: 10, kind: "odometry"),
        SE2FactorGraphCore.Edge(from: 2, to: 3, measurement: SE2Transform(xM: 1, yM: 0, yawRad: 0), weight: 10, kind: "odometry"),
        SE2FactorGraphCore.Edge(from: 3, to: 4, measurement: SE2Transform(xM: 1, yM: 0, yawRad: 0), weight: 10, kind: "odometry"),
        // Loop closure pulls node 4 back to the line y=0.
        SE2FactorGraphCore.Edge(from: 4, to: 1, measurement: SE2Transform(xM: -3, yM: 0, yawRad: 0), weight: 8, kind: "loop_closure"),
    ]
    let graph = try SE2FactorGraphCore.optimize(nodes: nodes, edges: edges)
    require(
        graph.finalResidual < 1.0e-3,
        "P1 fast-path must converge near zero residual, got \(graph.finalResidual)")
    require(
        close(graph.poses[1]?.xM ?? -1, 0.0) && close(graph.poses[1]?.yM ?? -1, 0.0),
        "P1 the anchor pose must stay fixed")
    require(
        close(graph.poses[2]?.yM ?? -1, 0.0, tolerance: 2.0e-2)
            && close(graph.poses[3]?.yM ?? -1, 0.0, tolerance: 2.0e-2),
        "P1 loop closure must flatten the drift, got \(graph.poses[3]?.yM ?? -1)")
}
catch {
    require(false, "P1 fast-path factor graph failed: \(error)")
}

// P7: the session snapshot transaction copies inputs into a private
// snapshot and computes a bundle digest over the stable bytes.
do {
    let session = try p7r6FreshDirectory("mobile-session")
    let fileManager = FileManager.default
    let priorMapSHA = String(repeating: "a", count: 64)
    let metadata = try CanonicalJSONEncoder.encode([
        "format": "MarketScannerFinalizedSessionMetadata",
        "version": 1,
        "formatVersion": 2,
        "finalized": true,
        "finalizedAtUnix": 1_700_000_100.0,
        "scanMode": "continuous_streaming",
        "workflowMode": "prior_map_localized",
        "trackingSessionId": "P7-SESSION",
        "storeId": "STORE-P7",
        "floorId": "FLOOR-P7",
        "priorMapId": "MAP-P7",
        "priorMapSha256": priorMapSHA,
        "processingEligibility": [
            "status": "eligible",
            "blockers": [],
        ],
        "captureHealth": [
            "localizationRequiredWriteFailureCount": 0,
            "localizationTraceRecordCount": 1,
            "localizationConstraintRecordCount": 1,
            "manualLocalizationEventCount": 0,
            "localizationStateEventCount": 1,
            "localizationEvidenceComplete": true,
            "localizationRecoveryEventCount": 1,
            "localizationLastRecoveryEpisodeId": 1,
            "localizationLastRecoveryFinishedAtUptime": 42.0,
            "localizationRecoveryEvidenceComplete": true,
        ],
        "localizationTrace": "localization_trace.jsonl",
        "manualLocalizationEvents": "manual_localization_events.jsonl",
        "localizationConstraints": "localization_constraints.jsonl",
        "localizationEvents": "localization_events.jsonl",
        "localizationRecoveryEvents": "localization_recovery_events.jsonl",
        "tagObservations": "tag_observations.jsonl",
        "localizedPriceTags": "localized_price_tags.json",
        "clockCorrelationCount": 2,
        "clockNodeBindingCount": 2,
        "clockLastMonotonic": 41.0,
        "clockLastUTC": 1_700_000_041.0,
        "clockEvidenceComplete": true,
        "tagObservationBurstCount": 0,
        "tagObservationBurstComplete": true,
    ])
    try metadata.write(to: session.appendingPathComponent("metadata.json"))
    try Data("trace\n".utf8).write(to: session.appendingPathComponent("localization_trace.jsonl"))
    try Data("constraints\n".utf8).write(to: session.appendingPathComponent("localization_constraints.jsonl"))
    try Data("manual\n".utf8).write(to: session.appendingPathComponent("manual_localization_events.jsonl"))
    try Data("obs\n".utf8).write(to: session.appendingPathComponent("tag_observations.jsonl"))
    try Data("events\n".utf8).write(to: session.appendingPathComponent("localization_events.jsonl"))
    try Data("recovery\n".utf8).write(to: session.appendingPathComponent("localization_recovery_events.jsonl"))
    try Data("[]".utf8).write(to: session.appendingPathComponent("localized_price_tags.json"))
    try Data("clock\n".utf8).write(to: session.appendingPathComponent("clock_correlations.jsonl"))
    try Data().write(to: session.appendingPathComponent("tag_observation_bursts.jsonl"))
    var p7ScanEvent = try CanonicalJSONEncoder.encode([
        "format": "SupermarketScanEvent",
        "version": 1,
        "timestamp": "2023-11-14T22:13:20.000Z",
        "timestampUnix": 1_700_000_000.0,
        "level": "info",
        "event": "scan_started",
        "message": "fixture scan started",
        "trackingSessionId": "P7-SESSION",
        "fields": [String: String](),
    ])
    p7ScanEvent.append(0x0A)
    try p7ScanEvent.write(
        to: session.appendingPathComponent("scan_events.jsonl"))
    let database = session.appendingPathComponent("source.db")
    // V1R3: the snapshot validates the DB (quick_check + Node/Link
    // inventory), so the fixture must be a real SQLite database.
    do {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            database.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
            let databaseHandle = db else {
            fatalError("P7 cannot create fixture sqlite DB")
        }
        defer { sqlite3_close(databaseHandle) }
        let schema = """
        CREATE TABLE Node (id INTEGER PRIMARY KEY, map_id INTEGER, weight INTEGER, stamp REAL, pose BLOB);
        CREATE TABLE Link (from_id INTEGER, to_id INTEGER, type INTEGER, transform BLOB, information_matrix BLOB);
        """
        guard sqlite3_exec(databaseHandle, schema, nil, nil, nil) == SQLITE_OK else {
            fatalError("P7 cannot create fixture sqlite schema")
        }
    }

    let taskRoot = try p7r6FreshDirectory("mobile-task")
    let snapshot = try SessionSnapshotTransaction.snapshot(
        finalizedSession: session,
        sourceDatabase: database,
        taskRoot: taskRoot,
        eligibility: SessionSnapshotTransaction.Eligibility(
            priorMapID: "MAP-P7",
            priorMapSHA256: priorMapSHA,
            storeID: "STORE-P7",
            floorID: "FLOOR-P7",
            appGitSHA: "test-git-sha"))
    require(
        !snapshot.bundleSHA256.isEmpty,
        "P7 snapshot must compute a non-empty bundle digest")
    require(
        fileManager.fileExists(
            atPath: snapshot.snapshotDirectory.appendingPathComponent("source.db").path),
        "P7 snapshot must contain the immutable source DB copy")
    require(
        fileManager.fileExists(
            atPath: snapshot.snapshotDirectory
                .appendingPathComponent("scan_events.jsonl").path),
        "RC-H34 snapshot must contain the immutable scan event evidence")
    // The persisted input manifest must agree with the snapshot digest,
    // and mutating the original session afterwards must not change it.
    let persistedManifestData = try Data(
        contentsOf: taskRoot.appendingPathComponent("input_manifest.json"))
    let persistedManifest = try StrictJSONDocumentParser.object(
        from: persistedManifestData,
        limits: StrictJSONDocumentLimits(maximumBytes: persistedManifestData.count + 1))
    require(
        (persistedManifest["bundle_sha256"] as? String) == snapshot.bundleSHA256,
        "P7 the persisted input manifest must bind the snapshot digest")
    require(
        (persistedManifest["generation"] as? String)?.isEmpty == false,
        "RC-B09 task reference must carry the committed generation")
    try SessionSnapshotTransaction.revalidateSnapshot(
        snapshot.snapshotDirectory)
    // iOS does not guarantee that SQLite can reopen `/dev/fd/<n>`. Exercise
    // the descriptor-bound private-copy fallback explicitly and prove that
    // its unique temporary directory is removed after validation.
    do {
        let validationPrefix = ".marketscanner-db-validation-"
        let temporaryRoot = fileManager.temporaryDirectory
        let beforeNames = Set((try? fileManager.contentsOfDirectory(
            atPath: temporaryRoot.path))?.filter {
                $0.hasPrefix(validationPrefix)
            } ?? [])
        SessionSnapshotTransaction
            .forcePrivateDatabaseValidationCopyForTests = true
        defer {
            SessionSnapshotTransaction
                .forcePrivateDatabaseValidationCopyForTests = false
        }
        try SessionSnapshotTransaction.revalidateSnapshot(
            snapshot.snapshotDirectory)
        let afterNames = Set((try? fileManager.contentsOfDirectory(
            atPath: temporaryRoot.path))?.filter {
                $0.hasPrefix(validationPrefix)
            } ?? [])
        require(
            beforeNames == afterNames,
            "iOS snapshot DB validation fallback must not leave private copies")
    }
    let snapshotMode = (try fileManager.attributesOfItem(
        atPath: snapshot.snapshotDirectory.path)[.posixPermissions]
        as? NSNumber)?.intValue
    let databaseMode = (try fileManager.attributesOfItem(
        atPath: snapshot.snapshotDirectory
            .appendingPathComponent("source.db").path)[.posixPermissions]
        as? NSNumber)?.intValue
    require(
        snapshotMode == 0o555 && databaseMode == 0o444,
        "RC-B09 committed snapshot directory/files must be 0555/0444")

    // A finalized historical scan can be exported independently of mobile
    // post-processing success. The verified package retains the phone copy
    // and a second export must never overwrite the first provider package.
    let historyDocuments = try p7r6FreshDirectory("history-export-documents")
    let historyRoot = historyDocuments.appendingPathComponent(
        "SupermarketSession-20260810-120000",
        isDirectory: true)
    let historySegment = historyRoot.appendingPathComponent(
        "segment_0001",
        isDirectory: true)
    try fileManager.createDirectory(
        at: historySegment,
        withIntermediateDirectories: true)
    for name in try fileManager.contentsOfDirectory(atPath: session.path) {
        let source = session.appendingPathComponent(name)
        let destinationName = name == "source.db"
            ? "rtabmap_segment_0001.db" : name
        try fileManager.copyItem(
            at: source,
            to: historySegment.appendingPathComponent(destinationName))
    }
    let historyExportDestination = try p7r6FreshDirectory(
        "history-export-provider")
    let firstHistoryExport = try SupermarketScanSession
        .exportFinalizedCapture(
            from: historySegment,
            localDocumentsDirectory: historyDocuments,
            destinationBaseDirectory: historyExportDestination,
            expectedTrackingSessionID: "P7-SESSION")
    require(
        fileManager.fileExists(atPath: historySegment.path)
            && fileManager.fileExists(atPath: firstHistoryExport.path),
        "historical export must retain the local finalized scan")
    let firstExportRoot = firstHistoryExport.deletingLastPathComponent()
    require(
        fileManager.fileExists(atPath: firstExportRoot.appendingPathComponent(
            "copy_verification.json").path)
            && fileManager.fileExists(atPath: firstExportRoot
                .appendingPathComponent("copy_package_manifest.json").path),
        "historical export must include verification receipts")
    let historySourceManifest = try CaptureDirectoryIntegrity.manifest(
        for: historySegment)
    let historyExportManifest = try CaptureDirectoryIntegrity.manifest(
        for: firstHistoryExport)
    require(
        historySourceManifest == historyExportManifest,
        "historical export source and provider manifests must match")
    let secondHistoryExport = try SupermarketScanSession
        .exportFinalizedCapture(
            from: historySegment,
            localDocumentsDirectory: historyDocuments,
            destinationBaseDirectory: historyExportDestination,
            expectedTrackingSessionID: "P7-SESSION")
    require(
        firstHistoryExport.deletingLastPathComponent()
            != secondHistoryExport.deletingLastPathComponent(),
        "historical export must create a collision-free package instead of overwriting")

    // Resume rejects permission drift even when bytes and hashes match.
    let snapshotDatabase = snapshot.snapshotDirectory
        .appendingPathComponent("source.db")
    try fileManager.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: snapshotDatabase.path)
    var modeDriftRejected = false
    do {
        try SessionSnapshotTransaction.revalidateSnapshot(
            snapshot.snapshotDirectory)
    } catch {
        modeDriftRejected = true
    }
    require(modeDriftRejected, "RC-B09 resume must reject artifact mode drift")
    try fileManager.setAttributes(
        [.posixPermissions: 0o444], ofItemAtPath: snapshotDatabase.path)
    try SessionSnapshotTransaction.revalidateSnapshot(
        snapshot.snapshotDirectory)

    // RC-B07 reads the nested captureHealth failure counter. A legacy
    // top-level zero must not hide a non-zero formal nested failure.
    let invalidSession = try p7r6FreshDirectory("mobile-session-invalid-health")
    for name in try fileManager.contentsOfDirectory(atPath: session.path) {
        try fileManager.copyItem(
            at: session.appendingPathComponent(name),
            to: invalidSession.appendingPathComponent(name))
    }
    var invalidMetadata = try StrictJSONDocumentParser.object(
        from: metadata,
        limits: StrictJSONDocumentLimits(maximumBytes: metadata.count + 1))
    var invalidCapture = invalidMetadata["captureHealth"] as! [String: Any]
    invalidCapture["localizationRequiredWriteFailureCount"] = 1
    invalidMetadata["captureHealth"] = invalidCapture
    invalidMetadata["requiredWriteFailureCount"] = 0
    try CanonicalJSONEncoder.encode(invalidMetadata).write(
        to: invalidSession.appendingPathComponent("metadata.json"))
    var nestedWriteFailureRejected = false
    do {
        _ = try SessionSnapshotTransaction.snapshot(
            finalizedSession: invalidSession,
            sourceDatabase: invalidSession.appendingPathComponent("source.db"),
            taskRoot: try p7r6FreshDirectory("mobile-task-invalid-health"),
            eligibility: SessionSnapshotTransaction.Eligibility(
                priorMapID: "MAP-P7",
                priorMapSHA256: priorMapSHA,
                storeID: "STORE-P7",
                floorID: "FLOOR-P7",
                appGitSHA: "test-git-sha"))
    } catch {
        nestedWriteFailureRejected = true
    }
    require(
        nestedWriteFailureRejected,
        "RC-B07 nested localization write failures must block snapshot")

    let missingManualWatermarkSession = try p7r6FreshDirectory(
        "mobile-session-missing-manual-watermark")
    for name in try fileManager.contentsOfDirectory(atPath: session.path) {
        try fileManager.copyItem(
            at: session.appendingPathComponent(name),
            to: missingManualWatermarkSession.appendingPathComponent(name))
    }
    var missingManualMetadata = try StrictJSONDocumentParser.object(
        from: metadata,
        limits: StrictJSONDocumentLimits(maximumBytes: metadata.count + 1))
    var missingManualCapture = missingManualMetadata["captureHealth"]
        as! [String: Any]
    missingManualCapture.removeValue(forKey: "manualLocalizationEventCount")
    missingManualMetadata["captureHealth"] = missingManualCapture
    try CanonicalJSONEncoder.encode(missingManualMetadata).write(
        to: missingManualWatermarkSession.appendingPathComponent(
            "metadata.json"))
    var missingManualWatermarkRejected = false
    do {
        _ = try SessionSnapshotTransaction.snapshot(
            finalizedSession: missingManualWatermarkSession,
            sourceDatabase: missingManualWatermarkSession
                .appendingPathComponent("source.db"),
            taskRoot: try p7r6FreshDirectory(
                "mobile-task-missing-manual-watermark"),
            eligibility: SessionSnapshotTransaction.Eligibility(
                priorMapID: "MAP-P7",
                priorMapSHA256: priorMapSHA,
                storeID: "STORE-P7",
                floorID: "FLOOR-P7",
                appGitSHA: "test-git-sha"))
    } catch {
        missingManualWatermarkRejected = true
    }
    require(
        missingManualWatermarkRejected,
        "formal snapshot must reject a missing manual exact-count watermark")

    // RC-H34: thermal counts are derived from scan_events.jsonl. A formal
    // finalized session cannot silently omit that evidence and publish a
    // lower interruption count.
    let missingEventsSession = try p7r6FreshDirectory(
        "mobile-session-missing-scan-events")
    for name in try fileManager.contentsOfDirectory(atPath: session.path)
        where name != "scan_events.jsonl" {
        try fileManager.copyItem(
            at: session.appendingPathComponent(name),
            to: missingEventsSession.appendingPathComponent(name))
    }
    var missingEventsRejected = false
    do {
        _ = try SessionSnapshotTransaction.snapshot(
            finalizedSession: missingEventsSession,
            sourceDatabase: missingEventsSession.appendingPathComponent("source.db"),
            taskRoot: try p7r6FreshDirectory("mobile-task-missing-scan-events"),
            eligibility: SessionSnapshotTransaction.Eligibility(
                priorMapID: "MAP-P7",
                priorMapSHA256: priorMapSHA,
                storeID: "STORE-P7",
                floorID: "FLOOR-P7",
                appGitSHA: "test-git-sha"))
    } catch {
        missingEventsRejected = true
    }
    require(
        missingEventsRejected,
        "RC-H34 missing scan event evidence must block snapshot")

    let malformedGraphSession = try p7r6FreshDirectory(
        "mobile-session-invalid-blob")
    for name in try fileManager.contentsOfDirectory(atPath: session.path) {
        try fileManager.copyItem(
            at: session.appendingPathComponent(name),
            to: malformedGraphSession.appendingPathComponent(name))
    }
    let malformedDatabase = malformedGraphSession.appendingPathComponent(
        "source.db")
    do {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            malformedDatabase.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle = db else {
            fatalError("RC-B10 cannot open malformed fixture DB")
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(
            handle, "INSERT INTO Node VALUES (1,0,1,1.0,?)",
            -1, &statement, nil)
        if let statement {
            let shortPose = Data(repeating: 0, count: 4)
            sqlite3_bind_blob(
                statement, 1, (shortPose as NSData).bytes,
                Int32(shortPose.count), unsafeBitCast(
                    -1, to: sqlite3_destructor_type.self))
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }
    var malformedGraphRejected = false
    do {
        _ = try SessionSnapshotTransaction.snapshot(
            finalizedSession: malformedGraphSession,
            sourceDatabase: malformedDatabase,
            taskRoot: try p7r6FreshDirectory("mobile-task-invalid-blob"),
            eligibility: SessionSnapshotTransaction.Eligibility(
                priorMapID: "MAP-P7",
                priorMapSHA256: priorMapSHA,
                storeID: "STORE-P7",
                floorID: "FLOOR-P7",
                appGitSHA: "test-git-sha"))
    } catch {
        malformedGraphRejected = true
    }
    require(
        malformedGraphRejected,
        "RC-B10 snapshot validator must reject an exact-BLOB violation")

    let injectedSidecar = session.appendingPathComponent("late-sidecar.jsonl")
    SessionSnapshotTransaction.faultInjector = { point in
        if case .afterSourceInventory = point {
            try Data("late\n".utf8).write(to: injectedSidecar)
        }
    }
    var lateFileRejected = false
    do {
        _ = try SessionSnapshotTransaction.snapshot(
            finalizedSession: session,
            sourceDatabase: database,
            taskRoot: try p7r6FreshDirectory("mobile-task-late-file"),
            eligibility: SessionSnapshotTransaction.Eligibility(
                priorMapID: "MAP-P7",
                priorMapSHA256: priorMapSHA,
                storeID: "STORE-P7",
                floorID: "FLOOR-P7",
                appGitSHA: "test-git-sha"))
    } catch {
        lateFileRejected = true
    }
    SessionSnapshotTransaction.faultInjector = nil
    try? fileManager.removeItem(at: injectedSidecar)
    require(
        lateFileRejected,
        "RC-B08 a sidecar added after pre-inventory must block commit")

    // RC-B09/macOS 14: every transient owner-write publication boundary
    // must roll back to the previous frozen generation on an injected error.
    // The durable transaction intent is removed only after recovery succeeds.
    for faultName in [
        "old_thaw_before_backup_rename",
        "new_rename_before_freeze",
        "new_freeze_before_parent_fsync",
        "after_snapshot_install",
    ] {
        SessionSnapshotTransaction.faultInjector = { point in
            let shouldFail: Bool
            switch (faultName, point) {
            case ("old_thaw_before_backup_rename",
                  .afterPreviousSnapshotThawBeforeBackupRename),
                 ("new_rename_before_freeze",
                  .afterSnapshotRenameBeforeFreeze),
                 ("new_freeze_before_parent_fsync",
                  .afterSnapshotFreezeBeforeParentFsync),
                 ("after_snapshot_install", .afterSnapshotInstall):
                shouldFail = true
            default:
                shouldFail = false
            }
            if shouldFail {
                throw NSError(
                    domain: "SnapshotFaultInjection", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: faultName])
            }
        }
        var interruptedCommitRejected = false
        do {
            _ = try SessionSnapshotTransaction.snapshot(
                finalizedSession: session,
                sourceDatabase: database,
                taskRoot: taskRoot,
                eligibility: SessionSnapshotTransaction.Eligibility(
                    priorMapID: "MAP-P7",
                    priorMapSHA256: priorMapSHA,
                    storeID: "STORE-P7",
                    floorID: "FLOOR-P7",
                    appGitSHA: "test-git-sha"))
        } catch {
            interruptedCommitRejected = true
        }
        SessionSnapshotTransaction.faultInjector = nil
        require(
            interruptedCommitRejected,
            "RC-B09 \(faultName) must surface failure")
        let restoredTaskManifest = try Data(
            contentsOf: taskRoot.appendingPathComponent("input_manifest.json"))
        require(
            restoredTaskManifest == persistedManifestData,
            "RC-B09 \(faultName) must restore the previous task reference")
        require(
            !fileManager.fileExists(atPath: taskRoot.appendingPathComponent(
                "input_snapshot.transaction.json").path),
            "RC-B09 \(faultName) must clear the recovered transaction intent")
        try SessionSnapshotTransaction.revalidateSnapshot(
            snapshot.snapshotDirectory)
        let restoredSnapshotMode = (try fileManager.attributesOfItem(
            atPath: snapshot.snapshotDirectory.path)[.posixPermissions]
            as? NSNumber)?.intValue
        require(
            restoredSnapshotMode == 0o555,
            "RC-B09 \(faultName) must leave the restored root frozen")
    }

    try Data("tampered".utf8).write(to: database)
    try Data("tampered-trace\n".utf8).write(
        to: session.appendingPathComponent("localization_trace.jsonl"))
    let manifestAfter = try Data(contentsOf: taskRoot.appendingPathComponent("input_manifest.json"))
    require(
        manifestAfter == persistedManifestData,
        "P7 the persisted snapshot manifest must not change when the original is tampered")

    // A non-empty source WAL blocks a new generation before the invalid
    // main DB can ever be copied or opened.
    let walURL = session.appendingPathComponent("source.db-wal")
    try Data([0x01]).write(to: walURL)
    var walRejected = false
    do {
        _ = try SessionSnapshotTransaction.snapshot(
            finalizedSession: session,
            sourceDatabase: database,
            taskRoot: try p7r6FreshDirectory("mobile-task-wal"),
            eligibility: SessionSnapshotTransaction.Eligibility(
                priorMapID: "MAP-P7",
                priorMapSHA256: priorMapSHA,
                storeID: "STORE-P7",
                floorID: "FLOOR-P7",
                appGitSHA: "test-git-sha"))
    } catch {
        walRejected = true
    }
    require(walRejected, "RC-B08 non-empty WAL must block snapshot")
}
catch {
    require(false, "P7 session snapshot transaction failed: \(error)")
}

// P8/P12: the persistent task state machine survives atomic writes and
// interrupted states are never reported completed.
do {
    let taskParent = try p7r6FreshDirectory("mobile-state")
    let taskRoot = taskParent.appendingPathComponent("t1", isDirectory: true)
    _ = try PersistentTaskCoordinator.createTask(taskID: "t1", taskRoot: taskRoot)
    _ = try PersistentTaskCoordinator.updateState(.snapshotting, taskRoot: taskRoot, progress: 0.1)
    _ = try PersistentTaskCoordinator.updateState(.fastOptimizing, taskRoot: taskRoot, progress: 0.4)
    _ = try PersistentTaskCoordinator.updateState(.interrupted, taskRoot: taskRoot, progress: 0.4)
    let record = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
    require(
        record.state == .interrupted && record.progress == 0.4,
        "P8 task.json must persist the interrupted state atomically")
    require(
        record.state != .completed,
        "P8 an interrupted task must never be reported completed")
    require(
        PersistentTaskCoordinator.isResumable(record),
        "P12 an interrupted task must be resumable after a crash")
    var invalidCompletionJumpRejected = false
    do {
        _ = try PersistentTaskCoordinator.updateState(
            .completed, taskRoot: taskRoot, progress: 1.0)
    } catch PersistentTaskCoordinator.TaskError.invalidTransition {
        invalidCompletionJumpRejected = true
    }
    require(
        invalidCompletionJumpRejected,
        "RC-B25 interrupted must not jump directly to completed")
    _ = try PersistentTaskCoordinator.updateState(
        .snapshotting,
        taskRoot: taskRoot,
        progress: 0.1,
        allowRecoveryReentry: true)
    for (state, progress) in [
        (PersistentTaskCoordinator.TaskState.fastOptimizing, 0.2),
        (.fastQualityCheck, 0.3),
        (.buildingTrajectory, 0.5),
        (.resolvingTags, 0.6),
        (.buildingWorkbook, 0.75),
        (.validatingResult, 0.85),
        (.committingResult, 0.95),
        (.completed, 1.0),
    ] {
        _ = try PersistentTaskCoordinator.updateState(
            state, taskRoot: taskRoot, progress: progress)
    }
    let completed = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
    require(
        completed.state == .completed && !PersistentTaskCoordinator.isResumable(completed),
        "P12 a completed task is terminal")
}
catch {
    require(false, "P8/P12 persistent task state machine failed: \(error)")
}

// RC-H29/H37: staged map reads bind one single regular inode and every
// store/map identity follows the same bounded path-safe policy.
do {
    let directory = try p7r6FreshDirectory("stable-map-source")
    let source = directory.appendingPathComponent("source.json")
    let payload = Data("{\"format\":\"fixture\"}".utf8)
    try payload.write(to: source)
    let stablePayload = try StableMapSourceFileReader.read(source)
    require(
        stablePayload == payload,
        "RC-H29 stable regular-file read must preserve exact bytes")

    let hardlink = directory.appendingPathComponent("hardlink.json")
    require(
        Darwin.link(source.path, hardlink.path) == 0,
        "RC-H29 fixture must create a hardlink")
    do {
        _ = try StableMapSourceFileReader.read(source)
        require(false, "RC-H29 hardlinked staged source must be rejected")
    } catch let error as MapSourceImportError {
        require(
            error.stableCode == "map_source_unreadable",
            "RC-H29 hardlink rejection must use stable unreadable code")
    }
    try FileManager.default.removeItem(at: hardlink)

    let symlink = directory.appendingPathComponent("symlink.json")
    require(
        Darwin.symlink(source.path, symlink.path) == 0,
        "RC-H29 fixture must create a symlink")
    do {
        _ = try StableMapSourceFileReader.read(symlink)
        require(false, "RC-H29 symlink staged source must be rejected")
    } catch let error as MapSourceImportError {
        require(
            error.stableCode == "map_source_unreadable",
            "RC-H29 symlink rejection must use stable unreadable code")
    }

    try MapSourceBusinessIdentityPolicy.validate(
        storeID: "STORE-上海-01", mapName: "一层 主地图")
    for invalid in [
        ("bad/store", "map"),
        ("store", ".hidden"),
        ("store\u{0001}", "map"),
        (String(repeating: "s", count:
            MapSourceBusinessIdentityPolicy.maximumStoreIDBytes + 1), "map"),
        ("store", " map "),
    ] {
        do {
            try MapSourceBusinessIdentityPolicy.validate(
                storeID: invalid.0, mapName: invalid.1)
            require(false, "RC-H37 unsafe store/map identity must be rejected")
        } catch let error as MapSourceImportError {
            require(
                error.stableCode == "map_source_invalid_business_identity",
                "RC-H37 invalid identity must use one stable error code")
        }
    }
} catch {
    require(false, "RC-H29/H37 stable source/identity tests failed: \(error)")
}

// RC-H34: thermal evidence comes only from strict immutable snapshot
// JSONL. Missing, partial, malformed and unknown-field records all block
// the summary instead of being skipped and undercounted.
do {
    func scanEvent(
        event: String,
        trackingSessionID: String = "THERMAL-SESSION",
        extra: [String: Any] = [:]
    ) throws -> Data {
        var object: [String: Any] = [
            "format": "SupermarketScanEvent",
            "version": 1,
            "timestamp": "2023-11-14T22:13:20.000Z",
            "timestampUnix": 1_700_000_000.0,
            "level": "warning",
            "event": event,
            "message": "fixture event",
            "trackingSessionId": trackingSessionID,
            "fields": [String: String](),
        ]
        for (key, value) in extra { object[key] = value }
        var data = try CanonicalJSONEncoder.encode(object)
        data.append(0x0A)
        return data
    }

    let snapshot = try p7r6FreshDirectory("strict-scan-events")
    var valid = try scanEvent(event: "scan_started")
    valid.append(try scanEvent(event: "thermal_critical"))
    try valid.write(to: snapshot.appendingPathComponent("scan_events.jsonl"))
    let combinedThermalCount = try MobileProcessingPipeline
        .countThermalInterruptions(
            in: snapshot,
            expectedTrackingSessionID: "THERMAL-SESSION",
            processingThermalSamples: 2)
    require(
        combinedThermalCount == 3,
        "RC-H34 strict snapshot count must include 1 scan + 2 processing samples")

    let liveDirectory = try p7r6FreshDirectory("live-scan-events")
    var live = Data()
    for _ in 0..<5 { live.append(try scanEvent(event: "thermal_critical")) }
    try live.write(to: liveDirectory.appendingPathComponent("scan_events.jsonl"))
    let immutableThermalCount = try MobileProcessingPipeline
        .countThermalInterruptions(
            in: snapshot,
            expectedTrackingSessionID: "THERMAL-SESSION",
            processingThermalSamples: 0)
    require(
        immutableThermalCount == 1,
        "RC-H34 mutable live events must not affect immutable snapshot count")

    let missing = try p7r6FreshDirectory("missing-scan-events")
    do {
        _ = try MobileProcessingPipeline.countThermalInterruptions(
            in: missing,
            expectedTrackingSessionID: "THERMAL-SESSION",
            processingThermalSamples: 0)
        require(false, "RC-H34 missing scan_events must fail closed")
    } catch let error as MobileProcessingPipeline.ScanEventEvidenceError {
        require(error == .missingFile, "RC-H34 missing file stable reason")
    }

    let unknown = try p7r6FreshDirectory("unknown-scan-events")
    try scanEvent(event: "scan_started", extra: ["unexpected": true])
        .write(to: unknown.appendingPathComponent("scan_events.jsonl"))
    do {
        _ = try MobileProcessingPipeline.countThermalInterruptions(
            in: unknown,
            expectedTrackingSessionID: "THERMAL-SESSION",
            processingThermalSamples: 0)
        require(false, "RC-H34 unknown scan-event field must fail closed")
    } catch let error as MobileProcessingPipeline.ScanEventEvidenceError {
        if case .record(let line, let reason) = error {
            require(
                line == 1 && reason.hasPrefix("unknown_field_"),
                "RC-H34 unknown-field reason must retain original line")
        } else {
            require(false, "RC-H34 unknown field must be a record error")
        }
    }

    let partial = try p7r6FreshDirectory("partial-scan-events")
    var partialBytes = try scanEvent(event: "scan_started")
    partialBytes.removeLast()
    try partialBytes.write(
        to: partial.appendingPathComponent("scan_events.jsonl"))
    do {
        _ = try MobileProcessingPipeline.countThermalInterruptions(
            in: partial,
            expectedTrackingSessionID: "THERMAL-SESSION",
            processingThermalSamples: 0)
        require(false, "RC-H34 partial final line must fail closed")
    } catch let error as MobileProcessingPipeline.ScanEventEvidenceError {
        if case .framing = error {} else {
            require(false, "RC-H34 partial line must be a framing error")
        }
    }

    let mixedIdentity = try p7r6FreshDirectory("mixed-session-scan-events")
    var mixedIdentityBytes = try scanEvent(event: "scan_started")
    mixedIdentityBytes.append(try scanEvent(
        event: "thermal_critical", trackingSessionID: "OTHER-SESSION"))
    try mixedIdentityBytes.write(
        to: mixedIdentity.appendingPathComponent("scan_events.jsonl"))
    do {
        _ = try MobileProcessingPipeline.countThermalInterruptions(
            in: mixedIdentity,
            expectedTrackingSessionID: "THERMAL-SESSION",
            processingThermalSamples: 0)
        require(false, "RC-H34 mixed-session scan events must fail closed")
    } catch let error as MobileProcessingPipeline.ScanEventEvidenceError {
        if case .record(let line, let reason) = error {
            require(
                line == 2 && reason == "tracking_session_identity_mismatch",
                "RC-H34 mixed-session rejection must retain line and stable reason")
        } else {
            require(false, "RC-H34 mixed-session evidence must be a record error")
        }
    }
} catch {
    require(false, "RC-H34 strict thermal evidence tests failed: \(error)")
}

} // end of C1/C2 default-mode-only host tests

// P7R6A fixture alignment mode: classifies every shared recovery fixture
// through the device-side strict parser and prints "<name> <category>" so
// the Python test can assert the Swift parser and the PC reader agree.
if CommandLine.arguments.count >= 3,
   CommandLine.arguments[1] == "--recovery-fixtures" {
    do {
        let fixtureDirectory = URL(
            fileURLWithPath: CommandLine.arguments[2],
            isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixtureDirectory.path).filter {
                $0.hasSuffix(".jsonl")
            }.sorted()
        guard !names.isEmpty else {
            FileHandle.standardError.write(
                Data("No recovery lifecycle fixtures found\n".utf8))
            exit(3)
        }
        for name in names {
            let data = try Data(
                contentsOf: fixtureDirectory.appendingPathComponent(name))
            let category: String
            do {
                _ = try RecoveryLifecyclePersistedEvidenceParser.parse(
                    snapshot: data,
                    expectation: p7r6aParseExpectation())
                category = "PASS"
            }
            catch let error as RecoveryLifecycleEvidenceParseError {
                category = error.stableCode
            }
            print("\(name) \(category)")
        }
        exit(0)
    }
    catch {
        FileHandle.standardError.write(
            Data("Recovery fixture alignment failed: \(error)\n".utf8))
        exit(4)
    }
}

if CommandLine.arguments.count == 2 {
    do {
        let digest = try PriorMapPackageIntegrity.validate(
            directory: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Package integrity passed \(digest)")
    }
    catch {
        FileHandle.standardError.write(Data("Package integrity failed: \(error)\n".utf8))
        exit(2)
    }
}

// P7R6C-C3: integrity-suite mode validates a batch of package directories
// in ONE executable invocation. The root contains subdirectories named
// "<case>.<expected>" where expected is "pass" or "fail"; the harness
// verifies every case against the snapshot validator without re-launching
// the process (CI wall-clock budgets otherwise get blown by repeated
// process starts).
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--integrity-suite" {
    do {
        let root = URL(
            fileURLWithPath: CommandLine.arguments[2],
            isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [])
        var failed: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(
                forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let name = entry.lastPathComponent
            let expected: Bool
            if name.hasSuffix(".pass") {
                expected = true
            }
            else if name.hasSuffix(".fail") {
                expected = false
            }
            else {
                continue
            }
            do {
                _ = try PriorMapPackageIntegrity.validate(directory: entry)
                if !expected {
                    failed.append("\(name): expected fail but passed")
                }
            }
            catch {
                if expected {
                    failed.append("\(name): expected pass but failed: \(error)")
                }
            }
        }
        guard failed.isEmpty else {
            FileHandle.standardError.write(
                Data(("Integrity suite failures:\n"
                    + failed.joined(separator: "\n") + "\n").utf8))
            exit(5)
        }
        print("Integrity suite passed")
    }
    catch {
        FileHandle.standardError.write(
            Data("Integrity suite failed: \(error)\n".utf8))
        exit(5)
    }
}

// Mobile-Only V1: --import-suite validates the three-format canonical
// parity and the XLSX safety policy in ONE invocation. The directory
// contains the fixtures produced by the Python harness:
//   sample.xlsx sample.csv sample.json  -> must import with equal
//                                          canonicalSourceSha256
//   formula.xlsx                        -> must fail formulaNotSupported
//   traversal.xlsx                      -> must fail zipTraversal
//   bomb.xlsx                           -> must fail zip ratio/total
//   multi-floor.json                    -> must import with 2 floors
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--import-suite" {
    do {
        let root = URL(
            fileURLWithPath: CommandLine.arguments[2],
            isDirectory: true)
        let fileManager = FileManager.default

        func load(_ name: String) throws -> Data {
            let url = root.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else {
                throw MapSourceImportError.unreadableSource(reason: "缺少 fixture \(name)")
            }
            return try Data(contentsOf: url)
        }

        var failures: [String] = []

        // Three-format parity: identical canonical digest and elements.
        do {
            let xlsxData = try load("sample.xlsx")
            let csvData = try load("sample.csv")
            let jsonData = try load("sample.json")

            let xlsxReport = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(xlsxData, named: "sample.xlsx"),
                originalFilename: "sample.xlsx",
                contract: .topLeft,
                storeId: "s1",
                allowLegacyXLSX: true)
            let csvReport = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(csvData, named: "sample.csv"),
                originalFilename: "sample.csv",
                contract: .topLeft,
                storeId: "s1")
            let jsonReport = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(jsonData, named: "sample.json"),
                originalFilename: "sample.json",
                contract: .topLeft,
                storeId: "s1")

            if xlsxReport.canonicalSourceSha256 != csvReport.canonicalSourceSha256 {
                failures.append("parity: xlsx vs csv canonical SHA mismatch")
            }
            if xlsxReport.canonicalSourceSha256 != jsonReport.canonicalSourceSha256 {
                failures.append("parity: xlsx vs json canonical SHA mismatch")
            }
            if xlsxReport.canonicalSource.elements != csvReport.canonicalSource.elements {
                failures.append("parity: xlsx vs csv elements mismatch")
            }
            if xlsxReport.canonicalSource.elements != jsonReport.canonicalSource.elements {
                let mismatch = zip(
                    xlsxReport.canonicalSource.elements,
                    jsonReport.canonicalSource.elements
                ).first { $0 != $1 }
                let left = mismatch.flatMap {
                    try? CanonicalJSONEncoder.encodeString($0.0.canonicalPayload)
                } ?? "missing"
                let right = mismatch.flatMap {
                    try? CanonicalJSONEncoder.encodeString($0.1.canonicalPayload)
                } ?? "missing"
                failures.append(
                    "parity: xlsx vs json elements mismatch; xlsx=\(left) json=\(right)")
            }
            if xlsxReport.elementCount != csvReport.elementCount
                || xlsxReport.elementCount != jsonReport.elementCount {
                failures.append("parity: element count mismatch")
            }
            if xlsxReport.floorCount != csvReport.floorCount
                || xlsxReport.floorCount != jsonReport.floorCount {
                failures.append("parity: floor count mismatch")
            }
            if xlsxReport.sourceFileSha256 == csvReport.sourceFileSha256 {
                failures.append("parity: sourceFileSha256 must differ across formats")
            }
            if xlsxReport.canonicalSourceSha256.isEmpty {
                failures.append("parity: canonical SHA must not be empty")
            }
        }
        catch {
            failures.append("parity: \(error)")
        }

        // V1R4 §14.1: a canonical v2 document round-trips to the same
        // digest and elements (document contract/identity win over the
        // wizard parameters).
        do {
            let v2Data = try load("sample-v2.json")
            let v2Report = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(v2Data, named: "sample-v2.json"),
                originalFilename: "sample-v2.json",
                contract: .bottomLeft)
            let xlsxReference = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(try load("sample.xlsx"), named: "sample.xlsx"),
                originalFilename: "sample.xlsx",
                contract: .topLeft,
                storeId: "s1",
                mapName: "sample",
                allowLegacyXLSX: true)
            if v2Report.canonicalSourceSha256 != xlsxReference.canonicalSourceSha256 {
                failures.append("v2 parity: canonical v2 digest must match xlsx")
            }
            if v2Report.canonicalSource.elements.count != xlsxReference.canonicalSource.elements.count {
                failures.append("v2 parity: element count mismatch")
            }
            if v2Report.coordinateContractOrigin != "top_left" {
                failures.append("v2 parity: document contract must win over wizard")
            }
            if v2Report.storeId != "s1" || v2Report.mapName != "sample" {
                failures.append("v2 parity: document identity must win over wizard")
            }
        }
        catch {
            failures.append("v2 parity: \(error)")
        }

        // I5: formula cells are rejected.
        do {
            let data = try load("formula.xlsx")
            _ = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(data, named: "formula.xlsx"),
                originalFilename: "formula.xlsx",
                contract: .topLeft,
                storeId: "s1",
                allowLegacyXLSX: true)
            failures.append("formula: expected rejection")
        }
        catch let error as MapSourceImportError {
            if error.stableCode != "map_source_formula_not_supported" {
                failures.append("formula: wrong code \(error.stableCode)")
            }
        }
        catch {
            failures.append("formula: unexpected error \(error)")
        }

        // I6: ZIP path traversal is rejected.
        do {
            let data = try load("traversal.xlsx")
            _ = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(data, named: "traversal.xlsx"),
                originalFilename: "traversal.xlsx",
                contract: .topLeft,
                storeId: "s1")
            failures.append("traversal: expected rejection")
        }
        catch let error as MapSourceImportError {
            if error.stableCode != "map_source_zip_traversal" {
                failures.append("traversal: wrong code \(error.stableCode)")
            }
        }
        catch {
            failures.append("traversal: unexpected error \(error)")
        }

        // I7: ZIP bomb (extreme compression ratio) is rejected.
        do {
            let data = try load("bomb.xlsx")
            _ = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(data, named: "bomb.xlsx"),
                originalFilename: "bomb.xlsx",
                contract: .topLeft,
                storeId: "s1")
            failures.append("bomb: expected rejection")
        }
        catch let error as MapSourceImportError {
            let code = error.stableCode
            if code != "map_source_zip_ratio_too_large"
                && code != "map_source_zip_entry_too_large"
                && code != "map_source_zip_total_too_large" {
                failures.append("bomb: wrong code \(code)")
            }
        }
        catch {
            failures.append("bomb: unexpected error \(error)")
        }

        // I14: multi-floor JSON imports with 3 floors.
        do {
            let data = try load("multi-floor.json")
            let report = try MapSourceImportCoordinator.importMap(
                stagedURL: try writeTemporary(data, named: "multi-floor.json"),
                originalFilename: "multi-floor.json",
                contract: .topLeft,
                storeId: "s1",
                mapName: "sample")
            if report.floorCount != 3 {
                failures.append("multi-floor: expected 3 floors, got \(report.floorCount)")
            }
        }
        catch {
            failures.append("multi-floor: \(error)")
        }

        guard failures.isEmpty else {
            FileHandle.standardError.write(
                Data(("Import suite failures:\n"
                    + failures.joined(separator: "\n") + "\n").utf8))
            exit(6)
        }
        print("Import suite passed")
    }
    catch {
        FileHandle.standardError.write(
            Data("Import suite failed: \(error)\n".utf8))
        exit(6)
    }
}

// Writes a fixture into a temporary file under the suite directory so the
// coordinator can hash a stable staged copy (the security-scoped copy is
// simulated by writing to a private staging file).
private func writeTemporary(_ data: Data, named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("import-suite-staging", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try data.write(to: url, options: [.atomic])
    return url
}

private func runShelfSegmentParity(
    workbookPath: String,
    expectedPath: String
) {
    do {
        let workbook = URL(fileURLWithPath: workbookPath)
        let report = try MapSourceImportCoordinator.importMap(
            stagedURL: workbook,
            originalFilename: workbook.lastPathComponent,
            contract: .bottomLeft,
            strict: true)
        let shelves = report.canonicalSource.elements.filter {
            ElementRoleClassifier.role(for: $0.shapeType) == .shelf
        }
        let actual = try MobilePriorMapCompiler.compiledShelfSegments(shelves)
            .map(\.canonicalPayload)
        let expectedData = try Data(
            contentsOf: URL(fileURLWithPath: expectedPath))
        let expected = try JSONSerialization.jsonObject(
            with: expectedData, options: [.fragmentsAllowed])
        let actualData = try CanonicalJSONEncoder.encode(actual as [Any])
        let expectedCanonical = try CanonicalJSONEncoder.encode(expected)
        guard actualData == expectedCanonical else {
            let actualText = String(data: actualData, encoding: .utf8) ?? "<invalid>"
            let expectedText = String(
                data: expectedCanonical, encoding: .utf8) ?? "<invalid>"
            throw PriorMapShelfSchemaError.invalid(
                "Swift/Python shelf segment mismatch; "
                    + "actual=\(actualText) expected=\(expectedText)")
        }
        print("Shelf segment parity passed count=\(actual.count)")
    } catch {
        FileHandle.standardError.write(
            Data("Shelf segment parity failed: \(error)\n".utf8))
        exit(13)
    }
}

private func runMapCase02Suite(
    workbookPath: String,
    outputPath: String,
    expectedCanonicalSHA256: String,
    expectedPackageSHA256: String,
    legacyWorkbookPath: String?
) {
    do {
        let workbook = URL(fileURLWithPath: workbookPath)
        let report = try MapSourceImportCoordinator.importMap(
            stagedURL: workbook,
            originalFilename: workbook.lastPathComponent,
            contract: .bottomLeft,
            strict: true)
        require(report.mapName == "Piaseczno", "MapCase02 map_name mismatch")
        require(report.storeId == "CAPL.2794", "MapCase02 storeCode mismatch")
        require(report.coordinateContractOrigin == "top_left",
                "formal XLSX must freeze top-left coordinate contract")
        require(report.elementCount == 1_630, "MapCase02 active count mismatch")
        require(report.ignoredElementCount == 208, "MapCase02 ignored count mismatch")
        require(report.legacyShelfInfoPresent
                && report.legacyShelfInfoRowCount == 1_573,
                "MapCase02 Shelf Info audit mismatch")
        let canonicalData = try CanonicalJSONEncoder.encode(
            report.canonicalSource.canonicalPayload)
        try canonicalData.write(
            to: URL(fileURLWithPath: outputPath + ".canonical.json"),
            options: [.atomic])
        require(report.canonicalSourceSha256 == expectedCanonicalSHA256,
                "Swift/Python canonical SHA mismatch: \(report.canonicalSourceSha256)")
        guard let mapInfo = report.canonicalSource.sourceMapInfo,
              let summary = report.canonicalSource.importSummary else {
            require(false, "MapCase02 formal source metadata missing")
            return
        }
        require(mapInfo.widthCm == 13_129 && mapInfo.heightCm == 8_770
                && mapInfo.scale == 20,
                "MapCase02 Basic Info dimensions/scale mismatch")
        require(summary.sourceElementCount == 1_838
                && summary.presentationIgnoredCount == 208
                && summary.ignoredByShapeType == [
                    "Circle": 93, "MapMark": 104, "Rect": 11,
                ],
                "MapCase02 source/presentation statistics mismatch")

        let expectedPolygons: [String: [[Double]]] = [
            "041-08": [[41.93, -3.90], [40.87, -3.90], [40.87, -15.53], [41.93, -15.53]],
            "042-03": [[45.35, -3.83], [44.29, -3.83], [44.29, -15.58], [45.35, -15.58]],
            "043-08": [[48.74, -3.85], [47.68, -3.85], [47.68, -15.56], [48.74, -15.56]],
            "060-07": [[114.85, -1.84], [113.66, -1.84], [113.66, -4.49], [114.85, -4.49]],
            "001-01": [[14.28, -78.68], [14.28, -77.72], [12.95, -77.72], [12.95, -78.68]],
            "TableFeature-106-330": [[127.00, -40.94], [124.44, -40.94], [124.44, -56.10], [127.00, -56.10]],
            "TableFeature-106-333": [[130.99, -56.73], [129.52, -56.73], [129.52, -72.43], [130.99, -72.43]],
            "Shelf-106-391-1": [[130.92, -73.25], [129.76, -73.25], [129.76, -75.25], [130.92, -75.25]],
            "Shelf-106-399-1": [[130.95, -25.03], [129.73, -25.03], [129.73, -27.87], [130.95, -27.87]],
        ]
        for (code, expected) in expectedPolygons {
            let matches = report.canonicalSource.elements.filter { $0.code == code }
            require(matches.count == 1, "MapCase02 landmark \(code) must be unique")
            guard let actual = matches.first?.geometry?["coordinates"] as? [[Double]] else {
                require(false, "MapCase02 landmark \(code) geometry missing")
                continue
            }
            require(actual.count == expected.count,
                    "MapCase02 landmark \(code) point count mismatch")
            for (actualPoint, expectedPoint) in zip(actual, expected) {
                require(close(actualPoint[0], expectedPoint[0], tolerance: 1.0e-6)
                        && close(actualPoint[1], expectedPoint[1], tolerance: 1.0e-6),
                        "MapCase02 landmark \(code) polygon mismatch: \(actual)")
            }
        }

        let obstaclePolygons: [[(Double, Double)]] =
            report.canonicalSource.elements.compactMap { element in
                let role = ElementRoleClassifier.role(for: element.shapeType)
                guard element.visible,
                      role == .shelf || role == .fixedStructure,
                      let coordinates = element.geometry?["coordinates"]
                        as? [[Double]],
                      coordinates.count >= 3 else {
                    return nil
                }
                return coordinates.map { ($0[0], $0[1]) }
            }
        func distanceToPolygon(
            point: (Double, Double),
            polygon: [(Double, Double)]
        ) -> Double {
            var best = Double.greatestFiniteMagnitude
            for index in polygon.indices {
                let a = polygon[index]
                let b = polygon[(index + 1) % polygon.count]
                let dx = b.0 - a.0
                let dy = b.1 - a.1
                let lengthSquared = dx * dx + dy * dy
                let ratio = lengthSquared > 1.0e-12
                    ? max(0, min(1,
                        ((point.0 - a.0) * dx + (point.1 - a.1) * dy)
                            / lengthSquared))
                    : 0
                best = min(
                    best,
                    hypot(
                        point.0 - (a.0 + ratio * dx),
                        point.1 - (a.1 + ratio * dy)))
            }
            return best
        }
        let reportedFreeStart = (58.03, -18.13)
        require(
            !obstaclePolygons.contains(where: {
                ShelfAssociationEngine.pointInPolygon(
                    point: reportedFreeStart,
                    polygon: $0)
            }),
            "reported MapCase02 start point must not be inside an obstacle")
        let reportedFreeStartClearance = obstaclePolygons.map {
            distanceToPolygon(point: reportedFreeStart, polygon: $0)
        }.min() ?? .infinity
        require(
            reportedFreeStartClearance >= 0.30,
            "reported MapCase02 start point must preserve the 0.30 m clearance gate")
        let knownShelfInterior = (41.40, -9.70)
        require(
            obstaclePolygons.contains(where: {
                ShelfAssociationEngine.pointInPolygon(
                    point: knownShelfInterior,
                    polygon: $0)
            }),
            "a known MapCase02 shelf interior must remain strictly rejected")

        let canonicalURL = try writeTemporary(
            canonicalData, named: "mapcase02-canonical-v3.json")
        let roundTrip = try MapSourceImportCoordinator.importMap(
            stagedURL: canonicalURL,
            originalFilename: canonicalURL.lastPathComponent,
            contract: .bottomLeft,
            strict: true)
        require(roundTrip.canonicalSourceSha256 == report.canonicalSourceSha256
                && roundTrip.elementCount == report.elementCount,
                "MapCase02 canonical v3 JSON round trip mismatch")

        // A canonical v3 document is a formal input, not a trusted
        // in-memory DTO. Keep the role but replace a structure polygon with
        // a line string: import must fail before compilation/rendering.
        var invalidCanonical = report.canonicalSource.canonicalPayload
        guard var invalidElements = invalidCanonical["elements"]
                as? [[String: Any]],
              let invalidElementIndex = invalidElements.firstIndex(where: {
                  ElementRoleClassifier.role(
                    for: $0["shape_type"] as? String ?? "")
                    == .fixedStructure
              }),
              var invalidGeometry = invalidElements[invalidElementIndex]["geometry"]
                as? [String: Any] else {
            require(false, "MapCase02 invalid canonical fixture could not be built")
            return
        }
        invalidGeometry["type"] = "line_string"
        invalidElements[invalidElementIndex]["geometry"] = invalidGeometry
        invalidCanonical["elements"] = invalidElements
        let invalidCanonicalData = try CanonicalJSONEncoder.encode(
            invalidCanonical)
        let invalidCanonicalURL = try writeTemporary(
            invalidCanonicalData,
            named: "mapcase02-invalid-geometry-v3.json")
        do {
            _ = try MapSourceImportCoordinator.importMap(
                stagedURL: invalidCanonicalURL,
                originalFilename: invalidCanonicalURL.lastPathComponent,
                contract: .topLeft,
                strict: true)
            require(false, "canonical v3 wrong geometry kind must be rejected")
        } catch let error as MapSourceImportError {
            require(error.stableCode == "map_source_invalid_geometry",
                    "canonical v3 wrong geometry returned \(error.stableCode)")
        }

        let excessiveSheetsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>
        """ + (1...(MapSourceImportLimits.maximumWorkbookSheets + 1)).map {
            "<sheet name=\"S\($0)\" sheetId=\"\($0)\" r:id=\"rId\($0)\"/>"
        }.joined() + "</sheets></workbook>"
        do {
            _ = try XLSXWorkbookReader.readSheets(entries: [
                XLSXZipReader.Entry(
                    name: "xl/workbook.xml",
                    data: Data(excessiveSheetsXML.utf8)),
            ])
            require(false, "excessive workbook sheet records must be rejected")
        } catch let error as MapSourceImportError {
            require(error.stableCode == "map_source_xlsx_invalid_xml",
                    "excessive sheets returned \(error.stableCode)")
        }
        let excessiveRelationshipsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """ + (1...(MapSourceImportLimits.maximumWorkbookRelationships + 1)).map {
            "<Relationship Id=\"rId\($0)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0).xml\"/>"
        }.joined() + "</Relationships>"
        do {
            _ = try XLSXWorkbookReader.readRelationships(entries: [
                XLSXZipReader.Entry(
                    name: "xl/_rels/workbook.xml.rels",
                    data: Data(excessiveRelationshipsXML.utf8)),
            ])
            require(false, "excessive workbook relationships must be rejected")
        } catch let error as MapSourceImportError {
            require(error.stableCode == "map_source_xlsx_invalid_xml",
                    "excessive relationships returned \(error.stableCode)")
        }

        let duplicateRelationshipsXML = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
        </Relationships>
        """.utf8)
        do {
            _ = try XLSXWorkbookReader.readRelationships(entries: [
                XLSXZipReader.Entry(
                    name: "xl/_rels/workbook.xml.rels",
                    data: duplicateRelationshipsXML),
            ])
            require(false, "duplicate workbook relationship IDs must be rejected")
        } catch let error as MapSourceImportError {
            require(error.stableCode == "map_source_xlsx_invalid_xml",
                    "duplicate relationship returned \(error.stableCode)")
        }
        let externalRelationshipsXML = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml" TargetMode="External"/>
        </Relationships>
        """.utf8)
        do {
            _ = try XLSXWorkbookReader.readRelationships(entries: [
                XLSXZipReader.Entry(
                    name: "xl/_rels/workbook.xml.rels",
                    data: externalRelationshipsXML),
            ])
            require(false, "external worksheet relationship must be rejected")
        } catch let error as MapSourceImportError {
            require(error.stableCode == "map_source_xlsx_invalid_xml",
                    "external relationship returned \(error.stableCode)")
        }
        do {
            _ = try XLSXWorkbookReader.worksheetEntry(
                entries: [
                    XLSXZipReader.Entry(
                        name: "xl/worksheets/sheet1.xml", data: Data()),
                    XLSXZipReader.Entry(
                        name: "worksheets/sheet1.xml", data: Data()),
                ],
                target: "worksheets/sheet1.xml")
            require(false, "ambiguous worksheet targets must be rejected")
        } catch let error as MapSourceImportError {
            require(error.stableCode == "map_source_xlsx_invalid_xml",
                    "ambiguous worksheet target returned \(error.stableCode)")
        }
        do {
            _ = try XLSXWorkbookReader.readSheets(entries: [
                XLSXZipReader.Entry(
                    name: "xl/workbook.xml",
                    data: Data("""
                    <?xml version="1.0"?><!DOCTYPE workbook [<!ENTITY x "x">]><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets/></workbook>
                    """.utf8)),
            ])
            require(false, "DOCTYPE workbook must be rejected")
        } catch let error as MapSourceImportError {
            require(error.stableCode == "map_source_xlsx_invalid_xml",
                    "DOCTYPE workbook returned \(error.stableCode)")
        }
        do {
            let aliasedSheets = [
                XLSXWorkbookReader.SheetInfo(
                    name: "Basic Info", relationshipID: "rId1"),
                XLSXWorkbookReader.SheetInfo(
                    name: "Element Info", relationshipID: "rId2"),
            ]
            let aliasedRelationships = [
                XLSXWorkbookReader.Relationship(
                    identifier: "rId1",
                    type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet",
                    target: "worksheets/sheet1.xml"),
                XLSXWorkbookReader.Relationship(
                    identifier: "rId2",
                    type: "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet",
                    target: "worksheets/sheet1.xml"),
            ]
            try XLSXWorkbookReader.validateSheetAuthorities(
                sheets: aliasedSheets,
                relationships: aliasedRelationships,
                entries: [XLSXZipReader.Entry(
                    name: "xl/worksheets/sheet1.xml", data: Data())])
            require(false, "aliased worksheet authorities must be rejected")
        } catch let error as MapSourceImportError {
            require(error.stableCode == "map_source_xlsx_invalid_xml",
                    "worksheet authority alias returned \(error.stableCode)")
        }

        func requireWorksheetRejection(_ label: String, _ xml: String) {
            do {
                _ = try XLSXWorksheetReader.readWorksheet(
                    entry: XLSXZipReader.Entry(
                        name: "xl/worksheets/\(label).xml",
                        data: Data(xml.utf8)),
                    sharedStrings: [])
                require(false, "\(label) worksheet must be rejected")
            } catch let error as MapSourceImportError {
                require(error.stableCode == "map_source_xlsx_invalid_xml",
                        "\(label) returned \(error.stableCode)")
            } catch {
                require(false, "\(label) returned unexpected error \(error)")
            }
        }
        requireWorksheetRejection(
            "missing-row-reference",
            """
            <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row><c r="A1"><v>1</v></c></row></sheetData></worksheet>
            """)
        requireWorksheetRejection(
            "duplicate-row-reference",
            """
            <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1"><v>1</v></c></row><row r="1"><c r="B1"><v>2</v></c></row></sheetData></worksheet>
            """)
        requireWorksheetRejection(
            "mismatched-cell-reference",
            """
            <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="2"><c r="A3"><v>1</v></c></row></sheetData></worksheet>
            """)
        requireWorksheetRejection(
            "duplicate-cell-reference",
            """
            <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1"><v>1</v></c><c r="A1"><v>2</v></c></row></sheetData></worksheet>
            """)
        requireWorksheetRejection(
            "oversized-column-reference",
            """
            <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="AAAAAAAAAAAAAAAAAAAA1"><v>1</v></c></row></sheetData></worksheet>
            """)
        requireWorksheetRejection(
            "leading-zero-row-reference",
            """
            <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="01"><c r="A01"><v>1</v></c></row></sheetData></worksheet>
            """)
        requireWorksheetRejection(
            "foreign-sheet-data",
            """
            <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:evil="urn:evil"><evil:sheetData><row r="1"><c r="A1"><v>1</v></c></row></evil:sheetData></worksheet>
            """)
        requireWorksheetRejection(
            "invalid-boolean-cell",
            """
            <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="b"><v>2</v></c></row></sheetData></worksheet>
            """)
        let oversizedInlineText = String(
            repeating: "x",
            count: Int(MapSourceImportLimits.maximumCellBytes) + 1)
        requireWorksheetRejection(
            "oversized-inline-cell",
            """
            <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>\(oversizedInlineText)</t></is></c></row></sheetData></worksheet>
            """)
        do {
            _ = try XLSXWorksheetReader.readWorksheet(
                entry: XLSXZipReader.Entry(
                    name: "xl/worksheets/negative-shared-string.xml",
                    data: Data("""
                    <?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>-1</v></c></row></sheetData></worksheet>
                    """.utf8)),
                sharedStrings: ["last"])
            require(false, "negative shared-string index must be rejected")
        } catch let error as MapSourceImportError {
            require(error.stableCode == "map_source_xlsx_invalid_xml",
                    "negative shared-string index returned \(error.stableCode)")
        }

        do {
            try XLSXMapSourceImporter.enforceElementCount(
                MapSourceImportLimits.maximumElements)
        } catch {
            require(false, "100,000 source elements must remain within the limit")
        }
        do {
            try XLSXMapSourceImporter.enforceElementCount(
                MapSourceImportLimits.maximumElements + 1)
            require(false, "100,001 source elements must be rejected")
        } catch let error as MapSourceImportError {
            require(error.stableCode == "map_source_element_count_too_large",
                    "100,001 source elements returned \(error.stableCode)")
        }

        var duplicateIDSource = report.canonicalSource
        require(duplicateIDSource.elements.count >= 2,
                "MapCase02 duplicate-ID fixture needs two elements")
        duplicateIDSource.elements[1].id = duplicateIDSource.elements[0].id
        let duplicateIDOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mapcase02-duplicate-id-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: duplicateIDOutput) }
        do {
            _ = try MobilePriorMapCompiler.compile(
                canonicalSource: duplicateIDSource,
                outputDirectory: duplicateIDOutput)
            require(false, "duplicate active element IDs must be rejected without a trap")
        } catch let error as MobilePriorMapCompiler.CompileError {
            if case .outputNotUsable = error {
                // Expected typed rejection.
            } else {
                require(false, "duplicate active ID returned \(error)")
            }
        } catch {
            require(false, "duplicate active ID returned unexpected error \(error)")
        }

        var duplicateStableSource = report.canonicalSource
        guard var duplicateBusinessElement = duplicateStableSource.elements.first
        else {
            require(false, "MapCase02 stable-ID fixture needs one element")
            return
        }
        duplicateBusinessElement.id += "-duplicate-row"
        duplicateBusinessElement.sourceRow =
            (duplicateStableSource.elements.map(\.sourceRow).max() ?? 0) + 1
        duplicateStableSource.elements.append(duplicateBusinessElement)
        if var summary = duplicateStableSource.importSummary {
            summary.sourceElementCount += 1
            duplicateStableSource.importSummary = summary
        }
        let duplicateStableOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mapcase02-duplicate-stable-id-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: duplicateStableOutput) }
        do {
            _ = try MobilePriorMapCompiler.compile(
                canonicalSource: duplicateStableSource,
                outputDirectory: duplicateStableOutput)
            require(false, "duplicate stable business IDs must be rejected")
        } catch let error as MobilePriorMapCompiler.CompileError {
            if case .outputNotUsable = error {
                // Expected typed rejection before package output.
            } else {
                require(false, "duplicate stable business ID returned \(error)")
            }
        } catch {
            require(false,
                    "duplicate stable business ID returned unexpected error \(error)")
        }

        let oversizedFloor: [[String: Any]] = [[
            "id": "1",
            "bounds": [
                "min_x_m": 0.0, "min_y_m": 0.0,
                "max_x_m": 3_000.0, "max_y_m": 1.0,
            ],
        ]]
        do {
            _ = try MobileDistanceFieldBuilder.build(
                elements: [], floors: oversizedFloor)
            require(false, "oversized distance-field dimension must be rejected")
        } catch let error as MapSourceImportError {
            require(error.stableCode == "map_source_invalid_geometry",
                    "distance-field budget returned \(error.stableCode)")
        }
        let oversizedDecodedLevel = PriorMapDistanceFieldLevel(
            resolutionM: 0.1,
            originM: [0, 0],
            width: Int.max,
            height: 1,
            encoding: "row_rle_u8_cm",
            dataSha256: String(repeating: "0", count: 64),
            rows: [])
        do {
            _ = try oversizedDecodedLevel.decodedValues()
            require(false, "oversized decoded distance level must reject before allocation")
        } catch {
            // Expected typed fail-closed rejection before width*height.
        }
        let oversizedRLELevel = PriorMapDistanceFieldLevel(
            resolutionM: 0.1,
            originM: [0, 0],
            width: 1,
            height: 1,
            encoding: "row_rle_u8_cm",
            dataSha256: String(repeating: "0", count: 64),
            rows: [[Int.max, 0]])
        do {
            _ = try oversizedRLELevel.decodedValues()
            require(false, "oversized RLE count must reject before append")
        } catch {
            // Expected fail-closed rejection before repeatElement allocation.
        }

        var oversizedSpatialElement = report.canonicalSource.elements[0]
        oversizedSpatialElement.bounds = [
            "min_x_m": 0, "min_y_m": 0,
            "max_x_m": 40_000_000, "max_y_m": 0,
            "width_m": 40_000_000, "height_m": 0,
        ]
        do {
            _ = try MobileSpatialIndexBuilder.build(
                elements: [oversizedSpatialElement],
                graph: ["nodes": [[String: Any]](), "edges": [[String: Any]]()],
                floors: oversizedFloor)
            require(false, "oversized spatial assignment must be rejected")
        } catch let error as MapSourceImportError {
            require(error.stableCode == "map_source_invalid_geometry",
                    "spatial budget returned \(error.stableCode)")
        }

        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        let compiled = try MobilePriorMapCompiler.compile(
            canonicalSource: report.canonicalSource,
            outputDirectory: output)
        require(compiled.elementCount == 1_630 && compiled.floorCount == 1,
                "MapCase02 compiler counts mismatch")
        require(
            compiled.priorMapID
                == "piaseczno-\(String(expectedCanonicalSHA256.prefix(12)))",
            "MapCase02 prior_map_id must use the canonical lowercase slug")
        require(
            MobileMapLibrary.isSafeIdentifier(compiled.priorMapID),
            "MapCase02 compiler must emit a MobileMapLibrary-safe identifier")
        require(
            MobilePriorMapCompiler.safeName("İstanbul") == "stanbul"
                && MobilePriorMapCompiler.safeName("Kelvin") == "elvin"
                && MobilePriorMapCompiler.safeName("北京A9") == "a9",
            "canonical slug must filter Unicode before ASCII lowercasing")
        let maximumLengthID = MobilePriorMapCompiler.safeName(
            String(repeating: "A", count: 200)) + "-" + String(
                expectedCanonicalSHA256.prefix(12))
        require(
            maximumLengthID.count == 128
                && MobileMapLibrary.isSafeIdentifier(maximumLengthID),
            "maximum legal map name must still produce a safe 128-byte ID")
        let packageSHA = try PriorMapPackageIntegrity.validate(directory: output)
        require(
            packageSHA == compiled.packageSHA256
                && packageSHA == expectedPackageSHA256,
            "MapCase02 frozen Swift package SHA mismatch: \(packageSHA)")
        let legacyIntegrityPackage = output.deletingLastPathComponent()
            .appendingPathComponent(
                ".mapcase02-legacy-uppercase-v2-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.copyItem(
            at: output, to: legacyIntegrityPackage)
        defer { try? FileManager.default.removeItem(at: legacyIntegrityPackage) }
        let legacyManifestURL = legacyIntegrityPackage.appendingPathComponent(
            "manifest.json")
        guard var legacyManifest = try JSONSerialization.jsonObject(
                with: Data(contentsOf: legacyManifestURL)) as? [String: Any]
        else {
            throw MapSourceImportError.invalidJSON(
                detail: "MapCase02 legacy v2 manifest fixture must decode")
        }
        let legacyPriorMapID = "Piaseczno-"
            + String(expectedCanonicalSHA256.prefix(12))
        legacyManifest["prior_map_id"] = legacyPriorMapID
        try CanonicalJSONEncoder.encode(legacyManifest).write(
            to: legacyManifestURL)
        let legacyPackageManifest = try MobilePackageManifestBuilder
            .buildManifest(directory: legacyIntegrityPackage)
        try CanonicalJSONEncoder.encode(legacyPackageManifest).write(
            to: legacyIntegrityPackage.appendingPathComponent(
                MobilePackageManifestBuilder.manifestFileName))
        var productionRejectedLegacyID = false
        do {
            _ = try PriorMapPackageIntegrity.validate(
                directory: legacyIntegrityPackage)
        } catch {
            productionRejectedLegacyID = true
        }
        require(
            productionRejectedLegacyID,
            "production integrity must reject legacy uppercase v2 IDs")
        let legacyIntegritySHA = try PriorMapPackageIntegrity.validate(
            directory: legacyIntegrityPackage,
            allowLegacyV2IdentifierForDiagnostics: true)
        require(
            legacyIntegritySHA
                == (legacyPackageManifest["package_sha256"] as? String)
                && !MobileMapLibrary.isSafeIdentifier(legacyPriorMapID),
            "legacy uppercase v2 must be accepted only by explicit diagnostics")
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: output.appendingPathComponent("manifest.json")))
            as? [String: Any]
        require(StrictJSONScalar.integer(manifest?["version"]) == 2
                && StrictJSONScalar.integer(manifest?["source_element_count"]) == 1_838
                && StrictJSONScalar.integer(manifest?["shelf_count"]) == 1_301
                && StrictJSONScalar.integer(manifest?["fixed_structure_count"]) == 329,
                "MapCase02 compiled manifest metrics mismatch")

        let duplicateStablePackage = output.deletingLastPathComponent()
            .appendingPathComponent(
                ".mapcase02-duplicate-stable-package-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.copyItem(at: output, to: duplicateStablePackage)
        defer { try? FileManager.default.removeItem(at: duplicateStablePackage) }
        let duplicateElementsURL = duplicateStablePackage
            .appendingPathComponent("elements.json")
        guard var duplicateElementsPayload = try JSONSerialization.jsonObject(
                with: Data(contentsOf: duplicateElementsURL)) as? [String: Any],
              var duplicatePackageElements = duplicateElementsPayload["elements"]
                as? [[String: Any]],
              duplicatePackageElements.count >= 2,
              let firstDuplicateID = duplicatePackageElements[0]["id"] as? String,
              let secondDuplicateID = duplicatePackageElements[1]["id"] as? String
        else {
            require(false, "duplicate stable package fixture could not be built")
            return
        }
        let duplicateBusinessSource: [String: Any] = [
            "id": "duplicate-official-business-id",
        ]
        let duplicatePackageIDs = Set([firstDuplicateID, secondDuplicateID])
        for index in duplicatePackageElements.indices
        where duplicatePackageIDs.contains(
            duplicatePackageElements[index]["id"] as? String ?? "") {
            duplicatePackageElements[index]["source"] = duplicateBusinessSource
        }
        duplicateElementsPayload["elements"] = duplicatePackageElements
        try CanonicalJSONEncoder.encode(duplicateElementsPayload)
            .write(to: duplicateElementsURL)
        for (filename, key) in [
            ("shelves.json", "shelves"),
            ("fixed_structures.json", "structures"),
        ] {
            let url = duplicateStablePackage.appendingPathComponent(filename)
            guard var payload = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: url)) as? [String: Any],
                  var values = payload[key] as? [[String: Any]] else {
                require(false, "duplicate stable \(filename) fixture is invalid")
                return
            }
            for index in values.indices
            where duplicatePackageIDs.contains(values[index]["id"] as? String ?? "") {
                values[index]["source"] = duplicateBusinessSource
            }
            payload[key] = values
            try CanonicalJSONEncoder.encode(payload).write(to: url)
        }
        var duplicateCanonicalSource = report.canonicalSource
        for index in duplicateCanonicalSource.elements.indices
        where duplicatePackageIDs.contains(
            duplicateCanonicalSource.elements[index].id) {
            duplicateCanonicalSource.elements[index].source = duplicateBusinessSource
        }
        let duplicateCanonicalData = try CanonicalJSONEncoder.encode(
            duplicateCanonicalSource.canonicalPayload)
        let duplicateCanonicalSHA = CanonicalSourceHasher.sha256(
            duplicateCanonicalData)
        let duplicateManifestURL = duplicateStablePackage
            .appendingPathComponent("manifest.json")
        guard var duplicateManifest = try JSONSerialization.jsonObject(
                with: Data(contentsOf: duplicateManifestURL)) as? [String: Any]
        else {
            require(false, "duplicate stable manifest fixture is invalid")
            return
        }
        duplicateManifest["canonical_source_sha256"] = duplicateCanonicalSHA
        duplicateManifest["prior_map_id"] = MobilePriorMapCompiler.safeName(
            report.mapName) + "-" + String(duplicateCanonicalSHA.prefix(12))
        try CanonicalJSONEncoder.encode(duplicateManifest)
            .write(to: duplicateManifestURL)
        let duplicateReboundManifest = try MobilePackageManifestBuilder
            .buildManifest(directory: duplicateStablePackage)
        try CanonicalJSONEncoder.encode(duplicateReboundManifest).write(
            to: duplicateStablePackage.appendingPathComponent(
                MobilePackageManifestBuilder.manifestFileName))
        do {
            _ = try PriorMapPackageIntegrity.validate(
                directory: duplicateStablePackage)
            require(false,
                    "re-signed duplicate stable business IDs must be rejected")
        } catch {
            // Expected: hashes and canonical claim are current, but stable
            // business identity remains ambiguous.
        }

        let extraBoundsPackage = output.deletingLastPathComponent()
            .appendingPathComponent(
                ".mapcase02-extra-bounds-package-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.copyItem(at: output, to: extraBoundsPackage)
        defer { try? FileManager.default.removeItem(at: extraBoundsPackage) }
        let extraElementsURL = extraBoundsPackage
            .appendingPathComponent("elements.json")
        let extraStructuresURL = extraBoundsPackage
            .appendingPathComponent("fixed_structures.json")
        guard var extraElementsPayload = try JSONSerialization.jsonObject(
                with: Data(contentsOf: extraElementsURL)) as? [String: Any],
              var extraElements = extraElementsPayload["elements"]
                as? [[String: Any]],
              let extraElementIndex = extraElements.firstIndex(where: {
                  $0["role"] as? String
                    == PriorMapElementRole.fixedStructure.rawValue
              }),
              let extraElementID = extraElements[extraElementIndex]["id"]
                as? String,
              var extraBounds = extraElements[extraElementIndex]["bounds"]
                as? [String: Any],
              var extraStructuresPayload = try JSONSerialization.jsonObject(
                with: Data(contentsOf: extraStructuresURL)) as? [String: Any],
              var extraStructures = extraStructuresPayload["structures"]
                as? [[String: Any]],
              let extraStructureIndex = extraStructures.firstIndex(where: {
                  $0["id"] as? String == extraElementID
              }) else {
            require(false, "extra bounds fixture could not be built")
            return
        }
        extraBounds["unexpected"] = 0.0
        extraElements[extraElementIndex]["bounds"] = extraBounds
        extraStructures[extraStructureIndex]["bounds"] = extraBounds
        extraElementsPayload["elements"] = extraElements
        extraStructuresPayload["structures"] = extraStructures
        try CanonicalJSONEncoder.encode(extraElementsPayload)
            .write(to: extraElementsURL)
        try CanonicalJSONEncoder.encode(extraStructuresPayload)
            .write(to: extraStructuresURL)
        let extraBoundsRebound = try MobilePackageManifestBuilder
            .buildManifest(directory: extraBoundsPackage)
        try CanonicalJSONEncoder.encode(extraBoundsRebound).write(
            to: extraBoundsPackage.appendingPathComponent(
                MobilePackageManifestBuilder.manifestFileName))
        do {
            _ = try PriorMapPackageIntegrity.validate(
                directory: extraBoundsPackage)
            require(false, "re-signed extra v2 bounds keys must be rejected")
        } catch {
            // Expected: subset and package hashes are current, but formal
            // v2 bounds are an exact six-field contract.
        }

        // Rebind package hashes after a cross-file-consistent geometry-kind
        // mutation. The production validator must reject the semantic
        // contract itself, not merely notice a stale package hash.
        let invalidPackage = output.deletingLastPathComponent()
            .appendingPathComponent(
                ".mapcase02-invalid-package-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.copyItem(at: output, to: invalidPackage)
        defer { try? FileManager.default.removeItem(at: invalidPackage) }
        let invalidElementsURL = invalidPackage.appendingPathComponent(
            "elements.json")
        let invalidStructuresURL = invalidPackage.appendingPathComponent(
            "fixed_structures.json")
        guard var invalidElementsPayload = try JSONSerialization.jsonObject(
                with: Data(contentsOf: invalidElementsURL)) as? [String: Any],
              var packageElements = invalidElementsPayload["elements"]
                as? [[String: Any]],
              let packageElementIndex = packageElements.firstIndex(where: {
                  $0["role"] as? String == PriorMapElementRole.fixedStructure.rawValue
              }),
              let invalidElementID = packageElements[packageElementIndex]["id"]
                as? String,
              var packageGeometry = packageElements[packageElementIndex]["geometry"]
                as? [String: Any],
              var invalidStructuresPayload = try JSONSerialization.jsonObject(
                with: Data(contentsOf: invalidStructuresURL)) as? [String: Any],
              var packageStructures = invalidStructuresPayload["structures"]
                as? [[String: Any]],
              let packageStructureIndex = packageStructures.firstIndex(where: {
                  $0["id"] as? String == invalidElementID
              }) else {
            require(false, "MapCase02 invalid package fixture could not be built")
            return
        }
        packageGeometry["type"] = "line_string"
        packageElements[packageElementIndex]["geometry"] = packageGeometry
        packageStructures[packageStructureIndex]["geometry"] = packageGeometry
        invalidElementsPayload["elements"] = packageElements
        invalidStructuresPayload["structures"] = packageStructures
        try CanonicalJSONEncoder.encode(invalidElementsPayload)
            .write(to: invalidElementsURL)
        try CanonicalJSONEncoder.encode(invalidStructuresPayload)
            .write(to: invalidStructuresURL)
        let reboundManifest = try MobilePackageManifestBuilder.buildManifest(
            directory: invalidPackage)
        try CanonicalJSONEncoder.encode(reboundManifest).write(
            to: invalidPackage.appendingPathComponent(
                MobilePackageManifestBuilder.manifestFileName))
        do {
            _ = try PriorMapPackageIntegrity.validate(directory: invalidPackage)
            require(false, "v2 package wrong geometry kind must be rejected")
        } catch {
            // Expected: package hashes are current, relationship validation
            // rejects the role-specific geometry kind.
        }

        func requireReboundManifestRejection(
            _ label: String,
            mutate: (inout [String: Any]) -> Void
        ) throws {
            let package = output.deletingLastPathComponent()
                .appendingPathComponent(
                    ".mapcase02-\(label)-\(UUID().uuidString)",
                    isDirectory: true)
            try FileManager.default.copyItem(at: output, to: package)
            defer { try? FileManager.default.removeItem(at: package) }
            let manifestURL = package.appendingPathComponent("manifest.json")
            guard var payload = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: manifestURL)) as? [String: Any] else {
                require(false, "\(label) manifest fixture is invalid")
                return
            }
            mutate(&payload)
            try CanonicalJSONEncoder.encode(payload).write(to: manifestURL)
            let rebound = try MobilePackageManifestBuilder.buildManifest(
                directory: package)
            try CanonicalJSONEncoder.encode(rebound).write(
                to: package.appendingPathComponent(
                    MobilePackageManifestBuilder.manifestFileName))
            var rejected = false
            do {
                _ = try PriorMapPackageIntegrity.validate(directory: package)
            } catch {
                rejected = true
            }
            require(rejected, "\(label) must fail after package hashes are rebound")
        }
        try requireReboundManifestRejection("forged-map-identity") { payload in
            payload["prior_map_id"] = "forged"
            payload["canonical_source_sha256"] = String(repeating: "0", count: 64)
        }
        try requireReboundManifestRejection("forged-coordinate-contract") { payload in
            payload["source_coordinate_system"] = [
                "unit": "inch",
                "origin": "bottom_left",
                "x_axis": "left",
                "y_axis": "up",
                "rotation_direction": "clockwise_degrees",
                "rectangle_anchor": "top_left",
                "rotation_pivot": "top_left_anchor",
            ]
        }
        try requireReboundManifestRejection("missing-manifest-width") { payload in
            guard var bounds = payload["bounds"] as? [String: Any] else {
                require(false, "missing manifest width fixture has no bounds")
                return
            }
            bounds.removeValue(forKey: "width_m")
            payload["bounds"] = bounds
        }
        try requireReboundManifestRejection("tiny-manifest-width-drift") { payload in
            guard var bounds = payload["bounds"] as? [String: Any],
                  let width = StrictJSONScalar.number(bounds["width_m"]) else {
                require(false, "tiny manifest width drift fixture has no bounds")
                return
            }
            bounds["width_m"] = width + 5.0e-7
            payload["bounds"] = bounds
        }
        try requireReboundManifestRejection("missing-floor-height") { payload in
            guard var floors = payload["floors"] as? [[String: Any]],
                  !floors.isEmpty,
                  var bounds = floors[0]["bounds"] as? [String: Any] else {
                require(false, "missing floor height fixture has no bounds")
                return
            }
            bounds.removeValue(forKey: "height_m")
            floors[0]["bounds"] = bounds
            payload["floors"] = floors
        }
        try requireReboundManifestRejection("claimed-canonical-hash") { payload in
            let forged = String(repeating: "0", count: 64)
            payload["canonical_source_sha256"] = forged
            payload["prior_map_id"] = "piaseczno-" + String(forged.prefix(12))
        }
        try requireReboundManifestRejection(
            "manifest-element-count-integral-float"
        ) { payload in
            payload["element_count"] = 1_630.0
        }
        try requireReboundManifestRejection(
            "manifest-warning-count-integral-float"
        ) { payload in
            guard let warningCount = StrictJSONScalar.integer(
                    payload["warning_count"]) else {
                require(false, "manifest fixture missing warning_count")
                return
            }
            payload["warning_count"] = Double(warningCount)
        }
        try requireReboundManifestRejection(
            "manifest-hidden-count-boolean"
        ) { payload in
            payload["hidden_element_count"] = false
        }
        try requireReboundManifestRejection(
            "manifest-statistics-integral-float"
        ) { payload in
            guard var statistics = payload["element_statistics"]
                    as? [String: Any],
                  let key = statistics.keys.sorted().first,
                  let count = StrictJSONScalar.integer(statistics[key]) else {
                require(false, "manifest fixture missing element statistics")
                return
            }
            statistics[key] = Double(count)
            payload["element_statistics"] = statistics
        }

        func requireReboundArtifactRejection(
            _ label: String,
            artifactName: String,
            mutate: (inout [String: Any]) throws -> Void
        ) throws {
            let package = output.deletingLastPathComponent()
                .appendingPathComponent(
                    ".mapcase02-\(label)-\(UUID().uuidString)",
                    isDirectory: true)
            try FileManager.default.copyItem(at: output, to: package)
            defer { try? FileManager.default.removeItem(at: package) }
            let artifactURL = package.appendingPathComponent(artifactName)
            guard var payload = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: artifactURL)) as? [String: Any] else {
                require(false, "\(label) artifact fixture is invalid")
                return
            }
            try mutate(&payload)
            try CanonicalJSONEncoder.encode(payload).write(to: artifactURL)
            let rebound = try MobilePackageManifestBuilder.buildManifest(
                directory: package)
            try CanonicalJSONEncoder.encode(rebound).write(
                to: package.appendingPathComponent(
                    MobilePackageManifestBuilder.manifestFileName))
            var rejected = false
            do {
                _ = try PriorMapPackageIntegrity.validate(directory: package)
            } catch {
                rejected = true
            }
            require(rejected, "\(label) must fail after package hashes are rebound")
        }

        try requireReboundArtifactRejection(
            "validation-node-count-integral-float",
            artifactName: "validation_report.json"
        ) { payload in
            guard var summary = payload["summary"] as? [String: Any] else {
                require(false, "validation report fixture missing summary")
                return
            }
            summary["node_count"] = 0.0
            payload["summary"] = summary
        }
        try requireReboundArtifactRejection(
            "validation-malformed-count-boolean",
            artifactName: "validation_report.json"
        ) { payload in
            guard var summary = payload["summary"] as? [String: Any] else {
                require(false, "validation report fixture missing summary")
                return
            }
            summary["malformed_row_count"] = false
            payload["summary"] = summary
        }
        try requireReboundArtifactRejection(
            "validation-warnings-not-array",
            artifactName: "validation_report.json"
        ) { payload in
            payload["warnings"] = ["invalid": true]
        }

        try requireReboundArtifactRejection(
            "shifted-shelf-segment",
            artifactName: "shelves.json"
        ) { payload in
            guard var segments = payload["shelf_segments"]
                    as? [[String: Any]],
                  !segments.isEmpty,
                  var start = segments[0]["longitudinal_start_m"] as? [Double],
                  var end = segments[0]["longitudinal_end_m"] as? [Double] else {
                require(false, "shifted shelf fixture missing segment")
                return
            }
            start[0] += 1
            end[0] += 1
            segments[0]["longitudinal_start_m"] = start
            segments[0]["longitudinal_end_m"] = end
            payload["shelf_segments"] = segments
        }
        try requireReboundArtifactRejection(
            "wrong-spatial-cell",
            artifactName: "spatial_index.json"
        ) { payload in
            guard var floors = payload["floors"] as? [String: Any],
                  let floorID = floors.keys.sorted().first,
                  var floor = floors[floorID] as? [String: Any],
                  let cells = floor["cells"] as? [String: Any] else {
                require(false, "spatial fixture missing floor cells")
                return
            }
            let identifiers = Set(cells.values.flatMap {
                ($0 as? [String]) ?? []
            }).sorted()
            floor["cells"] = ["999,999": identifiers]
            floors[floorID] = floor
            payload["floors"] = floors
        }
        try requireReboundArtifactRejection(
            "forged-road-graph",
            artifactName: "road_graph.json"
        ) { payload in
            payload["nodes"] = [[
                "id": "forged-node",
                "element_id": "forged-element",
                "floor_id": "1",
                "position_m": [0.0, 0.0],
                "cross_ids": [String](),
                "visible": true,
            ]]
        }
        try requireReboundArtifactRejection(
            "integral-float-distance-token",
            artifactName: "distance_fields.json"
        ) { payload in
            guard var floors = payload["floors"] as? [String: Any],
                  let floorID = floors.keys.sorted().first,
                  var floor = floors[floorID] as? [String: Any],
                  var levels = floor["levels"] as? [[String: Any]],
                  let width = StrictJSONScalar.integer(levels[0]["width"]) else {
                require(false, "distance token fixture missing level")
                return
            }
            levels[0]["width"] = Double(width)
            floor["levels"] = levels
            floors[floorID] = floor
            payload["floors"] = floors
        }
        try requireReboundArtifactRejection(
            "all-zero-distance-field",
            artifactName: "distance_fields.json"
        ) { payload in
            guard var floors = payload["floors"] as? [String: Any] else {
                require(false, "distance fixture missing floors")
                return
            }
            for floorID in floors.keys.sorted() {
                guard var floor = floors[floorID] as? [String: Any],
                      var levels = floor["levels"] as? [[String: Any]] else {
                    require(false, "distance fixture missing levels")
                    return
                }
                for index in levels.indices {
                    guard let width = StrictJSONScalar.integer(
                            levels[index]["width"]),
                          let height = StrictJSONScalar.integer(
                            levels[index]["height"]) else {
                        require(false, "distance fixture dimensions invalid")
                        return
                    }
                    let rows = [[Int]](
                        repeating: [width, 0], count: height)
                    levels[index]["rows"] = rows
                    levels[index]["data_sha256"] = CanonicalSourceHasher.sha256(
                        try CanonicalJSONEncoder.encode(rows))
                }
                floor["levels"] = levels
                floors[floorID] = floor
            }
            payload["floors"] = floors
        }

        let strictIntegerTokens = try JSONSerialization.jsonObject(
            with: Data("{\"integer\":2,\"float\":2.0,\"exponent\":2e0}".utf8))
            as? [String: Any]
        require(
            StrictJSONScalar.integer(strictIntegerTokens?["integer"]) == 2
                && StrictJSONScalar.integer(strictIntegerTokens?["float"]) == nil
                && StrictJSONScalar.integer(strictIntegerTokens?["exponent"]) == nil,
            "integral floating JSON tokens must not pass as strict integers")

        if let legacyWorkbookPath = legacyWorkbookPath {
            do {
                let legacy = URL(fileURLWithPath: legacyWorkbookPath)
                _ = try MapSourceImportCoordinator.importMap(
                    stagedURL: legacy,
                    originalFilename: legacy.lastPathComponent,
                    contract: .topLeft,
                    storeId: "legacy",
                    strict: true)
                require(false, "MapCase01 formal import must reject missing Basic Info")
            } catch let error as MapSourceImportError {
                require(error.stableCode == "map_source_xlsx_sheet_not_found",
                        "MapCase01 missing Basic Info returned \(error.stableCode): "
                            + error.localizedDescription)
            }
        }

        // Regression for the real-device failure: formal XLSX compilation
        // used to preserve uppercase map-name bytes while MobileMapLibrary
        // accepts only canonical lowercase path identifiers. Exercise the
        // same compile -> content-addressed move -> register -> list -> read
        // chain as MobileOnlyWorkflowCoordinator.
        let previousMapRoot = MobileMapLibrary.rootOverride
        let libraryTemporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mapcase02-library-\(UUID().uuidString)", isDirectory: true)
        MobileMapLibrary.rootOverride = libraryTemporary
        defer {
            restoreMutablePermissions(libraryTemporary)
            try? FileManager.default.removeItem(at: libraryTemporary)
            MobileMapLibrary.rootOverride = previousMapRoot
        }
        let installStaging = try MobileMapLibrary.stagingDirectory(
            for: "mapcase02-install")
        try FileManager.default.removeItem(at: installStaging)
        try FileManager.default.copyItem(at: output, to: installStaging)
        let installTarget = try MobileMapLibrary.packageDirectory(
            priorMapID: compiled.priorMapID,
            packageSHA: compiled.packageSHA256)
        try FileManager.default.createDirectory(
            at: installTarget.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: installStaging, to: installTarget)
        let installed = try MobileMapLibrary.register(
            priorMapID: compiled.priorMapID,
            name: report.mapName,
            packageSHA256: compiled.packageSHA256,
            packageURL: installTarget,
            floorCount: compiled.floorCount,
            elementCount: compiled.elementCount,
            compilerVersion: "swift-v1",
            canonicalSourceSHA256: report.canonicalSourceSha256)
        let listed = try MobileMapLibrary.listMaps()
        require(
            listed.count == 1 && listed[0].priorMapID == compiled.priorMapID
                && listed[0].packageSHA256 == compiled.packageSHA256,
            "MapCase02 installed package must round-trip through registry listing")
        let loaded = try MobileMapLibrary.map(
            priorMapID: installed.priorMapID,
            packageSHA256: installed.packageSHA256)
        require(
            loaded.priorMapID == installed.priorMapID
                && loaded.packageSHA256 == installed.packageSHA256
                && loaded.packageDirectory == installed.packageDirectory
                && loaded.canonicalSourceSHA256
                    == installed.canonicalSourceSHA256,
            "MapCase02 installed package must load by exact ID/SHA authority")
        print("MapCase02 suite passed canonical=\(report.canonicalSourceSha256) package=\(packageSHA)")
    } catch {
        FileHandle.standardError.write(
            Data("MapCase02 suite failed: \(error)\n".utf8))
        exit(12)
    }
}

/// Local real-workbook regression: every supplied formal XLSX must traverse
/// the production import/compiler/integrity/library chain and remain readable
/// by exact ID/SHA. This intentionally accepts paths at runtime so ignored
/// customer fixtures never become repository or CI dependencies.
private func runXLSXLibrarySmoke(workbookPaths: [String]) {
    let previousMapRoot = MobileMapLibrary.rootOverride
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "xlsx-library-smoke-\(UUID().uuidString)", isDirectory: true)
    MobileMapLibrary.rootOverride = temporary.appendingPathComponent(
        "Maps", isDirectory: true)
    defer {
        restoreMutablePermissions(temporary)
        try? FileManager.default.removeItem(at: temporary)
        MobileMapLibrary.rootOverride = previousMapRoot
    }

    do {
        var expectedIdentities: Set<String> = []
        for (index, workbookPath) in workbookPaths.enumerated() {
            let workbook = URL(fileURLWithPath: workbookPath)
            let report = try MapSourceImportCoordinator.importMap(
                stagedURL: workbook,
                originalFilename: workbook.lastPathComponent,
                contract: .topLeft,
                strict: true)
            let staging = try MobileMapLibrary.stagingDirectory(
                for: "xlsx-smoke-\(index)")
            let compiled = try MobilePriorMapCompiler.compile(
                canonicalSource: report.canonicalSource,
                outputDirectory: staging)
            require(
                MobileMapLibrary.isSafeIdentifier(compiled.priorMapID),
                "XLSX smoke emitted an unsafe ID for \(workbook.lastPathComponent)")
            require(
                compiled.priorMapID.hasPrefix(
                    MobilePriorMapCompiler.safeName(report.mapName) + "-"),
                "XLSX smoke ID slug mismatch for \(workbook.lastPathComponent)")
            let validatedSHA = try PriorMapPackageIntegrity.validate(
                directory: staging)
            require(
                validatedSHA == compiled.packageSHA256,
                "XLSX smoke integrity mismatch for \(workbook.lastPathComponent)")
            let target = try MobileMapLibrary.packageDirectory(
                priorMapID: compiled.priorMapID,
                packageSHA: compiled.packageSHA256)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: staging, to: target)
            let installed = try MobileMapLibrary.register(
                priorMapID: compiled.priorMapID,
                name: report.mapName,
                packageSHA256: compiled.packageSHA256,
                packageURL: target,
                floorCount: compiled.floorCount,
                elementCount: compiled.elementCount,
                compilerVersion: "swift-v1",
                canonicalSourceSHA256: report.canonicalSourceSha256)
            let loaded = try MobileMapLibrary.map(
                priorMapID: installed.priorMapID,
                packageSHA256: installed.packageSHA256)
            require(
                loaded.priorMapID == installed.priorMapID
                    && loaded.packageSHA256 == installed.packageSHA256,
                "XLSX smoke exact read failed for \(workbook.lastPathComponent)")
            expectedIdentities.insert(installed.relativePackagePath)
            print(
                "XLSX library smoke file=\(workbook.lastPathComponent) "
                    + "name=\(report.mapName) store=\(report.storeId) "
                    + "elements=\(compiled.elementCount) "
                    + "prior_map_id=\(compiled.priorMapID) "
                    + "package_sha256=\(compiled.packageSHA256)")
        }
        let listed = try MobileMapLibrary.listMaps()
        require(
            Set(listed.map(\.relativePackagePath)) == expectedIdentities,
            "XLSX smoke registry inventory mismatch")
        print("XLSX library smoke passed count=\(workbookPaths.count)")
    } catch {
        FileHandle.standardError.write(
            Data("XLSX library smoke failed: \(error)\n".utf8))
        exit(14)
    }
}

// V1R4 §14.2: registered packages are frozen immutable (555/444);
// restore write bits below a temporary directory so the suite can remove
// it after the run.
private func restoreMutablePermissions(_ root: URL) {
    if let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            _ = chmod(url.path, (values?.isDirectory ?? false) ? 0o755 : 0o644)
        }
    }
    _ = chmod(root.path, 0o755)
}

// Mobile-Only V1: --xlsx-scale exports a 100k-row DevicePositions
// workbook to the given directory. It runs as its own process so the
// default host mode stays inside the frozen peak-RSS gate.
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--xlsx-scale" {
    do {
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
            .appendingPathComponent("result-100k.xlsx")
        try MobileResultExporter.export(
            input: makeInput(positions: makePositions(100_000)), to: output)
        let bytes = (try FileManager.default.attributesOfItem(
            atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else {
            FileHandle.standardError.write(
                Data("xlsx-scale produced an empty file\n".utf8))
            exit(7)
        }
        print("xlsx-scale workbook bytes: \(bytes)")
    }
    catch {
        FileHandle.standardError.write(
            Data("xlsx-scale failed: \(error)\n".utf8))
        exit(7)
    }
}

// === Mobile-Only V1R1: Replay E2E (raw map source -> phone compile ->
// finalized session -> snapshot -> Fast Path -> trajectory -> tags ->
// result package -> streaming XLSX -> reopen validation) ===
// Runs through the production importer/compiler/pipeline only; no direct
// construction of FinalTrajectory.Node or FinalPriceTag (V1R1 §15).
// Worker modes below launch this executable repeatedly to exercise crash
// recovery. They must not rerun the complete E2E suite before reaching their
// requested worker entry: doing so multiplies runtime and lets unrelated
// periodic-timer assertions make a crash-worker invocation flaky.
if CommandLine.arguments.count <= 1 {
do {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("ms-replay-e2e-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporary, withIntermediateDirectories: true)
    defer {
        restoreMutablePermissions(temporary)
        try? FileManager.default.removeItem(at: temporary)
    }

    // 1) Raw map source (CSV) -> production importer -> canonical v2.
    let csv = """
    floor,element
    1,"{""shapeType"":""MapShelf"",""x"":100,""y"":100,""width"":300,""height"":80,""code"":""S1""}"
    1,"{""shapeType"":""MapTable"",""x"":500,""y"":100,""width"":200,""height"":100,""code"":""T1""}"
    1,"{""shapeType"":""MapRoadPoint"",""x"":10,""y"":10,""code"":""P1""}"
    """
    let mapRoot = temporary.appendingPathComponent("Maps")
    MobileMapLibrary.rootOverride = mapRoot
    let stagedMap = try writeTemporary(Data(csv.utf8), named: "e2e-map.csv")
    let report = try MapSourceImportCoordinator.importMap(
        stagedURL: stagedMap,
        originalFilename: "e2e-map.csv",
        contract: .topLeft,
        storeId: "s1")
    require(report.elementCount == 3, "E2E import must yield 3 elements, got \(report.elementCount)")
    require(!report.canonicalSourceSha256.isEmpty, "E2E canonical SHA must be non-empty")
    require(report.audit != nil, "E2E import must carry a v2 audit record")
    require(report.audit!.sourceRows.count == 3, "E2E audit must keep source rows")

    // 2) Production compiler -> durable map library registration.
    let compileDir = try MobileMapLibrary.stagingDirectory(for: "e2e-compile")
    let compileResult = try MobilePriorMapCompiler.compile(
        canonicalSource: report.canonicalSource,
        outputDirectory: compileDir)
    let target = try MobileMapLibrary.packageDirectory(
        priorMapID: compileResult.priorMapID,
        packageSHA: compileResult.packageSHA256)
    try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: compileDir, to: target)
    _ = try MobileMapLibrary.register(
        priorMapID: compileResult.priorMapID,
        name: report.mapName,
        packageSHA256: compileResult.packageSHA256,
        packageURL: target,
        floorCount: compileResult.floorCount,
        elementCount: compileResult.elementCount,
        compilerVersion: "swift-v1",
        canonicalSourceSHA256: report.canonicalSourceSha256)
    let maps = try MobileMapLibrary.listMaps()
    if maps.isEmpty {
        let registryURL = try MobileMapLibrary.registryURL()
        print("E2E debug: registry=\(registryURL.path)")
        if let raw = try? String(contentsOf: registryURL, encoding: .utf8) {
            print("E2E debug: registry content=\(raw.prefix(600))")
        }
        let packages = try FileManager.default.contentsOfDirectory(
            atPath: MobileMapLibrary.packagesRoot().path)
        print("E2E debug: packages=\(packages)")
    }
    require(maps.count == 1, "E2E map library must list 1 map, got \(maps.count)")
    require(
        maps[0].packageSHA256 == compileResult.packageSHA256,
        "E2E registry must bind the package SHA")

    // 3) Finalized real-style session fixture (sidecars + source DB).
    let session = temporary.appendingPathComponent("session", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let now = Date().timeIntervalSince1970
    let metadata: [String: Any] = [
        "format": "MarketScannerFinalizedSessionMetadata",
        "version": 1,
        "formatVersion": 2,
        "finalized": true,
        "scanMode": "continuous_streaming",
        "workflowMode": "prior_map_localized",
        "finalizedAtUnix": now + 30.0,
        "floorId": "1",
        "trackingSessionId": "E2E-SESSION",
        "storeId": "s1",
        "priorMapId": maps[0].priorMapID,
        "priorMapSha256": maps[0].packageSHA256,
        "processingEligibility": [
            "status": "eligible",
            "blockers": [],
        ],
        "captureHealth": [
            "localizationRequiredWriteFailureCount": 0,
            "localizationTraceRecordCount": 6,
            "localizationConstraintRecordCount": 6,
            "manualLocalizationEventCount": 0,
            "localizationStateEventCount": 1,
            "localizationEvidenceComplete": true,
            "localizationRecoveryEventCount": 0,
            "localizationRecoveryEvidenceComplete": true,
        ],
        "localizationTrace": "localization_trace.jsonl",
        "manualLocalizationEvents": "manual_localization_events.jsonl",
        "localizationConstraints": "localization_constraints.jsonl",
        "localizationEvents": "localization_events.jsonl",
        "localizationRecoveryEvents": "localization_recovery_events.jsonl",
        "tagObservations": "tag_observations.jsonl",
        "localizedPriceTags": "localized_price_tags.json",
        "localizedPriceTagCount": 0,
        // V1R4 §7.2 watermark: exact counts of the sidecar below.
        "clockCorrelationCount": 6,
        "clockNodeBindingCount": 6,
        "clockLastMonotonic": 50150.0,
        "clockLastUTC": now + 150.0,
        "clockEvidenceComplete": true,
        "tagObservationBurstCount": 0,
        "tagObservationBurstComplete": true,
    ]
    let metadataData = try CanonicalJSONEncoder.encode(metadata)
    try metadataData.write(to: session.appendingPathComponent("metadata.json"))
    var traces = ""
    for index in 0..<6 {
        let traceTimestamp = 100.0 + Double(index + 1) * 0.5
        let record: [String: Any] = [
            "format": "MarketScannerLocalizationTrace",
            "version": 1,
            "timestamp": traceTimestamp,
            "estimatedPose": [
                "x_m": Double(index) * 1.0, "y_m": 0.0, "yaw_rad": 0.0,
            ],
            "rawPose": [
                "x_m": Double(index) * 1.0, "y_m": 0.0, "yaw_rad": 0.0,
            ],
            "localizationState": "stable",
            "trackingState": "normal",
            "floorId": "1",
            "trackingSessionId": "E2E-SESSION",
            "priorMapId": maps[0].priorMapID,
            "priorMapSha256": maps[0].packageSHA256,
            "nodeTimebaseOffsetSeconds": now - 100.0,
            "nodeTimebaseTimestamp": traceTimestamp + (now - 100.0),
            "confidence": 1.0,
            "roadCandidates": [],
            "structureSource": "smoothed_scene_depth",
            "structurePointCount": 80,
            "structureCoverageAngleRad": 2.8,
            "matchCandidates": [],
            "matchUniqueness": 0.9,
            "matchResidualCost": 0.05,
            "matcherElapsedMs": 4.0,
            "constraintAccepted": true,
            "constraintReason": "E2E accepted matcher result",
            "measurementAccepted": true,
            "hypothesisTrusted": true,
            "correctionStepApplied": true,
            "recoveryConvergedThisUpdate": false,
            "confidenceAccepted": true,
            "constraintDisposition": "accepted_local",
            "postRecoveryTrustedLocalFrames": 3,
            "scanSearchPerformed": true,
            "hypothesisSupportFrames": 3,
            "hypothesisScoreMargin": 0.4,
            "recoverySearch": false,
            "correctionTranslationM": 0.0,
            "correctionYawDeg": 0.0,
            "activeHypothesisTrackCount": 1,
            "hypothesisReason": "trusted_hypothesis",
            "hypothesisTrackerElapsedMs": 1.0,
            "recoveryCooldownRemainingMs": 0.0,
            "recoveryAutomaticTriggerSuppressed": false,
        ]
        let recordData = try CanonicalJSONEncoder.encode(record)
        traces += String(data: recordData, encoding: .utf8)! + "\n"
    }
    try traces.data(using: .utf8)!.write(
        to: session.appendingPathComponent("localization_trace.jsonl"))
    for name in ["localization_events.jsonl",
                 "manual_localization_events.jsonl", "tag_observations.jsonl",
                 "localization_recovery_events.jsonl"] {
        try Data().write(to: session.appendingPathComponent(name))
    }
    // Accepted prior-map absolute constraints (§6.2): the E2E must carry
    // identity-bound evidence, otherwise the quality gate is allowed to
    // return LOCAL_FRAME_ONLY only. Records use the REAL write-side
    // schema (PriorMapConstraintRecord: camelCase, nodeTimebaseTimestamp
    // binding, uniqueness-derived sigma; no nodeId/mapPose/sigma fields).
    var constraints = ""
    for index in 0..<6 {
        let record: [String: Any] = [
            "format": "MarketScannerLocalizationConstraint",
            "version": 1,
            "timestamp": 100.0 + Double(index + 1) * 0.5,
            "nodeTimebaseTimestamp": now + Double(index + 1) * 0.5,
            "nodeTimebaseOffsetSeconds": now - 100.0,
            "trackingSessionId": "E2E-SESSION",
            "priorMapId": maps[0].priorMapID,
            "priorMapSha256": maps[0].packageSHA256,
            "floorId": "1",
            "accepted": true,
            "measurementAccepted": true,
            "correctionStepApplied": true,
            "confidenceAccepted": true,
            "disposition": "accepted_local",
            "reason": "E2E accepted matcher result",
            "predictedPose": [
                "x_m": Double(index) * 1.0, "y_m": 0.0, "yaw_rad": 0.0,
            ],
            "estimatedPose": [
                "x_m": Double(index) * 1.0, "y_m": 0.0, "yaw_rad": 0.0,
            ],
            "candidates": [],
            "uniqueness": 0.9,
            "residualCost": 0.05,
            "effectivePointCount": 60,
            "coverageAngleRad": 2.8,
            "matcherElapsedMs": 4.0,
        ]
        let recordData = try CanonicalJSONEncoder.encode(record)
        constraints += String(data: recordData, encoding: .utf8)! + "\n"
    }
    try constraints.data(using: .utf8)!.write(
        to: session.appendingPathComponent("localization_constraints.jsonl"))
    // Clock correlation sidecar (§7.1, schema v2): recorder-style
    // correlation records on the DEVICE-UPTIME axis (1:1 with UTC) plus
    // node-timebase bindings that freeze the RTAB-Map node-stamp axis.
    // The pipeline must map node stamps through the bindings; a
    // regression that mixes the uptime axis in or assumes stamps are UTC
    // would degrade every resampled position to UNAVAILABLE (V1R4 §7.3
    // regression test).
    var clock = ""
    for index in 0..<6 {
        let record: [String: Any] = [
            "format": "MarketScannerClockCorrelation",
            "version": 2,
            "record_kind": "correlation",
            "tracking_session_id": "E2E-SESSION",
            "monotonic_seconds": 50000.0 + Double(index) * 30.0,
            "utc_unix_seconds": now + Double(index) * 30.0,
            "timezone_id": "UTC",
            "utc_offset_seconds": 0,
            "reason": index == 0 ? "session_start"
                : (index == 5 ? "session_end" : "periodic"),
        ]
        let recordData = try CanonicalJSONEncoder.encode(record)
        clock += String(data: recordData, encoding: .utf8)! + "\n"
        let binding: [String: Any] = [
            "format": "MarketScannerClockCorrelation",
            "version": 2,
            "record_kind": "node_binding",
            "tracking_session_id": "E2E-SESSION",
            "node_id": index + 1,
            "node_stamp": now + Double(index + 1) * 0.5,
            "sampled_frame_timestamp": now + Double(index + 1) * 0.5,
            "system_uptime": 50000.0 + Double(index + 1) * 0.5,
            "utc_unix_seconds": now + Double(index + 1) * 0.5,
            "timezone_id": "UTC",
            "utc_offset_seconds": 0,
            "reason": "node_bound",
        ]
        let bindingData = try CanonicalJSONEncoder.encode(binding)
        clock += String(data: bindingData, encoding: .utf8)! + "\n"
    }
    try clock.data(using: .utf8)!.write(
        to: session.appendingPathComponent("clock_correlations.jsonl"))
    try Data("[]".utf8).write(
        to: session.appendingPathComponent("localized_price_tags.json"))
    try Data().write(
        to: session.appendingPathComponent("tag_observation_bursts.jsonl"))
    let scanEventTimestampFormatter = ISO8601DateFormatter()
    scanEventTimestampFormatter.formatOptions = [
        .withInternetDateTime,
        .withFractionalSeconds,
    ]
    let scanEventTimestamp = scanEventTimestampFormatter.string(
        from: Date(timeIntervalSince1970: now))
    var scanEvent = try CanonicalJSONEncoder.encode([
        "format": "SupermarketScanEvent",
        "version": 1,
        "timestamp": scanEventTimestamp,
        "timestampUnix": now,
        "level": "info",
        "event": "scan_started",
        "message": "fixture scan started",
        "trackingSessionId": "E2E-SESSION",
        "fields": [String: String](),
    ])
    scanEvent.append(0x0A)
    try scanEvent.write(
        to: session.appendingPathComponent("scan_events.jsonl"))
    // Minimal REAL SQLite source DB: the V1R3 snapshot validates the DB
    // (quick_check + Node/Link inventory), so a fake byte blob is no
    // longer accepted.
    do {
        let dbURL = session.appendingPathComponent("rtabmap_segment_0001.db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            dbURL.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
            let database = db else {
            fatalError("E2E cannot create fixture sqlite DB")
        }
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE Node (id INTEGER PRIMARY KEY, map_id INTEGER, weight INTEGER, stamp REAL, pose BLOB);
        CREATE TABLE Link (from_id INTEGER, to_id INTEGER, type INTEGER, transform BLOB, information_matrix BLOB);
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            fatalError("E2E cannot create fixture sqlite schema")
        }
        // Identity transform pose (12 floats) + 6x6 information (36
        // doubles) matching the exact-BLOB contract (§10.1).
        func poseBlob() -> Data {
            var values: [Float] = [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0]
            return Data(bytes: &values, count: 12 * MemoryLayout<Float>.size)
        }
        func infoBlob() -> Data {
            var values = [Double](repeating: 0, count: 36)
            values[0] = 10; values[7] = 10; values[35] = 10
            return Data(bytes: &values, count: 36 * MemoryLayout<Double>.size)
        }
        for index in 1...6 {
            var insert: OpaquePointer?
            sqlite3_prepare_v2(
                database, "INSERT INTO Node VALUES (?,?,?,?,?)", -1, &insert, nil)
            if let stmt = insert {
                sqlite3_bind_int64(stmt, 1, Int64(index))
                sqlite3_bind_int(stmt, 2, 0)
                sqlite3_bind_int(stmt, 3, 1)
                sqlite3_bind_double(stmt, 4, now + Double(index) * 0.5)
                let pose = poseBlob()
                let sqliteTransient = unsafeBitCast(
                    -1, to: sqlite3_destructor_type.self)
                sqlite3_bind_blob(stmt, 5, (pose as NSData).bytes, Int32(pose.count), sqliteTransient)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    // 4) Production pipeline: snapshot -> Fast Path -> trajectory -> tags
    //    -> result package -> streaming XLSX -> external manifest.
    // V1R2: the host suite wires the deterministic reference
    // implementation of the factor-graph gateway; the real app wires the
    // shared native core (`MobileNativeFactorGraph.wireIntoGateway()`).
    func referenceImplementation(
        path: String
    ) -> MobileNativeFactorGraphGateway.RunImplementation {
        return { request, _ in
        let snapshotDirectory = request.databaseURL.deletingLastPathComponent()
        let traceURL = snapshotDirectory.appendingPathComponent("localization_trace.jsonl")
        var rows: [MobileNativeTrajectoryRow] = []
        if let content = try? String(contentsOf: traceURL, encoding: .utf8) {
            var id: Int64 = 0
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestamp = object["timestamp"] as? Double,
                      let pose = object["estimatedPose"] as? [String: Any]
                else { continue }
                id += 1
                // Real DB node stamps are UTC seconds; the reference
                // implementation must emit the same axis (trace monotonic
                // timestamp + node-timebase offset), otherwise the 1 Hz
                // resample range is inconsistent with finalizedAtUnix.
                let offset = object["nodeTimebaseOffsetSeconds"] as? Double ?? 0
                rows.append(MobileNativeTrajectoryRow(
                    id: id,
                    stamp: timestamp + offset,
                    xM: pose["x_m"] as? Double ?? 0,
                    yM: pose["y_m"] as? Double ?? 0,
                    yawRad: pose["yaw_rad"] as? Double ?? 0,
                    mapID: 0,
                    componentID: 0,
                    publishEligible: true,
                    uncertaintyM: 0.05))
            }
        }
        guard !rows.isEmpty else {
            throw MobileNativeFactorGraphError.nativeFailed("reference graph is empty")
        }
        let disposition: MobileGraphDisposition = request.absolutePriors.isEmpty
            ? .localFrameOnly : .pass
        return MobileNativeGraphOutcome(
            disposition: disposition,
            qualityJSON: try nativeQualityFixture(
                request: request,
                path: path,
                disposition: disposition,
                trajectoryCount: rows.count,
                skeletonCount: rows.count,
                publishCount: rows.count),
            trajectory: rows,
            skeletonIDs: rows.map { $0.id })
        }
    }
    MobileNativeFactorGraphGateway.runFastImplementation = referenceImplementation(
        path: "fast")
    MobileNativeFactorGraphGateway.runFullGraphImplementation = referenceImplementation(
        path: "full_graph_optimization")

    // Strict absolute-prior parsing (§6.1) needs the snapshot-DB node
    // inventory; the host suite reads the fixture Node table directly
    // (the real app wires MobileGraphReader in wireIntoGateway()).
    MobileProcessingPipeline.absolutePriorNodeInventoryProvider = { dbURL in
        var inventory: [AbsolutePriorEvidenceNode] = []
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let database = db else { return [] }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "SELECT id, stamp FROM Node ORDER BY id",
            -1, &statement, nil) == SQLITE_OK,
            let stmt = statement else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            inventory.append(AbsolutePriorEvidenceNode(
                nodeID: sqlite3_column_int64(stmt, 0),
                stamp: sqlite3_column_double(stmt, 1)))
        }
        return inventory
    }

    MobileProcessingTaskStore.rootOverride = temporary.appendingPathComponent("Tasks")
    MobileResultLibrary.rootOverride = temporary.appendingPathComponent("Results")
    let taskRoot = try MobileProcessingTaskStore.createTask(taskID: "e2e-task")
    let outcome = try MobileProcessingPipeline.run(
        request: MobileProcessingPipeline.Request(
            finalizedSession: session,
            sourceDatabase: session.appendingPathComponent("rtabmap_segment_0001.db"),
            taskRoot: taskRoot,
            priorMap: maps[0],
            storeID: "s1",
            floorID: "1",
            trackingSessionID: "E2E-SESSION",
            appGitSHA: "e2e",
            appVersion: "1.0",
            deviceModel: "host",
            osVersion: "macos",
            nativeCoreSHA256: "",
            policySHA: "host-policy-v1"),
        progress: { _, _ in },
        isCancelled: { false })
    require(
        outcome.devicePositionCount > 0,
        "E2E must emit device positions, got \(outcome.devicePositionCount)")
    // With the clock sidecar present the resampled positions must still
    // be AVAILABLE (guards the monotonic/uptime axis regression).
    require(
        outcome.availablePositionCount > 0,
        "E2E must emit AVAILABLE positions even with a clock sidecar, "
        + "got \(outcome.availablePositionCount)/\(outcome.devicePositionCount)")
    require(
        !outcome.resultEntry.workbookSHA256.isEmpty,
        "E2E workbook SHA must be recorded externally")

    // 5) Reopen validation: the exported workbook must re-read through
    //    the production ZIP reader with the required parts.
    let workbookData = try Data(contentsOf: outcome.resultEntry.workbookURL)
    let entries = try XLSXZipReader.readEntries(data: workbookData)
    let names = Set(entries.map { $0.name })
    require(
        names.contains("xl/workbook.xml"),
        "E2E workbook must contain xl/workbook.xml")
    require(
        names.contains("xl/worksheets/sheet1.xml"),
        "E2E workbook must contain xl/worksheets/sheet1.xml")

    // 6) Result library lists the committed immutable result.
    let results = MobileResultLibrary.listResults()
    require(results.count == 1, "E2E result library must list 1 result, got \(results.count)")
    require(
        results[0].workbookSHA256 == outcome.resultEntry.workbookSHA256,
        "E2E result SHA must persist in the library")

    // V1R4 §16.3 manifest strictness: the reader re-validates exact
    // bytes and the top-level field whitelist; a tampered result is
    // isolated with a typed diagnostic, never silently listed.
    let tamperStaging = try MobileResultLibrary.stagingDirectory(
        taskID: "tamper-task", resultID: "result-tamper")
    try Data("{}".utf8).write(to: tamperStaging.appendingPathComponent("a.json"))
    try Data("{}".utf8).write(to: tamperStaging.appendingPathComponent("b.json"))
    let tamperName = "result-tamper.xlsx"
    try Data("x".utf8).write(to: tamperStaging.appendingPathComponent(tamperName))
    _ = try MobileResultLibrary.commit(
        resultID: "result-tamper",
        taskID: "tamper-task",
        stagingDirectory: tamperStaging,
        packageFiles: ["a.json", "b.json"],
        workbookFilename: tamperName,
        manifestExtras: [:])
    let tamperDirectory = try MobileResultLibrary.resultDirectory(resultID: "result-tamper")
    // V1R5 §13.1 (review H-02): a committed result is IMMUTABLE — every
    // file is 0444 and the directory tree is 0555.
    let tamperA = tamperDirectory.appendingPathComponent("a.json")
    let immutableAttributes = try FileManager.default
        .attributesOfItem(atPath: tamperA.path)
    require(
        (immutableAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o444,
        "X-strict committed result files must be read-only 0444")
    do {
        try Data("{}drift".utf8).write(to: tamperA)
        require(false, "X-strict committed result must reject writes")
    } catch {
        // Expected: the immutable package refuses mutation.
    }
    // A hostile writer with owner permissions can still chmod; the read
    // path must then isolate the tampered artifact (exact bytes).
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: tamperA.path)
    // Exact bytes: appending to an artifact must fail the read.
    try Data("{}drift".utf8).write(to: tamperA)
    do {
        _ = try MobileResultLibrary.readResult(resultID: "result-tamper")
        require(false, "X-strict exact byte drift must be rejected")
    } catch let error as MobileResultLibrary.ResultError {
        if case .artifactCorrupt = error {} else {
            require(false, "X-strict byte drift must be artifactCorrupt, got \(error)")
        }
    }
    // Restore the artifact, then add an unknown top-level field.
    try Data("{}".utf8).write(to: tamperA)
    let tamperManifestURL = tamperDirectory
        .appendingPathComponent(MobileResultLibrary.manifestFileName)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: tamperManifestURL.path)
    var tampered = try JSONSerialization.jsonObject(
        with: Data(contentsOf: tamperManifestURL)) as! [String: Any]
    tampered["sneaky_extension"] = 1
    try JSONSerialization.data(withJSONObject: tampered)
        .write(to: tamperManifestURL)
    do {
        _ = try MobileResultLibrary.readResult(resultID: "result-tamper")
        require(false, "X-strict unknown manifest field must be rejected")
    } catch let error as MobileResultLibrary.ResultError {
        if case .invalidManifest = error {} else {
            require(false, "X-strict unknown field must be invalidManifest, got \(error)")
        }
    }
    // The tampered result is never listed and is moved, not deleted,
    // into a durable audit wrapper.
    let visibleAfterTamper = MobileResultLibrary.listResults()
    require(
        visibleAfterTamper.count == 1,
        "X-strict tampered result must be isolated from listResults")
    require(
        !FileManager.default.fileExists(atPath: tamperDirectory.path),
        "RC-H24 corrupted result must leave the visible result root")
    require(
        !MobileResultLibrary.lastListingDiagnostics().isEmpty,
        "RC-H24 result listing must expose a runtime audit diagnostic")
    let resultQuarantine = try MobileResultLibrary.root()
        .appendingPathComponent("quarantine", isDirectory: true)
    let resultQuarantineEntries = try FileManager.default
        .contentsOfDirectory(atPath: resultQuarantine.path)
    require(
        resultQuarantineEntries.count == 1,
        "RC-H24 exactly one corrupted result must be quarantined")
    let resultQuarantineWrapper = resultQuarantine.appendingPathComponent(
        resultQuarantineEntries[0], isDirectory: true)
    require(
        FileManager.default.fileExists(atPath: resultQuarantineWrapper
            .appendingPathComponent("result_payload").path)
            && FileManager.default.fileExists(atPath: resultQuarantineWrapper
                .appendingPathComponent(
                    MobileResultLibrary.quarantineDiagnosticFileName).path),
        "RC-H24 quarantine must preserve payload plus durable diagnostic")

    // =================================================================
    // Historical RESCAN_SESSION transaction compatibility. New non-PASS
    // runs publish a PARTIAL/NOT_PUBLISHABLE Result, but previously durable
    // terminal artifacts still require strict immutable recovery semantics.
    // =================================================================
    do {
        let savedFast = MobileNativeFactorGraphGateway.runFastImplementation
        let savedFull = MobileNativeFactorGraphGateway.runFullGraphImplementation
        defer {
            MobileNativeFactorGraphGateway.runFastImplementation = savedFast
            MobileNativeFactorGraphGateway.runFullGraphImplementation = savedFull
            MobileProcessingPipeline.sessionRescanArtifactWriteFaultInjector = nil
            PersistentTaskCoordinator.writeFaultInjector = nil
        }
        let resultCountBefore = MobileResultLibrary.listResults().count
        var fastInvocationCount = 0
        var fullInvocationCount = 0
        func failingGraph(
            request: MobileNativeGraphRequest,
            path: String
        ) throws -> MobileNativeGraphOutcome {
            return MobileNativeGraphOutcome(
                disposition: .recoverableFail,
                qualityJSON: try nativeQualityFixture(
                    request: request,
                    path: path,
                    disposition: .recoverableFail,
                    trajectoryCount: 1,
                    skeletonCount: 1,
                    publishCount: 1),
                trajectory: [MobileNativeTrajectoryRow(
                    id: 1,
                    stamp: now + 1.0,
                    xM: 1.0,
                    yM: 2.0,
                    yawRad: 0.5,
                    mapID: 0,
                    componentID: 0,
                    publishEligible: true,
                    uncertaintyM: 0.05)],
                skeletonIDs: [1])
        }
        MobileNativeFactorGraphGateway.runFastImplementation = { request, cancelled in
            fastInvocationCount += 1
            return try failingGraph(request: request, path: "fast")
        }
        MobileNativeFactorGraphGateway.runFullGraphImplementation = { request, cancelled in
            fullInvocationCount += 1
            return try failingGraph(
                request: request, path: "full_graph_optimization")
        }
        let gateNTaskRoot = try MobileProcessingTaskStore.createTask(
            taskID: "gate-n-graph-fail")
        let gateNRequest = MobileProcessingPipeline.Request(
            finalizedSession: session,
            sourceDatabase: session.appendingPathComponent("rtabmap_segment_0001.db"),
            taskRoot: gateNTaskRoot,
            priorMap: maps[0],
            storeID: "s1",
            floorID: "1",
            trackingSessionID: "E2E-SESSION",
            appGitSHA: "e2e",
            appVersion: "1.0",
            deviceModel: "host",
            osVersion: "macos",
            nativeCoreSHA256: "",
            policySHA: "host-policy-v1")
        let gateNOutcome = try MobileProcessingPipeline.run(
            request: gateNRequest, progress: { _, _ in }, isCancelled: { false })
        require(
            fastInvocationCount == 1 && fullInvocationCount == 1,
            "partial-result Route A must run Fast once and Full at most once")
        let gateNRecord = try PersistentTaskCoordinator.read(taskRoot: gateNTaskRoot)
        require(
            gateNRecord.state == .completed && gateNRecord.error == nil,
            "non-PASS finite trajectory must commit a completed partial Result")
        require(
            MobileResultLibrary.listResults().count == resultCountBefore + 1
                && gateNOutcome.resultEntry.manifest["result_quality_status"]
                    as? String == "LOCAL_FRAME_ONLY"
                && gateNOutcome.resultEntry.manifest["publish_permitted"]
                    as? Bool == false
                && (gateNOutcome.resultEntry.manifest["degradation_count"]
                    as? Int ?? 0) > 0,
            "non-PASS graph must preserve a non-publishable partial Result")

        // A deeper-solver failure is not allowed to erase a Fast outcome
        // that already passed the strict native contract. The result remains
        // non-publishable and records the exact fallback reason. Conversely,
        // invalid ABI/outcome memory is never eligible for this fallback.
        MobileNativeFactorGraphGateway.runFullGraphImplementation = {
            _, _ in
            throw MobileNativeFactorGraphError.nativeFailed(
                "host full solver did not converge")
        }
        let fullFallbackTaskRoot = try MobileProcessingTaskStore.createTask(
            taskID: "gate-n-full-fallback")
        var fullFallbackRequest = gateNRequest
        fullFallbackRequest.taskRoot = fullFallbackTaskRoot
        let fullFallbackOutcome = try MobileProcessingPipeline.run(
            request: fullFallbackRequest,
            progress: { _, _ in }, isCancelled: { false })
        require(
            fullFallbackOutcome.resultEntry.manifest["processing_path"]
                as? String == "fast_fallback_after_full_graph_failure"
                && fullFallbackOutcome.resultEntry.manifest[
                    "result_quality_status"] as? String != "COMPLETE"
                && fullFallbackOutcome.resultEntry.manifest[
                    "publish_permitted"] as? Bool == false,
            "Full solver failure must commit the validated Fast partial result")
        let fullFallbackQuality = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fullFallbackOutcome.resultEntry.directory
                .appendingPathComponent("quality_report.json"))) as! [String: Any]
        let fullFallbackResult = fullFallbackQuality["result"]
            as! [String: Any]
        let fullFallbackDegradations = fullFallbackResult["degradations"]
            as! [[String: Any]]
        require(
            fullFallbackDegradations.contains {
                $0["code"] as? String
                    == "full_graph_failed_fallback_to_fast"
            },
            "Full-to-Fast fallback must be explicit in quality_report.json")

        MobileNativeFactorGraphGateway.runFullGraphImplementation = {
            _, _ in
            throw MobileNativeFactorGraphError.invalidOutcome(
                "host forged trajectory pointer")
        }
        let invalidFullTaskRoot = try MobileProcessingTaskStore.createTask(
            taskID: "gate-n-invalid-full-outcome")
        var invalidFullRequest = gateNRequest
        invalidFullRequest.taskRoot = invalidFullTaskRoot
        var invalidFullRejected = false
        do {
            _ = try MobileProcessingPipeline.run(
                request: invalidFullRequest,
                progress: { _, _ in }, isCancelled: { false })
        } catch let error as MobileOnlyWorkflowError {
            if case .processingFailed(let detail) = error {
                invalidFullRejected = detail.contains("结果不可信")
            }
        }
        require(
            invalidFullRejected,
            "invalid Full ABI/outcome must remain fatal instead of falling back")

        // Build a legacy terminal artifact payload directly so the immutable
        // recovery/parser contract below remains covered.
        let legacyTaskRoot = try MobileProcessingTaskStore.createTask(
            taskID: "legacy-rescan-template")
        var legacyRequest = gateNRequest
        legacyRequest.taskRoot = legacyTaskRoot
        let legacySnapshot = try SessionSnapshotTransaction.snapshot(
            finalizedSession: session,
            sourceDatabase: session.appendingPathComponent(
                "rtabmap_segment_0001.db"),
            taskRoot: legacyTaskRoot)
        let legacyCheckpoint = PersistentTaskCheckpoint.snapshotCheckpoint(
            request: legacyRequest, snapshot: legacySnapshot, retryCount: 0)
        let legacyTask = RescanTask(
            taskID: "legacy-rescan-task", taskType: .insufficientLoop,
            floorID: "1", barcode: "", tagInstanceID: nil,
            shelfCode: "", shelfSegmentID: "", regionStartCm: nil,
            regionEndCm: nil, localStartTime: "", localEndTime: "",
            reasonCode: "graph_quality_failed",
            humanMessage: "legacy graph quality failed",
            suggestedAction: "RESCAN_SESSION", priority: 1)
        do {
            try MobileProcessingPipeline.persistSessionRescanOutcome(
                request: legacyRequest,
                snapshot: legacySnapshot,
                processingPath: "full_graph_optimization",
                graphDisposition: "RECOVERABLE_FAIL",
                reasonCode: "graph_quality_failed",
                humanMessage: legacyTask.humanMessage,
                rescanTask: legacyTask,
                checkpoint: legacyCheckpoint)
            require(false, "legacy RESCAN template must throw typed terminal outcome")
        } catch MobileOnlyWorkflowError.rescanSessionRequired {
            // Expected.
        }
        let gateNRescanURL = legacyTaskRoot.appendingPathComponent(
            MobileProcessingPipeline.sessionRescanArtifactFileName)
        let gateNRescanData = try Data(contentsOf: gateNRescanURL)
        let gateNRescan = try JSONSerialization.jsonObject(
            with: gateNRescanData) as! [String: Any]
        let legacyArtifactSHA = SHA256.hash(data: gateNRescanData).map {
            String(format: "%02x", $0)
        }.joined()
        try MobileProcessingPipeline.validateSessionRescanArtifact(
            taskRoot: legacyTaskRoot,
            request: legacyRequest,
            inputBundleSHA256: legacySnapshot.bundleSHA256,
            expectedSHA256: legacyArtifactSHA)

        // Adversarial artifact parser fixtures: JSON numeric 0/1 cannot
        // impersonate Bool, and reason/disposition combinations are a
        // cross-field contract rather than two independent enums.
        func updateRescanTaskPayload(
            _ payload: inout [String: Any],
            reasonCode: String,
            taskType: String,
            humanMessage: String? = nil
        ) {
            var rescanTasks = payload["rescan_tasks"] as! [String: Any]
            var tasks = rescanTasks["tasks"] as! [[String: Any]]
            tasks[0]["reason_code"] = reasonCode
            tasks[0]["task_type"] = taskType
            if let humanMessage {
                tasks[0]["human_message"] = humanMessage
            }
            rescanTasks["tasks"] = tasks
            payload["rescan_tasks"] = rescanTasks
        }
        func writeAdversarialRescanArtifact(
            taskID: String,
            mutate: (inout [String: Any]) -> Void
        ) throws -> (URL, MobileProcessingPipeline.Request, String, String, Data) {
            let taskRoot = try MobileProcessingTaskStore.createTask(taskID: taskID)
            var request = gateNRequest
            request.taskRoot = taskRoot
            var payload = gateNRescan
            payload["task_id"] = taskID
            mutate(&payload)
            let data = try CanonicalJSONEncoder.encode(payload)
            let url = taskRoot.appendingPathComponent(
                MobileProcessingPipeline.sessionRescanArtifactFileName)
            try data.write(to: url, options: .withoutOverwriting)
            require(chmod(url.path, 0o400) == 0,
                "RC RESCAN adversarial fixture must freeze artifact")
            let inputBundleSHA = payload["input_bundle_sha256"] as! String
            let sha = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            return (taskRoot, request, inputBundleSHA, sha, data)
        }
        func requireAdversarialRescanRejected(
            _ fixture: (
                URL, MobileProcessingPipeline.Request, String, String, Data),
            label: String
        ) throws {
            do {
                try MobileProcessingPipeline.validateSessionRescanArtifact(
                    taskRoot: fixture.0,
                    request: fixture.1,
                    inputBundleSHA256: fixture.2,
                    expectedSHA256: fixture.3)
                require(false, "RC RESCAN \(label) must be rejected")
            } catch let error
                    as MobileProcessingPipeline.SessionRescanArtifactError {
                if case .invalid = error {} else {
                    require(false,
                        "RC RESCAN \(label) rejection type wrong: \(error)")
                }
            }
            let record = try PersistentTaskCoordinator.read(taskRoot: fixture.0)
            let artifact = try Data(contentsOf: fixture.0.appendingPathComponent(
                MobileProcessingPipeline.sessionRescanArtifactFileName))
            require(record.state == .created && record.error == nil
                    && artifact == fixture.4,
                "RC RESCAN \(label) rejection must not mutate task/artifact")
        }

        let numericPublish = try writeAdversarialRescanArtifact(
            taskID: "rescan-numeric-publish-bool") { payload in
                payload["publish_permitted"] = 0
            }
        try requireAdversarialRescanRejected(
            numericPublish, label: "numeric publish_permitted")
        let numericResult = try writeAdversarialRescanArtifact(
            taskID: "rescan-numeric-result-bool") { payload in
                payload["result_published"] = 1
            }
        try requireAdversarialRescanRejected(
            numericResult, label: "numeric result_published")

        let noPublishNonPass = try writeAdversarialRescanArtifact(
            taskID: "rescan-no-publish-non-pass") { payload in
                payload["reason_code"] = "no_publish_eligible_trajectory"
                payload["graph_disposition"] = "RECOVERABLE_FAIL"
                updateRescanTaskPayload(
                    &payload,
                    reasonCode: "no_publish_eligible_trajectory",
                    taskType: MobileWorksheets.RescanTaskType
                        .weakLocalization.rawValue)
            }
        try requireAdversarialRescanRejected(
            noPublishNonPass, label: "no-publish + non-PASS")
        let graphFailurePass = try writeAdversarialRescanArtifact(
            taskID: "rescan-graph-failure-pass") { payload in
                payload["graph_disposition"] = "PASS"
            }
        try requireAdversarialRescanRejected(
            graphFailurePass, label: "graph-quality-failed + PASS")
        let graphFailureResource = try writeAdversarialRescanArtifact(
            taskID: "rescan-graph-failure-resource") { payload in
                payload["graph_disposition"] = "RESOURCE_REQUIRED"
            }
        try requireAdversarialRescanRejected(
            graphFailureResource,
            label: "graph-quality-failed + RESOURCE_REQUIRED")

        // The former graph-failure RESCAN writer/crash matrix was removed:
        // finite non-PASS trajectories now use the ordinary immutable Result
        // transaction, whose rename/checkpoint crash matrix is exercised in
        // §15 below. Strict legacy artifact parsing remains covered above.
        print(
            "partial Result + legacy RESCAN parser compatibility passed")
    } catch {
        require(false, "RC RESCAN terminal outcome failed: \(error)")
    }

    // =================================================================
    // V1R4 §15 Gate L: per-stage durable checkpoints + crash injection.
    // Every stage below leaves task.json at that stage with a full
    // identity-bound checkpoint, deletes the source session, and
    // verifies the run resumes from the verified immutable snapshot —
    // never re-reading the mutable source database.
    // =================================================================
    let crashTasksRoot = temporary.appendingPathComponent("TasksCrash")
    let crashResultsRoot = temporary.appendingPathComponent("ResultsCrash")
    MobileProcessingTaskStore.rootOverride = crashTasksRoot
    MobileResultLibrary.rootOverride = crashResultsRoot
    do {
        // Seed: one full run produces the durable snapshot + a
        // completed task whose checkpoint binds the full identity.
        let seedRoot = try MobileProcessingTaskStore.createTask(taskID: "crash-seed")
        let seedRequest = MobileProcessingPipeline.Request(
            finalizedSession: session,
            sourceDatabase: session.appendingPathComponent("rtabmap_segment_0001.db"),
            taskRoot: seedRoot,
            priorMap: maps[0],
            storeID: "s1",
            floorID: "1",
            trackingSessionID: "E2E-SESSION",
            appGitSHA: "e2e",
            appVersion: "1.0",
            deviceModel: "host",
            osVersion: "macos",
            nativeCoreSHA256: "",
            policySHA: "host-policy-v1")
        _ = try MobileProcessingPipeline.run(
            request: seedRequest, progress: { _, _ in }, isCancelled: { false })
        var seedRecord = try PersistentTaskCoordinator.read(taskRoot: seedRoot)
        require(
            seedRecord.state == .completed,
            "§15 seed run must end completed, got \(seedRecord.state.rawValue)")
        require(
            seedRecord.checkpoint?["task_id"] as? String == "crash-seed"
                && (seedRecord.checkpoint?["retry_count"] as? Int ?? -1) == 0,
            "§15 completed checkpoint must bind task_id and retry_count")
        func makeCrashSnapshot(
            taskRoot: URL
        ) throws -> SessionSnapshotTransaction.SessionSnapshot {
            try SessionSnapshotTransaction.snapshot(
                finalizedSession: session,
                sourceDatabase: seedRequest.sourceDatabase,
                taskRoot: taskRoot,
                eligibility: SessionSnapshotTransaction.Eligibility(
                    priorMapID: maps[0].priorMapID,
                    priorMapSHA256: maps[0].packageSHA256,
                    storeID: "s1",
                    floorID: "1",
                    appGitSHA: "e2e"))
        }

        // Every durable stage of the pipeline (spec §15 stage list),
        // snapshotting included (snapshot completed, crash before the
        // first optimization stage).
        let stages: [PersistentTaskCoordinator.TaskState] = [
            .snapshotting, .fastOptimizing, .fastQualityCheck,
            .deepReprocessing, .deepOptimizing,
            .buildingTrajectory, .resolvingTags,
            .buildingWorkbook, .validatingResult, .committingResult,
        ]
        func advanceCrashFixture(
            taskRoot: URL,
            to target: PersistentTaskCoordinator.TaskState,
            checkpoint: [String: Any]
        ) throws {
            let fastRoute: [PersistentTaskCoordinator.TaskState] = [
                .snapshotting, .fastOptimizing, .fastQualityCheck,
                .buildingTrajectory, .resolvingTags, .buildingWorkbook,
                .validatingResult, .committingResult,
            ]
            let deepRoute: [PersistentTaskCoordinator.TaskState] = [
                .snapshotting, .fastOptimizing, .fastQualityCheck,
                .deepReprocessing, .deepOptimizing,
                .buildingTrajectory, .resolvingTags, .buildingWorkbook,
                .validatingResult, .committingResult,
            ]
            let route = target == .deepReprocessing || target == .deepOptimizing
                ? deepRoute : fastRoute
            guard let targetIndex = route.firstIndex(of: target) else {
                fatalError("unsupported crash fixture target: \(target.rawValue)")
            }
            for state in route[...targetIndex] {
                try PersistentTaskCoordinator.updateState(
                    state, taskRoot: taskRoot, progress: 0.5,
                    checkpoint: checkpoint)
            }
        }

        // Recovery must explicitly clear the diagnostic attached to an
        // interrupted/resource-pause terminal generation. nil keeps its
        // historical "preserve" meaning for ordinary updates; clearError
        // is used at recovery reentry and completed transitions.
        for (taskID, oldReason) in [
            ("clear-interrupted-error", "system_interrupted"),
            ("clear-resource-pause-error", "resource_pause"),
        ] {
            let taskRoot = try MobileProcessingTaskStore.createTask(taskID: taskID)
            _ = try PersistentTaskCoordinator.updateState(
                .interrupted, taskRoot: taskRoot, error: oldReason)
            _ = try PersistentTaskCoordinator.updateState(
                .snapshotting,
                taskRoot: taskRoot,
                clearError: true,
                allowRecoveryReentry: true)
            let successRoute: [PersistentTaskCoordinator.TaskState] = [
                .fastOptimizing, .fastQualityCheck, .buildingTrajectory,
                .resolvingTags, .buildingWorkbook, .validatingResult,
                .committingResult,
            ]
            for state in successRoute {
                _ = try PersistentTaskCoordinator.updateState(
                    state, taskRoot: taskRoot)
            }
            _ = try PersistentTaskCoordinator.updateState(
                .completed,
                taskRoot: taskRoot,
                progress: 1.0,
                clearError: true)
            let completed = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
            require(completed.state == .completed && completed.error == nil,
                "RC recovery \(oldReason) must not leak stale error into completed")
        }

        // RC committed-result transaction blocker: once the immutable
        // result receipt/final rename is visible, neither a result-commit
        // post-rename fault nor any completed task-writer boundary may
        // demote the task to generic failed or trigger a duplicate export.
        struct InjectedCommittedResultFault: Error {
            let label: String
        }
        func exactCommittedEntry(
            taskRoot: URL
        ) throws -> MobileResultLibrary.ResultEntry {
            let record = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
            let expected = try PersistentTaskCheckpoint
                .expectedCommittedResultIDs(
                    in: record.checkpoint, taskID: record.taskID)
            guard let entry = try MobileResultLibrary.committedResult(
                    taskID: record.taskID,
                    expectedResultIDs: expected) else {
                throw InjectedCommittedResultFault(
                    label: "missing committed result for \(record.taskID)")
            }
            return entry
        }
        func requireImmutableCommittedResult(
            _ entry: MobileResultLibrary.ResultEntry,
            label: String
        ) throws {
            let directoryMode = (try FileManager.default.attributesOfItem(
                atPath: entry.directory.path)[.posixPermissions] as? NSNumber)?.intValue
            let receiptMode = (try FileManager.default.attributesOfItem(
                atPath: entry.directory.appendingPathComponent(
                    MobileResultLibrary.commitReceiptFileName).path)[
                        .posixPermissions] as? NSNumber)?.intValue
            require(directoryMode == 0o555,
                "\(label) committed result root must remain 0555")
            require(receiptMode == 0o444,
                "\(label) committed receipt must remain 0444")
        }

        let postRenameCommitStages: [MobileResultLibrary.CommitStage] = [
            .afterRename, .afterParentFsync,
        ]
        for commitStage in postRenameCommitStages {
            let taskID = "result-commit-fault-\(commitStage.rawValue)"
            let taskRoot = try MobileProcessingTaskStore.createTask(taskID: taskID)
            var request = seedRequest
            request.taskRoot = taskRoot
            MobileResultLibrary.commitFaultInjector = { stage in
                if stage == commitStage {
                    throw InjectedCommittedResultFault(label: stage.rawValue)
                }
            }
            var faultOutcome: MobileProcessingPipeline.Outcome?
            do {
                faultOutcome = try MobileProcessingPipeline.run(
                    request: request,
                    progress: { _, _ in },
                    isCancelled: { false })
            } catch {
                MobileResultLibrary.commitFaultInjector = nil
                require(false,
                    "RC committed result \(commitStage.rawValue) must reconcile, got \(error)")
            }
            MobileResultLibrary.commitFaultInjector = nil
            let record = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
            require(record.state == .completed,
                "RC committed result \(commitStage.rawValue) must finish completed")
            require(record.error == nil,
                "RC committed result \(commitStage.rawValue) must clear stale error")
            let terminalIntent = try MobileTerminalStatePersistence
                .readIntentIfPresent(taskRoot: taskRoot)
            require(
                terminalIntent == nil,
                "RC committed result \(commitStage.rawValue) must not create failed intent")
            let committedEntry = try exactCommittedEntry(taskRoot: taskRoot)
            require(
                faultOutcome?.resultEntry.resultID == committedEntry.resultID,
                "RC committed result \(commitStage.rawValue) must return the one visible result")
            try requireImmutableCommittedResult(
                committedEntry, label: commitStage.rawValue)
        }

        let completedWriteStages: [PersistentTaskCoordinator.WriteStage] = [
            .beforeTemporaryWrite, .afterTemporaryFsync,
            .afterRename, .afterParentFsync,
        ]
        for writeStage in completedWriteStages {
            let taskID = "completed-write-fault-\(writeStage.rawValue)"
            let taskRoot = try MobileProcessingTaskStore.createTask(taskID: taskID)
            var request = seedRequest
            request.taskRoot = taskRoot
            // Install the task writer fault only after the result's parent
            // fsync. Earlier task transitions therefore remain real
            // production writes; only the completed boundary is injected.
            MobileResultLibrary.commitFaultInjector = { stage in
                if stage == .afterParentFsync {
                    PersistentTaskCoordinator.writeFaultInjector = { actual in
                        if actual == writeStage {
                            throw InjectedCommittedResultFault(
                                label: "completed-\(actual.rawValue)")
                        }
                    }
                }
            }
            var firstOutcome: MobileProcessingPipeline.Outcome?
            var firstError: Error?
            do {
                firstOutcome = try MobileProcessingPipeline.run(
                    request: request,
                    progress: { _, _ in },
                    isCancelled: { false })
            } catch {
                firstError = error
            }
            MobileResultLibrary.commitFaultInjector = nil
            PersistentTaskCoordinator.writeFaultInjector = nil

            var record = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
            let firstCommitted = try exactCommittedEntry(taskRoot: taskRoot)
            try requireImmutableCommittedResult(
                firstCommitted, label: "completed-\(writeStage.rawValue)")
            let terminalIntent = try MobileTerminalStatePersistence
                .readIntentIfPresent(taskRoot: taskRoot)
            require(
                terminalIntent == nil,
                "RC completed \(writeStage.rawValue) must not create failed intent")

            switch writeStage {
            case .beforeTemporaryWrite, .afterTemporaryFsync:
                require(firstOutcome == nil && firstError != nil,
                    "RC completed \(writeStage.rawValue) pre-rename fault must surface")
                require(record.state == .committingResult,
                    "RC completed \(writeStage.rawValue) must preserve committing_result")
                let recovered = try MobileProcessingPipeline.run(
                    request: request,
                    progress: { _, _ in },
                    isCancelled: { false })
                record = try PersistentTaskCoordinator.read(taskRoot: taskRoot)
                require(record.state == .completed,
                    "RC completed \(writeStage.rawValue) restart must reconcile completed")
                require(record.error == nil,
                    "RC completed \(writeStage.rawValue) restart must clear stale error")
                require(recovered.resultEntry.resultID == firstCommitted.resultID,
                    "RC completed \(writeStage.rawValue) restart must not duplicate export")
            case .afterRename, .afterParentFsync:
                require(firstError == nil && firstOutcome != nil,
                    "RC completed \(writeStage.rawValue) must accept exact durable reread")
                require(record.state == .completed,
                    "RC completed \(writeStage.rawValue) must remain completed")
                require(record.error == nil,
                    "RC completed \(writeStage.rawValue) must not retain stale error")
                require(firstOutcome?.resultEntry.resultID == firstCommitted.resultID,
                    "RC completed \(writeStage.rawValue) must return exact committed result")
            }
            let finalCommitted = try exactCommittedEntry(taskRoot: taskRoot)
            require(finalCommitted.resultID == firstCommitted.resultID,
                "RC completed \(writeStage.rawValue) must keep exactly one result")
        }

        // Fail-closed negative fixtures: an expected result with a
        // conflicting receipt and two valid results claiming one task are
        // never treated as "no result", never resumed, and never demoted
        // to generic failed.
        func commitRecoveryFixture(
            taskID: String,
            resultIDs: [String]
        ) throws -> (MobileProcessingPipeline.Request, URL, [MobileResultLibrary.ResultEntry]) {
            let taskRoot = try MobileProcessingTaskStore.createTask(taskID: taskID)
            var request = seedRequest
            request.taskRoot = taskRoot
            let snapshot = try makeCrashSnapshot(taskRoot: taskRoot)
            let primaryResultID = resultIDs[0]
            var checkpoint = PersistentTaskCheckpoint.snapshotCheckpoint(
                request: request,
                snapshot: snapshot,
                retryCount: 1,
                processingPath: "fast")
            checkpoint = PersistentTaskCheckpoint.withDurableOutputs(
                [PersistentTaskCheckpoint.taskReference("input_snapshot"),
                 PersistentTaskCheckpoint.taskReference("input_manifest.json"),
                 PersistentTaskCheckpoint.resultStagingReference(
                    taskID: taskID,
                    resultID: primaryResultID,
                    relativePath: "payload.json")],
                in: checkpoint)
            try advanceCrashFixture(
                taskRoot: taskRoot,
                to: .committingResult,
                checkpoint: checkpoint)
            var entries: [MobileResultLibrary.ResultEntry] = []
            for resultID in resultIDs {
                let staging = try MobileResultLibrary.stagingDirectory(
                    taskID: taskID, resultID: resultID)
                try Data("{}".utf8).write(
                    to: staging.appendingPathComponent("payload.json"))
                let workbookName = "\(resultID).xlsx"
                try Data("fixture".utf8).write(
                    to: staging.appendingPathComponent(workbookName))
                entries.append(try MobileResultLibrary.commit(
                    resultID: resultID,
                    taskID: taskID,
                    stagingDirectory: staging,
                    packageFiles: ["payload.json"],
                    workbookFilename: workbookName,
                    manifestExtras: [
                        "store_id": request.storeID,
                        "prior_map_id": request.priorMap.priorMapID,
                        "prior_map_sha256": request.priorMap.packageSHA256,
                        "tracking_session_id": request.trackingSessionID,
                        "source_database": request.sourceDatabase.lastPathComponent,
                        "input_bundle_sha256": snapshot.bundleSHA256,
                        "native_core_sha256": request.nativeCoreSHA256,
                        "processing_path": "fast",
                        "policy_sha": request.policySHA,
                        "projection_policy_version": 1,
                        "trajectory_sha256": String(repeating: "1", count: 64),
                        "graph_quality_sha256": String(repeating: "2", count: 64),
                        "device_position_count": 1,
                        "available_position_count": 1,
                        "tag_count": 0,
                        "rescan_count": 0,
                    ]))
            }
            return (request, taskRoot, entries)
        }

        let receiptFixture = try commitRecoveryFixture(
            taskID: "committed-receipt-conflict",
            resultIDs: ["result-receipt-conflict"])
        let badReceiptURL = receiptFixture.2[0].directory
            .appendingPathComponent(MobileResultLibrary.commitReceiptFileName)
        var badReceipt = try JSONSerialization.jsonObject(
            with: Data(contentsOf: badReceiptURL)) as! [String: Any]
        badReceipt["manifest_sha256"] = String(repeating: "0", count: 64)
        require(chmod(badReceiptURL.path, 0o644) == 0,
            "RC receipt conflict fixture must unlock receipt")
        try CanonicalJSONEncoder.encode(badReceipt).write(to: badReceiptURL)
        require(chmod(badReceiptURL.path, 0o444) == 0,
            "RC receipt conflict fixture must refreeze receipt")
        do {
            _ = try PersistentTaskCheckpoint.recover(
                taskRoot: receiptFixture.1,
                request: receiptFixture.0)
            require(false, "RC conflicting commit receipt must fail closed")
        } catch {
            let record = try PersistentTaskCoordinator.read(
                taskRoot: receiptFixture.1)
            require(record.state == .committingResult,
                "RC conflicting receipt must preserve committing_result")
        }

        let multipleFixture = try commitRecoveryFixture(
            taskID: "committed-multiple-results",
            resultIDs: ["result-multiple-a", "result-multiple-b"])
        do {
            _ = try PersistentTaskCheckpoint.recover(
                taskRoot: multipleFixture.1,
                request: multipleFixture.0)
            require(false, "RC multiple committed results must fail closed")
        } catch {
            let record = try PersistentTaskCoordinator.read(
                taskRoot: multipleFixture.1)
            require(record.state == .committingResult,
                "RC multiple results must preserve committing_result")
        }
        print(
            "RC committed-result recovery passed: result-faults=2 completed-writer=4 fail-closed=2")

        // RC orphan terminal-intent bootstrap blocker: an existing task
        // directory without task.json must never let a later run replace a
        // durable terminal marker. Early business gates now run only after a
        // real task record exists, so they can be terminalized exactly.
        let orphanTaskID = "orphan-terminal-intent"
        let orphanRoot = try MobileProcessingTaskStore.taskRoot(
            taskID: orphanTaskID)
        try FileManager.default.createDirectory(
            at: orphanRoot, withIntermediateDirectories: true)
        let orphanBusinessError = MobileOnlyWorkflowError.invalidState(
            "orphan intent fixture")
        do {
            try MobileTerminalStatePersistence.persistThenRethrow(
                orphanBusinessError, taskRoot: orphanRoot)
            require(false, "orphan intent fixture must fail task persistence")
        } catch let failure as MobileTerminalStatePersistence.DurabilityFailure {
            require(
                failure.phase == .persistTaskState,
                "orphan intent must fail only after its marker is durable")
        }
        let orphanIntent = try MobileTerminalStatePersistence
            .readIntentIfPresent(taskRoot: orphanRoot)
        require(
            !FileManager.default.fileExists(
                atPath: PersistentTaskCoordinator.taskFileURL(
                    taskRoot: orphanRoot).path)
                && orphanIntent != nil,
            "orphan fixture must contain intent and no task.json")
        do {
            _ = try MobileProcessingTaskStore.createTask(taskID: orphanTaskID)
            require(false, "createTask must not replace an orphan intent")
        } catch let error as MobileProcessingTaskStore.StoreError {
            if case .invalidTask = error {} else {
                require(false, "orphan createTask returned wrong store error")
            }
        }
        var orphanRequest = seedRequest
        orphanRequest.taskRoot = orphanRoot
        do {
            _ = try MobileProcessingPipeline.run(
                request: orphanRequest,
                progress: { _, _ in },
                isCancelled: { false })
            require(false, "pipeline must not replace an orphan intent")
        } catch let error as PersistentTaskCheckpoint.CheckpointError {
            if case .invalidRecord(let detail) = error {
                require(
                    detail.contains("intent") && detail.contains("task.json"),
                    "orphan checkpoint error must identify the conflict")
            } else {
                require(false, "orphan pipeline returned wrong checkpoint error")
            }
        }
        let retainedOrphanIntent = try MobileTerminalStatePersistence
            .readIntentIfPresent(taskRoot: orphanRoot)
        require(
            !FileManager.default.fileExists(
                atPath: PersistentTaskCoordinator.taskFileURL(
                    taskRoot: orphanRoot).path)
                && retainedOrphanIntent != nil,
            "failed orphan restart must preserve the exact audit marker")

        let nonemptyTaskID = "missing-task-record-nonempty"
        let nonemptyRoot = try MobileProcessingTaskStore.taskRoot(
            taskID: nonemptyTaskID)
        try FileManager.default.createDirectory(
            at: nonemptyRoot, withIntermediateDirectories: true)
        try Data("unexpected".utf8).write(
            to: nonemptyRoot.appendingPathComponent("unexpected.bin"))
        do {
            _ = try MobileProcessingTaskStore.createTask(taskID: nonemptyTaskID)
            require(false, "non-empty task directory without task.json must reject")
        } catch let error as MobileProcessingTaskStore.StoreError {
            if case .invalidTask = error {} else {
                require(false, "non-empty task directory returned wrong error")
            }
        }

        let repairedTaskID = "empty-create-residue"
        let repairedRoot = try MobileProcessingTaskStore.taskRoot(
            taskID: repairedTaskID)
        try FileManager.default.createDirectory(
            at: repairedRoot, withIntermediateDirectories: true)
        _ = try MobileProcessingTaskStore.createTask(taskID: repairedTaskID)
        let repairedRecord = try PersistentTaskCoordinator.read(
            taskRoot: repairedRoot)
        require(
            repairedRecord.taskID == repairedTaskID
                && repairedRecord.state == .created,
            "empty mkdir residue must be repaired with an exact created record")

        let earlyGateTaskID = "early-build-identity-gate"
        let earlyGateRoot = try MobileProcessingTaskStore.taskRoot(
            taskID: earlyGateTaskID)
        var earlyGateRequest = seedRequest
        earlyGateRequest.taskRoot = earlyGateRoot
        earlyGateRequest.appGitSHA = "unknown"
        do {
            _ = try MobileProcessingPipeline.run(
                request: earlyGateRequest,
                progress: { _, _ in },
                isCancelled: { false })
            require(false, "unknown build identity must reject")
        } catch let error as MobileOnlyWorkflowError {
            if case .invalidState(let detail) = error {
                require(
                    detail.contains("build identity"),
                    "early gate returned wrong invalid-state detail")
            } else {
                require(false, "early build gate returned wrong workflow error")
            }
        }
        let earlyGateRecord = try PersistentTaskCoordinator.read(
            taskRoot: earlyGateRoot)
        let earlyGateIntent = try MobileTerminalStatePersistence
            .readIntentIfPresent(taskRoot: earlyGateRoot)
        require(
            earlyGateRecord.state == .failed
                && earlyGateRecord.error?.contains("build identity") == true
                && earlyGateIntent == nil,
            "early business gate must durably commit failed task without orphan intent")
        print("RC task bootstrap/orphan-intent recovery passed")

        var crashRequests: [MobileProcessingPipeline.Request] = []
        for stage in stages {
            let taskID = "crash-\(stage.rawValue)"
            let taskRoot = try MobileProcessingTaskStore.createTask(taskID: taskID)
            var request = seedRequest
            request.taskRoot = taskRoot
            let snapshot = try makeCrashSnapshot(taskRoot: taskRoot)
            var checkpoint = PersistentTaskCheckpoint.snapshotCheckpoint(
                request: request, snapshot: snapshot, retryCount: 1)
            checkpoint = PersistentTaskCheckpoint.withProcessingPath(
                "fast", in: checkpoint)
            // The result-stage checkpoints bind the staged result
            // artifacts too (they are durable at that point).
            if stage == .validatingResult || stage == .committingResult {
                let stagedResultID = "result-crash"
                checkpoint = PersistentTaskCheckpoint.withDurableOutputs(
                    [PersistentTaskCheckpoint.taskReference("input_snapshot"),
                     PersistentTaskCheckpoint.taskReference("input_manifest.json"),
                     PersistentTaskCheckpoint.resultStagingReference(
                        taskID: taskID,
                        resultID: stagedResultID,
                        relativePath: "result-crash.xlsx")],
                    in: checkpoint)
                // The staged workbook must exist: the checkpoint claims
                // the result artifacts are durable.
                let stagedWorkbook = try MobileResultLibrary.stagingDirectory(
                    taskID: taskID, resultID: stagedResultID)
                try Data("crash-stage".utf8).write(
                    to: stagedWorkbook.appendingPathComponent("result-crash.xlsx"))
            }
            try advanceCrashFixture(
                taskRoot: taskRoot, to: stage, checkpoint: checkpoint)
            crashRequests.append(request)
        }

        // snapshotting WITHOUT a durable snapshot (created record, no
        // checkpoint) restarts from scratch: the session is still there.
        let freshRoot = try MobileProcessingTaskStore.createTask(taskID: "crash-fresh")
        var freshRequest = seedRequest
        freshRequest.taskRoot = freshRoot
        _ = try MobileProcessingPipeline.run(
            request: freshRequest, progress: { _, _ in }, isCancelled: { false })
        let freshRecord = try PersistentTaskCoordinator.read(taskRoot: freshRoot)
        require(
            freshRecord.state == .completed,
            "§15 a created task without checkpoint must run from scratch")

        // Prepare the negative recovery fixtures while the mutable source
        // still exists. Each snapshot is generated for its own task ID;
        // after the source is deleted the tests exercise only checkpoint
        // validation and immutable-snapshot recovery.
        let mismatchRoot = try MobileProcessingTaskStore.createTask(
            taskID: "crash-identity")
        let mismatchSnapshot = try makeCrashSnapshot(taskRoot: mismatchRoot)
        let refRoot = try MobileProcessingTaskStore.createTask(
            taskID: "crash-ref-missing")
        let refSnapshot = try makeCrashSnapshot(taskRoot: refRoot)
        let persistRoot = try MobileProcessingTaskStore.createTask(
            taskID: "crash-persist")
        let persistSnapshot = try makeCrashSnapshot(taskRoot: persistRoot)

        // Delete the source session: every resume below must succeed
        // WITHOUT re-reading the mutable source database.
        try FileManager.default.removeItem(at: session)
        require(
            !FileManager.default.fileExists(atPath: session.path),
            "§15 crash fixture must remove the source session")

        for request in crashRequests {
            let stage = request.taskRoot.lastPathComponent
            let outcome = try MobileProcessingPipeline.run(
                request: request, progress: { _, _ in }, isCancelled: { false })
            let record = try PersistentTaskCoordinator.read(taskRoot: request.taskRoot)
            require(
                record.state == .completed,
                "§15 resume from \(stage) must complete, got \(record.state.rawValue)")
            require(
                (record.checkpoint?["retry_count"] as? Int ?? -1) >= 1,
                "§15 resumed checkpoint must carry retry_count >= 1")
            require(
                !outcome.resultEntry.resultID.isEmpty,
                "§15 resumed run must commit a result")
        }

        // Terminal states never restart in-place (no new task
        // impersonating a resume): completed / failed / cancelled.
        do {
            _ = try MobileProcessingPipeline.run(
                request: seedRequest, progress: { _, _ in }, isCancelled: { false })
            require(false, "§15 completed task must refuse an in-place restart")
        } catch let error as PersistentTaskCheckpoint.CheckpointError {
            if case .notResumable = error {} else {
                require(false, "§15 completed restart must be notResumable, got \(error)")
            }
        }
        seedRecord = try PersistentTaskCoordinator.read(taskRoot: seedRoot)
        require(
            seedRecord.state == .completed,
            "§15 refused restart must NOT overwrite the completed state")

        // Identity mismatch is fail-closed: the checkpoint binds the
        // map/app/native/policy identity of the original run.
        var mismatchRequest = seedRequest
        mismatchRequest.taskRoot = mismatchRoot
        var mismatchCheckpoint = PersistentTaskCheckpoint.snapshotCheckpoint(
            request: mismatchRequest, snapshot: mismatchSnapshot, retryCount: 1)
        mismatchCheckpoint["map_identity"] = [
            "prior_map_id": "other-map",
            "prior_map_sha256": "deadbeef",
            "canonical_source_sha256": "cafe",
        ]
        try advanceCrashFixture(
            taskRoot: mismatchRoot, to: .fastOptimizing,
            checkpoint: mismatchCheckpoint)
        do {
            _ = try MobileProcessingPipeline.run(
                request: mismatchRequest, progress: { _, _ in }, isCancelled: { false })
            require(false, "§15 identity mismatch must be fail-closed")
        } catch let error as PersistentTaskCheckpoint.CheckpointError {
            if case .identityMismatch = error {} else {
                require(false, "§15 identity mismatch must be identityMismatch, got \(error)")
            }
        }

        // A missing durable reference fails recovery (fail closed).
        var refRequest = seedRequest
        refRequest.taskRoot = refRoot
        var refCheckpoint = PersistentTaskCheckpoint.snapshotCheckpoint(
            request: refRequest, snapshot: refSnapshot, retryCount: 1)
        refCheckpoint["snapshot_path"] = "input_snapshot_does_not_exist"
        try advanceCrashFixture(
            taskRoot: refRoot, to: .fastOptimizing,
            checkpoint: refCheckpoint)
        do {
            _ = try MobileProcessingPipeline.run(
                request: refRequest, progress: { _, _ in }, isCancelled: { false })
            require(false, "§15 missing durable reference must be fail-closed")
        } catch let error as PersistentTaskCheckpoint.CheckpointError {
            if case .referenceMissing = error {} else {
                require(false, "§15 missing reference must be referenceMissing, got \(error)")
            }
        }

        // Persist failure must block stage progress: with the task
        // directory read-only, the resume's updateState cannot write
        // task.json and the run must stop.
        var persistRequest = seedRequest
        persistRequest.taskRoot = persistRoot
        try advanceCrashFixture(
            taskRoot: persistRoot, to: .fastOptimizing,
            checkpoint: PersistentTaskCheckpoint.snapshotCheckpoint(
                request: persistRequest, snapshot: persistSnapshot, retryCount: 1))
        require(chmod(persistRoot.path, 0o555) == 0, "§15 cannot make task root read-only")
        defer { _ = chmod(persistRoot.path, 0o755) }
        do {
            _ = try MobileProcessingPipeline.run(
                request: persistRequest, progress: { _, _ in }, isCancelled: { false })
            require(false, "§15 persist failure must block stage progress")
        } catch {
            // updateState cannot write task.json: the run is blocked.
        }
        _ = chmod(persistRoot.path, 0o755)
        let persistRecord = try PersistentTaskCoordinator.read(taskRoot: persistRoot)
        require(
            persistRecord.state == .fastOptimizing,
            "§15 blocked persist must leave the stage untouched, got \(persistRecord.state.rawValue)")

        // Restore the shared roots for the tests that follow.
        MobileProcessingTaskStore.rootOverride = temporary.appendingPathComponent("Tasks")
        MobileResultLibrary.rootOverride = temporary.appendingPathComponent("Results")
        print(
            "§15 crash-injection passed: stages=\(stages.count) resume-all source-db-deleted")
    } catch {
        MobileProcessingTaskStore.rootOverride = temporary.appendingPathComponent("Tasks")
        MobileResultLibrary.rootOverride = temporary.appendingPathComponent("Results")
        require(false, "§15 crash-injection failed: \(error)")
    }

    // =================================================================
    // V1R4 §18 Gate O: dynamic resource governor budget.
    // The task estimate carries every §18 component (snapshot bytes, raw
    // nodes/links, skeleton/factors, native outcome + Swift copy, tag
    // observations/bursts, trajectory rows, XLSX temp, result staging,
    // safety reserve); each stage checks its CURRENT total against
    // device-class RSS headroom, available memory, free disk, thermal
    // and battery. Rejections are fail-closed resourceRequired and the
    // run-scoped sampler keeps REAL peak RSS / thermal counters.
    // =================================================================
    do {
        // 1) Estimate arithmetic: total sums every component and the
        //    safety reserve is always included.
        var estimate = ProcessingResourceGovernor.TaskEstimate()
        require(estimate.totalBytes == estimate.safetyReserveBytes,
            "§18 empty estimate must still carry the safety reserve")
        estimate.snapshotBytes = 1000
        estimate.rawGraphBytes = 2000
        estimate.skeletonFactorBytes = 3000
        estimate.nativeOutcomeBytes = 4000
        estimate.tagEvidenceBytes = 5000
        estimate.trajectoryBytes = 6000
        estimate.xlsxTempBytes = 7000
        estimate.resultStagingBytes = 8000
        estimate.safetyReserveBytes = 9000
        require(estimate.totalBytes == 45000,
            "§18 estimate total must sum all components, got \(estimate.totalBytes)")

        // 2) Device class follows physical memory.
        ProcessingResourceGovernor.physicalMemoryOverrideBytes = 3 * 1024 * 1024 * 1024
        require(ProcessingResourceGovernor.deviceClass() == .low,
            "§18 3 GB physical must classify as low")
        ProcessingResourceGovernor.physicalMemoryOverrideBytes = 5 * 1024 * 1024 * 1024
        require(ProcessingResourceGovernor.deviceClass() == .mid,
            "§18 5 GB physical must classify as mid")
        ProcessingResourceGovernor.physicalMemoryOverrideBytes = 8 * 1024 * 1024 * 1024
        require(ProcessingResourceGovernor.deviceClass() == .high,
            "§18 8 GB physical must classify as high")
        ProcessingResourceGovernor.resetOverrides()
        require(ProcessingResourceGovernor.deviceClass() == .high,
            "§18 host physical memory must classify as high")

        // 3) Every §18 stage passes on a healthy host with a small
        //    estimate (real measurements, no overrides).
        ProcessingResourceGovernor.beginRun()
        var stageEstimate = ProcessingResourceGovernor.TaskEstimate()
        stageEstimate.snapshotBytes = 20 * 1024 * 1024
        stageEstimate.rawGraphBytes = 4 * 1024 * 1024
        stageEstimate.safetyReserveBytes = 16 * 1024 * 1024
        for stage in ["snapshot", "fast", "deep", "trajectory",
                      "tags", "xlsx", "result_commit"] {
            try ProcessingResourceGovernor.checkBudget(
                stage: stage, estimate: stageEstimate)
        }

        // 4) Thermal serious/critical never starts heavy work.
        ProcessingResourceGovernor.thermalStateOverride = .critical
        do {
            try ProcessingResourceGovernor.checkBudget(
                stage: "fast", estimate: stageEstimate)
            require(false, "§18 critical thermal must fail closed")
        } catch let error as MobileOnlyWorkflowError {
            if case .resourceRequired = error {} else {
                require(false, "§18 thermal rejection must be resourceRequired, got \(error)")
            }
        }
        ProcessingResourceGovernor.endRun()
        ProcessingResourceGovernor.resetOverrides()

        // 5) Free disk below estimate + baseline fails closed.
        ProcessingResourceGovernor.beginRun()
        ProcessingResourceGovernor.freeDiskOverrideBytes = 0
        do {
            try ProcessingResourceGovernor.checkBudget(
                stage: "snapshot", estimate: stageEstimate)
            require(false, "§18 exhausted disk must fail closed")
        } catch let error as MobileOnlyWorkflowError {
            if case .resourceRequired = error {} else {
                require(false, "§18 disk rejection must be resourceRequired, got \(error)")
            }
        }
        ProcessingResourceGovernor.endRun()
        ProcessingResourceGovernor.resetOverrides()

        // 6) Available memory below estimate + baseline fails closed.
        ProcessingResourceGovernor.beginRun()
        ProcessingResourceGovernor.availableMemoryOverrideBytes = 0
        do {
            try ProcessingResourceGovernor.checkBudget(
                stage: "trajectory", estimate: stageEstimate)
            require(false, "§18 exhausted available memory must fail closed")
        } catch let error as MobileOnlyWorkflowError {
            if case .resourceRequired = error {} else {
                require(false, "§18 memory rejection must be resourceRequired, got \(error)")
            }
        }
        ProcessingResourceGovernor.endRun()
        ProcessingResourceGovernor.resetOverrides()

        // 7) A missing available-memory measurement is fail-closed on
        //    device; the host injects the same production outcome.
        ProcessingResourceGovernor.beginRun()
        ProcessingResourceGovernor.availableMemoryMeasurementFailureOverride = true
        do {
            try ProcessingResourceGovernor.checkBudget(
                stage: "trajectory", estimate: stageEstimate)
            require(false, "§18 unavailable memory measurement must fail closed")
        } catch let error as MobileOnlyWorkflowError {
            if case .resourceRequired = error {} else {
                require(false, "§18 measurement failure must be resourceRequired")
            }
        }
        ProcessingResourceGovernor.endRun()
        ProcessingResourceGovernor.resetOverrides()

        // 8) RSS headroom: current footprint + task estimate must fit
        //    the device-class ceiling. A 512 MB low-class device cannot
        //    take a 1 GB estimate.
        ProcessingResourceGovernor.beginRun()
        ProcessingResourceGovernor.physicalMemoryOverrideBytes = 512 * 1024 * 1024
        var hugeEstimate = ProcessingResourceGovernor.TaskEstimate()
        hugeEstimate.snapshotBytes = 1024 * 1024 * 1024
        do {
            try ProcessingResourceGovernor.checkBudget(
                stage: "deep", estimate: hugeEstimate)
            require(false, "§18 over-budget RSS headroom must fail closed")
        } catch let error as MobileOnlyWorkflowError {
            if case .resourceRequired = error {} else {
                require(false, "§18 headroom rejection must be resourceRequired, got \(error)")
            }
        }
        ProcessingResourceGovernor.endRun()
        ProcessingResourceGovernor.resetOverrides()

        // 9) The 250 ms timer catches pressure inside a long stage. Even
        //    if the thermal state later recovers, the next budget boundary
        //    must reject that interrupted run.
        ProcessingResourceGovernor.beginRun()
        ProcessingResourceGovernor.thermalStateOverride = .serious
        // The sampler runs on a utility queue. A fixed 350 ms sleep is only
        // one nominal timer interval plus leeway and can expire before that
        // queue is scheduled on a loaded CI host. Poll for bounded evidence
        // instead: this still requires the production timer to fire (no
        // manual sample is injected), while allowing ordinary scheduler
        // latency without making the contract flaky.
        let periodicSampleDeadline =
            ProcessInfo.processInfo.systemUptime + 2.0
        while ProcessingResourceGovernor
                .runSeriousOrCriticalThermalSampleCount() == 0,
              ProcessInfo.processInfo.systemUptime < periodicSampleDeadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        ProcessingResourceGovernor.thermalStateOverride = nil
        require(
            ProcessingResourceGovernor.runSeriousOrCriticalThermalSampleCount() >= 1,
            "§18 periodic sampler must observe serious thermal pressure")
        do {
            try ProcessingResourceGovernor.checkBudget(
                stage: "result_commit", estimate: stageEstimate)
            require(false, "§18 recovered thermal interruption must still block publish")
        } catch let error as MobileOnlyWorkflowError {
            if case .resourceRequired = error {} else {
                require(false, "§18 sampled thermal history must be resourceRequired")
            }
        }
        ProcessingResourceGovernor.endRun()
        ProcessingResourceGovernor.resetOverrides()

        // 10) Manual samples remain exact lower-bound evidence, beginRun
        //     resets counters, and peak RSS is monotonic within one run.
        ProcessingResourceGovernor.beginRun()
        ProcessingResourceGovernor.thermalStateOverride = .serious
        ProcessingResourceGovernor.sampleRunDiagnostics()
        ProcessingResourceGovernor.sampleRunDiagnostics()
        require(
            ProcessingResourceGovernor.runSeriousOrCriticalThermalSampleCount() >= 2,
            "§18 serious thermal samples must be counted per run")
        let peakAfterThermal = ProcessingResourceGovernor.runPeakMemoryFootprintMB()
        require(peakAfterThermal > 0,
            "§18 run peak RSS must be sampled, got \(peakAfterThermal)")
        ProcessingResourceGovernor.resetOverrides()
        ProcessingResourceGovernor.beginRun()
        require(
            ProcessingResourceGovernor.runSeriousOrCriticalThermalSampleCount() == 0,
            "§18 beginRun must reset thermal counters")
        require(
            ProcessingResourceGovernor.runPeakMemoryFootprintMB() == 0,
            "§18 beginRun must reset peak RSS")
        ProcessingResourceGovernor.endRun()

        print(
            "§18 resource-governor passed: stages=7 rejections=6 periodic-sampling=PASS")
    } catch {
        ProcessingResourceGovernor.endRun()
        ProcessingResourceGovernor.resetOverrides()
        require(false, "§18 resource-governor failed: \(error)")
    }

    print(
        "E2E replay passed: maps=\(maps.count) positions=\(outcome.devicePositionCount) "
            + "tags=\(outcome.tagCount) rescan=\(outcome.rescanCount) "
            + "sha=\(outcome.resultEntry.workbookSHA256.prefix(16))")
}
catch {
    FileHandle.standardError.write(
        Data("E2E replay failed: \(error)\n".utf8))
    exit(9)
}
}

// RC Snapshot transaction crash worker. Every crash phase starts from one
// committed baseline generation; a fresh process then re-enters the normal
// snapshot API, which reconciles the durable intent before creating the next
// generation.
if CommandLine.arguments.count == 5,
   CommandLine.arguments[1] == "--snapshot-publication-crash-worker" {
    let session = URL(
        fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let taskRoot = URL(
        fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    let phase = CommandLine.arguments[4]
    let priorMapSHA = String(repeating: "a", count: 64)
    let eligibility = SessionSnapshotTransaction.Eligibility(
        priorMapID: "MAP-P7",
        priorMapSHA256: priorMapSHA,
        storeID: "STORE-P7",
        floorID: "FLOOR-P7",
        appGitSHA: "snapshot-crash-worker")
    enum SnapshotCrashWorkerFault: Error {
        case enterRollback
    }
    let postcheckAuthorityPayload = Data(
        "{\"unrelated_postcheck\":true}\n".utf8)
    let unrelatedIntentPayload = Data(
        "{\"unrelated_intent\":true}\n".utf8)
    var intentRemovalReplacementInjected = false
    var generationRootReplacementInjected = false
    var artifactReplacementInjected = false
    var artifactPostHashMutationInjected = false
    let generationRoot = taskRoot.appendingPathComponent(
        "input_snapshot", isDirectory: true)
    let preparedGenerationRootReplacement = taskRoot.appendingPathComponent(
        "input_snapshot.prepared-root-replacement-test", isDirectory: true)
    let displacedGenerationRoot = taskRoot.appendingPathComponent(
        "input_snapshot.displaced-root-test", isDirectory: true)
    do {
        if phase == "generation_root_postopen_replace" {
            guard FileManager.default.fileExists(atPath: generationRoot.path),
                  !FileManager.default.fileExists(
                    atPath: preparedGenerationRootReplacement.path),
                  !FileManager.default.fileExists(
                    atPath: displacedGenerationRoot.path) else {
                Darwin._exit(55)
            }
            do {
                try FileManager.default.copyItem(
                    at: generationRoot,
                    to: preparedGenerationRootReplacement)
            } catch {
                Darwin._exit(56)
            }
        }
        if phase != "baseline" && phase != "recover" {
            SessionSnapshotTransaction.faultInjector = { point in
                if phase == "generation_root_postopen_replace",
                   case .afterGenerationRootOpenBeforeValidation = point {
                    guard !generationRootReplacementInjected else { return }
                    guard chmod(generationRoot.path, mode_t(0o755)) == 0,
                          chmod(
                            preparedGenerationRootReplacement.path,
                            mode_t(0o755)) == 0 else {
                        Darwin._exit(57)
                    }
                    guard renameatx_np(
                        AT_FDCWD, generationRoot.path,
                        AT_FDCWD, displacedGenerationRoot.path,
                        UInt32(RENAME_EXCL)) == 0 else {
                        Darwin._exit(58)
                    }
                    guard renameatx_np(
                        AT_FDCWD, preparedGenerationRootReplacement.path,
                        AT_FDCWD, generationRoot.path,
                        UInt32(RENAME_EXCL)) == 0 else {
                        Darwin._exit(59)
                    }
                    guard chmod(displacedGenerationRoot.path, mode_t(0o555)) == 0,
                          chmod(generationRoot.path, mode_t(0o555)) == 0 else {
                        Darwin._exit(66)
                    }
                    generationRootReplacementInjected = true
                    return
                }
                if (phase == "artifact_metadata_symlink"
                        || phase == "artifact_metadata_hardlink"
                        || phase == "artifact_metadata_mode_clone"),
                   case let .afterArtifactAuthorityReadBeforeOpen(name) = point,
                   name == "metadata.json" {
                    guard !artifactReplacementInjected else { return }
                    let metadata = generationRoot.appendingPathComponent(name)
                    let originalName: String
                    switch phase {
                    case "artifact_metadata_symlink":
                        originalName = "metadata.original-symlink-test"
                    case "artifact_metadata_hardlink":
                        originalName = "metadata.original-hardlink-test"
                    default:
                        originalName = "metadata.original-mode-clone-test"
                    }
                    let original = generationRoot.appendingPathComponent(
                        originalName)
                    guard chmod(generationRoot.path, mode_t(0o755)) == 0 else {
                        Darwin._exit(67)
                    }
                    guard renameatx_np(
                        AT_FDCWD, metadata.path,
                        AT_FDCWD, original.path,
                        UInt32(RENAME_EXCL)) == 0 else {
                        Darwin._exit(60)
                    }
                    if phase == "artifact_metadata_symlink" {
                        guard Darwin.symlink(
                            originalName, metadata.path) == 0 else {
                            Darwin._exit(61)
                        }
                    } else if phase == "artifact_metadata_hardlink" {
                        guard Darwin.link(original.path, metadata.path) == 0 else {
                            Darwin._exit(62)
                        }
                    } else {
                        do {
                            try FileManager.default.copyItem(
                                at: original, to: metadata)
                        } catch {
                            Darwin._exit(63)
                        }
                        guard chmod(metadata.path, mode_t(0o644)) == 0 else {
                            Darwin._exit(64)
                        }
                    }
                    guard chmod(generationRoot.path, mode_t(0o555)) == 0 else {
                        Darwin._exit(65)
                    }
                    artifactReplacementInjected = true
                    return
                }
                if phase == "artifact_posthash_mutate",
                   case let .afterArtifactHashBeforeGenerationEnd(name) = point,
                   name == "localization_trace.jsonl" {
                    guard !artifactPostHashMutationInjected else { return }
                    let artifact = generationRoot.appendingPathComponent(name)
                    guard chmod(generationRoot.path, mode_t(0o755)) == 0,
                          chmod(artifact.path, mode_t(0o644)) == 0 else {
                        Darwin._exit(78)
                    }
                    do {
                        let handle = try FileHandle(forWritingTo: artifact)
                        try handle.seek(toOffset: 0)
                        try handle.write(contentsOf: Data("TRACE\n".utf8))
                        try handle.truncate(atOffset: 6)
                        try handle.synchronize()
                        try handle.close()
                    } catch {
                        Darwin._exit(79)
                    }
                    guard chmod(artifact.path, mode_t(0o444)) == 0,
                          chmod(generationRoot.path, mode_t(0o555)) == 0 else {
                        Darwin._exit(69)
                    }
                    artifactPostHashMutationInjected = true
                    return
                }
                if phase == "rollback_after_authority" {
                    if case .afterTaskReferenceDurableBeforeCleanup = point {
                        throw SnapshotCrashWorkerFault.enterRollback
                    }
                    if case .afterPriorAuthorityRestoreBeforeGenerationCleanup
                            = point {
                        Darwin._exit(99)
                    }
                    return
                }
                if phase == "cleanup_replace",
                   case .afterCleanupRootPreparedBeforeRemoval = point {
                    let backup = taskRoot.appendingPathComponent(
                        "input_snapshot.backup", isDirectory: true)
                    let displaced = taskRoot.appendingPathComponent(
                        "input_snapshot.displaced", isDirectory: true)
                    guard renameatx_np(
                        AT_FDCWD, backup.path,
                        AT_FDCWD, displaced.path,
                        UInt32(RENAME_EXCL)) == 0 else {
                        Darwin._exit(41)
                    }
                    do {
                        try FileManager.default.createDirectory(
                            at: backup, withIntermediateDirectories: false)
                        try Data("replacement-must-survive\n".utf8).write(
                            to: backup.appendingPathComponent("marker.txt"))
                    } catch {
                        Darwin._exit(42)
                    }
                    Darwin._exit(103)
                }
                if (phase == "reference_postcheck_replace"
                        || phase == "reference_postcheck_appear"
                        || phase == "reference_swap_postrename_replace"),
                   case .afterTaskReferenceAuthorityRecheckBeforeInstall = point {
                    let authority = taskRoot.appendingPathComponent(
                        "input_manifest.json")
                    if phase == "reference_postcheck_replace"
                        || phase == "reference_swap_postrename_replace" {
                        let displaced = taskRoot.appendingPathComponent(
                            "input_manifest.displaced-postcheck-test")
                        guard renameatx_np(
                            AT_FDCWD, authority.path,
                            AT_FDCWD, displaced.path,
                            UInt32(RENAME_EXCL)) == 0 else {
                            Darwin._exit(46)
                        }
                    }
                    do {
                        try postcheckAuthorityPayload.write(to: authority)
                        guard chmod(authority.path, mode_t(0o444)) == 0 else {
                            Darwin._exit(47)
                        }
                    } catch {
                        Darwin._exit(48)
                    }
                    return
                }
                if phase == "reference_swap_postrename_replace",
                   case .afterTaskReferenceRenameBeforePostcheck = point {
                    Darwin._exit(107)
                }
                if phase == "first_clear_postcheck_appear"
                    || phase == "first_clear_postrename_crash_appear"
                    || phase == "first_clear_postrename" {
                    if case .afterTaskReferenceDurableBeforeCleanup = point {
                        throw SnapshotCrashWorkerFault.enterRollback
                    }
                    if (phase == "first_clear_postcheck_appear"
                            || phase == "first_clear_postrename_crash_appear"),
                       case .afterTaskReferenceAuthorityRecheckBeforeClear = point {
                        let authority = taskRoot.appendingPathComponent(
                            "input_manifest.json")
                        let displaced = taskRoot.appendingPathComponent(
                            "input_manifest.displaced-clear-postcheck-test")
                        guard renameatx_np(
                            AT_FDCWD, authority.path,
                            AT_FDCWD, displaced.path,
                            UInt32(RENAME_EXCL)) == 0 else {
                            Darwin._exit(49)
                        }
                        do {
                            try postcheckAuthorityPayload.write(to: authority)
                            guard chmod(authority.path, mode_t(0o444)) == 0 else {
                                Darwin._exit(50)
                            }
                        } catch {
                            Darwin._exit(51)
                        }
                        return
                    }
                    if phase == "first_clear_postrename_crash_appear",
                       case .afterTaskReferenceClearRenameBeforePostcheck = point {
                        Darwin._exit(108)
                    }
                    if phase == "first_clear_postrename",
                       case .afterTaskReferenceClearRenameBeforePostcheck = point {
                        Darwin._exit(112)
                    }
                }
                if (phase == "intent_removal_replace"
                        || phase == "intent_removal_postrename_crash_replace"),
                   case .afterTransactionIntentAuthorityRecheckBeforeRemoval = point {
                    guard !intentRemovalReplacementInjected else { return }
                    let intent = taskRoot.appendingPathComponent(
                        SessionSnapshotTransaction.transactionIntentFileName)
                    let displaced = taskRoot.appendingPathComponent(
                        "input_snapshot.transaction.displaced-postcheck-test")
                    guard renameatx_np(
                        AT_FDCWD, intent.path,
                        AT_FDCWD, displaced.path,
                        UInt32(RENAME_EXCL)) == 0 else {
                        Darwin._exit(52)
                    }
                    do {
                        try unrelatedIntentPayload.write(to: intent)
                        guard chmod(intent.path, mode_t(0o444)) == 0 else {
                            Darwin._exit(53)
                        }
                    } catch {
                        Darwin._exit(54)
                    }
                    intentRemovalReplacementInjected = true
                    return
                }
                if phase == "intent_removal_postrename_crash_replace",
                   case .afterTransactionIntentRemovalRenameBeforePostcheck = point {
                    Darwin._exit(109)
                }
                if phase == "transaction_unbound_temp_replace",
                   case .afterTransactionIntentCreationBeforeIdentityBind = point {
                    let names = try FileManager.default.contentsOfDirectory(
                        atPath: taskRoot.path).filter {
                            $0.hasPrefix(
                                SessionSnapshotTransaction
                                    .transactionIntentCreationPrefix)
                        }
                    guard names.count == 1 else { Darwin._exit(70) }
                    let temporary = taskRoot.appendingPathComponent(names[0])
                    let displaced = taskRoot.appendingPathComponent(
                        "input_snapshot.transaction.unbound-displaced-test")
                    guard renameatx_np(
                        AT_FDCWD, temporary.path,
                        AT_FDCWD, displaced.path,
                        UInt32(RENAME_EXCL)) == 0 else {
                        Darwin._exit(71)
                    }
                    do {
                        try Data("unrelated-unbound-intent\n".utf8).write(
                            to: temporary)
                        guard chmod(temporary.path, mode_t(0o600)) == 0 else {
                            Darwin._exit(72)
                        }
                    } catch {
                        Darwin._exit(73)
                    }
                    Darwin._exit(110)
                }
                if phase == "task_unbound_temp_replace",
                   case .afterTaskReferenceCreationBeforeIdentityBind = point {
                    let names = try FileManager.default.contentsOfDirectory(
                        atPath: taskRoot.path).filter {
                            $0.hasPrefix(
                                SessionSnapshotTransaction
                                    .taskManifestCreationPrefix)
                        }
                    guard names.count == 1 else { Darwin._exit(74) }
                    let temporary = taskRoot.appendingPathComponent(names[0])
                    let displaced = taskRoot.appendingPathComponent(
                        "input_manifest.unbound-displaced-test")
                    guard renameatx_np(
                        AT_FDCWD, temporary.path,
                        AT_FDCWD, displaced.path,
                        UInt32(RENAME_EXCL)) == 0 else {
                        Darwin._exit(75)
                    }
                    do {
                        try Data("unrelated-unbound-task-reference\n".utf8).write(
                            to: temporary)
                        guard chmod(temporary.path, mode_t(0o600)) == 0 else {
                            Darwin._exit(76)
                        }
                    } catch {
                        Darwin._exit(77)
                    }
                    Darwin._exit(111)
                }
                if (phase == "reference_replace" || phase == "reference_appear"),
                   case .afterTaskReferenceAuthorityReadBeforeInstall = point {
                    let authority = taskRoot.appendingPathComponent(
                        "input_manifest.json")
                    let displaced = taskRoot.appendingPathComponent(
                        "input_manifest.displaced-by-test")
                    if FileManager.default.fileExists(atPath: authority.path) {
                        guard renameatx_np(
                            AT_FDCWD, authority.path,
                            AT_FDCWD, displaced.path,
                            UInt32(RENAME_EXCL)) == 0 else {
                            Darwin._exit(43)
                        }
                    }
                    do {
                        try Data("{\"unrelated\":true}\n".utf8).write(
                            to: authority)
                        guard chmod(authority.path, mode_t(0o444)) == 0 else {
                            Darwin._exit(44)
                        }
                    } catch {
                        Darwin._exit(45)
                    }
                    return
                }
                switch (phase, point) {
                case ("after_intent_temp",
                      .afterTransactionIntentTemporaryFsyncBeforeRename):
                    Darwin._exit(90)
                case ("after_intent_rename",
                      .afterTransactionIntentRenameBeforeParentFsync):
                    Darwin._exit(91)
                case ("old_thaw",
                      .afterPreviousSnapshotThawBeforeBackupRename):
                    Darwin._exit(92)
                case ("old_rename",
                      .afterPreviousSnapshotRenameBeforeFreeze):
                    Darwin._exit(101)
                case ("old_freeze",
                      .afterPreviousSnapshotFreezeBeforeParentFsync):
                    Darwin._exit(102)
                case ("new_rename", .afterSnapshotRenameBeforeFreeze):
                    Darwin._exit(93)
                case ("new_freeze", .afterSnapshotFreezeBeforeParentFsync):
                    Darwin._exit(94)
                case ("after_install", .afterSnapshotInstall):
                    Darwin._exit(95)
                case ("reference_temp",
                      .afterTaskReferenceTemporaryFsyncBeforeRename):
                    Darwin._exit(100)
                case ("reference_swap_postrename",
                      .afterTaskReferenceRenameBeforePostcheck):
                    Darwin._exit(106)
                case ("reference_rename", .beforeTaskReferenceFsync):
                    Darwin._exit(96)
                case ("reference_durable",
                      .afterTaskReferenceDurableBeforeCleanup):
                    Darwin._exit(97)
                case ("recovery_core_postintent_crash",
                      .afterRecoveryCoreBeforeReturn):
                    Darwin._exit(114)
                case ("cleanup_root",
                      .afterCleanupRootPreparedBeforeRemoval):
                    Darwin._exit(98)
                case ("cleanup_child", .afterCleanupChildRemoval):
                    Darwin._exit(104)
                case ("intent_remove_postrename",
                      .afterTransactionIntentRemovalRenameBeforePostcheck):
                    Darwin._exit(113)
                default:
                    break
                }
            }
        }
        let snapshot = try SessionSnapshotTransaction.snapshot(
            finalizedSession: session,
            sourceDatabase: session.appendingPathComponent("source.db"),
            taskRoot: taskRoot,
            eligibility: eligibility)
        SessionSnapshotTransaction.faultInjector = nil
        if phase == "intent_removal_replace" {
            guard intentRemovalReplacementInjected else {
                FileHandle.standardError.write(
                    Data("snapshot intent-removal replacement missed fault point\n".utf8))
                exit(38)
            }
            print("snapshot intent-removal replacement injected")
            exit(105)
        }
        if phase != "baseline" && phase != "recover" {
            FileHandle.standardError.write(
                Data("snapshot crash worker missed fault point\n".utf8))
            exit(38)
        }
        try SessionSnapshotTransaction.revalidateSnapshot(
            snapshot.snapshotDirectory)
        guard (try permissions(snapshot.snapshotDirectory)) == 0o555,
              (try permissions(taskRoot.appendingPathComponent(
                "input_manifest.json"))) == 0o444 else {
            throw NSError(
                domain: "SnapshotCrashWorker", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "snapshot recovery modes are not 0555/0444"])
        }
        let forbidden = [
            "input_snapshot.backup",
            "input_snapshot.staging",
            SessionSnapshotTransaction.transactionIntentFileName,
        ]
        for name in forbidden {
            guard !FileManager.default.fileExists(
                    atPath: taskRoot.appendingPathComponent(name).path) else {
                throw NSError(
                    domain: "SnapshotCrashWorker", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "snapshot recovery left \(name)"])
            }
        }
        let temporaryIntents = try FileManager.default.contentsOfDirectory(
            atPath: taskRoot.path).filter {
                $0.hasPrefix(
                    SessionSnapshotTransaction.transactionIntentTemporaryPrefix)
                    || ($0.hasPrefix(
                        SessionSnapshotTransaction.taskManifestTemporaryPrefix)
                        && $0.hasSuffix(
                            SessionSnapshotTransaction.taskManifestTemporarySuffix))
            }
        guard temporaryIntents.isEmpty else {
            throw NSError(
                domain: "SnapshotCrashWorker", code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    "snapshot recovery left intent temporary"])
        }
        print("snapshot \(phase) passed")
        exit(0)
    } catch {
        SessionSnapshotTransaction.faultInjector = nil
        FileHandle.standardError.write(
            Data("snapshot crash worker failed: \(error)\n".utf8))
        exit(39)
    }
}

// RC Result publication crash worker. Production fault points call process
// exit directly so restart recovery is exercised without Swift stack
// unwinding, catch or defer cleanup.
func runResultPublicationCrashWorkerIfRequested() {
    guard CommandLine.arguments.count == 5,
          CommandLine.arguments[1] == "--result-publication-crash-worker"
    else { return }
    let resultsRoot = URL(
        fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let phase = CommandLine.arguments[3]
    let recoveryEntry = CommandLine.arguments[4]
    let taskID = "result-crash-task"
    let resultID = "result-crash-final"
    let workbookName = "result-crash.xlsx"
    let coordinationRoot = resultsRoot.deletingLastPathComponent()
    let lockAttemptMarker = coordinationRoot.appendingPathComponent(
        ".\(resultsRoot.lastPathComponent).recovery-lock-attempt")
    let lockAcquiredMarker = coordinationRoot.appendingPathComponent(
        ".\(resultsRoot.lastPathComponent).recovery-lock-acquired")
    let publisherReleaseMarker = coordinationRoot.appendingPathComponent(
        ".\(resultsRoot.lastPathComponent).release-publisher")
    MobileResultLibrary.rootOverride = resultsRoot
    do {
        if phase.hasPrefix("primitive_") {
            try FileManager.default.createDirectory(
                at: resultsRoot, withIntermediateDirectories: true)
            let source = resultsRoot.appendingPathComponent(
                "publication-source", isDirectory: true)
            let destination = resultsRoot.appendingPathComponent(
                "publication-destination", isDirectory: true)
            let replacement = resultsRoot.appendingPathComponent(
                "publication-replacement", isDirectory: true)
            let displaced = resultsRoot.appendingPathComponent(
                "publication-displaced", isDirectory: true)
            try FileManager.default.createDirectory(
                at: source, withIntermediateDirectories: false)
            let payload = source.appendingPathComponent("marker.txt")
            try Data("publication-original\n".utf8).write(to: payload)
            guard chmod(payload.path, mode_t(0o444)) == 0 else {
                Darwin._exit(120)
            }
            let sourceIdentity = try ImmutableDirectoryPublication.identity(
                of: source,
                allowedModes: [ImmutableDirectoryPublication.renameableMode])

            if phase == "primitive_publication_source_reappear" {
                var rejected = false
                do {
                    try ImmutableDirectoryPublication.publish(
                        source: source,
                        destination: destination,
                        expectedIdentity: sourceIdentity,
                        afterFreezeBeforeParentSync: {
                            try FileManager.default.createDirectory(
                                at: source, withIntermediateDirectories: false)
                            try Data("replacement-source-must-survive\n".utf8)
                                .write(to: source.appendingPathComponent("evidence.txt"))
                        })
                } catch {
                    rejected = true
                }
                guard rejected,
                      FileManager.default.fileExists(
                        atPath: source.appendingPathComponent("evidence.txt").path),
                      FileManager.default.fileExists(atPath: destination.path) else {
                    Darwin._exit(121)
                }
                print("result primitive source-reappear passed")
                exit(0)
            }

            try FileManager.default.copyItem(at: source, to: replacement)
            guard chmod(replacement.path, mode_t(0o555)) == 0 else {
                Darwin._exit(122)
            }
            func replacePublishedDestination() {
                guard chmod(destination.path, mode_t(0o755)) == 0,
                      chmod(replacement.path, mode_t(0o755)) == 0,
                      renameatx_np(
                        AT_FDCWD, destination.path,
                        AT_FDCWD, displaced.path,
                        UInt32(RENAME_EXCL)) == 0,
                      renameatx_np(
                        AT_FDCWD, replacement.path,
                        AT_FDCWD, destination.path,
                        UInt32(RENAME_EXCL)) == 0,
                      chmod(displaced.path, mode_t(0o555)) == 0,
                      chmod(destination.path, mode_t(0o555)) == 0 else {
                    Darwin._exit(123)
                }
            }

            if phase == "primitive_publication_destination_replace" {
                var rejected = false
                do {
                    try ImmutableDirectoryPublication.publish(
                        source: source,
                        destination: destination,
                        expectedIdentity: sourceIdentity,
                        afterFreezeBeforeParentSync: replacePublishedDestination)
                } catch {
                    rejected = true
                }
                let replacementIdentity = try ImmutableDirectoryPublication.identity(
                    of: destination,
                    allowedModes: [ImmutableDirectoryPublication.immutableMode])
                guard rejected,
                      replacementIdentity != sourceIdentity,
                      FileManager.default.fileExists(atPath: displaced.path) else {
                    Darwin._exit(124)
                }
                print("result primitive destination-replace passed")
                exit(0)
            }

            if phase == "primitive_interrupted_destination_replace" {
                guard chmod(source.path, mode_t(0o755)) == 0,
                      renameatx_np(
                        AT_FDCWD, source.path,
                        AT_FDCWD, destination.path,
                        UInt32(RENAME_EXCL)) == 0 else {
                    Darwin._exit(125)
                }
                var rejected = false
                do {
                    try ImmutableDirectoryPublication.freezeInterruptedDestination(
                        destination,
                        expectedIdentity: sourceIdentity,
                        afterFreezeBeforeParentSync: replacePublishedDestination)
                } catch {
                    rejected = true
                }
                let replacementIdentity = try ImmutableDirectoryPublication.identity(
                    of: destination,
                    allowedModes: [ImmutableDirectoryPublication.immutableMode])
                guard rejected,
                      replacementIdentity != sourceIdentity,
                      FileManager.default.fileExists(atPath: displaced.path) else {
                    Darwin._exit(126)
                }
                print("result primitive interrupted-replace passed")
                exit(0)
            }
            Darwin._exit(127)
        }

        if phase.hasPrefix("verify_") {
            let deterministicReadPhases: Set<String> = [
                "verify_artifact_posthash_mutate",
                "verify_manifest_postread_replace",
                "verify_receipt_postread_replace",
                "verify_result_root_final_sweep_replace",
            ]
            let payloadBytes = 64
            let staging = try MobileResultLibrary.stagingDirectory(
                taskID: taskID, resultID: resultID)
            try Data(repeating: 0x61, count: payloadBytes).write(
                to: staging.appendingPathComponent("payload.json"))
            try Data("xlsx-verification\n".utf8).write(
                to: staging.appendingPathComponent(workbookName))
            _ = try MobileResultLibrary.commit(
                resultID: resultID,
                taskID: taskID,
                stagingDirectory: staging,
                packageFiles: ["payload.json"],
                workbookFilename: workbookName)
            let final = try MobileResultLibrary.resultDirectory(resultID: resultID)
            let payloadURL = final.appendingPathComponent("payload.json")
            let manifestURL = final.appendingPathComponent(
                MobileResultLibrary.manifestFileName)
            let receiptURL = final.appendingPathComponent(
                MobileResultLibrary.commitReceiptFileName)
            let displacedEvidence = resultsRoot.appendingPathComponent(
                "verification-displaced-evidence")
            let replacementRoot = resultsRoot.appendingPathComponent(
                "verification-root-replacement", isDirectory: true)
            let displacedRoot = resultsRoot.appendingPathComponent(
                "verification-root-displaced", isDirectory: true)
            if phase == "verify_result_root_final_sweep_replace" {
                try FileManager.default.copyItem(at: final, to: replacementRoot)
                guard chmod(replacementRoot.path, mode_t(0o555)) == 0 else {
                    Darwin._exit(128)
                }
            }

            let mutationFinished = DispatchSemaphore(value: 0)
            let mutationLock = NSLock()
            var mutationError: Error?
            var mutationScheduled = false
            func recordMutationError(_ error: Error) {
                mutationLock.lock()
                mutationError = error
                mutationLock.unlock()
            }
            func mutateVerificationFixture() {
                do {
                    switch phase {
                    case "verify_artifact_symlink":
                        guard chmod(final.path, mode_t(0o755)) == 0,
                              renameatx_np(
                                AT_FDCWD, payloadURL.path,
                                AT_FDCWD, displacedEvidence.path,
                                UInt32(RENAME_EXCL)) == 0,
                              Darwin.symlink(
                                displacedEvidence.path, payloadURL.path) == 0,
                              chmod(final.path, mode_t(0o555)) == 0 else {
                            throw NSError(domain: "ResultVerification", code: 1)
                        }
                    case "verify_artifact_hardlink":
                        guard chmod(final.path, mode_t(0o755)) == 0,
                              renameatx_np(
                                AT_FDCWD, payloadURL.path,
                                AT_FDCWD, displacedEvidence.path,
                                UInt32(RENAME_EXCL)) == 0,
                              Darwin.link(
                                displacedEvidence.path, payloadURL.path) == 0,
                              chmod(final.path, mode_t(0o555)) == 0 else {
                            throw NSError(domain: "ResultVerification", code: 2)
                        }
                    case "verify_artifact_mode_clone":
                        guard chmod(final.path, mode_t(0o755)) == 0,
                              renameatx_np(
                                AT_FDCWD, payloadURL.path,
                                AT_FDCWD, displacedEvidence.path,
                                UInt32(RENAME_EXCL)) == 0 else {
                            throw NSError(domain: "ResultVerification", code: 3)
                        }
                        try FileManager.default.copyItem(
                            at: displacedEvidence, to: payloadURL)
                        guard chmod(payloadURL.path, mode_t(0o644)) == 0,
                              chmod(final.path, mode_t(0o555)) == 0 else {
                            throw NSError(domain: "ResultVerification", code: 4)
                        }
                    case "verify_artifact_posthash_mutate":
                        guard chmod(final.path, mode_t(0o755)) == 0,
                              chmod(payloadURL.path, mode_t(0o644)) == 0 else {
                            throw NSError(domain: "ResultVerification", code: 5)
                        }
                        let descriptor = open(
                            payloadURL.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                        guard descriptor >= 0 else {
                            throw NSError(domain: "ResultVerification", code: 6)
                        }
                        var byte: UInt8 = 0x62
                        let wrote = Darwin.pwrite(descriptor, &byte, 1, 0)
                        let synced = fsync(descriptor)
                        _ = close(descriptor)
                        guard wrote == 1, synced == 0,
                              chmod(payloadURL.path, mode_t(0o444)) == 0,
                              chmod(final.path, mode_t(0o555)) == 0 else {
                            throw NSError(domain: "ResultVerification", code: 7)
                        }
                    case "verify_manifest_postread_replace",
                         "verify_receipt_postread_replace":
                        let authority = phase == "verify_manifest_postread_replace"
                            ? manifestURL : receiptURL
                        guard chmod(final.path, mode_t(0o755)) == 0,
                              renameatx_np(
                                AT_FDCWD, authority.path,
                                AT_FDCWD, displacedEvidence.path,
                                UInt32(RENAME_EXCL)) == 0 else {
                            throw NSError(domain: "ResultVerification", code: 8)
                        }
                        try FileManager.default.copyItem(
                            at: displacedEvidence, to: authority)
                        guard chmod(authority.path, mode_t(0o444)) == 0,
                              chmod(final.path, mode_t(0o555)) == 0 else {
                            throw NSError(domain: "ResultVerification", code: 9)
                        }
                    case "verify_result_root_final_sweep_replace":
                        guard chmod(final.path, mode_t(0o755)) == 0,
                              chmod(replacementRoot.path, mode_t(0o755)) == 0,
                              renameatx_np(
                                AT_FDCWD, final.path,
                                AT_FDCWD, displacedRoot.path,
                                UInt32(RENAME_EXCL)) == 0,
                              renameatx_np(
                                AT_FDCWD, replacementRoot.path,
                                AT_FDCWD, final.path,
                                UInt32(RENAME_EXCL)) == 0,
                              chmod(displacedRoot.path, mode_t(0o555)) == 0,
                              chmod(final.path, mode_t(0o555)) == 0 else {
                            throw NSError(domain: "ResultVerification", code: 10)
                        }
                    default:
                        throw NSError(domain: "ResultVerification", code: 11)
                    }
                } catch {
                    recordMutationError(error)
                }
                mutationFinished.signal()
            }
            MobileResultLibrary.processLockAcquiredObserver = {
                guard !mutationScheduled else { return }
                guard !deterministicReadPhases.contains(phase) else { return }
                mutationScheduled = true
                mutateVerificationFixture()
            }
            MobileResultLibrary.resultReadVerificationObserver = { stage in
                guard !mutationScheduled else { return }
                let shouldMutate: Bool
                switch stage {
                case .artifactHashed(let name):
                    shouldMutate = phase == "verify_artifact_posthash_mutate"
                        && name == "payload.json"
                case .initialManifestAndReceiptBound:
                    shouldMutate = phase == "verify_manifest_postread_replace"
                        || phase == "verify_receipt_postread_replace"
                case .beforeFinalSweep:
                    shouldMutate =
                        phase == "verify_result_root_final_sweep_replace"
                }
                guard shouldMutate else { return }
                mutationScheduled = true
                mutateVerificationFixture()
            }
            var rejected = false
            do {
                _ = try MobileResultLibrary.readResult(resultID: resultID)
            } catch {
                rejected = true
            }
            MobileResultLibrary.processLockAcquiredObserver = nil
            MobileResultLibrary.resultReadVerificationObserver = nil
            guard mutationFinished.wait(timeout: .now() + 10.0) == .success else {
                Darwin._exit(129)
            }
            mutationLock.lock()
            let capturedMutationError = mutationError
            mutationLock.unlock()
            guard capturedMutationError == nil, rejected else {
                Darwin._exit(130)
            }
            if phase == "verify_artifact_posthash_mutate" {
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: payloadURL.path)
                guard (attributes[.size] as? NSNumber)?.intValue == payloadBytes else {
                    Darwin._exit(131)
                }
            }
            guard FileManager.default.fileExists(atPath: final.path) else {
                Darwin._exit(132)
            }
            print("result \(phase) rejected replacement")
            exit(0)
        }

        if !phase.hasPrefix("recover") {
            let staging = try MobileResultLibrary.stagingDirectory(
                taskID: taskID, resultID: resultID)
            try Data("{\"crash\":true}\n".utf8).write(
                to: staging.appendingPathComponent("payload.json"))
            try Data("xlsx-crash\n".utf8).write(
                to: staging.appendingPathComponent(workbookName))
            MobileResultLibrary.commitFaultInjector = { stage in
                switch (phase, stage) {
                case ("after_intent_temp",
                      .afterPublishIntentTemporaryFsyncBeforeRename):
                    Darwin._exit(80)
                case ("after_intent_rename",
                      .afterPublishIntentRenameBeforeParentFsync):
                    Darwin._exit(81)
                case ("hold_after_intent",
                      .afterPublishIntentDurableBeforeDirectoryRename):
                    let deadline = ProcessInfo.processInfo.systemUptime + 30.0
                    while !FileManager.default.fileExists(
                            atPath: publisherReleaseMarker.path),
                          ProcessInfo.processInfo.systemUptime < deadline {
                        usleep(10_000)
                    }
                    Darwin._exit(
                        FileManager.default.fileExists(
                            atPath: publisherReleaseMarker.path) ? 86 : 87)
                case ("after_directory_rename",
                      .afterDirectoryRenameBeforeFreeze):
                    Darwin._exit(82)
                case ("after_destination_fchmod",
                      .afterDestinationFchmodBeforeDirectoryFsync):
                    Darwin._exit(88)
                case ("after_destination_freeze",
                      .afterDestinationFreezeBeforeParentFsync):
                    Darwin._exit(83)
                case ("after_exact_read", .afterRename):
                    Darwin._exit(84)
                case ("after_parent_fsync", .afterParentFsync):
                    Darwin._exit(85)
                default:
                    break
                }
            }
            _ = try MobileResultLibrary.commit(
                resultID: resultID,
                taskID: taskID,
                stagingDirectory: staging,
                packageFiles: ["payload.json"],
                workbookFilename: workbookName)
            FileHandle.standardError.write(
                Data("result crash worker missed fault point\n".utf8))
            exit(28)
        }

        if phase == "recover_lock_probe" {
            MobileResultLibrary.processLockAttemptObserver = {
                guard FileManager.default.createFile(
                    atPath: lockAttemptMarker.path,
                    contents: Data("attempt\n".utf8)) else {
                    throw NSError(
                        domain: "ResultCrashWorker", code: 7,
                        userInfo: [NSLocalizedDescriptionKey:
                            "cannot publish lock-attempt marker"])
                }
            }
            MobileResultLibrary.processLockAcquiredObserver = {
                guard FileManager.default.createFile(
                    atPath: lockAcquiredMarker.path,
                    contents: Data("acquired\n".utf8)) else {
                    throw NSError(
                        domain: "ResultCrashWorker", code: 8,
                        userInfo: [NSLocalizedDescriptionKey:
                            "cannot publish lock-acquired marker"])
                }
            }
        }

        let final = try MobileResultLibrary.resultDirectory(resultID: resultID)
        let finalExistedBeforeRecovery = FileManager.default.fileExists(
            atPath: final.path)
        switch recoveryEntry {
        case "list":
            _ = MobileResultLibrary.listResults()
        case "read":
            if finalExistedBeforeRecovery {
                _ = try MobileResultLibrary.readResult(resultID: resultID)
            } else {
                _ = MobileResultLibrary.listResults()
            }
        case "committed":
            _ = try MobileResultLibrary.committedResult(
                taskID: taskID, expectedResultIDs: [resultID])
        case "cleanup":
            MobileResultLibrary.cleanupStaging(taskID: taskID)
        default:
            throw NSError(
                domain: "ResultCrashWorker", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unknown recovery entry"])
        }
        MobileResultLibrary.cleanupStaging(taskID: taskID)
        let visible = MobileResultLibrary.listResults()
        // `listResults()` and `cleanupStaging()` are intentionally
        // non-throwing for the app UI: recovery failures are represented by
        // an empty listing plus a diagnostic. The crash-worker process must
        // promote every recovery diagnostic to a failing exit so the
        // executable contract can distinguish fail-closed recovery from an
        // ordinary empty library. Check after the final listing because an
        // earlier pass may first restore or quarantine unexpected authority,
        // and only the subsequent pass reports the durable failure state.
        let recoveryDiagnostics = MobileResultLibrary.lastListingDiagnostics()
        if !recoveryDiagnostics.isEmpty {
            throw NSError(
                domain: "ResultCrashWorker",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey:
                    "result recovery failed closed: "
                        + recoveryDiagnostics.joined(separator: "; ")])
        }
        let committed = FileManager.default.fileExists(atPath: final.path)
        if committed {
            let reopened = try MobileResultLibrary.readResult(resultID: resultID)
            guard reopened.resultID == resultID,
                  (try permissions(final)) == 0o555 else {
                throw NSError(
                    domain: "ResultCrashWorker", code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "recovered result is not exact immutable final"])
            }
            for name in [
                "payload.json", workbookName,
                MobileResultLibrary.manifestFileName,
                MobileResultLibrary.commitReceiptFileName,
            ] {
                guard (try permissions(final.appendingPathComponent(name)))
                        == 0o444 else {
                    throw NSError(
                        domain: "ResultCrashWorker", code: 3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "recovered result artifact is not 0444"])
                }
            }
            guard visible.count == 1 else {
                throw NSError(
                    domain: "ResultCrashWorker", code: 4,
                    userInfo: [NSLocalizedDescriptionKey:
                        "committed crash result is not uniquely listed"])
            }
        } else if !visible.isEmpty {
            throw NSError(
                domain: "ResultCrashWorker", code: 5,
                userInfo: [NSLocalizedDescriptionKey:
                    "pre-rename crash exposed a result"])
        }
        let internalNames = try FileManager.default.contentsOfDirectory(
            atPath: resultsRoot.path).filter {
                $0.contains(".publish-intent")
                    || $0.hasPrefix(".result-publish-intent-tmp-")
                    || $0.hasPrefix(".result-staging-")
            }
        guard internalNames.isEmpty else {
            throw NSError(
                domain: "ResultCrashWorker", code: 6,
                userInfo: [NSLocalizedDescriptionKey:
                    "result recovery left transaction artifacts: \(internalNames)"])
        }
        print("result recovered committed=\(committed ? 1 : 0)")
        MobileResultLibrary.processLockAttemptObserver = nil
        MobileResultLibrary.processLockAcquiredObserver = nil
        exit(0)
    } catch {
        MobileResultLibrary.processLockAttemptObserver = nil
        MobileResultLibrary.processLockAcquiredObserver = nil
        FileHandle.standardError.write(
            Data("result crash worker failed: \(error)\n".utf8))
        exit(29)
    }
}

// RC-HIGH Map Library quarantine crash worker. The Python host launches this
// mode as a separate process and the production fault injector calls `_exit`
// at seven durable thaw/rename/freeze/fsync boundaries. A second process enters through
// list/map/rebuild and proves startup reconciliation against the same real
// filesystem tree.
func runMapQuarantineCrashWorkerIfRequested() {
    guard CommandLine.arguments.count == 5,
          CommandLine.arguments[1] == "--map-quarantine-crash-worker"
    else { return }
    let mapRoot = URL(
        fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let phase = CommandLine.arguments[3]
    let entry = CommandLine.arguments[4]
    let priorMapID = "crash-recovery-map"
    let packageSHA = String(repeating: "c", count: 64)
    MobileMapLibrary.rootOverride = mapRoot
    do {
        let source = try MobileMapLibrary.packageDirectory(
            priorMapID: priorMapID, packageSHA: packageSHA)
        let coordinationRoot = mapRoot.deletingLastPathComponent()
        let quarantineRoot = mapRoot
            .appendingPathComponent("quarantine", isDirectory: true)
            .appendingPathComponent(priorMapID, isDirectory: true)

        func rollbackDiagnosticTemporary() throws -> URL {
            let names = try FileManager.default.contentsOfDirectory(
                atPath: quarantineRoot.path)
            guard let name = names.first(where: {
                $0.hasPrefix(".") && $0.hasSuffix(".diagnostic.tmp")
            }) else {
                throw NSError(
                    domain: "MapQuarantineCrashWorker", code: 10,
                    userInfo: [NSLocalizedDescriptionKey:
                        "missing rollback diagnostic temporary"])
            }
            return quarantineRoot.appendingPathComponent(name)
        }

        func publishRemovalTombstone() throws -> URL {
            let temporary = try rollbackDiagnosticTemporary()
            let suffix = ".diagnostic.tmp"
            let transactionID = String(
                temporary.lastPathComponent.dropFirst().dropLast(suffix.count))
            let removal = quarantineRoot.appendingPathComponent(
                ".\(transactionID).diagnostic.removing")
            guard renameatx_np(
                AT_FDCWD, temporary.path,
                AT_FDCWD, removal.path,
                UInt32(RENAME_EXCL)) == 0 else {
                throw NSError(
                    domain: "MapQuarantineCrashWorker", code: 11,
                    userInfo: [NSLocalizedDescriptionKey:
                        "cannot publish diagnostic removal tombstone"])
            }
            try MobileMapLibrary.syncDirectory(quarantineRoot)
            return removal
        }

        if !phase.hasPrefix("recover") {
            try FileManager.default.createDirectory(
                at: source, withIntermediateDirectories: true)
            let invalidManifest = Data("{}\n".utf8)
            let manifestURL = source.appendingPathComponent("manifest.json")
            try invalidManifest.write(to: manifestURL)
            let payloadURL = source.appendingPathComponent("payload.bin")
            if phase == "after_diagnostic_large" {
                try Data(repeating: 0x71, count: 128 * 1024 * 1024)
                    .write(to: payloadURL)
            } else {
                try Data("crash-window-payload\n".utf8).write(to: payloadURL)
            }
            try MobileMapLibrary.syncFile(manifestURL)
            try MobileMapLibrary.syncFile(payloadURL)
            try MobileMapLibrary.syncDirectory(source)
            try MobileMapLibrary.syncDirectory(source.deletingLastPathComponent())
            try MobileMapLibrary.syncDirectory(try MobileMapLibrary.packagesRoot())
            guard chmod(source.path, mode_t(0o555)) == 0 else {
                throw NSError(
                    domain: "MapQuarantineCrashWorker", code: 7,
                    userInfo: [NSLocalizedDescriptionKey:
                        "cannot freeze source fixture before quarantine"])
            }
            try MobileMapLibrary.syncDirectory(source)

            let registry: [String: Any] = [
                "format": "MarketScannerMapRegistry",
                "version": MobileMapLibrary.currentRegistryVersion,
                "generation": 1,
                "map_count": 1,
                "maps": [[
                    "prior_map_id": priorMapID,
                    "name": "Crash Recovery Map",
                    "package_sha256": packageSHA,
                    "package_directory": "\(priorMapID)/\(packageSHA)",
                    "floor_count": 1,
                    "element_count": 0,
                    "compiled_at_utc": 1.0,
                    "compiler_version": "crash-fixture",
                    "canonical_source_sha256": String(repeating: "d", count: 64),
                ]],
            ]
            let registryURL = try MobileMapLibrary.registryURL()
            try (try CanonicalJSONEncoder.encode(registry)).write(to: registryURL)
            try MobileMapLibrary.syncFile(registryURL)
            try MobileMapLibrary.syncDirectory(mapRoot)

            MobileMapLibrary.quarantineFaultInjector = { point in
                switch (phase, point) {
                case ("after_source_thaw", .afterSourceThawBeforePayloadRename):
                    Darwin._exit(70)
                case ("after_payload", .afterPayloadRename): Darwin._exit(71)
                case ("after_diagnostic_placement",
                      .afterDiagnosticPlacementBeforeFreeze):
                    Darwin._exit(76)
                case ("after_diagnostic", .afterDiagnosticPlacementAndFreeze):
                    Darwin._exit(72)
                case ("after_diagnostic_large",
                      .afterDiagnosticPlacementAndFreeze):
                    Darwin._exit(89)
                case ("after_publish_rename", .afterPublishRenameBeforeFreeze):
                    Darwin._exit(74)
                case ("after_publish_freeze", .afterPublishFreezeBeforeParentSync):
                    Darwin._exit(75)
                case ("after_publish", .afterPublishRenameAndParentSync):
                    Darwin._exit(73)
                case ("replace_map_root_after_open",
                      .afterSourceThawBeforePayloadRename):
                    let displaced = coordinationRoot.appendingPathComponent(
                        "map-root-open-displaced", isDirectory: true)
                    try FileManager.default.copyItem(
                        at: mapRoot, to: displaced)
                    guard renameatx_np(
                        AT_FDCWD, mapRoot.path,
                        AT_FDCWD, displaced.path,
                        UInt32(RENAME_SWAP)) == 0 else {
                        // The worker's outer catch intentionally maps
                        // production rejection to 19.  Use a distinct exit
                        // for fixture mutation failure so the host test cannot
                        // mistake a failed swap for the expected rejection.
                        Darwin._exit(95)
                    }
                case ("replace_map_lock_after_acquire",
                      .afterSourceThawBeforePayloadRename):
                    let lock = mapRoot.appendingPathComponent(
                        ".map-library.lock")
                    let displaced = coordinationRoot.appendingPathComponent(
                        "map-lock-open-displaced")
                    guard renameatx_np(
                        AT_FDCWD, lock.path,
                        AT_FDCWD, displaced.path,
                        UInt32(RENAME_EXCL)) == 0 else {
                        throw NSError(
                            domain: "MapQuarantineCrashWorker", code: 14,
                            userInfo: [NSLocalizedDescriptionKey:
                                "cannot displace acquired map lock"])
                    }
                    let replacementDescriptor = Darwin.open(
                        lock.path,
                        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                        mode_t(0o600))
                    guard replacementDescriptor >= 0 else {
                        throw NSError(
                            domain: "MapQuarantineCrashWorker", code: 15,
                            userInfo: [NSLocalizedDescriptionKey:
                                "cannot create replacement map lock"])
                    }
                    let replacementSynced = fsync(replacementDescriptor)
                    _ = close(replacementDescriptor)
                    guard replacementSynced == 0 else {
                        throw NSError(
                            domain: "MapQuarantineCrashWorker", code: 16,
                            userInfo: [NSLocalizedDescriptionKey:
                                "cannot sync replacement map lock"])
                    }
                default: break
                }
            }
            try MobileMapLibrary.rebuildRegistry()
            FileHandle.standardError.write(
                Data("crash worker did not reach requested fault point\n".utf8))
            exit(18)
        }

        if phase == "recover_after_source_restore" {
            MobileMapLibrary.quarantineFaultInjector = { point in
                guard case .afterRollbackSourceModeRestoreBeforeIntentRemoval = point else {
                    return
                }
                Darwin._exit(77)
            }
        }
        if phase == "recover_replace_after_mode_restore" {
            let displaced = source.deletingLastPathComponent()
                .appendingPathComponent("displaced-\(packageSHA)", isDirectory: true)
            try FileManager.default.copyItem(at: source, to: displaced)
            guard chmod(displaced.path, mode_t(0o755)) == 0 else {
                throw NSError(
                    domain: "MapQuarantineCrashWorker", code: 8,
                    userInfo: [NSLocalizedDescriptionKey:
                        "cannot prepare writable replacement source"])
            }
            MobileMapLibrary.quarantineFaultInjector = { point in
                guard case .afterRollbackSourceModeRestoreBeforeIntentRemoval = point else {
                    return
                }
                // Exchange the diagnostic-bound source and its byte-identical
                // clone atomically.  A two-rename replacement has an
                // avoidable missing-path window and can fail between renames
                // under hosted APFS scheduling; RENAME_SWAP leaves both
                // identities present for the subsequent assertions.
                guard renameatx_np(
                    AT_FDCWD, source.path,
                    AT_FDCWD, displaced.path,
                    UInt32(RENAME_SWAP)) == 0 else {
                    throw NSError(
                        domain: "MapQuarantineCrashWorker", code: 9,
                        userInfo: [NSLocalizedDescriptionKey:
                            "cannot replace source during recovery"])
                }
            }
        }
        if phase == "recover_after_tombstone_rename" {
            MobileMapLibrary.quarantineFaultInjector = { point in
                guard case .afterRollbackSourceModeRestoreBeforeIntentRemoval = point
                else { return }
                _ = try publishRemovalTombstone()
                Darwin._exit(78)
            }
        }
        if phase == "recover_replace_source_after_tombstone" {
            let sourceParent = source.deletingLastPathComponent()
            let replacement = sourceParent.appendingPathComponent(
                "tombstone-original-\(packageSHA)", isDirectory: true)
            try FileManager.default.copyItem(at: source, to: replacement)
            guard chmod(replacement.path, mode_t(0o755)) == 0 else {
                throw NSError(
                    domain: "MapQuarantineCrashWorker", code: 17,
                    userInfo: [NSLocalizedDescriptionKey:
                        "cannot prepare tombstone source replacement"])
            }
            MobileMapLibrary.quarantineFaultInjector = { point in
                guard case .afterRollbackSourceModeRestoreBeforeIntentRemoval = point
                else { return }
                _ = try publishRemovalTombstone()
                // Atomically replace the authoritative pathname with the
                // byte-identical clone. The original inode moves directly
                // to the audit-evidence path, avoiding a two-rename window
                // whose second RENAME_EXCL was scheduler/filesystem fragile
                // on hosted APFS runners.
                guard renameatx_np(
                    AT_FDCWD, source.path,
                    AT_FDCWD, replacement.path,
                    UInt32(RENAME_SWAP)) == 0 else {
                    Darwin._exit(91)
                }
                Darwin._exit(79)
            }
        }
        if phase == "recover_after_tombstone_unlink_before_fsync" {
            MobileMapLibrary.quarantineFaultInjector = { point in
                guard case .afterRollbackSourceModeRestoreBeforeIntentRemoval = point
                else { return }
                let removal = try publishRemovalTombstone()
                guard Darwin.unlink(removal.path) == 0 else {
                    Darwin._exit(92)
                }
                // Deliberately omit the quarantine-root fsync. This is the
                // exact process-death window after unlink and before its
                // directory durability barrier.
                Darwin._exit(80)
            }
        }

        if phase == "recover_replace_pending_after_open"
                || phase == "recover_replace_embedded_after_read" {
            let pendingName = try FileManager.default.contentsOfDirectory(
                atPath: quarantineRoot.path).first(where: {
                    $0.hasPrefix(".") && $0.hasSuffix(".pending")
                })
            guard let pendingName else {
                throw NSError(
                    domain: "MapQuarantineCrashWorker", code: 18,
                    userInfo: [NSLocalizedDescriptionKey:
                        "missing pending fixture for delayed replacement"])
            }
            let pending = quarantineRoot.appendingPathComponent(
                pendingName, isDirectory: true)
            let displaced = coordinationRoot.appendingPathComponent(
                phase == "recover_replace_pending_after_open"
                    ? "pending-root-open-original"
                    : "embedded-diagnostic-original")
            if phase == "recover_replace_pending_after_open" {
                try FileManager.default.copyItem(at: pending, to: displaced)
            } else {
                let diagnostic = pending.appendingPathComponent(
                    MobileMapLibrary.quarantineDiagnosticFileName)
                try FileManager.default.copyItem(at: diagnostic, to: displaced)
                guard chmod(displaced.path, mode_t(0o444)) == 0 else {
                    throw NSError(
                        domain: "MapQuarantineCrashWorker", code: 19,
                        userInfo: [NSLocalizedDescriptionKey:
                            "cannot freeze replacement embedded diagnostic"])
                }
            }

            var mutationPerformed = false
            MobileMapLibrary.quarantineReadVerificationObserver = { point in
                guard !mutationPerformed else { return }
                if phase == "recover_replace_pending_after_open" {
                    guard case .payloadFileOpened = point else { return }
                    guard renameatx_np(
                        AT_FDCWD, pending.path,
                        AT_FDCWD, displaced.path,
                        UInt32(RENAME_SWAP)) == 0 else {
                        throw NSError(
                            domain: "MapQuarantineCrashWorker", code: 20,
                            userInfo: [NSLocalizedDescriptionKey:
                                "cannot replace opened pending root"])
                    }
                } else {
                    guard case .diagnosticOpened = point else { return }
                    let diagnostic = pending.appendingPathComponent(
                        MobileMapLibrary.quarantineDiagnosticFileName)
                    guard chmod(pending.path, mode_t(0o755)) == 0,
                          renameatx_np(
                            AT_FDCWD, diagnostic.path,
                            AT_FDCWD, displaced.path,
                            UInt32(RENAME_SWAP)) == 0,
                          chmod(pending.path, mode_t(0o555)) == 0 else {
                        throw NSError(
                            domain: "MapQuarantineCrashWorker", code: 21,
                            userInfo: [NSLocalizedDescriptionKey:
                                "cannot replace opened embedded diagnostic"])
                    }
                }
                mutationPerformed = true
            }
            defer {
                MobileMapLibrary.quarantineReadVerificationObserver = nil
            }
            var rejected = false
            do {
                _ = try MobileMapLibrary.listMaps()
            } catch {
                rejected = true
            }
            guard rejected, mutationPerformed,
                  FileManager.default.fileExists(atPath: displaced.path),
                  FileManager.default.fileExists(atPath: pending.path) else {
                Darwin._exit(94)
            }
            print("map \(phase) rejected replacement")
            exit(0)
        }

        switch entry {
        case "list":
            _ = try MobileMapLibrary.listMaps()
        case "map":
            do {
                _ = try MobileMapLibrary.map(
                    priorMapID: priorMapID, packageSHA256: packageSHA)
            } catch let error as MobileMapLibrary.LibraryError {
                switch error {
                case .packageMissing, .packageNotContained,
                     .packageVerificationFailed:
                    break
                default:
                    throw error
                }
            }
        case "rebuild":
            try MobileMapLibrary.rebuildRegistry()
        default:
            throw NSError(
                domain: "MapQuarantineCrashWorker", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unknown recovery entry"])
        }
        // Rebuild removes the stale production registry record after the
        // recovery entry has reconciled the hidden transaction.
        try MobileMapLibrary.rebuildRegistry()
        let listed = try MobileMapLibrary.listMaps()
        let registryData = try Data(contentsOf: try MobileMapLibrary.registryURL())
        let registry = try StrictJSONDocumentParser.object(
            from: registryData,
            limits: StrictJSONDocumentLimits(
                maximumBytes: registryData.count + 1))
        let mapCount = StrictJSONScalar.integer(registry["map_count"]) ?? -1
        print("recovered listed=\(listed.count) registry=\(mapCount)")
        exit(0)
    } catch {
        FileHandle.standardError.write(
            Data("map quarantine crash worker failed: \(error)\n".utf8))
        exit(19)
    }
}

// V1R4 §14.2 Map Library CAS: the library must serialize registry
// mutations, CAS the generation, re-verify packages on register/list/
// map, reject unsafe identities and path escapes, freeze packages
// immutable after registration, and derive floor counts from the REAL
// manifest floors on rebuild. Runs as its own process so the default
// host mode stays inside the frozen peak-RSS gate (same pattern as
// --xlsx-scale).
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--map-library-cas" {
    do {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-map-library-cas-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true)
        defer {
            restoreMutablePermissions(temporary)
            try? FileManager.default.removeItem(at: temporary)
        }

        // Fixture through the production importer + compiler only.
        let csv = """
        floor,element
        1,"{""shapeType"":""MapShelf"",""x"":100,""y"":100,""width"":300,""height"":80,""code"":""S1""}"
        1,"{""shapeType"":""MapTable"",""x"":500,""y"":100,""width"":200,""height"":100,""code"":""T1""}"
        1,"{""shapeType"":""MapRoadPoint"",""x"":10,""y"":10,""code"":""P1""}"
        """
        MobileMapLibrary.rootOverride = temporary.appendingPathComponent("Maps")
        let stagedMap = try writeTemporary(Data(csv.utf8), named: "cas-map.csv")
        let report = try MapSourceImportCoordinator.importMap(
            stagedURL: stagedMap,
            originalFilename: "cas-map.csv",
            contract: .topLeft,
            storeId: "s1",
            mapName: "Piaseczno")
        require(report.elementCount == 3, "CAS import must yield 3 elements")
        let compileDir = try MobileMapLibrary.stagingDirectory(for: "cas-compile")
        let compileResult = try MobilePriorMapCompiler.compile(
            canonicalSource: report.canonicalSource,
            outputDirectory: compileDir)
        require(
            compileResult.priorMapID.hasPrefix("piaseczno-")
                && MobileMapLibrary.isSafeIdentifier(compileResult.priorMapID),
            "CAS mixed-case map name must compile to a lowercase safe ID")
        require(
            MobilePriorMapCompiler.safeName("İstanbul") == "stanbul"
                && MobilePriorMapCompiler.safeName("Kelvin") == "elvin"
                && MobilePriorMapCompiler.safeName("北京A9") == "a9",
            "CAS slug parity must filter Unicode before ASCII lowercasing")
        let longID = MobilePriorMapCompiler.safeName(
            String(repeating: "A", count: 200)) + "-"
            + String(report.canonicalSourceSha256.prefix(12))
        require(
            longID.count == 128 && MobileMapLibrary.isSafeIdentifier(longID),
            "CAS 200-byte legal map name must produce a safe bounded ID")

        let legacyCaseID = "Piaseczno-"
            + String(report.canonicalSourceSha256.prefix(12))
        let legacyCaseDirectory = try MobileMapLibrary.packagesRoot()
            .appendingPathComponent(legacyCaseID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyCaseDirectory, withIntermediateDirectories: true)
        do {
            _ = try MobileMapLibrary.packageDirectory(
                priorMapID: compileResult.priorMapID,
                packageSHA: compileResult.packageSHA256)
            require(false, "CAS case-fold legacy directory must reject before write")
        } catch let error as MobileMapLibrary.LibraryError {
            guard case .noncanonicalPackageDirectorySpelling(
                let expected, let actual) = error else {
                throw error
            }
            require(
                expected == compileResult.priorMapID && actual == legacyCaseID,
                "CAS case-fold rejection must report exact expected/actual IDs")
        }
        try FileManager.default.removeItem(at: legacyCaseDirectory)
        let target = try MobileMapLibrary.packageDirectory(
            priorMapID: compileResult.priorMapID,
            packageSHA: compileResult.packageSHA256)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: compileDir, to: target)
        func casRegister() throws {
            _ = try MobileMapLibrary.register(
                priorMapID: compileResult.priorMapID,
                name: report.mapName,
                packageSHA256: compileResult.packageSHA256,
                packageURL: target,
                floorCount: compileResult.floorCount,
                elementCount: compileResult.elementCount,
                compilerVersion: "swift-v1",
                canonicalSourceSHA256: report.canonicalSourceSha256)
        }

        // 1) First registration creates the registry by rename at
        //    generation 1; a duplicate registration stays idempotent and
        //    advances the generation (serialized writes).
        try casRegister()
        var registryObject = try JSONSerialization.jsonObject(
            with: Data(contentsOf: try MobileMapLibrary.registryURL()))
            as? [String: Any]
        require(
            registryObject?["generation"] as? Int == 1
                && (registryObject?["maps"] as? [[String: Any]])?.count == 1,
            "CAS: first registration must create a generation-1 registry")
        try casRegister()
        registryObject = try JSONSerialization.jsonObject(
            with: Data(contentsOf: try MobileMapLibrary.registryURL()))
            as? [String: Any]
        require(
            registryObject?["generation"] as? Int == 2
                && (registryObject?["maps"] as? [[String: Any]])?.count == 1,
            "CAS: duplicate registration must stay idempotent and advance the generation")
        let listedAfterReregister = try MobileMapLibrary.listMaps()
        require(
            listedAfterReregister.count == 1,
            "CAS: re-registration must still list exactly one map")

        // RC-B26 version policy: one map ID may retain multiple exact-SHA
        // versions. Build a second valid package with the same frozen map
        // identity but changed shelf content; both must remain addressable.
        var variantSource = report.canonicalSource
        variantSource.elements[0].code = "S1-V2"
        let variantCompileDir = try MobileMapLibrary.stagingDirectory(
            for: "cas-compile-variant")
        let variantResult = try MobilePriorMapCompiler.compile(
            canonicalSource: variantSource,
            outputDirectory: variantCompileDir)
        require(
            variantResult.priorMapID == compileResult.priorMapID
                && variantResult.packageSHA256 != compileResult.packageSHA256,
            "RC-B26 fixture must produce same map ID with a different SHA")
        let variantTarget = try MobileMapLibrary.packageDirectory(
            priorMapID: variantResult.priorMapID,
            packageSHA: variantResult.packageSHA256)
        try FileManager.default.moveItem(
            at: variantCompileDir, to: variantTarget)
        _ = try MobileMapLibrary.register(
            priorMapID: variantResult.priorMapID,
            name: report.mapName,
            packageSHA256: variantResult.packageSHA256,
            packageURL: variantTarget,
            floorCount: variantResult.floorCount,
            elementCount: variantResult.elementCount,
            compilerVersion: "swift-v2",
            canonicalSourceSHA256: report.canonicalSourceSha256)
        registryObject = try JSONSerialization.jsonObject(
            with: Data(contentsOf: try MobileMapLibrary.registryURL()))
            as? [String: Any]
        let listedVersions = try MobileMapLibrary.listMaps()
        require(
            registryObject?["generation"] as? Int == 3
                && (registryObject?["maps"] as? [[String: Any]])?.count == 2
                && listedVersions.count == 2,
            "RC-B26 same map ID must retain both exact-SHA versions")
        _ = try MobileMapLibrary.map(
            priorMapID: variantResult.priorMapID,
            packageSHA256: variantResult.packageSHA256)

        // 2) Unsafe identities are rejected before any filesystem mutation.
        var unsafeRejected = false
        do {
            _ = try MobileMapLibrary.register(
                priorMapID: "../escape",
                name: "x",
                packageSHA256: compileResult.packageSHA256,
                packageURL: target,
                floorCount: compileResult.floorCount,
                elementCount: compileResult.elementCount,
                compilerVersion: "swift-v1",
                canonicalSourceSHA256: report.canonicalSourceSha256)
        } catch let error as MobileMapLibrary.LibraryError {
            if case .unsafeIdentifier = error { unsafeRejected = true }
        }
        require(unsafeRejected, "CAS: unsafe priorMapID must be rejected")
        for reservedComponent in [".", ".."] {
            require(
                !MobileMapLibrary.isSafeIdentifier(reservedComponent),
                "CAS: reserved path component \(reservedComponent) must not be a safe ID")
            var packagePathRejected = false
            do {
                _ = try MobileMapLibrary.packageDirectory(
                    priorMapID: reservedComponent,
                    packageSHA: compileResult.packageSHA256)
            } catch let error as MobileMapLibrary.LibraryError {
                if case .unsafeIdentifier = error {
                    packagePathRejected = true
                }
            }
            require(
                packagePathRejected,
                "CAS: packageDirectory must reject reserved ID \(reservedComponent)")
        }
        let twoLevelPackage = try MobileMapLibrary.packageDirectory(
            priorMapID: compileResult.priorMapID,
            packageSHA: compileResult.packageSHA256)
        require(
            twoLevelPackage.deletingLastPathComponent().lastPathComponent
                == compileResult.priorMapID
                && twoLevelPackage.lastPathComponent
                    == compileResult.packageSHA256,
            "CAS: safe package path must remain exactly <id>/<sha>")
        var shaRejected = false
        do {
            _ = try MobileMapLibrary.register(
                priorMapID: compileResult.priorMapID,
                name: "x",
                packageSHA256: "not-a-sha",
                packageURL: target,
                floorCount: compileResult.floorCount,
                elementCount: compileResult.elementCount,
                compilerVersion: "swift-v1",
                canonicalSourceSHA256: report.canonicalSourceSha256)
        } catch let error as MobileMapLibrary.LibraryError {
            if case .unsafeIdentifier = error { shaRejected = true }
        }
        require(shaRejected, "CAS: non-SHA packageSHA256 must be rejected")

        // 3) The registered package is immutable (files 444, dirs 555).
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: target.appendingPathComponent("manifest.json").path)
        let fileMode = (fileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        require(
            fileMode & 0o777 == 0o444,
            "CAS: package files must be read-only, got \(String(format: "%o", fileMode))")
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let dirMode = (dirAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        require(
            dirMode & 0o777 == 0o555,
            "CAS: package directories must be 555, got \(String(format: "%o", dirMode))")

        // P1-4: an undeclared symlink must be rejected before any package
        // artifact is chmodded, and path-based chmod must never follow it
        // to an external target.
        let externalModeTarget = temporary.appendingPathComponent(
            "package-freeze-external-target")
        try Data("external-target\n".utf8).write(to: externalModeTarget)
        guard chmod(externalModeTarget.path, mode_t(0o640)) == 0,
              chmod(target.path, mode_t(0o755)) == 0 else {
            throw NSError(
                domain: "MapLibraryCAS", code: 30,
                userInfo: [NSLocalizedDescriptionKey:
                    "cannot prepare package-freeze symlink fixture"])
        }
        let undeclaredLink = target.appendingPathComponent(
            "undeclared-freeze-link")
        guard Darwin.symlink(
                externalModeTarget.path, undeclaredLink.path) == 0 else {
            throw NSError(
                domain: "MapLibraryCAS", code: 31,
                userInfo: [NSLocalizedDescriptionKey:
                    "cannot create package-freeze symlink fixture"])
        }
        var symlinkFreezeRejected = false
        do {
            try casRegister()
        } catch let error as MobileMapLibrary.LibraryError {
            switch error {
            case .cannotMakeImmutable, .packageVerificationFailed:
                symlinkFreezeRejected = true
            default:
                throw error
            }
        }
        let externalModeAfter = ((try FileManager.default.attributesOfItem(
            atPath: externalModeTarget.path))[.posixPermissions]
            as? NSNumber)?.intValue ?? 0
        guard Darwin.unlink(undeclaredLink.path) == 0,
              chmod(target.path, mode_t(0o555)) == 0 else {
            throw NSError(
                domain: "MapLibraryCAS", code: 32,
                userInfo: [NSLocalizedDescriptionKey:
                    "cannot restore package-freeze symlink fixture"])
        }
        require(
            symlinkFreezeRejected && externalModeAfter & 0o777 == 0o640,
            "P1-4 package freeze must reject undeclared symlinks without "
                + "chmodding their external targets")

        // 4) list/map re-verify; a path-escape registry record marks the
        //    WHOLE index corrupt (V1R5 §13.4 / review H-10: a persistent
        //    identity index never drops entries silently — list and map
        //    fail closed with registryCorrupt until the index is rebuilt).
        let listedBeforeEscape = try MobileMapLibrary.listMaps()
        require(listedBeforeEscape.count == 2, "CAS: list must return both verified versions")
        _ = try MobileMapLibrary.map(
            priorMapID: compileResult.priorMapID,
            packageSHA256: compileResult.packageSHA256)
        var registry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: try MobileMapLibrary.registryURL())) as? [String: Any]
        var corrupt = registry ?? [:]
        var corruptMaps: [[String: Any]] = []
        for var record in ((registry?["maps"] as? [[String: Any]]) ?? []) {
            if record["package_directory"] as? String
                == "\(compileResult.priorMapID)/\(compileResult.packageSHA256)" {
                record["package_directory"] =
                    "../outside/\(compileResult.priorMapID)/\(compileResult.packageSHA256)"
            }
            corruptMaps.append(record)
        }
        corrupt["maps"] = corruptMaps
        try (try CanonicalJSONEncoder.encode(corrupt)).write(
            to: try MobileMapLibrary.registryURL())
        var listCorruptRejected = false
        do {
            _ = try MobileMapLibrary.listMaps()
            require(false, "CAS: corrupt registry must fail closed on list")
        } catch let error as MobileMapLibrary.LibraryError {
            if case .registryCorrupt = error { listCorruptRejected = true }
        }
        require(listCorruptRejected, "CAS: corrupt registry list must be registryCorrupt")
        var escapeRejected = false
        do {
            _ = try MobileMapLibrary.map(
                priorMapID: compileResult.priorMapID,
                packageSHA256: compileResult.packageSHA256)
        } catch let error as MobileMapLibrary.LibraryError {
            if case .registryCorrupt = error { escapeRejected = true }
        }
        require(escapeRejected, "CAS: escaped registry record must fail map closed")
        // Restore the registry before the serialized-write phase.
        try (try CanonicalJSONEncoder.encode(registry!)).write(
            to: try MobileMapLibrary.registryURL())

        // 5) Registrations serialize under the library lock: two
        //    back-to-back writes must both survive and advance the
        //    generation exactly twice (a lost-write regression would only
        //    advance it once). They run on the main thread so the frozen
        //    peak-RSS gate is not disturbed by extra dispatch worker
        //    stacks.
        for _ in 0..<2 {
            try casRegister()
        }
        registry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: try MobileMapLibrary.registryURL())) as? [String: Any]
        let generationAfterWrites = registry?["generation"] as? Int ?? 0
        require(
            generationAfterWrites == 5
                && (registry?["maps"] as? [[String: Any]])?.count == 2,
            "CAS: serialized registrations must advance the generation twice "
                + "(generation \(generationAfterWrites), expected 5)")
        let listedAfterWrites = try MobileMapLibrary.listMaps()
        require(
            listedAfterWrites.count == 2,
            "CAS: post-registration list must still return both versions")

        // 6) rebuildRegistry derives floorCount from the REAL manifest
        //    floors and restores a corrupt index.
        try MobileMapLibrary.rebuildRegistry()
        let rebuilt = try MobileMapLibrary.listMaps()
        require(rebuilt.count == 2, "CAS: rebuild must recover both SHA versions")
        require(
            rebuilt.allSatisfy {
                $0.floorCount == compileResult.floorCount
                    && $0.elementCount == compileResult.elementCount
            },
            "CAS: rebuild must derive floor/element counts from the manifest")

        // RC-B27: a valid-identity directory with a digest mismatch is
        // fully verified, rejected and moved outside packages/.
        let invalidSHA = String(repeating: "a", count: 64)
        let invalidPackage = try MobileMapLibrary.packageDirectory(
            priorMapID: compileResult.priorMapID,
            packageSHA: invalidSHA)
        try FileManager.default.copyItem(at: target, to: invalidPackage)
        try MobileMapLibrary.rebuildRegistry()
        let listedAfterQuarantine = try MobileMapLibrary.listMaps()
        require(
            !FileManager.default.fileExists(atPath: invalidPackage.path)
                && listedAfterQuarantine.count == 2,
            "RC-B27 rebuild must quarantine a package whose digest mismatches its SHA path")
        let quarantineID = try MobileMapLibrary.root()
            .appendingPathComponent("quarantine", isDirectory: true)
            .appendingPathComponent(compileResult.priorMapID, isDirectory: true)
        let quarantineEntries = try FileManager.default.contentsOfDirectory(
            atPath: quarantineID.path)
        let quarantineEntry = quarantineEntries.first(where: {
            $0.hasPrefix(invalidSHA + "-")
        }) ?? ""
        require(
            !quarantineEntry.isEmpty,
            "RC-B27 quarantined package must remain auditable")
        let quarantineDirectory = quarantineID.appendingPathComponent(
            quarantineEntry, isDirectory: true)
        let diagnosticURL = quarantineDirectory.appendingPathComponent(
            MobileMapLibrary.quarantineDiagnosticFileName)
        let diagnosticData = try Data(contentsOf: diagnosticURL)
        let diagnostic = try StrictJSONDocumentParser.object(
            from: diagnosticData,
            limits: StrictJSONDocumentLimits(
                maximumBytes: diagnosticData.count + 1))
        let sourceIdentity = diagnostic["source_identity"] as? [String: Any]
        require(
            diagnostic["format"] as? String
                == "MarketScannerMapQuarantineDiagnostic"
                && StrictJSONScalar.integer(diagnostic["version"]) == 3
                && diagnostic["transaction_id"] as? String == quarantineEntry
                && diagnostic["reason"] as? String
                    == "package_validation_failed"
                && (StrictJSONScalar.number(
                    diagnostic["quarantined_at_unix"]) ?? 0) > 0
                && sourceIdentity?["prior_map_id"] as? String
                    == compileResult.priorMapID
                && sourceIdentity?["package_sha256"] as? String == invalidSHA
                && diagnostic["source_path"] as? String == invalidPackage.path
                && StrictJSONScalar.integer(diagnostic["source_mode"]) != nil
                && diagnostic["quarantine_path"] as? String
                    == quarantineDirectory.path
                && MobileMapLibrary.isSHA256(
                    diagnostic["payload_tree_sha256"] as? String ?? "")
                && UInt64(diagnostic["payload_device"] as? String ?? "") != nil
                && UInt64(diagnostic["payload_inode"] as? String ?? "") != nil
                && !(diagnostic["validator_detail"] as? String ?? "").isEmpty,
            "RC-B27 quarantine diagnostic must bind transaction/reason/time/"
                + "source/path/mode/payload dev-inode/hash/detail")
        let diagnosticAttributes = try FileManager.default.attributesOfItem(
            atPath: diagnosticURL.path)
        let diagnosticMode = (diagnosticAttributes[.posixPermissions]
            as? NSNumber)?.intValue ?? 0
        let quarantineAttributes = try FileManager.default.attributesOfItem(
            atPath: quarantineDirectory.path)
        let quarantineMode = (quarantineAttributes[.posixPermissions]
            as? NSNumber)?.intValue ?? 0
        require(
            diagnosticAttributes[.type] as? FileAttributeType == .typeRegular
                && diagnosticMode & 0o777 == 0o444
                && quarantineMode & 0o777 == 0o555,
            "RC-B27 quarantine diagnostic/package must be immutable")

        // A diagnostic-commit failure after the payload rename must restore
        // the exact source path and abort rebuild; it may not leave a hidden
        // or published quarantine entry without its diagnostic.
        enum InjectedMapQuarantineFailure: Error {
            case afterPayloadRename
        }
        let rollbackSHA = String(repeating: "b", count: 64)
        let rollbackPackage = try MobileMapLibrary.packageDirectory(
            priorMapID: compileResult.priorMapID,
            packageSHA: rollbackSHA)
        try FileManager.default.copyItem(at: target, to: rollbackPackage)
        MobileMapLibrary.quarantineFaultInjector = { point in
            if case .afterPayloadRename = point {
                throw InjectedMapQuarantineFailure.afterPayloadRename
            }
        }
        var quarantineFailureRejected = false
        do {
            try MobileMapLibrary.rebuildRegistry()
        } catch let error as MobileMapLibrary.LibraryError {
            if case .packageVerificationFailed = error {
                quarantineFailureRejected = true
            }
        }
        MobileMapLibrary.quarantineFaultInjector = nil
        let afterRollbackEntries = try FileManager.default.contentsOfDirectory(
            atPath: quarantineID.path)
        require(
            quarantineFailureRejected
                && FileManager.default.fileExists(atPath: rollbackPackage.path)
                && !afterRollbackEntries.contains(where: {
                    $0.contains(rollbackSHA)
                }),
            "RC-B27 quarantine diagnostic failure must rollback and fail closed")
        try MobileMapLibrary.rebuildRegistry()
        let afterRetryEntries = try FileManager.default.contentsOfDirectory(
            atPath: quarantineID.path)
        require(
            !FileManager.default.fileExists(atPath: rollbackPackage.path)
                && afterRetryEntries.contains(where: {
                    $0.hasPrefix(rollbackSHA + "-")
                }),
            "RC-B27 retry must publish one diagnosed quarantine package")

        // RC-B27: an existing registry with a missing/illegal generation
        // is corrupt. Neither queries nor rebuild may silently overwrite
        // it as generation zero.
        var missingGeneration = try JSONSerialization.jsonObject(
            with: Data(contentsOf: try MobileMapLibrary.registryURL()))
            as! [String: Any]
        missingGeneration.removeValue(forKey: "generation")
        try (try CanonicalJSONEncoder.encode(missingGeneration)).write(
            to: try MobileMapLibrary.registryURL())
        var missingGenerationRejected = false
        do {
            _ = try MobileMapLibrary.listMaps()
        } catch let error as MobileMapLibrary.LibraryError {
            if case .registryCorrupt = error { missingGenerationRejected = true }
        }
        require(
            missingGenerationRejected,
            "RC-B27 missing registry generation must be registryCorrupt")
        var rebuildGenerationRejected = false
        do {
            try MobileMapLibrary.rebuildRegistry()
        } catch let error as MobileMapLibrary.LibraryError {
            if case .registryCorrupt = error { rebuildGenerationRejected = true }
        }
        require(
            rebuildGenerationRejected,
            "RC-B27 rebuild must not overwrite an illegal generation")
        print(
            "map library CAS passed: generation CAS, immutable packages, "
                + "multi-SHA identity, full rebuild verification and quarantine")
    }
    catch {
        FileHandle.standardError.write(
            Data("map library CAS failed: \(error)\n".utf8))
        exit(14)
    }
}

// === Mobile-Only V1R4: strict absolute-prior parser (§6.1) ===
// The parser must classify records against the REAL write-side schema:
// constraints carry nodeTimebaseTimestamp/estimatedPose/uniqueness (no
// nodeId/mapPose/sigma); manual v3 carries snake_case
// nearest_node_id/confirmed_map_pose/node_binding_status; recovery
// events are audited and never produce priors. Every rejection must be
// fail-closed with a stable audit code.
do {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("ms-prior-parser-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    // Node inventory: ids 1...6 at stamps 1001...1006.
    let nodes = (1...6).map {
        AbsolutePriorEvidenceNode(nodeID: Int64($0), stamp: 1000.0 + Double($0))
    }
    let mapID = "MAP-1"
    let sha = "SHA-1"
    let session = "S-1"
    let floor = "1"

    // The 200k burst index stores the two finite string domains as compact
    // codes. Exercise every accepted value and both rejection paths so the
    // memory optimization cannot weaken exact observation matching.
    let compactViews = ["front", "back", "unknown"]
    let compactTracking = [
        "uninitialized", "initializing", "stable", "usable",
        "recovering", "weak", "lost", "manualCorrection", "unknown",
    ]
    for view in compactViews {
        for tracking in compactTracking {
            let sample = TagBurstFrameSample(
                frameId: "compact-frame", observationId: "compact-observation",
                boundNodeId: 1, frameTimestamp: 1, nodeTimestamp: 1,
                depth: 0.9, view: view, tracking: tracking, confidence: 0.8)
            guard let compact = VerifiedTagBurstFrame(
                burstIndex: 0, sample: sample) else {
                require(false, "valid compact burst-frame domain rejected")
                continue
            }
            require(
                compact.matches(view: view, tracking: tracking),
                "compact burst-frame domain did not round-trip")
            require(
                !compact.matches(view: view == "front" ? "back" : "front",
                                 tracking: tracking),
                "compact burst-frame view mismatch was accepted")
        }
    }
    let invalidCompactSample = TagBurstFrameSample(
        frameId: "compact-invalid", observationId: "compact-invalid",
        boundNodeId: 1, frameTimestamp: 1, nodeTimestamp: 1,
        depth: 0.9, view: "side", tracking: "stable", confidence: 0.8)
    require(
        VerifiedTagBurstFrame(
            burstIndex: 0, sample: invalidCompactSample) == nil,
        "unknown compact burst-frame domain must fail closed")

    func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try CanonicalJSONEncoder.encode(object)
        return String(data: data, encoding: .utf8)! + "\n"
    }
    func writeSidecar(_ name: String, lines: [String]) throws {
        try lines.joined().data(using: .utf8)!.write(
            to: temporary.appendingPathComponent(name))
    }

    // 1) Localization constraints: 3 valid + 9 rejected categories.
    var constraintLines: [String] = []
    let validConstraint: [String: Any] = [
        "format": "MarketScannerLocalizationConstraint",
        "version": 1,
        "timestamp": 992.0,
        "nodeTimebaseTimestamp": 1002.0,
        "nodeTimebaseOffsetSeconds": 10.0,
        "trackingSessionId": session,
        "priorMapId": mapID,
        "priorMapSha256": sha,
        "floorId": floor,
        "accepted": true,
        "measurementAccepted": true,
        "correctionStepApplied": true,
        "confidenceAccepted": true,
        "disposition": "accepted_local",
        "reason": "host",
        "predictedPose": ["x_m": 1.0, "y_m": 0.0, "yaw_rad": 0.0],
        "estimatedPose": ["x_m": 2.0, "y_m": 0.0, "yaw_rad": 0.0],
        "candidates": [],
        "uniqueness": 0.9,
        "residualCost": 0.05,
        "effectivePointCount": 60,
        "coverageAngleRad": 2.8,
        "matcherElapsedMs": 4.0,
    ]
    for index in 0..<3 {
        var record = validConstraint
        record["nodeTimebaseTimestamp"] = 1002.0 + Double(index)
        record["timestamp"] = 992.0 + Double(index)
        record["estimatedPose"] = [
            "x_m": Double(index + 1), "y_m": 0.0, "yaw_rad": 0.0,
        ]
        constraintLines.append(try jsonLine(record))
    }
    func constraint(_ edits: [String: Any]) throws -> String {
        var record = validConstraint
        for (key, value) in edits { record[key] = value }
        return try jsonLine(record)
    }
    constraintLines.append(try constraint(["priorMapId": "OTHER"]))
    constraintLines.append(try constraint([
        "accepted": false,
        "measurementAccepted": false,
        "correctionStepApplied": false,
        "confidenceAccepted": false,
        "disposition": "rejected",
    ]))
    constraintLines.append(try constraint(["uniqueness": 1.5]))
    constraintLines.append(try constraint(["disposition": "rejected"]))
    constraintLines.append(try constraint([
        "priorMapId": NSNull(),
    ]))
    constraintLines.append(try constraint([
        "estimatedPose": NSNull(),
    ]))
    constraintLines.append(try constraint([
        "nodeTimebaseTimestamp": NSNull(),
    ]))
    constraintLines.append(try constraint(["uniqueness": "abc"]))
    constraintLines.append(try constraint(["nodeTimebaseTimestamp": "nope"]))
    try writeSidecar("localization_constraints.jsonl", lines: constraintLines)

    // 2) Manual v3: 1 valid + 5 rejected categories.
    let validManual: [String: Any] = [
        "format": "MarketScannerManualLocalizationEvent",
        "version": 3,
        "wall_clock_timestamp": "2027-01-15T08:00:00.000Z",
        "wall_clock_timestamp_unix": 1800000000.0,
        "frame_timestamp": 991.0,
        "node_timebase_frame_timestamp": 1001.0,
        "node_timebase_offset_seconds": 10.0,
        "nearest_node_id": 1,
        "nearest_node_stamp": 1001.0,
        "node_time_delta_seconds": 0.0,
        "node_time_snapshot_generation": 5,
        "node_binding_status": "matched",
        "node_binding_reason": "nearest",
        "alignment_version": 3,
        "tracking_session_id": session,
        "prior_map_id": mapID,
        "prior_map_sha256": sha,
        "floor_id": floor,
        "reason": "host",
        "arkit_pose": ["x_m": 0.0, "y_m": 0.0, "yaw_rad": 0.0],
        "confirmed_map_pose": ["x_m": 5.0, "y_m": 2.0, "yaw_rad": 0.1],
    ]
    func manual(_ edits: [String: Any]) throws -> String {
        var record = validManual
        for (key, value) in edits { record[key] = value }
        return try jsonLine(record)
    }
    var manualLines: [String] = []
    manualLines.append(try jsonLine(validManual))
    // Stale alignment watermark (same version again).
    manualLines.append(try manual([
        "nearest_node_id": 2, "nearest_node_stamp": 1002.0,
        "frame_timestamp": 992.0, "node_timebase_frame_timestamp": 1002.0,
    ]))
    // Unmatched binding status.
    manualLines.append(try manual([
        "alignment_version": 4, "node_binding_status": "unmatched",
        "nearest_node_id": 1, "nearest_node_stamp": 1001.0,
    ]))
    // Node id not present in the inventory.
    manualLines.append(try manual([
        "alignment_version": 5, "nearest_node_id": 99,
        "nearest_node_stamp": 1099.0, "frame_timestamp": 1089.0,
        "node_timebase_frame_timestamp": 1099.0,
        "node_time_delta_seconds": 0.0,
    ]))
    // Node stamp mismatch.
    manualLines.append(try manual([
        "alignment_version": 6, "nearest_node_id": 2,
        "nearest_node_stamp": 9999.0, "frame_timestamp": 992.0,
        "node_timebase_frame_timestamp": 1002.0,
        "node_time_delta_seconds": 0.0,
    ]))
    // Missing wall clock.
    manualLines.append(try manual([
        "alignment_version": 7, "wall_clock_timestamp": NSNull(),
        "wall_clock_timestamp_unix": NSNull(),
    ]))
    try writeSidecar("manual_localization_events.jsonl", lines: manualLines)

    // 3) Recovery events: audited only; must never produce priors.
    var recoveryLines: [String] = []
    recoveryLines.append(try jsonLine([
        "format": "MarketScannerRecoveryLifecycleEvent",
        "version": 2, "outcome": "converged",
    ]))
    recoveryLines.append(try jsonLine([
        "format": "MarketScannerRecoveryLifecycleEvent",
        "version": 2, "outcome": "cancelled",
    ]))
    try writeSidecar("localization_recovery_events.jsonl", lines: recoveryLines)

    let parseResult = try AbsolutePriorEvidenceParser.parse(
        snapshotDirectory: temporary,
        nodes: nodes,
        priorMapID: mapID,
        priorMapSHA256: sha,
        trackingSessionID: session,
        floorID: floor,
        expectedConstraintCount: 12,
        expectedManualCount: 6,
        expectedRecoveryCount: 2)
    let audit = parseResult.audit
    require(
        audit.constraintTotal == 12 && audit.constraintAccepted == 3,
        "strict parser constraint counts wrong: \(audit.constraintTotal)/\(audit.constraintAccepted)")
    require(
        audit.constraintIdentityRejected == 2,
        "constraint identity rejections wrong: \(audit.constraintIdentityRejected)")
    require(
        audit.constraintNotAcceptedRejected == 1
            && audit.constraintDispositionRejected == 1
            && audit.constraintPoseRejected == 1
            && audit.constraintUniquenessRejected == 2
            && audit.constraintTimestampRejected == 2,
        "constraint rejection breakdown wrong")
    require(
        audit.manualTotal == 6 && audit.manualAccepted == 1,
        "strict parser manual counts wrong: \(audit.manualTotal)/\(audit.manualAccepted)")
    require(
        audit.manualAlignmentRejected == 1
            && audit.manualBindingRejected == 3
            && audit.manualWallClockRejected == 1,
        "manual rejection breakdown wrong")
    require(
        audit.recoveryRecordCount == 2,
        "recovery audit count wrong: \(audit.recoveryRecordCount)")
    require(
        parseResult.priors.count == 4,
        "strict parser prior count wrong: \(parseResult.priors.count)")
    require(
        audit.acceptedPriorCount == 4,
        "accepted prior count wrong: \(audit.acceptedPriorCount)")

    // The pipeline adds one independent, moderately uncertain start-pose
    // gauge after strict sidecar parsing. It binds deterministically to the
    // earliest graph node and must use the shared PC/mobile policy.
    let initialPrior = MobileProcessingPipeline.initialMapPosePrior(
        metadata: [
            "initialMapPose": [
                "x_m": 31.25,
                "y_m": -79.0,
                "yaw_rad": Double.pi / 2.0,
            ],
        ],
        nodes: nodes)
    require(initialPrior != nil, "valid initialMapPose must create a prior")
    require(initialPrior!.nodeID == 1, "initial pose must bind earliest node")
    require(initialPrior!.kind == 3, "initial pose prior kind must be 3")
    require(
        abs(initialPrior!.information3x3[0] - 1.0) < 1.0e-9,
        "initial position sigma must be 1 metre")
    require(
        abs(initialPrior!.information3x3[8]
            - 1.0 / pow(Double.pi / 12.0, 2)) < 1.0e-9,
        "initial yaw sigma must be 15 degrees")
    // Uniqueness 0.9 -> weight = max(1.0, 6.0*0.9) = 5.4; the derived
    // information must equal the weight (sigma = 1/sqrt(weight)).
    let expectedWeight = AbsolutePriorEvidenceLimits.weightForUniqueness(0.9)
    require(abs(expectedWeight - 5.4) < 1.0e-9, "weight policy drifted")
    if let first = parseResult.priors.first {
        // Constraint nodeTimebaseTimestamp 1002.0 binds to node 2
        // (stamp 1002.0) — the nearest inventory node.
        require(first.nodeID == 2, "first prior must bind node 2")
        require(
            abs(first.information3x3[0] - expectedWeight) < 1.0e-9,
            "derived information must equal the uniqueness weight")
        require(first.kind == 0, "constraint prior kind must be localization")
    } else {
        require(false, "missing expected constraint prior")
    }
    // Manual prior uses the fixed policy sigma (0.10 m).
    let manualPrior = parseResult.priors.first { $0.kind == 2 }
    require(manualPrior != nil, "missing expected manual prior")
    require(
        abs(manualPrior!.information3x3[0] - 1.0 / (0.10 * 0.10)) < 1.0e-9,
        "manual prior must use the fixed policy sigma")
    // Fatal details contain 8 corrupt/contradictory constraints + 5 manual
    // failures. The one well-formed accepted=false constraint is audited
    // separately and must not poison the pipeline clean gate.
    require(
        audit.rejectedDetails.count == 13,
        "rejected detail count wrong: \(audit.rejectedDetails.count)")
    require(
        audit.nonAcceptedDetails.count == 1
            && audit.nonAcceptedDetails[0].reason == "constraint_not_accepted",
        "normal non-accepted constraint must be non-fatal audit evidence")
    let reasons = Set(audit.rejectedDetails.map { $0.reason })
    require(
        reasons.contains("constraint_identity_missing_or_mismatch")
            && reasons.contains("constraint_uniqueness_invalid")
            && reasons.contains("manual_event_node_id_not_found")
            && reasons.contains("manual_event_node_stamp_mismatch")
            && reasons.contains("manual_event_wall_clock_missing_or_invalid")
            && reasons.contains("manual_event_time_or_alignment_invalid"),
        "rejected stable codes incomplete: \(reasons.sorted())")

    func parseConstraintAudit(
        directoryName: String,
        constraintRecord: [String: Any],
        expectedConstraintCount: Int? = nil
    ) throws -> AbsolutePriorEvidenceParseResult {
        let directory = temporary.appendingPathComponent(
            directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try jsonLine(constraintRecord).data(using: .utf8)!.write(
            to: directory.appendingPathComponent(
                "localization_constraints.jsonl"))
        try Data().write(
            to: directory.appendingPathComponent(
                "manual_localization_events.jsonl"))
        return try AbsolutePriorEvidenceParser.parse(
            snapshotDirectory: directory,
            nodes: nodes,
            priorMapID: mapID,
            priorMapSHA256: sha,
            trackingSessionID: session,
            floorID: floor,
            expectedConstraintCount: expectedConstraintCount,
            expectedManualCount: 0,
            expectedRecoveryCount: 0)
    }
    var normalRejected = validConstraint
    normalRejected["accepted"] = false
    normalRejected["measurementAccepted"] = false
    normalRejected["correctionStepApplied"] = false
    normalRejected["confidenceAccepted"] = false
    normalRejected["disposition"] = "rejected"
    let normalRejectedResult = try parseConstraintAudit(
        directoryName: "normal-rejected",
        constraintRecord: normalRejected,
        expectedConstraintCount: 1)
    require(
        normalRejectedResult.audit.clean
            && normalRejectedResult.audit.nonAcceptedDetails.count == 1
            && normalRejectedResult.priors.isEmpty,
        "well-formed accepted=false constraint must not block clean processing")

    var invalidAcceptedType = normalRejected
    invalidAcceptedType["accepted"] = 0
    let invalidAcceptedResult = try parseConstraintAudit(
        directoryName: "invalid-accepted-type",
        constraintRecord: invalidAcceptedType)
    require(
        !invalidAcceptedResult.audit.clean
            && invalidAcceptedResult.audit.rejectedDetails.map(\.reason)
                .contains("constraint_accepted_invalid"),
        "numeric accepted flag must remain fatal schema evidence")

    var rejectedWrongIdentity = normalRejected
    rejectedWrongIdentity["floorId"] = "OTHER"
    let rejectedWrongIdentityResult = try parseConstraintAudit(
        directoryName: "rejected-wrong-identity",
        constraintRecord: rejectedWrongIdentity)
    require(
        !rejectedWrongIdentityResult.audit.clean
            && rejectedWrongIdentityResult.audit.rejectedDetails.map(\.reason)
                .contains("constraint_identity_missing_or_mismatch"),
        "accepted=false must not hide identity corruption")

    require(
        AbsolutePriorEvidenceLimits.qualificationMaximumConstraintRecords
            == 345_600
            && AbsolutePriorEvidenceLimits.maximumRecords >= 345_600
            && AbsolutePriorEvidenceLimits.manualMaximumFileBytes
                == GeneratedMobileEvidenceContracts
                    .File_manual_localization_events_jsonl.max_file_bytes
            && AbsolutePriorEvidenceLimits.manualMaximumRecordBytes
                == GeneratedMobileEvidenceContracts
                    .File_manual_localization_events_jsonl.max_record_bytes
            && AbsolutePriorEvidenceLimits.manualMaximumRecords
                == GeneratedMobileEvidenceContracts
                    .File_manual_localization_events_jsonl.max_records
            && AbsolutePriorEvidenceLimits.recoveryMaximumFileBytes
                == RecoveryLifecycleEvidenceLimits.maximumFileBytes
            && AbsolutePriorEvidenceLimits.recoveryMaximumRecordBytes
                == RecoveryLifecycleEvidenceLimits.maximumRecordBytes
            && AbsolutePriorEvidenceLimits.recoveryMaximumRecords
                == RecoveryLifecycleEvidenceLimits.maximumRecords,
        "absolute-prior sidecars must use their own frozen input contracts")
    var oversizedManualWatermarkRejected = false
    do {
        _ = try AbsolutePriorEvidenceParser.parse(
            snapshotDirectory: temporary,
            nodes: nodes,
            priorMapID: mapID,
            priorMapSHA256: sha,
            trackingSessionID: session,
            floorID: floor,
            expectedConstraintCount: 12,
            expectedManualCount:
                AbsolutePriorEvidenceLimits.manualMaximumRecords + 1,
            expectedRecoveryCount: 2)
    } catch AbsolutePriorEvidenceParseError.tooManyRecords(
        let source, let actual) {
        oversizedManualWatermarkRejected = source == "manual metadata watermark"
            && actual == AbsolutePriorEvidenceLimits.manualMaximumRecords + 1
    }
    require(
        oversizedManualWatermarkRejected,
        "manual metadata watermark above its generated hard cap must reject before I/O")
    var oversizedRecoveryWatermarkRejected = false
    do {
        _ = try AbsolutePriorEvidenceParser.parse(
            snapshotDirectory: temporary,
            nodes: nodes,
            priorMapID: mapID,
            priorMapSHA256: sha,
            trackingSessionID: session,
            floorID: floor,
            expectedConstraintCount: 12,
            expectedManualCount: 6,
            expectedRecoveryCount:
                AbsolutePriorEvidenceLimits.recoveryMaximumRecords + 1)
    } catch AbsolutePriorEvidenceParseError.tooManyRecords(
        let source, let actual) {
        oversizedRecoveryWatermarkRejected = source == "recovery metadata watermark"
            && actual == AbsolutePriorEvidenceLimits.recoveryMaximumRecords + 1
    }
    require(
        oversizedRecoveryWatermarkRejected,
        "recovery metadata watermark above its lifecycle hard cap must reject before I/O")
    var watermarkMismatchRejected = false
    do {
        _ = try parseConstraintAudit(
            directoryName: "constraint-watermark-mismatch",
            constraintRecord: normalRejected,
            expectedConstraintCount: 2)
    } catch AbsolutePriorEvidenceParseError.constraintCountMismatch(
        let actual, let expected) {
        watermarkMismatchRejected = actual == 1 && expected == 2
    }
    require(
        watermarkMismatchRejected,
        "localization constraint metadata watermark must match exact JSONL rows")

    func constraintFatalReason(
        _ directoryName: String, _ record: [String: Any], _ reason: String
    ) throws -> Bool {
        let result = try parseConstraintAudit(
            directoryName: directoryName, constraintRecord: record)
        return !result.audit.clean
            && result.audit.rejectedDetails.map(\.reason).contains(reason)
    }
    var unknownConstraintField = validConstraint
    unknownConstraintField["futureDrift"] = 1
    let unknownConstraintFieldRejected = try constraintFatalReason(
        "constraint-unknown-field", unknownConstraintField,
        "constraint_unknown_field")
    require(
        unknownConstraintFieldRejected,
        "unknown constraint top-level fields must fail closed")
    var unknownConstraintPoseField = validConstraint
    unknownConstraintPoseField["estimatedPose"] = [
        "x_m": 2.0, "y_m": 0.0, "yaw_rad": 0.0, "z_m": 0.0,
    ]
    let unknownConstraintPoseRejected = try constraintFatalReason(
        "constraint-unknown-pose-field", unknownConstraintPoseField,
        "constraint_pose_invalid")
    require(
        unknownConstraintPoseRejected,
        "unknown constraint pose fields must fail closed")
    var unknownCandidateField = validConstraint
    unknownCandidateField["candidates"] = [[
        "pose": ["x_m": 2.0, "y_m": 0.0, "yaw_rad": 0.0],
        "cost": 0.1, "score": 0.9, "futureDrift": true,
    ]]
    let unknownCandidateRejected = try constraintFatalReason(
        "constraint-unknown-candidate-field", unknownCandidateField,
        "constraint_pose_invalid")
    require(
        unknownCandidateRejected,
        "unknown candidate subobject fields must fail closed")
    for (name, invalidVersion): (String, Any) in [
        ("bool", true), ("fractional", 1.5),
    ] {
        var invalidVersionRecord = validConstraint
        invalidVersionRecord["version"] = invalidVersion
        let invalidVersionRejected = try constraintFatalReason(
            "constraint-version-\(name)", invalidVersionRecord,
            "constraint_version_unsupported")
        require(
            invalidVersionRejected,
            "constraint version \(name) must be a strict integer")
    }

    func parseManualAudit(
        directoryName: String,
        manualRecord: [String: Any],
        manualNodes: [AbsolutePriorEvidenceNode] = nodes,
        expectedManualCount: Int = 1
    ) throws -> AbsolutePriorEvidenceParseResult {
        let directory = temporary.appendingPathComponent(
            directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data().write(
            to: directory.appendingPathComponent(
                "localization_constraints.jsonl"))
        try jsonLine(manualRecord).data(using: .utf8)!.write(
            to: directory.appendingPathComponent(
                "manual_localization_events.jsonl"))
        return try AbsolutePriorEvidenceParser.parse(
            snapshotDirectory: directory,
            nodes: manualNodes,
            priorMapID: mapID,
            priorMapSHA256: sha,
            trackingSessionID: session,
            floorID: floor,
            expectedConstraintCount: 0,
            expectedManualCount: expectedManualCount,
            expectedRecoveryCount: 0)
    }
    var manualWatermarkMismatchRejected = false
    do {
        _ = try parseManualAudit(
            directoryName: "manual-watermark-mismatch",
            manualRecord: validManual,
            expectedManualCount: 2)
    } catch AbsolutePriorEvidenceParseError.manualCountMismatch(
        let actual, let expected) {
        manualWatermarkMismatchRejected = actual == 1 && expected == 2
    }
    require(
        manualWatermarkMismatchRejected,
        "manual localization metadata watermark must match exact JSONL rows")

    var recoveryWatermarkMismatchRejected = false
    do {
        _ = try AbsolutePriorEvidenceParser.parse(
            snapshotDirectory: temporary,
            nodes: nodes,
            priorMapID: mapID,
            priorMapSHA256: sha,
            trackingSessionID: session,
            floorID: floor,
            expectedConstraintCount: 12,
            expectedManualCount: 6,
            expectedRecoveryCount: 3)
    } catch AbsolutePriorEvidenceParseError.recoveryCountMismatch(
        let actual, let expected) {
        recoveryWatermarkMismatchRejected = actual == 2 && expected == 3
    }
    require(
        recoveryWatermarkMismatchRejected,
        "recovery metadata watermark must match exact JSONL rows")
    var wallClockMismatch = validManual
    wallClockMismatch["wall_clock_timestamp_unix"] = 1_800_000_001.0
    let wallClockMismatchResult = try parseManualAudit(
        directoryName: "manual-wall-clock-mismatch",
        manualRecord: wallClockMismatch)
    require(
        wallClockMismatchResult.audit.rejectedDetails.map(\.reason)
            .contains("manual_event_wall_clock_missing_or_invalid"),
        "manual ISO and Unix timestamps must identify the same instant")

    var ambiguousV2 = validManual
    ambiguousV2["version"] = 2
    ambiguousV2["frame_timestamp"] = 991.0
    ambiguousV2["node_timebase_frame_timestamp"] = 1001.0
    ambiguousV2["nearest_node_id"] = NSNull()
    ambiguousV2["nearest_node_stamp"] = NSNull()
    ambiguousV2["node_time_delta_seconds"] = NSNull()
    ambiguousV2["node_binding_status"] = "frame_timestamp_only"
    let ambiguousV2Result = try parseManualAudit(
        directoryName: "manual-v2-ambiguous",
        manualRecord: ambiguousV2,
        manualNodes: [
            AbsolutePriorEvidenceNode(nodeID: 1, stamp: 1000.0),
            AbsolutePriorEvidenceNode(nodeID: 2, stamp: 1002.0),
        ])
    require(
        ambiguousV2Result.audit.rejectedDetails.map(\.reason)
            .contains("manual_event_node_binding_ambiguous"),
        "manual v2 binding must enforce the second-nearest margin")

    var claimedWrongV3 = validManual
    claimedWrongV3["frame_timestamp"] = 991.9
    claimedWrongV3["node_timebase_frame_timestamp"] = 1001.9
    claimedWrongV3["nearest_node_id"] = 1
    claimedWrongV3["nearest_node_stamp"] = 1001.0
    claimedWrongV3["node_time_delta_seconds"] = 0.9
    let claimedWrongV3Result = try parseManualAudit(
        directoryName: "manual-v3-not-nearest",
        manualRecord: claimedWrongV3)
    require(
        claimedWrongV3Result.audit.rejectedDetails.map(\.reason)
            .contains("manual_event_claimed_node_not_nearest"),
        "manual v3 claimed ID must equal the recomputed nearest node")
    // Report payload round-trips through CanonicalJSONEncoder.
    let report = audit.reportPayload(priors: parseResult.priors)
    let reportData = try CanonicalJSONEncoder.encode(report)
    require(!reportData.isEmpty, "prior evidence report must serialize")
    print(
        "strict prior parser passed: constraints=\(audit.constraintAccepted)/\(audit.constraintTotal) "
            + "manual=\(audit.manualAccepted)/\(audit.manualTotal) "
            + "recovery=\(audit.recoveryRecordCount) priors=\(parseResult.priors.count)")
}
catch {
    FileHandle.standardError.write(
        Data("strict prior parser failed: \(error)\n".utf8))
    exit(10)
}

// === RC-B12..B14: burst v2 + strict tag DTO/exact consumption ===
do {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent("ms-tag-parser-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    // Node inventory: ids 1...6 at stamps 1001...1006.
    let nodes = (1...6).map {
        AbsolutePriorEvidenceNode(nodeID: Int64($0), stamp: 1000.0 + Double($0))
    }
    let mapID = "MAP-1"
    let sha = "SHA-1"
    let session = "S-1"
    let floor = "1"

    func jsonLine(_ object: [String: Any]) throws -> String {
        let data = try CanonicalJSONEncoder.encode(object)
        return String(data: data, encoding: .utf8)! + "\n"
    }

    func frame(
        _ index: Int, observationID: String? = nil,
        view: String = "front", tracking: String = "stable"
    ) -> [String: Any] {
        [
            "frame_id": "frame-\(index)",
            "observation_id": observationID ?? "OBS-\(index)",
            "bound_node_id": index,
            "frame_timestamp": 999.0 + Double(index),
            "node_timestamp": 1000.0 + Double(index),
            "depth": 0.95,
            "view": view,
            "tracking": tracking,
            "confidence": 0.9,
        ]
    }
    func burst(
        _ burstID: String, sequence: Int, frames: [[String: Any]]
    ) -> [String: Any] {
        let frameTimes = frames.map { StrictJSONScalar.number($0["frame_timestamp"])! }
        let nodeIDs = frames.map { StrictJSONScalar.integer($0["bound_node_id"])! }
        let depths = frames.map { StrictJSONScalar.number($0["depth"])! }
        let confidences = frames.map { StrictJSONScalar.number($0["confidence"])! }
        return [
            "format": "MarketScannerPriceTagBurst", "version": 2,
            "prior_map_id": mapID, "prior_map_sha256": sha,
            "tracking_session_id": session, "floor_id": floor,
            "burst_id": burstID, "sequence": sequence,
            "barcode": "6901234567890", "symbology": "EAN13",
            "complete": true, "frame_count": frames.count, "frames": frames,
            "first_frame_timestamp": frameTimes.min() ?? 0,
            "last_frame_timestamp": frameTimes.max() ?? 0,
            "bound_node_id_min": nodeIDs.min() ?? 0,
            "bound_node_id_max": nodeIDs.max() ?? 0,
            "depth_quality": depths.reduce(0, +) / Double(max(1, depths.count)),
            "view_angle": TagObservationBurstEvidenceParser.dominantVote(
                frames.map { $0["view"] as! String }),
            "tracking_quality": TagObservationBurstEvidenceParser.dominantVote(
                frames.map { $0["tracking"] as! String }),
            "localization_confidence_mean": confidences.reduce(0, +)
                / Double(max(1, confidences.count)),
        ]
    }
    func parseBurstFixture(
        name: String, object: [String: Any], expectedCount: Int,
        expectedLastID: String?
    ) throws -> TagObservationBurstEvidenceParseResult {
        let directory = temporary.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try jsonLine(object).data(using: .utf8)!.write(
            to: directory.appendingPathComponent("tag_observation_bursts.jsonl"))
        return try TagObservationBurstEvidenceParser.parse(
            snapshotDirectory: directory, nodes: nodes,
            priorMapID: mapID, priorMapSHA256: sha,
            trackingSessionID: session, floorID: floor,
            expectedBurstCount: expectedCount,
            expectedLastBurstID: expectedLastID)
    }

    // 1/2/3-frame smoke: frame count is exact and ties are ambiguous.
    for count in 1...3 {
        var samples = (1...count).map { frame($0) }
        if count == 2 {
            samples[1]["view"] = "back"
        }
        let burstID = "BURST-\(count)"
        let parsed = try parseBurstFixture(
            name: "burst-\(count)",
            object: burst(burstID, sequence: 1, frames: samples),
            expectedCount: 1,
            expectedLastID: burstID)
        require(parsed.frameCount == count, "burst \(count) frame count drift")
        if count == 2 {
            require(parsed.bursts[0].viewAngle == "unknown", "front/back tie must be unknown")
        }
    }
    var tampered = burst("BURST-TAMPER", sequence: 1, frames: [frame(1)])
    tampered["depth_quality"] = 0.1
    let tamperedResult = try parseBurstFixture(
        name: "burst-tampered", object: tampered,
        expectedCount: 1, expectedLastID: "BURST-TAMPER")
    require(
        tamperedResult.audit.rejectedDetails.map(\.reason).contains("summary_mismatch"),
        "tampered burst summary must reject")
    require(
        tamperedResult.retainedDegradedBursts.count == 1
            && tamperedResult.retainedDegradedBursts[0].burstID
                == "BURST-TAMPER"
            && tamperedResult.sourceBusinessCaptureCount == 1,
        "identity-safe summary degradation must retain one business capture")
    // A burst's durable frame/observation IDs remain globally reserved even
    // when a later summary check degrades that burst. Otherwise a following
    // record could reuse the IDs and silently replace the original capture.
    let reuseDirectory = temporary.appendingPathComponent(
        "degraded-burst-id-reuse", isDirectory: true)
    try FileManager.default.createDirectory(
        at: reuseDirectory, withIntermediateDirectories: true)
    var degradedFirst = burst(
        "BURST-DEGRADED-FIRST", sequence: 1,
        frames: [frame(1, observationID: "OBS-1")])
    degradedFirst["depth_quality"] = 0.1
    var duplicateFrame = frame(2, observationID: "OBS-2")
    duplicateFrame["frame_id"] = "frame-1"
    let duplicateFrameBurst = burst(
        "BURST-DUPLICATE-FRAME", sequence: 2,
        frames: [duplicateFrame])
    let duplicateObservationBurst = burst(
        "BURST-DUPLICATE-OBSERVATION", sequence: 3,
        frames: [frame(3, observationID: "OBS-1")])
    try (
        jsonLine(degradedFirst)
            + jsonLine(duplicateFrameBurst)
            + jsonLine(duplicateObservationBurst)
    ).data(using: .utf8)!.write(
        to: reuseDirectory.appendingPathComponent(
            "tag_observation_bursts.jsonl"))
    let reuseResult = try TagObservationBurstEvidenceParser.parse(
        snapshotDirectory: reuseDirectory, nodes: nodes,
        priorMapID: mapID, priorMapSHA256: sha,
        trackingSessionID: session, floorID: floor,
        expectedBurstCount: 3,
        expectedLastBurstID: "BURST-DUPLICATE-OBSERVATION")
    let reuseReasons = Set(reuseResult.audit.rejectedDetails.map(\.reason))
    require(
        reuseReasons.contains("summary_mismatch")
            && reuseReasons.contains("duplicate_frame_id")
            && reuseReasons.contains("duplicate_observation_id")
            && reuseResult.sourceBusinessCaptureCount == 3,
        "degraded bursts must reserve durable frame and observation IDs globally")
    let zeroResult = try parseBurstFixture(
        name: "burst-zero",
        object: burst("BURST-ZERO", sequence: 1, frames: []),
        expectedCount: 1, expectedLastID: "BURST-ZERO")
    require(
        zeroResult.audit.rejectedDetails.map(\.reason)
            .contains("frame_count_or_frames_invalid"),
        "complete zero-frame burst must reject")
    let duplicateResult = try parseBurstFixture(
        name: "burst-duplicate",
        object: burst(
            "BURST-DUP", sequence: 1,
            frames: [frame(1, observationID: "OBS-DUP"),
                     frame(2, observationID: "OBS-DUP")]),
        expectedCount: 1, expectedLastID: "BURST-DUP")
    require(
        duplicateResult.audit.rejectedDetails.map(\.reason)
            .contains("duplicate_observation_id"),
        "burst observation IDs must be globally unique")

    let mainFrames = [frame(1), frame(2), frame(3)]
    try jsonLine(burst("BURST-MAIN", sequence: 1, frames: mainFrames))
        .data(using: .utf8)!.write(
            to: temporary.appendingPathComponent("tag_observation_bursts.jsonl"))
    let verifiedBursts = try TagObservationBurstEvidenceParser.parse(
        snapshotDirectory: temporary, nodes: nodes,
        priorMapID: mapID, priorMapSHA256: sha,
        trackingSessionID: session, floorID: floor,
        expectedBurstCount: 1, expectedLastBurstID: "BURST-MAIN")

    let validRecord: [String: Any] = [
        "format": "MarketScannerPriceTagObservation",
        "version": 2,
        "observation_id": "OBS-1",
        "timestamp": 100.0,
        "payload": "6901234567890",
        "symbology": "EAN13",
        "normalized_bounds": [0.1, 0.2, 0.3, 0.4],
        "frame_timestamp": 1000.0,
        "node_timebase_frame_timestamp": 1001.0,
        "node_timebase_offset_seconds": 1.0,
        "pose_timestamp_delta_ms": 2.0,
        "alignment_version": 3,
        "alignment_snapshot_timestamp": 999.998,
        "alignment_age_ms": 2.0,
        "alignment_version_lag": 0,
        "alignment_freshness": "fresh",
        "raw_map_position": ["x_m": 1.0, "y_m": 2.0, "height_m": 1.5],
        "measurement_method": "scene_depth",
        "measurement_confidence": 0.9,
        "depth_sample_count": 40,
        "depth_inlier_count": 38,
        "depth_inlier_ratio": 0.95,
        "depth_median_m": 1.2,
        "depth_mad_m": 0.1,
        "plane_residual_m": 0.02,
        "surface_normal_camera": [0.0, 0.0, -1.0],
        "localization_state": "stable",
        "localization_confidence": 0.9,
        "prior_map_id": mapID,
        "prior_map_sha256": sha,
        "floor_id": floor,
        "tracking_session_id": session,
        "needs_review": false,
        // V1R5 §5.4: durable burst linkage assigned at persistence time.
        "burst_id": "BURST-MAIN",
        "frame_id": "frame-1",
        "bound_node_id": 1,
        "bound_node_stamp": 1001.0,
        "bound_node_map_id": 0,
        "coordinate_frame": "RTABMAP_BOUND_NODE_LOCAL",
        "point_in_bound_node_frame": ["x_m": 1.0, "y_m": 2.0, "z_m": 0.0],
        "measurement_height_m": 1.5,
    ]
    func observation(
        _ edits: [String: Any], removing: [String] = []
    ) throws -> String {
        var record = validRecord
        for (key, value) in edits { record[key] = value }
        removing.forEach { record.removeValue(forKey: $0) }
        return try jsonLine(record)
    }
    var lines: [String] = []
    lines.append(try observation([
        "observation_id": "OBS-1",
        "frame_timestamp": 1000.0,
        "node_timebase_frame_timestamp": 1001.0,
        "alignment_snapshot_timestamp": 999.998,
        "frame_id": "frame-1",
        "raw_map_position": ["x_m": 1.0, "y_m": 2.0, "height_m": 1.5],
    ]))
    // height_m absent is valid; the record stays planar/review-only.
    lines.append(try observation([
        "observation_id": "OBS-2",
        "frame_timestamp": 1001.0,
        "node_timebase_frame_timestamp": 1002.0,
        "alignment_snapshot_timestamp": 1000.998,
        "frame_id": "frame-2", "needs_review": true,
        "bound_node_id": 2, "bound_node_stamp": 1002.0,
        "point_in_bound_node_frame": ["x_m": 1.1, "y_m": 2.1, "z_m": 0.0],
        "raw_map_position": ["x_m": 1.1, "y_m": 2.1],
    ]))
    lines.append(try observation([
        "observation_id": "OBS-3",
        "frame_timestamp": 1002.0,
        "node_timebase_frame_timestamp": 1003.0,
        "alignment_snapshot_timestamp": 1001.998,
        "frame_id": "frame-3", "needs_review": true,
        "bound_node_id": 3, "bound_node_stamp": 1003.0,
        "measurement_method": "unavailable", "measurement_confidence": 0.0,
    ], removing: ["raw_map_position", "point_in_bound_node_frame",
                  "measurement_height_m"]))
    lines.append(try observation([
        "observation_id": "OBS-NOT-IN-BURST", "frame_id": "frame-x",
    ]))
    lines.append(try observation([
        "observation_id": "OBS-1",
    ]))
    lines.append(try observation([
        "observation_id": "OBS-RAW",
        "raw_map_position": "wrong-type",
    ]))
    lines.append(try observation([
        "observation_id": "OBS-HEIGHT",
        "raw_map_position": ["x_m": 1.0, "y_m": 2.0, "height_m": "bad"],
    ]))
    lines.append(try observation([
        "observation_id": "OBS-TIME", "node_timebase_offset_seconds": 2.0,
    ]))
    lines.append(try observation([
        "observation_id": "OBS-DEPTH", "depth_inlier_count": 37,
    ]))
    lines.append(try observation([
        "observation_id": "OBS-NORMAL", "surface_normal_camera": [0.0, 0.0, -2.0],
    ]))
    lines.append(try observation([
        "observation_id": "OBS-FRESH", "alignment_freshness": "aging",
    ]))
    lines.append(try observation([
        "observation_id": "OBS-METHOD", "measurement_method": "center_bearing",
    ]))
    try lines.joined().data(using: .utf8)!.write(
        to: temporary.appendingPathComponent("tag_observations.jsonl"))

    let result = try TagObservationEvidenceParser.parse(
        snapshotDirectory: temporary,
        nodes: nodes,
        priorMapID: mapID,
        priorMapSHA256: sha,
        trackingSessionID: session,
        floorID: floor,
        verifiedBursts: verifiedBursts)
    let audit = result.audit
    require(
        audit.recordTotal == 12,
        "tag parser record total wrong: \(audit.recordTotal)")
    require(
        audit.recordAccepted == 3
            && audit.recordUnlocalizedSkipped == 1,
        "tag parser accepted/unlocalized wrong: \(audit.recordAccepted)/\(audit.recordUnlocalizedSkipped)")
    require(audit.totalRejected == 9, "tag parser total rejected wrong: \(audit.totalRejected)")
    require(
        audit.rejectedDetails.count == 9,
        "tag parser rejected details must count every rejection: \(audit.rejectedDetails.count)")
    let reasons = Set(audit.rejectedDetails.map { $0.reason })
    require(
        reasons.contains("observation_frame_exact_mismatch")
            && reasons.contains("duplicate_observation_id")
            && reasons.contains("raw_pose_invalid")
            && reasons.contains("raw_height_invalid")
            && reasons.contains("node_timebase_invariant_invalid")
            && reasons.contains("depth_count_ratio_inconsistent")
            && reasons.contains("surface_normal_not_unit")
            && reasons.contains("alignment_freshness_inconsistent")
            && reasons.contains("schema_or_finite_invalid"),
        "tag parser stable codes incomplete: \(reasons.sorted())")
    require(
        result.boundNodeIDs == [1, 2, 3],
        "tag parser bound node ids wrong: \(result.boundNodeIDs)")
    require(
        result.observations.count == 3,
        "tag parser observation count wrong: \(result.observations.count)")
    require(
        verifiedBursts.releaseFramesWithIncompleteBurstAudit().isEmpty
            && verifiedBursts.remainingFrameCount == 0,
        "fully consumed burst frames must release without degradation")
    let localized = result.observations[0]
    require(
        localized.boundNodeID == 1
            && localized.barcode == "6901234567890"
            && localized.rawPositionM != nil
            && localized.burstID == "BURST-MAIN"
            && localized.frameID == "frame-1",
        "tag parser first observation must bind node 1 with a position and burst linkage")
    let unlocalized = result.observations[2]
    require(
        result.observations[1].rawPositionM != nil
            && unlocalized.boundNodeID == 3 && unlocalized.rawPositionM == nil,
        "height is independent of node-local position; unavailable evidence remains unlocalized")

    let missingDirectory = temporary.appendingPathComponent(
        "missing-observation-burst", isDirectory: true)
    try FileManager.default.createDirectory(
        at: missingDirectory, withIntermediateDirectories: true)
    try jsonLine(burst("BURST-MISSING", sequence: 1, frames: mainFrames))
        .data(using: .utf8)!.write(to: missingDirectory
            .appendingPathComponent("tag_observation_bursts.jsonl"))
    let missingBursts = try TagObservationBurstEvidenceParser.parse(
        snapshotDirectory: missingDirectory, nodes: nodes,
        priorMapID: mapID, priorMapSHA256: sha,
        trackingSessionID: session, floorID: floor,
        expectedBurstCount: 1, expectedLastBurstID: "BURST-MISSING")
    let partialLines = lines.prefix(2).joined()
        .replacingOccurrences(of: "BURST-MAIN", with: "BURST-MISSING")
    try partialLines.data(using: .utf8)!.write(
        to: missingDirectory.appendingPathComponent("tag_observations.jsonl"))
    let partialObservations = try TagObservationEvidenceParser.parse(
        snapshotDirectory: missingDirectory, nodes: nodes,
        priorMapID: mapID, priorMapSHA256: sha,
        trackingSessionID: session, floorID: floor,
        verifiedBursts: missingBursts)
    let incomplete = missingBursts.releaseFramesWithIncompleteBurstAudit()
    require(
        partialObservations.observations.count == 2
            && incomplete.count == 1
            && incomplete[0].burstID == "BURST-MISSING"
            && incomplete[0].missingObservationCount == 1
            && missingBursts.remainingFrameCount == 0,
        "missing observation frames must become one bounded burst degradation")

    let malformedDirectory = temporary.appendingPathComponent(
        "malformed-burst-degradation", isDirectory: true)
    try FileManager.default.createDirectory(
        at: malformedDirectory, withIntermediateDirectories: true)
    let validBurstLine = try jsonLine(
        burst("BURST-VALID", sequence: 1, frames: mainFrames))
    var malformedBurst = burst(
        "BURST-MALFORMED", sequence: 2, frames: mainFrames)
    malformedBurst["frame_count"] = 99
    let malformedBurstLine = try jsonLine(malformedBurst)
    try (validBurstLine + malformedBurstLine).data(using: .utf8)!.write(
        to: malformedDirectory.appendingPathComponent(
            "tag_observation_bursts.jsonl"))
    let partiallyValidBursts = try TagObservationBurstEvidenceParser.parse(
        snapshotDirectory: malformedDirectory, nodes: nodes,
        priorMapID: mapID, priorMapSHA256: sha,
        trackingSessionID: session, floorID: floor,
        expectedBurstCount: 2, expectedLastBurstID: "BURST-MALFORMED")
    require(
        partiallyValidBursts.bursts.count == 1
            && partiallyValidBursts.retainedDegradedBursts.count == 1
            && partiallyValidBursts.retainedDegradedBursts[0].burstID
                == "BURST-MALFORMED"
            && partiallyValidBursts.retainedDegradedBursts[0]
                .rejectionReason == "frame_count_or_frames_invalid"
            && partiallyValidBursts.sourceBusinessCaptureCount == 2
            && partiallyValidBursts.audit.recordTotal == 2
            && partiallyValidBursts.audit.totalRejected == 1
            && partiallyValidBursts.audit.rejectedDetails.first?.reason
                == "frame_count_or_frames_invalid",
        "one malformed burst must preserve its business identity, other bursts and the durable watermark")
    let degradedPriorMap = MobileMapLibrary.MapEntry(
        priorMapID: mapID,
        name: "degraded-burst-map",
        packageSHA256: sha,
        packageDirectory: malformedDirectory,
        floorCount: 1,
        elementCount: 0,
        compiledAtUTC: 0,
        compilerVersion: "test",
        canonicalSourceSHA256: String(repeating: "b", count: 64))
    let retainedDegradedResult = try MobileProcessingPipeline.finalizeTags(
        observations: [],
        resolverIndex: TagObservationResolver.NodeIndex(
            finalNodes: [], rawNodeStamps: [:]),
        shelves: [],
        shelfIndex: nil,
        structures: [],
        sessionID: session,
        storeID: "STORE-DEGRADED",
        priorMap: degradedPriorMap,
        floorID: floor,
        graphQualityPassed: false,
        minimumAssociationMarginM: 0.5,
        sourceBursts: partiallyValidBursts.bursts,
        retainedDegradedBursts:
            partiallyValidBursts.retainedDegradedBursts)
    require(
        retainedDegradedResult.0.count == 2
            && retainedDegradedResult.0.allSatisfy {
                $0.qualityStatus == "LOW_CONFIDENCE"
            }
            && retainedDegradedResult.0.contains {
                $0.tagInstanceID.contains("BURST-MALFORMED")
                    && $0.reason
                        == "burst_schema_degraded:frame_count_or_frames_invalid"
                    && $0.mapXM == nil && $0.mapYM == nil
            },
        "every identity-safe durable burst must produce exactly one retained tag row")
    // Report payload round-trips through CanonicalJSONEncoder.
    let report = audit.reportPayload()
    let reportData = try CanonicalJSONEncoder.encode(report)
    require(!reportData.isEmpty, "tag evidence report must serialize")
    print(
        "strict tag parser passed: accepted=\(audit.recordAccepted)/\(audit.recordTotal) "
            + "rejected=\(audit.totalRejected) unlocalized=\(audit.recordUnlocalizedSkipped)")
}
catch {
    FileHandle.standardError.write(
        Data("strict tag parser failed: \(error)\n".utf8))
    exit(11)
}

// MARK: - Strict native quality JSON / C outcome / RunSummary binding

/// Complete production-format native quality fixture. Host gateway tests use
/// the same strict schema/request/count binding as the C bridge; no minimal
/// or permissive test-only JSON is allowed to reach the pipeline.
func nativeQualityFixture(
    request: MobileNativeGraphRequest,
    path: String,
    disposition: MobileGraphDisposition,
    trajectoryCount: Int,
    skeletonCount: Int,
    publishCount: Int,
    factorCount: Int = 1,
    graphSHA256: String = String(repeating: "a", count: 64),
    factorSHA256: String = String(repeating: "b", count: 64)
) throws -> String {
    let residual: [String: Any] = [
        "count": 0, "p50": 0.0, "p95": 0.0, "max": 0.0,
    ]
    let residuals: [String: Any] = [
        "odometry": residual, "loop": residual,
        "prior": residual, "recovery": residual,
    ]
    let appliedPriors = min(request.absolutePriors.count, factorCount)
    let appliedPriorRecords = Array(request.absolutePriors.prefix(appliedPriors))
    let root: [String: Any] = [
        "format": "MarketScannerGraphQuality",
        "version": 3,
        "policy_version": "candidate-1",
        "abi_version": 5,
        "path": path,
        "disposition": disposition.reportValue,
        "graph_input_sha256": graphSHA256,
        "factor_set_sha256": factorSHA256,
        "projection_policy_version": Int(request.projectionPolicyVersion),
        "prior_map_id": request.priorMapID,
        "prior_map_sha256": request.priorMapSHA256,
        "tracking_session_id": request.trackingSessionID,
        "absolute_prior_count": request.absolutePriors.count,
        "parsed_valid_prior_count": request.absolutePriors.count,
        "applied_prior_factor_count": appliedPriors,
        "unique_prior_node_count": appliedPriors,
        "applied_prior_count": appliedPriors,
        "initial_map_pose_prior_count": appliedPriorRecords.filter {
            $0.kind == 3
        }.count,
        "robust_consensus_prior_count": appliedPriorRecords.filter {
            $0.kind != 3
        }.count,
        "robust_consensus_unique_prior_node_count": Set(
            appliedPriorRecords.filter { $0.kind != 3 }.map { $0.nodeID }
        ).count,
        "long_range_loop_factor_count": 0,
        "rejected_priors": 0,
        "fused_prior_duplicates": 0,
        "prior_conflicts": 0,
        "component_count": trajectoryCount > 0 ? 1 : 0,
        "total_components": trajectoryCount > 0 ? 1 : 0,
        "anchored_components": publishCount > 0 ? 1 : 0,
        "publish_nodes": publishCount,
        "publish_ratio": trajectoryCount > 0
            ? Double(publishCount) / Double(trajectoryCount) : 0.0,
        "anchored_ratio": publishCount > 0 ? 1.0 : 0.0,
        "isolated_count": 0,
        "cross_floor_link_count": 0,
        "gap_segments": 0,
        "aggregated_chains": 0,
        "reciprocal_inconsistent": 0,
        "weighted_chi2": 0.0,
        "dof": 0,
        "chi2_per_dof": 0.0,
        "residual_by_kind": residuals,
        "yaw_residual_by_kind": residuals,
        "residual_threshold_ratio": 0.0,
        "yaw_threshold_ratio": 0.0,
        "info_policy": ["regularized": 0, "rejected": 0],
        "correction": [
            "median": 0.0, "p95": 0.0, "max": 0.0, "max_jump": 0.0,
            "yaw_median": 0.0, "yaw_p95": 0.0, "yaw_max": 0.0,
            "yaw_max_jump": 0.0,
        ],
        "coverage": trajectoryCount > 0
            ? Double(publishCount) / Double(trajectoryCount) : 0.0,
        "optimizer_error": "",
        "solver": [
            "strategy": "g2o_robust", "iterations": 1,
            "final_error": 0.0, "converged": true,
            "stopped_reason": "converged", "initial_error": 0.0,
            "relative_improvement": 0.0, "wall_seconds": 0.01,
            "chunks": 1, "skeleton_nodes": skeletonCount,
            "factor_count": factorCount, "available": true,
        ],
        "gauge_by_component": [],
        "health": [
            "node_count": trajectoryCount, "link_count": 0,
            "malformed_links": 0, "void_links": 0,
            "ignored_optional_links": 0, "loop_links": 0,
            "prior_links": 0, "recovery_links": 0,
        ],
    ]
    let data = try CanonicalJSONEncoder.encode(root)
    guard let value = String(data: data, encoding: .utf8) else {
        throw MobileNativeFactorGraphError.invalidOutcome(
            "host quality fixture UTF-8 encoding failed")
    }
    return value
}

// P0 native outcome contract: disposition is authoritative before the
// optional error string; quality is a complete strict DTO bound exactly to
// request identity, C/runtime truth and RunSummary.
do {
    require(
        MobileNativeOutcomeContract.maximumPriors == 4_096
            && MobileNativeOutcomeContract.maximumFactors == 4_096,
        "native prior/factor caps must match the generated 4096 contract")
    try MobileNativeOutcomeContract.validateInputCounts(
        priorCount: 4_096, tagNodeCount: 0)
    var priorOverflowRejected = false
    do {
        try MobileNativeOutcomeContract.validateInputCounts(
            priorCount: 4_097, tagNodeCount: 0)
    } catch let error as MobileNativeFactorGraphError {
        if case .invalidOutcome = error { priorOverflowRejected = true }
    }
    require(priorOverflowRejected, "4097 Swift priors must fail before native allocation")

    let crossComponentBacktrack = [
        MobileNativeTrajectoryRow(
            id: 1, stamp: 100, xM: 0, yM: 0, yawRad: 0,
            mapID: 0, componentID: 1, publishEligible: true,
            uncertaintyM: 0.1),
        MobileNativeTrajectoryRow(
            id: 2, stamp: 10, xM: 1, yM: 0, yawRad: 0,
            mapID: 0, componentID: 2, publishEligible: false,
            uncertaintyM: 0.1),
        MobileNativeTrajectoryRow(
            id: 3, stamp: 101, xM: 2, yM: 0, yawRad: 0,
            mapID: 0, componentID: 1, publishEligible: true,
            uncertaintyM: 0.1),
    ]
    try MobileNativeOutcomeContract.validateComponentTimestampOrder(
        crossComponentBacktrack)
    var sameComponentBacktrackRejected = false
    do {
        var invalid = crossComponentBacktrack
        invalid.append(MobileNativeTrajectoryRow(
            id: 4, stamp: 99, xM: 3, yM: 0, yawRad: 0,
            mapID: 0, componentID: 1, publishEligible: true,
            uncertaintyM: 0.1))
        try MobileNativeOutcomeContract.validateComponentTimestampOrder(invalid)
    } catch let error as MobileNativeFactorGraphError {
        if case .invalidOutcome(let detail) = error {
            sameComponentBacktrackRejected = detail.contains("component 1")
        }
    }
    require(
        sameComponentBacktrackRejected,
        "native timestamps may backtrack across components but never inside one component")

    var resourceSemanticsPreserved = false
    do {
        _ = try MobileNativeOutcomeContract.disposition(
            rawValue: MobileGraphDisposition.resourceRequired.rawValue,
            errorMessage: "optimizer factors exceed the 4096 hard bound")
    } catch let error as MobileOnlyWorkflowError {
        if case .resourceRequired(let detail) = error {
            resourceSemanticsPreserved = detail.contains("4096")
        }
    }
    require(
        resourceSemanticsPreserved,
        "RESOURCE_REQUIRED + native error must remain a resumable resource error")

    var unknownDispositionRejectedFirst = false
    do {
        _ = try MobileNativeOutcomeContract.disposition(
            rawValue: 99, errorMessage: "generic native error")
    } catch let error as MobileNativeFactorGraphError {
        if case .invalidOutcome(let detail) = error {
            unknownDispositionRejectedFirst = detail.contains("unknown ABI disposition")
        }
    }
    require(
        unknownDispositionRejectedFirst,
        "unknown disposition must be rejected before interpreting native error")

    let request = MobileNativeGraphRequest(
        databaseURL: URL(fileURLWithPath: "/private/tmp/native-quality.db"),
        tagNodeIDs: [],
        absolutePriors: [MobileAbsolutePrior(
            nodeID: 1, mapXM: 0, mapYM: 0, mapYawRad: 0,
            information3x3: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            kind: 0, episodeID: 1)],
        priorMapID: "map-quality",
        priorMapSHA256: String(repeating: "c", count: 64),
        trackingSessionID: "session-quality",
        projectionPolicyVersion: 1,
        maxWallSeconds: 600)
    let trajectory = [
        MobileNativeTrajectoryRow(
            id: 1, stamp: 1, xM: 0, yM: 0, yawRad: 0,
            mapID: 0, componentID: 0, publishEligible: true,
            uncertaintyM: 0.1),
        MobileNativeTrajectoryRow(
            id: 2, stamp: 2, xM: 1, yM: 0, yawRad: 0,
            mapID: 0, componentID: 0, publishEligible: false,
            uncertaintyM: nil),
    ]
    let qualityAtBoundary = try nativeQualityFixture(
        request: request,
        path: "fast",
        disposition: .pass,
        trajectoryCount: 2,
        skeletonCount: 1,
        publishCount: 1,
        factorCount: 4_096)
    let outcome = MobileNativeGraphOutcome(
        disposition: .pass,
        qualityJSON: qualityAtBoundary,
        trajectory: trajectory,
        skeletonIDs: [1])
    let report = try MobileNativeOutcomeContract.qualityReport(
        in: outcome, request: request, expectedPath: "fast")
    require(
        report.solver.factorCount == 4_096,
        "native success must read solver.factor_count, not top-level factor_count")

    func qualityObject(_ json: String) throws -> [String: Any] {
        return try StrictJSONDocumentParser.object(
            from: Data(json.utf8),
            limits: StrictJSONDocumentLimits(maximumBytes: 1024 * 1024))
    }
    func mutatedQuality(
        _ json: String, _ mutate: (inout [String: Any]) -> Void
    ) throws -> String {
        var object = try qualityObject(json)
        mutate(&object)
        return String(
            data: try CanonicalJSONEncoder.encode(object), encoding: .utf8)!
    }
    func qualityRejected(_ json: String) -> Bool {
        do {
            _ = try MobileNativeQualityReport.parse(qualityJSON: json)
            return false
        } catch {
            return true
        }
    }

    let unknown = try mutatedQuality(qualityAtBoundary) {
        $0["factor_count"] = 4_096
    }
    let wrongType = try mutatedQuality(qualityAtBoundary) { $0["version"] = "2" }
    let wrongBool = try mutatedQuality(qualityAtBoundary) {
        var solver = $0["solver"] as! [String: Any]
        solver["factor_count"] = true
        $0["solver"] = solver
    }
    let overflow = try mutatedQuality(qualityAtBoundary) {
        var solver = $0["solver"] as! [String: Any]
        solver["factor_count"] = 4_097
        $0["solver"] = solver
    }
    let duplicate = qualityAtBoundary.replacingOccurrences(
        of: "\"version\":3",
        with: "\"version\":3,\"version\":3")
    require(
        qualityRejected(unknown) && qualityRejected(wrongType)
            && qualityRejected(wrongBool) && qualityRejected(overflow)
            && qualityRejected(duplicate),
        "strict quality must reject unknown/duplicate/wrong-type/Bool/overflow")

    func bindingRejected(
        qualityJSON: String = qualityAtBoundary,
        request candidateRequest: MobileNativeGraphRequest = request,
        expectedPath: String = "fast",
        disposition: MobileGraphDisposition = .pass,
        trajectoryRows: [MobileNativeTrajectoryRow] = trajectory,
        skeletonIDs: [Int64] = [1]
    ) -> Bool {
        do {
            _ = try MobileNativeOutcomeContract.qualityReport(
                in: MobileNativeGraphOutcome(
                    disposition: disposition,
                    qualityJSON: qualityJSON,
                    trajectory: trajectoryRows,
                    skeletonIDs: skeletonIDs),
                request: candidateRequest,
                expectedPath: expectedPath)
            return false
        } catch {
            return true
        }
    }
    var wrongIdentityRequest = request
    wrongIdentityRequest.trackingSessionID = "other-session"
    require(
        bindingRejected(expectedPath: "full_graph_optimization")
            && bindingRejected(disposition: .recoverableFail)
            && bindingRejected(request: wrongIdentityRequest)
            && bindingRejected(skeletonIDs: [1, 2])
            && bindingRejected(trajectoryRows: [trajectory[0], trajectory[1], trajectory[1]]),
        "quality request/path/disposition/C-count mismatch must fail closed")

    let badSHA = try mutatedQuality(qualityAtBoundary) {
        $0["graph_input_sha256"] = String(repeating: "A", count: 64)
    }
    let badABI = try mutatedQuality(qualityAtBoundary) { $0["abi_version"] = 3 }
    require(
        qualityRejected(badSHA) && qualityRejected(badABI),
        "quality SHA shape and ABI version mismatch must fail closed")
    var cBindingRejected = false
    do {
        try report.validate(
            request: request,
            expectedPath: "fast",
            disposition: .pass,
            trajectoryCount: 2,
            skeletonCount: 1,
            publishCount: 1,
            cABIVersion: 3,
            cFactorCount: 4_095,
            cGraphInputSHA256: String(repeating: "d", count: 64),
            cFactorSetSHA256: String(repeating: "e", count: 64))
    } catch {
        cBindingRejected = true
    }
    require(cBindingRejected, "runtime ABI/factor/graph/factor C binding mismatch must reject")

    var metricsObject = try qualityObject(qualityAtBoundary)
    var health = metricsObject["health"] as! [String: Any]
    health["loop_links"] = 3
    health["prior_links"] = 2
    health["recovery_links"] = 1
    metricsObject["health"] = health
    let metricsJSON = String(
        data: try CanonicalJSONEncoder.encode(metricsObject), encoding: .utf8)!
    let metrics = try MobileProcessingPipeline.NativeQualityMetrics.parse(
        qualityJSON: metricsJSON)
    require(
        metrics.factorCount == 4_096 && metrics.loopLinks == 3
            && metrics.priorLinks == 2 && metrics.recoveryLinks == 1
            && metrics.graphInputSHA256 == String(repeating: "a", count: 64)
            && metrics.factorSetSHA256 == String(repeating: "b", count: 64),
        "RunSummary projection must use exact typed quality values")
    var lenientMetricsRejected = false
    do {
        _ = try MobileProcessingPipeline.NativeQualityMetrics.parse(
            qualityJSON: "{\"format\":\"MarketScannerGraphQuality\",\"version\":3}")
    } catch {
        lenientMetricsRejected = true
    }
    require(
        lenientMetricsRejected,
        "RunSummary must reject partial quality instead of returning empty metrics")
    print("P0 strict native quality/C outcome/RunSummary binding passed")
}
catch {
    FileHandle.standardError.write(
        Data("P0 native outcome contract failed: \(error)\n".utf8))
    exit(18)
}

// Focused mode used by the Python host harness so the release-blocking
// absolute-prior/native contracts remain independently executable even when
// an unrelated earlier default-suite fixture is under active repair.
if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--absolute-prior-contract" {
    print("Absolute prior/native targeted contract tests passed")
    exit(0)
}

// === Mobile-Only V1R4: strict clock evidence parser (§7.3) ===
// The parser must fail closed on identity/schema/count/order/duplicate
// violations, detect discontinuity segments (clock jumps, timezone
// changes) and never interpolate across them; node stamps are never
// assumed to be UTC.
do {
    let sessionID = "CLOCK-SESSION"
    let now = Date().timeIntervalSince1970

    func clockLine(_ object: [String: Any]) throws -> String {
        let data = try CanonicalJSONEncoder.encode(object)
        return String(data: data, encoding: .utf8)! + "\n"
    }
    func correlation(
        _ uptime: Double, utc: Double, timezone: String = "UTC",
        offset: Int = 0, reason: String = "periodic"
    ) -> [String: Any] {
        return [
            "format": "MarketScannerClockCorrelation",
            "version": 2,
            "record_kind": "correlation",
            "tracking_session_id": sessionID,
            "monotonic_seconds": uptime,
            "utc_unix_seconds": utc,
            "timezone_id": timezone,
            "utc_offset_seconds": offset,
            "reason": reason,
        ]
    }
    func binding(
        _ nodeID: Int, nodeStamp: Double, uptime: Double, utc: Double,
        timezone: String = "UTC", offset: Int = 0
    ) -> [String: Any] {
        return [
            "format": "MarketScannerClockCorrelation",
            "version": 2,
            "record_kind": "node_binding",
            "tracking_session_id": sessionID,
            "node_id": nodeID,
            "node_stamp": nodeStamp,
            "sampled_frame_timestamp": nodeStamp,
            "system_uptime": uptime,
            "utc_unix_seconds": utc,
            "timezone_id": timezone,
            "utc_offset_seconds": offset,
            "reason": "node_bound",
        ]
    }
    func parseLines(
        _ lines: [String],
        expectedCorrelation: Int? = nil,
        expectedBinding: Int? = nil
    ) throws -> StrictClockEvidenceParser.ParsedEvidence {
        return try StrictClockEvidenceParser.parse(
            content: lines.joined(),
            expectedTrackingSessionID: sessionID,
            expectedCorrelationCount: expectedCorrelation,
            expectedBindingCount: expectedBinding)
    }
    func expectRejection(
        _ message: String,
        _ matches: (StrictClockEvidenceParser.ParseError) -> Bool,
        _ body: () throws -> StrictClockEvidenceParser.ParsedEvidence
    ) {
        do {
            _ = try body()
            require(false, "\(message): expected rejection")
        } catch let error as StrictClockEvidenceParser.ParseError {
            require(matches(error), "\(message): wrong error \(error)")
        } catch {
            require(false, "\(message): wrong error type \(error)")
        }
    }

    // T1: node stamps carry a NON-UTC offset (+300 s); the mapper must
    // recover the real UTC through the bindings, never the raw stamp.
    var t1Lines: [String] = []
    for index in 0..<4 {
        t1Lines.append(try clockLine(correlation(
            1000.0 + Double(index) * 30.0,
            utc: now + Double(index) * 30.0,
            reason: index == 0 ? "session_start" : "periodic")))
        t1Lines.append(try clockLine(binding(
            index + 1,
            nodeStamp: now + 300.0 + Double(index) * 0.5,
            uptime: 1000.0 + Double(index) * 0.5,
            utc: now + Double(index) * 0.5)))
    }
    let t1Evidence = try parseLines(
        t1Lines, expectedCorrelation: 4, expectedBinding: 4)
    require(
        StrictClockEvidenceParser.isEvidenceSufficient(t1Evidence),
        "T1 evidence must be sufficient")
    let t1Mapper = StrictClockEvidenceParser.buildMapper(
        evidence: t1Evidence, sessionStartStamp: now + 300.0)
    let t1Start = t1Mapper.utcSeconds(forMonotonic: 0) ?? -1
    let t1Mid = t1Mapper.utcSeconds(forMonotonic: 1.0) ?? -1
    require(t1Start >= 0 && t1Mid >= 0, "T1 mapper must cover the session span")
    require(
        abs(t1Start - now) < 1.0e-6,
        "T1 non-UTC stamp offset must recover the real UTC")
    require(
        abs(t1Mid - (now + 1.0)) < 1.0e-6,
        "T1 mid-span mapping must be linear")

    // T2: non-1:1 clock scale (UTC advances 2x uptime); the mapper must
    // still recover absolute UTC.
    var t2Lines: [String] = []
    for index in 0..<4 {
        t2Lines.append(try clockLine(correlation(
            1000.0 + Double(index) * 30.0,
            utc: now + Double(index) * 60.0,
            reason: index == 0 ? "session_start" : "periodic")))
        t2Lines.append(try clockLine(binding(
            index + 1,
            nodeStamp: now + Double(index) * 0.5,
            uptime: 1000.0 + Double(index) * 0.5,
            utc: now + Double(index) * 1.0)))
    }
    let t2Evidence = try parseLines(
        t2Lines, expectedCorrelation: 4, expectedBinding: 4)
    let t2Mapper = StrictClockEvidenceParser.buildMapper(
        evidence: t2Evidence, sessionStartStamp: now)
    let t2Mid = t2Mapper.utcSeconds(forMonotonic: 1.0) ?? -1
    require(t2Mid >= 0, "T2 mapper must cover the scaled session")
    require(
        abs(t2Mid - (now + 2.0)) < 1.0e-6,
        "T2 scaled clock must map to absolute UTC")

    // T3: manual clock jump +300 s mid-session -> explicit discontinuity
    // segment; interpolation across it is forbidden (UNAVAILABLE). V1R5
    // Bindings inside the jump segment cannot be attributed to either side.
    // Their strict business/node identity remains auditable, but only that
    // local binding is excluded; valid bindings on both sides survive.
    var t3Lines: [String] = []
    let t3Correlations: [(Double, Double, String)] = [
        (980.0, now - 20.0, "session_start"),
        (1000.0, now, "periodic"),
        (1015.0, now + 315.0, "system_clock_change"),
        (1030.0, now + 330.0, "periodic"),
        (1060.0, now + 360.0, "session_end"),
    ]
    for (uptime, utc, reason) in t3Correlations {
        t3Lines.append(try clockLine(correlation(uptime, utc: utc, reason: reason)))
    }
    let t3Bindings: [(Int, Double, Double)] = [
        (1, 990.5, now - 9.5), (2, 995.0, now - 5.0),
        (3, 1015.5, now + 315.5), (4, 1016.0, now + 316.0),
    ]
    for (nodeID, uptime, utc) in t3Bindings {
        t3Lines.append(try clockLine(binding(
            nodeID, nodeStamp: uptime, uptime: uptime, utc: utc)))
    }
    let t3Evidence = try parseLines(
        t3Lines, expectedCorrelation: 5, expectedBinding: 4)
    let t3Mapper = StrictClockEvidenceParser.buildMapper(
        evidence: t3Evidence, sessionStartStamp: 990.5)
    require(
        abs((t3Mapper.utcSeconds(forMonotonic: 0) ?? -1) - (now - 9.5)) < 1.0e-6,
        "T3 pre-jump mapping must be exact")
    require(
        t3Mapper.utcSeconds(forMonotonic: 10.0) == nil,
        "T3 must not interpolate across the clock jump")
    require(
        abs((t3Mapper.utcSeconds(forMonotonic: 25.0) ?? -1) - (now + 315.5)) < 1.0e-6,
        "T3 post-jump mapping must be exact")
    // T3b: a binding inside the jump segment is retained in the declared
    // watermark audit but excluded from the usable mapper inventory.
    let t3bEvidence = try parseLines([
            try clockLine(correlation(980.0, utc: now - 20.0, reason: "session_start")),
            try clockLine(correlation(1000.0, utc: now, reason: "periodic")),
            try clockLine(correlation(1015.0, utc: now + 315.0, reason: "system_clock_change")),
            try clockLine(correlation(1030.0, utc: now + 330.0, reason: "periodic")),
            try clockLine(binding(1, nodeStamp: 990.5, uptime: 990.5, utc: now - 9.5)),
            try clockLine(binding(2, nodeStamp: 1001.0, uptime: 1001.0, utc: now + 1.0)),
            try clockLine(binding(3, nodeStamp: 1015.5, uptime: 1015.5, utc: now + 315.5)),
        ])
    require(
        t3bEvidence.bindings.map(\.nodeID) == [1, 3]
            && t3bEvidence.rejectedCorrelationBindingNodeIDs == [2],
        "T3b must exclude only the unattributable jump-segment binding")

    // T4: DST transition (same timezone id, offset -18000 -> -14400);
    // absolute UTC stays continuous so no discontinuity edge, and the
    // local offset context switches at the transition.
    var t4Lines: [String] = []
    let tz = "America/Toronto"
    // 2025-03-09 06:59:30 UTC -> 07:00:00 UTC is the real Toronto
    // spring-forward boundary. Fixed UTC makes IANA offset validation
    // deterministic on every test date.
    let dstNow = 1_741_503_570.0
    t4Lines.append(try clockLine(correlation(
        1000.0, utc: dstNow, timezone: tz, offset: -18000, reason: "session_start")))
    t4Lines.append(try clockLine(correlation(
        1030.0, utc: dstNow + 30.0, timezone: tz, offset: -14400)))
    t4Lines.append(try clockLine(correlation(
        1060.0, utc: dstNow + 60.0, timezone: tz, offset: -14400, reason: "session_end")))
    t4Lines.append(try clockLine(binding(
        1, nodeStamp: 1000.5, uptime: 1000.5, utc: dstNow + 0.5,
        timezone: tz, offset: -18000)))
    t4Lines.append(try clockLine(binding(
        2, nodeStamp: 1030.5, uptime: 1030.5, utc: dstNow + 30.5,
        timezone: tz, offset: -14400)))
    let t4Evidence = try parseLines(
        t4Lines, expectedCorrelation: 3, expectedBinding: 2)
    let t4Mapper = StrictClockEvidenceParser.buildMapper(
        evidence: t4Evidence, sessionStartStamp: 1000.5)
    require(
        abs((t4Mapper.utcSeconds(forMonotonic: 15.0) ?? -1) - (dstNow + 15.5)) < 1.0e-6,
        "T4 DST must keep absolute UTC continuous")
    require(
        t4Mapper.context(forMonotonic: 5.0).utcOffsetSeconds == -18000
            && t4Mapper.context(forMonotonic: 40.0).utcOffsetSeconds == -14400,
        "T4 DST local offset context must switch")

    // T5: timezone change (UTC -> Asia/Shanghai) is an explicit
    // discontinuity; interpolation across it is forbidden. V1R5 §7.4:
    // bindings inside the change segment are rejected fail-closed.
    var t5Lines: [String] = []
    t5Lines.append(try clockLine(correlation(
        985.0, utc: now - 15.0, reason: "session_start")))
    t5Lines.append(try clockLine(correlation(
        1000.0, utc: now)))
    t5Lines.append(try clockLine(correlation(
        1030.0, utc: now + 30.0, timezone: "Asia/Shanghai", offset: 28800,
        reason: "timezone_change")))
    t5Lines.append(try clockLine(correlation(
        1060.0, utc: now + 60.0, timezone: "Asia/Shanghai", offset: 28800,
        reason: "session_end")))
    t5Lines.append(try clockLine(binding(
        1, nodeStamp: 990.5, uptime: 990.5, utc: now - 9.5)))
    t5Lines.append(try clockLine(binding(
        2, nodeStamp: 995.0, uptime: 995.0, utc: now - 5.0)))
    t5Lines.append(try clockLine(binding(
        3, nodeStamp: 1030.5, uptime: 1030.5, utc: now + 30.5,
        timezone: "Asia/Shanghai", offset: 28800)))
    t5Lines.append(try clockLine(binding(
        4, nodeStamp: 1031.0, uptime: 1031.0, utc: now + 31.0,
        timezone: "Asia/Shanghai", offset: 28800)))
    let t5Evidence = try parseLines(
        t5Lines, expectedCorrelation: 4, expectedBinding: 4)
    let t5Mapper = StrictClockEvidenceParser.buildMapper(
        evidence: t5Evidence, sessionStartStamp: 990.5)
    require(
        t5Mapper.utcSeconds(forMonotonic: 15.0) == nil,
        "T5 must not interpolate across the timezone change")
    require(
        abs((t5Mapper.utcSeconds(forMonotonic: 40.0) ?? -1) - (now + 30.5)) < 1.0e-6,
        "T5 post-change mapping must be exact")

    // T6: metadata watermark count mismatch.
    expectRejection("T6 count mismatch", { if case .countMismatch = $0 { return true }; return false }) {
        try parseLines(t1Lines, expectedCorrelation: 5)
    }
    // T7: truncated tail (missing final newline).
    expectRejection("T7 truncated tail", { if case .noFinalNewline = $0 { return true }; return false }) {
        _ = try parseLines(t1Lines)
        return try StrictClockEvidenceParser.parse(
            content: String(t1Lines.joined().dropLast()),
            expectedTrackingSessionID: sessionID,
            expectedCorrelationCount: nil,
            expectedBindingCount: nil)
    }
    // T8: duplicate monotonic sample.
    expectRejection("T8 duplicate sample", { if case .duplicateSample = $0 { return true }; return false }) {
        try parseLines([
            try clockLine(correlation(1000.0, utc: now, reason: "session_start")),
            try clockLine(correlation(1000.0, utc: now + 1.0)),
        ])
    }
    // T9: wrong tracking session identity.
    expectRejection("T9 session mismatch", { if case .sessionIdentityMismatch = $0 { return true }; return false }) {
        var wrong = correlation(1000.0, utc: now, reason: "session_start")
        wrong["tracking_session_id"] = "OTHER-SESSION"
        return try parseLines([try clockLine(wrong)])
    }
    // T10: duplicate node_id binding.
    expectRejection("T10 duplicate node id", { if case .duplicateNodeBinding = $0 { return true }; return false }) {
        try parseLines([
            try clockLine(correlation(1000.0, utc: now, reason: "session_start")),
            try clockLine(correlation(1030.0, utc: now + 30.0)),
            try clockLine(binding(1, nodeStamp: now, uptime: 1000.5, utc: now + 0.5)),
            try clockLine(binding(1, nodeStamp: now + 0.5, uptime: 1001.0, utc: now + 1.0)),
        ])
    }
    // T11: blank line.
    expectRejection("T11 blank line", { if case .blankLine = $0 { return true }; return false }) {
        try parseLines([
            try clockLine(correlation(1000.0, utc: now, reason: "session_start")),
            "\n",
        ])
    }
    // T12: legacy v1 schema is not authoritative.
    expectRejection("T12 legacy version", { if case .versionUnsupportedLegacy = $0 { return true }; return false }) {
        var legacy = correlation(1000.0, utc: now, reason: "session_start")
        legacy["version"] = 1
        return try parseLines([try clockLine(legacy)])
    }
    // T13: unknown field.
    expectRejection("T13 unknown field", { if case .unknownField = $0 { return true }; return false }) {
        var extra = correlation(1000.0, utc: now, reason: "session_start")
        extra["surprise"] = 1
        return try parseLines([try clockLine(extra)])
    }
    // T14: JSON bool must never pass as a strict integer.
    expectRejection("T14 bool int", { if case .invalidInteger = $0 { return true }; return false }) {
        var boolOffset = correlation(1000.0, utc: now, reason: "session_start")
        boolOffset["utc_offset_seconds"] = true
        return try parseLines([try clockLine(boolOffset)])
    }
    // T15: one locally inconsistent binding is excluded and audited. With
    // no other binding the evidence is insufficient, but parsing the rest of
    // the session is not falsely reported as corrupt.
    let t15Evidence = try parseLines([
            try clockLine(correlation(1000.0, utc: now, reason: "session_start")),
            try clockLine(correlation(1030.0, utc: now + 30.0)),
            try clockLine(binding(1, nodeStamp: now, uptime: 1005.0, utc: now + 15.0)),
        ])
    require(
        t15Evidence.bindings.isEmpty
            && t15Evidence.rejectedCorrelationBindingNodeIDs == [1]
            && !StrictClockEvidenceParser.isEvidenceSufficient(t15Evidence),
        "T15 mismatch must be audited locally and leave evidence insufficient")
    // T16: insufficient evidence (only one binding).
    let t16Evidence = try parseLines([
        try clockLine(correlation(1000.0, utc: now, reason: "session_start")),
        try clockLine(correlation(1030.0, utc: now + 30.0)),
        try clockLine(binding(1, nodeStamp: now, uptime: 1000.5, utc: now + 0.5)),
    ])
    require(
        !StrictClockEvidenceParser.isEvidenceSufficient(t16Evidence),
        "T16 one binding must be insufficient evidence")
    // T17: reordered (non-increasing) monotonic sample.
    expectRejection("T17 reordered", { if case .nonIncreasingMonotonic = $0 { return true }; return false }) {
        try parseLines([
            try clockLine(correlation(1000.0, utc: now, reason: "session_start")),
            try clockLine(correlation(990.0, utc: now + 1.0)),
        ])
    }
    // T18: backward clock.
    expectRejection("T18 backward clock", { if case .backwardClock = $0 { return true }; return false }) {
        try parseLines([
            try clockLine(correlation(1000.0, utc: now, reason: "session_start")),
            try clockLine(correlation(1030.0, utc: now - 10.0)),
        ])
    }
    // RC-H10: reason is a closed enum, and node_bound is binding-only.
    expectRejection("T19 reason whitelist", { if case .reasonInvalid = $0 { return true }; return false }) {
        try parseLines([
            try clockLine(correlation(1000.0, utc: now, reason: "invented_reason")),
        ])
    }
    // RC-H11: UTC is the authoritative injective axis. Local timestamps
    // may repeat during DST fall-back because timezone + offset remain in
    // every output row, but duplicate UTC can never be inverted safely.
    expectRejection("T20 non-injective UTC", { if case .nonInjectiveUTC = $0 { return true }; return false }) {
        try parseLines([
            try clockLine(correlation(1000.0, utc: now, reason: "session_start")),
            try clockLine(correlation(1030.0, utc: now)),
        ])
    }
    // RC-H09: degradation audit reports the original JSONL line, not the
    // ordinal of the compact binding array.
    let t21Evidence = try parseLines([
            try clockLine(correlation(1000.0, utc: now, reason: "session_start")),
            try clockLine(correlation(1030.0, utc: now + 30.0)),
            try clockLine(binding(
                1, nodeStamp: now, uptime: 1005.0, utc: now + 15.0)),
        ])
    require(
        t21Evidence.rejectedCorrelationBindingLines == [3],
        "T21 mismatch audit must retain the original JSONL line")
    // RC-B21: IANA id alone is insufficient; the offset must match that
    // timezone's rules at the exact UTC instant.
    expectRejection("T22 timezone offset", {
        if case .timezoneOffsetMismatch = $0 { return true }
        return false
    }) {
        try parseLines([
            try clockLine(correlation(
                1000.0, utc: now, timezone: "UTC", offset: 3600,
                reason: "session_start")),
        ])
    }
    // sampled_frame_timestamp and node_stamp share the RTAB-Map/node epoch
    // timebase. system_uptime is independent and must not be compared to
    // either of them directly.
    expectRejection("T23 frame/node-stamp relation", {
        if case .bindingFrameNodeStampMismatch = $0 { return true }
        return false
    }) {
        var badBinding = binding(
            1, nodeStamp: now, uptime: 1000.5, utc: now + 0.5)
        badBinding["sampled_frame_timestamp"] = 9990.0
        return try parseLines([
            try clockLine(correlation(
                1000.0, utc: now, reason: "session_start")),
            try clockLine(correlation(1030.0, utc: now + 30.0)),
            try clockLine(badBinding),
        ])
    }
    // T24a: clock bindings are sampled and may be sparse. Every binding must
    // exist in the DB and match its exact stamp, but an unbound DB node is a
    // bounded interpolation/UNAVAILABLE concern, not corrupt evidence.
    let sparseInventoryEvidence = try StrictClockEvidenceParser.parse(
        content: [
            try clockLine(correlation(
                1000.0, utc: now, reason: "session_start")),
            try clockLine(correlation(1030.0, utc: now + 30.0)),
            try clockLine(binding(
                1, nodeStamp: now, uptime: 1000.5, utc: now + 0.5)),
            try clockLine(binding(
                3, nodeStamp: now + 2.0, uptime: 1002.5,
                utc: now + 2.5)),
        ].joined(),
        expectedTrackingSessionID: sessionID,
        expectedCorrelationCount: 2,
        expectedBindingCount: 2,
        expectedNodeStampsByID: [
            1: now,
            2: now + 1.0,
            3: now + 2.0,
        ])
    require(
        sparseInventoryEvidence.bindings.count == 2,
        "T24a sparse DB clock bindings must be accepted")
    // A self-consistent sidecar must still bind every present clock record to
    // the exact snapshot DB node inventory; a fabricated id/stamp rejects.
    expectRejection("T24 DB node inventory", {
        if case .nodeInventoryMismatch = $0 { return true }
        return false
    }) {
        try StrictClockEvidenceParser.parse(
            content: t1Lines.joined(),
            expectedTrackingSessionID: sessionID,
            expectedCorrelationCount: 4,
            expectedBindingCount: 4,
            expectedNodeStampsByID: [
                1: now + 300.0,
                2: now + 300.5,
                3: now + 301.0,
                4: now + 999.0,
            ])
    }
    // Absolute residuals, not dimensionless 50% ratio drift, identify a
    // modest unannounced +3s jump. An explicit system_clock_change also
    // splits a two-sample run where no independent scale estimate exists.
    let modestJump = [
        ClockCorrelationRecord.make(
            trackingSessionID: sessionID, monotonicSeconds: 0,
            utcUnixSeconds: now, timezoneID: "UTC",
            utcOffsetSeconds: 0, reason: "session_start"),
        ClockCorrelationRecord.make(
            trackingSessionID: sessionID, monotonicSeconds: 30,
            utcUnixSeconds: now + 30, timezoneID: "UTC",
            utcOffsetSeconds: 0, reason: "periodic"),
        ClockCorrelationRecord.make(
            trackingSessionID: sessionID, monotonicSeconds: 60,
            utcUnixSeconds: now + 63, timezoneID: "UTC",
            utcOffsetSeconds: 0, reason: "periodic"),
    ]
    require(
        StrictClockEvidenceParser.discontinuityEdges(of: modestJump) == Set([1]),
        "T25 +3s absolute clock residual must mark the exact jump edge")
    let explicitJump = [
        modestJump[0],
        ClockCorrelationRecord.make(
            trackingSessionID: sessionID, monotonicSeconds: 30,
            utcUnixSeconds: now + 300, timezoneID: "UTC",
            utcOffsetSeconds: 0, reason: "system_clock_change"),
    ]
    require(
        StrictClockEvidenceParser.discontinuityEdges(of: explicitJump) == Set([0]),
        "T26 explicit system_clock_change must split a two-sample run")
    print(
        "strict clock parser passed: offset/scale/jump/DST/tz mapped, "
            + "count/truncate/duplicate/session/legacy/unknown/bool rejected")
}
catch {
    FileHandle.standardError.write(
        Data("strict clock parser failed: \(error)\n".utf8))
    exit(11)
}

var finalizationResourceUsage = rusage()
if getrusage(RUSAGE_SELF, &finalizationResourceUsage) == 0 {
    print("Default test peak RSS bytes: \(finalizationResourceUsage.ru_maxrss)")
}
print("PriorMapLocalizationCore Swift tests passed")
