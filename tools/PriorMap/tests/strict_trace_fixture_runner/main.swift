import Foundation

// The production target gets this default from
// RecoveryLifecycleEvidenceParser.swift. The focused fixture executable does
// not compile that unrelated parser graph, so provide the same frozen default.
enum RecoveryLifecycleEvidenceLimits {
    static let maximumJSONNestingDepth = 32
}

private func stableReason(_ error: Error) -> String {
    guard let error = error as? StrictLocalizationTraceParser.ParseError else {
        return "unexpected_error"
    }
    switch error {
    case .record(_, let reason):
        return reason
    case .qualificationLimitExceeded:
        return "qualification_limit_exceeded"
    case .countMismatch:
        return "count_mismatch"
    case .missingFile:
        return "missing_file"
    case .fileTooLarge:
        return "file_too_large"
    case .framing:
        return "framing_error"
    }
}

let arguments = CommandLine.arguments
let compactionOrigin: Double?
let fixtureDirectoryArgument: String
if arguments.count == 4, arguments[1] == "--compaction-origin",
   let origin = Double(arguments[2]), origin.isFinite {
    compactionOrigin = origin
    fixtureDirectoryArgument = arguments[3]
} else if arguments.count == 2 {
    compactionOrigin = nil
    fixtureDirectoryArgument = arguments[1]
} else {
    FileHandle.standardError.write(Data(
        "usage: strict-trace-runner [--compaction-origin SECONDS] FIXTURE_DIR\n".utf8))
    exit(2)
}

if fixtureDirectoryArgument == "--qualification-preflight" {
    do {
        _ = try StrictLocalizationTraceParser.parse(
            snapshotDirectory: FileManager.default.temporaryDirectory,
            trackingSessionID: "session-a",
            priorMapID: "map-a",
            priorMapSHA256:
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            floorID: "1",
            expectedCount:
                StrictLocalizationTraceParser.qualificationMaximumRecords + 1)
        print("unexpected_pass")
    } catch {
        print(stableReason(error))
    }
    exit(0)
}

let fixtureDirectory = URL(fileURLWithPath: fixtureDirectoryArgument)
let fileManager = FileManager.default
let files = try fileManager.contentsOfDirectory(
    at: fixtureDirectory,
    includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "jsonl" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

for fixture in files {
    let work = fileManager.temporaryDirectory.appendingPathComponent(
        "strict-trace-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: work) }
    try fileManager.copyItem(
        at: fixture,
        to: work.appendingPathComponent("localization_trace.jsonl"))
    let reason: String
    do {
        _ = try StrictLocalizationTraceParser.parse(
            snapshotDirectory: work,
            trackingSessionID: "session-a",
            priorMapID: "map-a",
            priorMapSHA256:
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            floorID: "1",
            expectedCount: 1,
            retentionOriginNodeTimestamp: compactionOrigin)
        reason = "OK"
    } catch {
        reason = stableReason(error)
    }
    print("\(fixture.lastPathComponent)=\(reason)")
}
