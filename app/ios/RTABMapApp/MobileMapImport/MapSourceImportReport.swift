import Foundation

/// Result of a completed map-source import, ready for the parse
/// confirmation UI and the mobile compiler.
struct MapSourceImportReport: Equatable {
    var format: String
    var fileSizeBytes: Int64
    var mapName: String
    var storeId: String
    var floorCount: Int
    var elementCount: Int
    var sourceFileSha256: String
    var canonicalSourceSha256: String
    var warningCount: Int
    var malformedRowCount: Int
    var coordinateContractOrigin: String

    var canonicalSource: MarketScannerPriorMapSource
}
