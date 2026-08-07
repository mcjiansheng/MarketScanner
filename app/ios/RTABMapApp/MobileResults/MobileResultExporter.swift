import Foundation

/// Assembles the four business worksheets from final processing data and
/// writes the workbook through the streaming XLSX writer.
enum MobileResultExporter {
    struct Input {
        var devicePositions: [FinalTrajectory.DevicePositionRow]
        var priceTags: [FinalPriceTag]
        var rescanTasks: [RescanTask]
        var runSummary: [String: String]
        var appGitSHA: String
        var appVersion: String
        var deviceModel: String
        var osVersion: String
    }

    static func export(input: Input, to url: URL) throws {
        let sheets = [
            priceTagsSheet(input),
            devicePositionsSheet(input),
            runSummarySheet(input),
            rescanSheet(input),
        ]
        try XLSXWorkbookWriter.write(
            sheets: sheets,
            coreProperties: [
                "creator": "MarketScanner",
                "title": "MarketScanner Store Scan Result",
            ],
            to: url
        )
    }

    static func priceTagsSheet(_ input: Input) -> XLSXWorkbookWriter.SheetSpec {
        // V1R4 §16.2: rows are produced lazily one at a time; the tags
        // array is never mapped into a full `[[CellValue]]`.
        return XLSXWorkbookWriter.SheetSpec(
            name: "PriceTags",
            headers: MobileWorksheets.priceTagsHeaders,
            rows: XLSXWorkbookWriter.XLSXRowMapSequence(source: input.priceTags) { tag in
                [
                    .text(tag.tagInstanceID),
                    .text(tag.barcode),
                    .text(tag.symbology),
                    .text(tag.storeID),
                    .text(tag.floorID),
                    .integer(Int64(tag.mapVersion)),
                    .text(tag.priorMapSha256),
                    .text(tag.trackingSessionID),
                    .text(tag.shelfCode),
                    .text(tag.shelfSegmentID),
                    .text(tag.shelfSide),
                    numberOrEmpty(tag.distanceFromShelfStartCm),
                    numberOrEmpty(tag.positionRatio),
                    .number(tag.mapXM),
                    .number(tag.mapYM),
                    .integer(Int64(tag.observationCount)),
                    .number(tag.positionSpreadCm),
                    .number(tag.localizationConfidence),
                    .number(tag.associationConfidence),
                    .text(tag.qualityStatus),
                    .text(tag.reason),
                ]
            }
        )
    }

    static func devicePositionsSheet(_ input: Input) -> XLSXWorkbookWriter.SheetSpec {
        // V1R4 §16.2: 100k+ rows stream row-by-row; never materialised.
        return XLSXWorkbookWriter.SheetSpec(
            name: "DevicePositions",
            headers: MobileWorksheets.devicePositionsHeaders,
            rows: XLSXWorkbookWriter.XLSXRowMapSequence(source: input.devicePositions) { row in
                [
                    .integer(Int64(row.sequence)),
                    .text(row.localTimestamp),
                    .text(row.utcTimestamp),
                    .integer(row.unixTimeS),
                    .text(row.timezoneID),
                    .integer(Int64(row.utcOffset)),
                    .number(row.sessionElapsedS),
                    .text(row.storeID),
                    .text(row.floorID),
                    numberOrEmpty(row.mapXM),
                    numberOrEmpty(row.mapYM),
                    numberOrEmpty(row.yawDeg),
                    .text(row.positionStatus),
                    .text(row.positionSource),
                    intOrEmpty(row.beforeNodeID),
                    intOrEmpty(row.afterNodeID),
                    numberOrEmpty(row.interpolationRatio),
                    numberOrEmpty(row.localizationConfidence),
                    numberOrEmpty(row.estimatedUncertaintyM),
                    .text(row.trackingState),
                    .text(row.graphQualityStatus),
                    .text(row.priorMapID),
                    .text(row.priorMapSha256),
                    .text(row.trackingSessionID),
                    .text(row.appGitSHA),
                ]
            }
        )
    }

    static func runSummarySheet(_ input: Input) -> XLSXWorkbookWriter.SheetSpec {
        let summary = input.runSummary
        return XLSXWorkbookWriter.SheetSpec(
            name: "RunSummary",
            headers: MobileWorksheets.runSummaryHeaders
        ) {
            [
                MobileWorksheets.runSummaryHeaders.map { header in
                    .text(summary[header] ?? "")
                },
            ]
        }
    }

    static func rescanSheet(_ input: Input) -> XLSXWorkbookWriter.SheetSpec {
        // V1R4 §16.2: rescan tasks stream lazily, never materialised.
        return XLSXWorkbookWriter.SheetSpec(
            name: "RescanRequired",
            headers: MobileWorksheets.rescanRequiredHeaders,
            rows: XLSXWorkbookWriter.XLSXRowMapSequence(source: input.rescanTasks) { task in
                [
                    .text(task.taskID),
                    .text(task.taskType.rawValue),
                    .text(task.floorID),
                    .text(task.barcode),
                    textOrEmpty(task.tagInstanceID),
                    .text(task.shelfCode),
                    .text(task.shelfSegmentID),
                    numberOrEmpty(task.regionStartCm),
                    numberOrEmpty(task.regionEndCm),
                    .text(task.localStartTime),
                    .text(task.localEndTime),
                    .text(task.reasonCode),
                    .text(task.humanMessage),
                    .text(task.suggestedAction),
                    .integer(Int64(task.priority)),
                ]
            }
        )
    }

    private static func numberOrEmpty(_ value: Double?) -> XLSXWorkbookWriter.CellValue {
        guard let value = value else { return .empty }
        return .number(value)
    }

    private static func intOrEmpty(_ value: Int64?) -> XLSXWorkbookWriter.CellValue {
        guard let value = value else { return .empty }
        return .integer(value)
    }

    private static func textOrEmpty(_ value: String?) -> XLSXWorkbookWriter.CellValue {
        guard let value = value else { return .empty }
        return .text(value)
    }
}
