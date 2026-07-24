import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(1)
    }
}

func close(_ first: Double, _ second: Double, tolerance: Double = 1.0e-9) -> Bool {
    return abs(first - second) <= tolerance
}

require(PriorMapScanConfiguration.freeMapping.isReadyToStart, "free mapping must remain startable")
require(
    PriorMapScanConfiguration(
        formatVersion: 1,
        workflowMode: .priorMapLocalized,
        packageDirectory: nil,
        priorMapId: nil,
        priorMapSha256: nil,
        floorId: nil,
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
    initialMapPose: PriorMapPose2D(xM: 2, yM: 3, yawRad: .pi / 2))
require(ready.isReadyToStart, "complete prior-map setup must start")

let identity = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: 0,
    forwardX: 0,
    forwardZ: -1)
require(close(identity.xM, 0), "identity map x")
require(close(identity.yM, 0), "identity map y")
require(close(identity.yawRad, 0), "identity yaw must point toward map +y")

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
    forwardZ: -1)
require(close(backward.yM, -1), "ARKit +z backward must be map -y")

let right = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 1,
    positionZ: 0,
    forwardX: 0,
    forwardZ: -1)
require(close(right.xM, 1), "ARKit +x must be map +x")

let leftTurn = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: 0,
    forwardX: -1,
    forwardZ: 0)
require(close(leftTurn.yawRad, .pi / 2), "left turn must be positive map yaw")

let rightTurn = PriorMapStageOneMath.arkitHorizontalPose(
    positionX: 0,
    positionZ: 0,
    forwardX: 1,
    forwardZ: 0)
require(close(rightTurn.yawRad, -.pi / 2), "right turn must be negative map yaw")

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
    trackingState: "normal",
    accepted: false,
    validPointCount: 0,
    coverageAngleRad: 0,
    uniqueness: 0,
    residualCost: 0.15,
    mapMismatch: false)
require(initializing.phase == .initializing, "first unmatched frame must stay initializing")
confidenceManager.reset()
for timestamp in 1...3 {
    _ = confidenceManager.update(
        timestamp: Double(timestamp),
        trackingState: "normal",
        accepted: true,
        validPointCount: 100,
        coverageAngleRad: 1.2,
        uniqueness: 0.3,
        residualCost: 0.02,
        mapMismatch: false)
}
require(confidenceManager.phase == .stable, "three trusted observations must enter stable")
let weak = confidenceManager.update(
    timestamp: 4,
    trackingState: "limited",
    accepted: false,
    validPointCount: 40,
    coverageAngleRad: 0.2,
    uniqueness: 0,
    residualCost: 0.15,
    mapMismatch: false)
require(weak.phase == .weak, "limited tracking must degrade to weak")

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

print("PriorMapLocalizationCore Swift tests passed")
