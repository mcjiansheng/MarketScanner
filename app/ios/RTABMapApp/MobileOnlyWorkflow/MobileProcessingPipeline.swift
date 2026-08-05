import Foundation

/// End-to-end mobile processing pipeline (V1R1 Gate E/F/H/I/J).
///
/// Input: a finalized session directory (segment_0001) plus its source
/// database and a phone-compiled prior map from the on-device library.
/// Output: an immutable result package under the result library whose
/// workbook SHA256 is recorded only in the external result manifest.
///
/// Stages:
/// 1. P7R6D-grade immutable session snapshot (never touches the source DB).
/// 2. Read localization evidence (real sidecars) and the prior map.
/// 3. Fast Path: relative SE(2) factor-graph optimization over the
///    localized nodes.
/// 4. Final trajectory: one row per UTC second (1 Hz DevicePositions).
/// 5. Tag finalization: resolve -> cluster -> shelf association ->
///    automatic quality gate (ACCEPTED / RESCAN_REQUIRED).
/// 6. Result package files + streaming four-sheet XLSX + external
///    manifest commit.
enum MobileProcessingPipeline {

    struct Request {
        var finalizedSession: URL
        var sourceDatabase: URL
        var taskRoot: URL
        var priorMap: MobileMapLibrary.MapEntry
        var storeID: String
        var trackingSessionID: String
        var appGitSHA: String
        var appVersion: String
        var deviceModel: String
        var osVersion: String
    }

    struct Outcome {
        var resultEntry: MobileResultLibrary.ResultEntry
        var devicePositionCount: Int
        var availablePositionCount: Int
        var tagCount: Int
        var rescanCount: Int
    }

    enum PipelineError: Error, LocalizedError {
        case missingMetadata
        case emptyTrace
        case noOptimizedNodes
        case cannotBuildWorkbook(String)
        case invalidPriorMap(String)

        var errorDescription: String? {
            switch self {
            case .missingMetadata: return "会话元数据缺失"
            case .emptyTrace: return "本地化轨迹为空，无法处理"
            case .noOptimizedNodes: return "优化后没有可用节点"
            case .cannotBuildWorkbook(let d): return "工作簿生成失败：\(d)"
            case .invalidPriorMap(let d): return "先验地图无效：\(d)"
            }
        }
    }

    // MARK: - Run

    static func run(
        request: Request,
        progress: (Double, String) -> Void,
        isCancelled: () -> Bool
    ) throws -> Outcome {
        progress(0.05, "生成会话快照")
        let snapshot = try SessionSnapshotTransaction.snapshot(
            finalizedSession: request.finalizedSession,
            sourceDatabase: request.sourceDatabase,
            taskRoot: request.taskRoot)
        guard !isCancelled() else { throw MobileOnlyWorkflowError.cancelled }

        progress(0.15, "读取会话元数据")
        let metadata = try readMetadata(in: snapshot.snapshotDirectory)
        let floorID = metadata["floorId"] as? String ?? "1"
        let finalizedAtUnix = metadata["finalizedAtUnix"] as? Double
            ?? metadata["finalized_at_unix"] as? Double
            ?? Date().timeIntervalSince1970

        progress(0.20, "读取本地化轨迹")
        let traces = try readTrace(in: snapshot.snapshotDirectory)
        guard !traces.isEmpty else { throw PipelineError.emptyTrace }

        // --- Fast Path: SE(2) relative factor graph ---------------------
        progress(0.30, "快速路径优化")
        let sampledNodes = buildGraphNodes(from: traces)
        let graphNodes = sampledNodes.map { $0.node }
        let graphEdges = buildOdometryEdges(from: graphNodes)
        let optimized: SE2FactorGraphCore.OptimizedGraph
        do {
            optimized = try SE2FactorGraphCore.optimize(
                nodes: graphNodes, edges: graphEdges)
        } catch {
            throw MobileOnlyWorkflowError.processingFailed("Fast Path 求解失败：\(error)")
        }
        guard !optimized.poses.isEmpty else { throw PipelineError.noOptimizedNodes }
        guard !isCancelled() else { throw MobileOnlyWorkflowError.cancelled }

        // --- UTC mapping (clock correlations, segment-gated) ------------
        progress(0.40, "构建时钟映射")
        let utcMapper = try buildUTCMapper(
            snapshotDirectory: snapshot.snapshotDirectory,
            traces: traces,
            finalizedAtUnix: finalizedAtUnix)

        // --- Final trajectory (1 Hz) ------------------------------------
        progress(0.50, "构建最终轨迹")
        let finalNodes = optimized.poses.sorted { $0.key < $1.key }.compactMap {
            pair -> FinalTrajectory.Node? in
            guard let sampled = sampledNodes.first(where: { $0.id == pair.key }) else {
                return nil
            }
            return FinalTrajectory.Node(
                id: pair.key,
                monotonicSeconds: sampled.monotonicSeconds,
                xM: pair.value.xM,
                yM: pair.value.yM,
                yawRad: pair.value.yawRad,
                uncertaintyM: 0.0,
                floorID: sampled.floorID)
        }
        let lostIntervals = buildLostIntervals(from: traces)
        let trajectoryInput = FinalTrajectory.Input(
            nodes: finalNodes,
            lostIntervals: lostIntervals,
            sessionStartUTC: (traces.first.map { firstTraceUTC($0, utcMapper: utcMapper) })
                ?? finalizedAtUnix - 1,
            sessionEndUTC: finalizedAtUnix)
        let devicePositions = FinalTrajectory.resample(
            input: trajectoryInput,
            utcMapper: utcMapper,
            storeID: request.storeID,
            priorMapID: request.priorMap.priorMapID,
            priorMapSha256: request.priorMap.packageSHA256,
            trackingSessionID: request.trackingSessionID,
            appGitSHA: request.appGitSHA)
        guard !isCancelled() else { throw MobileOnlyWorkflowError.cancelled }

        // --- Tags -------------------------------------------------------
        progress(0.65, "解析价签")
        let tagObservations = try readTagObservations(in: snapshot.snapshotDirectory)
        let shelves = try readShelves(from: request.priorMap)
        let (priceTags, rescanTasks) = try finalizeTags(
            observations: tagObservations,
            finalNodes: finalNodes.map {
                TagObservationResolver.FinalNodePose(
                    id: $0.id,
                    monotonicSeconds: $0.monotonicSeconds,
                    pose: SE2Transform(xM: $0.xM, yM: $0.yM, yawRad: $0.yawRad),
                    floorID: $0.floorID)
            },
            shelves: shelves,
            sessionID: request.trackingSessionID,
            storeID: request.storeID,
            priorMap: request.priorMap,
            floorID: floorID,
            graphQualityPassed: optimized.converged)
        guard !isCancelled() else { throw MobileOnlyWorkflowError.cancelled }

        // --- Result package ---------------------------------------------
        progress(0.80, "生成结果包")
        let resultID = "result-\(UUID().uuidString.lowercased())"
        let resultDirectory = try MobileResultLibrary.resultDirectory(resultID: resultID)
        try FileManager.default.createDirectory(
            at: resultDirectory, withIntermediateDirectories: true)

        // final_trajectory.jsonl
        var trajectoryLines = ""
        for row in devicePositions {
            if let data = try? CanonicalJSONEncoder.encode(row.canonicalPayload),
               let line = String(data: data, encoding: .utf8) {
                trajectoryLines += line + "\n"
            }
        }
        try trajectoryLines.data(using: .utf8)!.write(
            to: resultDirectory.appendingPathComponent("final_trajectory.jsonl"))

        // final_tags.json / rescan_tasks.json / quality_report.json
        let tagsPayload: [String: Any] = [
            "format": "MarketScannerFinalTags",
            "version": 1,
            "count": priceTags.count,
            "tags": priceTags.map { priceTagPayload($0) },
        ]
        let tagsData = try CanonicalJSONEncoder.encode(tagsPayload)
        try tagsData.write(
            to: resultDirectory.appendingPathComponent("final_tags.json"))
        let rescanPayload: [String: Any] = [
            "format": "MarketScannerRescanTasks",
            "version": 1,
            "count": rescanTasks.count,
            "tasks": rescanTasks.map { rescanTaskPayload($0) },
        ]
        let rescanData = try CanonicalJSONEncoder.encode(rescanPayload)
        try rescanData.write(
            to: resultDirectory.appendingPathComponent("rescan_tasks.json"))
        let qualityReport: [String: Any] = [
            "format": "MarketScannerQualityReport",
            "version": 1,
            "graph": [
                "node_count": graphNodes.count,
                "edge_count": graphEdges.count,
                "final_residual": optimized.finalResidual,
                "iterations": optimized.iterationsUsed,
                "converged": optimized.converged,
            ],
            "trajectory": [
                "device_position_count": devicePositions.count,
                "available_count": devicePositions.filter { $0.positionStatus == "AVAILABLE" }.count,
                "unavailable_count": devicePositions.filter { $0.positionStatus != "AVAILABLE" }.count,
            ],
            "tags": [
                "observation_count": tagObservations.count,
                "accepted_count": priceTags.filter { $0.qualityStatus == "ACCEPTED" }.count,
                "rescan_count": rescanTasks.count,
            ],
        ]
        try CanonicalJSONEncoder.encode(qualityReport).write(
            to: resultDirectory.appendingPathComponent("quality_report.json"))
        // input_manifest.json copy from the snapshot transaction.
        let inputManifestURL = request.taskRoot.appendingPathComponent("input_manifest.json")
        if FileManager.default.fileExists(atPath: inputManifestURL.path) {
            try FileManager.default.copyItem(
                at: inputManifestURL,
                to: resultDirectory.appendingPathComponent("input_manifest.json"))
        }

        // --- Streaming four-sheet XLSX ----------------------------------
        progress(0.90, "导出工作簿")
        let runSummary = buildRunSummary(
            request: request,
            resultID: resultID,
            metadata: metadata,
            optimized: optimized,
            devicePositions: devicePositions,
            priceTags: priceTags,
            rescanTasks: rescanTasks,
            processingPath: "fast")
        let workbookName = "\(resultID).xlsx"
        let workbookURL = resultDirectory.appendingPathComponent(workbookName)
        do {
            try MobileResultExporter.export(
                input: MobileResultExporter.Input(
                    devicePositions: devicePositions,
                    priceTags: priceTags,
                    rescanTasks: rescanTasks,
                    runSummary: runSummary,
                    appGitSHA: request.appGitSHA,
                    appVersion: request.appVersion,
                    deviceModel: request.deviceModel,
                    osVersion: request.osVersion),
                to: workbookURL)
        } catch {
            throw PipelineError.cannotBuildWorkbook("\(error)")
        }

        // --- External manifest commit (workbook SHA is external only) ---
        progress(0.98, "提交结果清单")
        let entry = try MobileResultLibrary.commit(
            resultID: resultID,
            taskID: request.taskRoot.lastPathComponent,
            packageFiles: [
                "final_trajectory.jsonl",
                "final_tags.json",
                "quality_report.json",
                "rescan_tasks.json",
                "input_manifest.json",
            ],
            workbookFilename: workbookName,
            manifestExtras: [
                "store_id": request.storeID,
                "prior_map_id": request.priorMap.priorMapID,
                "prior_map_sha256": request.priorMap.packageSHA256,
                "tracking_session_id": request.trackingSessionID,
                "source_database": request.sourceDatabase.lastPathComponent,
            ])
        progress(1.0, "完成")
        return Outcome(
            resultEntry: entry,
            devicePositionCount: devicePositions.count,
            availablePositionCount: devicePositions.filter { $0.positionStatus == "AVAILABLE" }.count,
            tagCount: priceTags.count,
            rescanCount: rescanTasks.count)
    }

    // MARK: - Evidence readers

    /// One localized node record from `localization_trace.jsonl`.
    struct TraceRecord {
        var timestamp: Double
        var xM: Double
        var yM: Double
        var yawRad: Double
        var localizationState: String
        var trackingState: String
        var floorID: String
        var nodeTimebaseOffsetSeconds: Double
        var nodeTimebaseTimestamp: Double
        var confidence: Double
    }

    static func readMetadata(in snapshotDirectory: URL) throws -> [String: Any] {
        let url = snapshotDirectory.appendingPathComponent("metadata.json")
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
        else { throw PipelineError.missingMetadata }
        return object
    }

    static func readTrace(in snapshotDirectory: URL) throws -> [TraceRecord] {
        let url = snapshotDirectory.appendingPathComponent("localization_trace.jsonl")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var records: [TraceRecord] = []
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? StrictJSONDocumentParser.object(
                      from: data,
                      limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
            else { continue }
            guard let timestamp = object["timestamp"] as? Double,
                  let pose = object["estimatedPose"] as? [String: Any],
                  let xM = pose["x_m"] as? Double,
                  let yM = pose["y_m"] as? Double,
                  let yawRad = pose["yaw_rad"] as? Double
            else { continue }
            records.append(TraceRecord(
                timestamp: timestamp,
                xM: xM, yM: yM, yawRad: yawRad,
                localizationState: object["localizationState"] as? String ?? "unknown",
                trackingState: object["trackingState"] as? String ?? "unknown",
                floorID: object["floorId"] as? String ?? "1",
                nodeTimebaseOffsetSeconds: object["nodeTimebaseOffsetSeconds"] as? Double ?? 0,
                nodeTimebaseTimestamp: object["nodeTimebaseTimestamp"] as? Double ?? timestamp,
                confidence: object["confidence"] as? Double ?? 0))
        }
        return records
    }

    // MARK: - Fast Path graph

    /// One sampled graph node together with its trace metadata needed by
    /// the trajectory stage.
    struct GraphSampledNode {
        var id: Int64
        var monotonicSeconds: Double
        var floorID: String
        var node: SE2FactorGraphCore.Node
    }

    /// Samples the trace into graph nodes (stride keeps the solve fast on
    /// device while preserving loop structure).
    static func buildGraphNodes(from traces: [TraceRecord], stride: Int = 4) -> [GraphSampledNode] {
        var nodes: [GraphSampledNode] = []
        for (index, trace) in traces.enumerated() where index % stride == 0 {
            let id = Int64(index / stride) + 1
            let node = SE2FactorGraphCore.Node(
                id: id,
                initialPose: SE2Transform(xM: trace.xM, yM: trace.yM, yawRad: trace.yawRad),
                isAnchor: nodes.isEmpty,
                floorID: trace.floorID)
            nodes.append(GraphSampledNode(
                id: id,
                monotonicSeconds: trace.timestamp,
                floorID: trace.floorID,
                node: node))
        }
        return nodes
    }

    /// Odometry edges between consecutive sampled nodes (relative
    /// measurement = inv(T_i) * T_{i+1}, scalar weight).
    static func buildOdometryEdges(from nodes: [SE2FactorGraphCore.Node]) -> [SE2FactorGraphCore.Edge] {
        var edges: [SE2FactorGraphCore.Edge] = []
        for index in 0..<(nodes.count - 1) {
            let from = nodes[index]
            let to = nodes[index + 1]
            let measurement = from.initialPose.inverse.composed(with: to.initialPose)
            edges.append(SE2FactorGraphCore.Edge(
                from: from.id, to: to.id,
                measurement: measurement,
                weight: 1.0,
                kind: "odometry"))
        }
        return edges
    }

    // MARK: - Clock / UTC

    /// Builds a segment-gated monotonic->UTC mapper. Prefers the real
    /// `clock_correlations.jsonl` sidecar (V1R1 §8.2); falls back to a
    /// single segment derived from the trace node-timebase, which is the
    /// pre-Gate-D evidence available in existing sessions.
    static func buildUTCMapper(
        snapshotDirectory: URL,
        traces: [TraceRecord],
        finalizedAtUnix: Double
    ) throws -> MonotonicUTCMapper {
        let clockURL = snapshotDirectory.appendingPathComponent("clock_correlations.jsonl")
        if let content = try? String(contentsOf: clockURL, encoding: .utf8),
           let mapper = parseClockCorrelations(content, finalizedAtUnix: finalizedAtUnix) {
            return mapper
        }
        // Fallback: single segment using the first trace as the anchor.
        guard let first = traces.first else { return MonotonicUTCMapper(records: []) }
        var records: [ClockCorrelationRecord] = []
        for trace in traces {
            let utc = trace.nodeTimebaseTimestamp - (trace.timestamp - first.timestamp)
            records.append(ClockCorrelationRecord.make(
                trackingSessionID: "",
                monotonicSeconds: trace.timestamp,
                utcUnixSeconds: utc,
                timezoneID: TimeZone.current.identifier,
                utcOffsetSeconds: TimeZone.current.secondsFromGMT(),
                reason: "session_trace_fallback"))
        }
        return MonotonicUTCMapper(records: records)
    }

    /// Parses `clock_correlations.jsonl` (one JSON per line) into a
    /// segment-gated mapper. Segments are the session start, periodic
    /// records and explicit change events; an exact-count watermark is
    /// not required for the fallback path.
    static func parseClockCorrelations(
        _ content: String,
        finalizedAtUnix: Double
    ) -> MonotonicUTCMapper? {
        var records: [ClockCorrelationRecord] = []
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? StrictJSONDocumentParser.object(
                      from: data,
                      limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any],
                  let monotonic = object["monotonic_seconds"] as? Double,
                  let utcUnixSeconds = object["utc_unix_seconds"] as? Double
            else { continue }
            records.append(ClockCorrelationRecord.make(
                trackingSessionID: object["tracking_session_id"] as? String ?? "",
                monotonicSeconds: monotonic,
                utcUnixSeconds: utcUnixSeconds,
                timezoneID: object["timezone_id"] as? String ?? TimeZone.current.identifier,
                utcOffsetSeconds: object["utc_offset_seconds"] as? Int
                    ?? TimeZone.current.secondsFromGMT(),
                reason: object["reason"] as? String ?? "periodic"))
        }
        guard !records.isEmpty else { return nil }
        return MonotonicUTCMapper(records: records)
    }

    private static func firstTraceUTC(_ trace: TraceRecord, utcMapper: MonotonicUTCMapper) -> Double {
        return utcMapper.utcSeconds(forMonotonic: trace.timestamp)
            ?? trace.nodeTimebaseTimestamp
    }

    /// Lost intervals from the real localization/tracking states.
    static func buildLostIntervals(from traces: [TraceRecord]) -> [FinalTrajectory.LostInterval] {
        var intervals: [FinalTrajectory.LostInterval] = []
        var currentStart: Double?
        var currentReason = ""
        for trace in traces {
            let lost = trace.localizationState == "lost"
                || trace.localizationState == "initializing"
                || trace.trackingState == "unavailable"
            if lost {
                if currentStart == nil {
                    currentStart = trace.timestamp
                    currentReason = trace.localizationState == "initializing"
                        ? "localization_initializing" : "tracking_lost"
                }
            } else if let start = currentStart {
                intervals.append(FinalTrajectory.LostInterval(
                    fromMonotonic: start, toMonotonic: trace.timestamp,
                    reason: currentReason))
                currentStart = nil
            }
        }
        if let start = currentStart {
            intervals.append(FinalTrajectory.LostInterval(
                fromMonotonic: start,
                toMonotonic: traces.last?.timestamp ?? start,
                reason: currentReason))
        }
        return intervals
    }

    // MARK: - Tags

    struct RawTagObservation {
        var barcode: String
        var symbology: String
        var floorID: String
        var nodeID: Int64?
        var nodeTimestamp: Double?
        var frameMonotonicSeconds: Double
        var rawPositionM: (Double, Double, Double)
        var rawNodePose: SE2Transform
        var trackingSessionID: String
    }

    /// Reads `tag_observations.jsonl` (empty file -> []).
    static func readTagObservations(in snapshotDirectory: URL) throws -> [RawTagObservation] {
        let url = snapshotDirectory.appendingPathComponent("tag_observations.jsonl")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var result: [RawTagObservation] = []
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? StrictJSONDocumentParser.object(
                      from: data,
                      limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any]
            else { continue }
            guard let barcode = object["barcode"] as? String else { continue }
            let position = object["position"] as? [String: Any]
                ?? object["raw_position"] as? [String: Any]
            let pose = object["nodePose"] as? [String: Any]
                ?? object["raw_node_pose"] as? [String: Any]
            result.append(RawTagObservation(
                barcode: barcode,
                symbology: object["symbology"] as? String ?? "unknown",
                floorID: object["floorId"] as? String ?? object["floor_id"] as? String ?? "1",
                nodeID: (object["nodeId"] as? NSNumber)?.int64Value
                    ?? (object["node_id"] as? NSNumber)?.int64Value,
                nodeTimestamp: object["nodeTimestamp"] as? Double
                    ?? object["node_timestamp"] as? Double,
                frameMonotonicSeconds: object["timestamp"] as? Double
                    ?? object["frame_monotonic_seconds"] as? Double ?? 0,
                rawPositionM: (
                    (position?["x_m"] as? Double) ?? (position?["x"] as? Double) ?? 0,
                    (position?["y_m"] as? Double) ?? (position?["y"] as? Double) ?? 0,
                    (position?["z_m"] as? Double) ?? (position?["z"] as? Double) ?? 0),
                rawNodePose: SE2Transform(
                    xM: (pose?["x_m"] as? Double) ?? (pose?["x"] as? Double) ?? 0,
                    yM: (pose?["y_m"] as? Double) ?? (pose?["y"] as? Double) ?? 0,
                    yawRad: (pose?["yaw_rad"] as? Double) ?? (pose?["yaw"] as? Double) ?? 0),
                trackingSessionID: object["trackingSessionId"] as? String
                    ?? object["tracking_session_id"] as? String ?? ""))
        }
        return result
    }

    /// Shelf segments from the compiled prior-map package (`shelves.json`).
    static func readShelves(from map: MobileMapLibrary.MapEntry) throws -> [ShelfAssociationEngine.ShelfSegment] {
        let url = map.packageDirectory.appendingPathComponent("shelves.json")
        let data = try Data(contentsOf: url)
        guard let object = try? StrictJSONDocumentParser.object(
            from: data,
            limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any],
            let rawShelves = object["shelves"] as? [[String: Any]]
        else { throw PipelineError.invalidPriorMap(map.packageDirectory.path) }
        var shelves: [ShelfAssociationEngine.ShelfSegment] = []
        for raw in rawShelves {
            guard let shelfCode = raw["code"] as? String,
                  let floorID = raw["floor_id"] as? String,
                  let geometry = raw["geometry"] as? [String: Any]
            else { continue }
            // Accept either two points or bounds-derived endpoints.
            if let startX = geometry["x1_m"] as? Double,
               let startY = geometry["y1_m"] as? Double,
               let endX = geometry["x2_m"] as? Double,
               let endY = geometry["y2_m"] as? Double {
                shelves.append(ShelfAssociationEngine.ShelfSegment(
                    shelfCode: shelfCode, floorID: floorID,
                    startM: (startX, startY), endM: (endX, endY),
                    side: "front"))
            } else if let minX = geometry["min_x_m"] as? Double,
                      let minY = geometry["min_y_m"] as? Double,
                      let maxX = geometry["max_x_m"] as? Double,
                      let maxY = geometry["max_y_m"] as? Double {
                // Bounds fallback: use the longer axis as the shelf line.
                let horizontal = (maxX - minX) >= (maxY - minY)
                if horizontal {
                    shelves.append(ShelfAssociationEngine.ShelfSegment(
                        shelfCode: shelfCode, floorID: floorID,
                        startM: (minX, minY), endM: (maxX, minY),
                        side: "front"))
                } else {
                    shelves.append(ShelfAssociationEngine.ShelfSegment(
                        shelfCode: shelfCode, floorID: floorID,
                        startM: (minX, minY), endM: (minX, maxY),
                        side: "front"))
                }
            }
        }
        return shelves
    }

    static func finalizeTags(
        observations: [RawTagObservation],
        finalNodes: [TagObservationResolver.FinalNodePose],
        shelves: [ShelfAssociationEngine.ShelfSegment],
        sessionID: String,
        storeID: String,
        priorMap: MobileMapLibrary.MapEntry,
        floorID: String,
        graphQualityPassed: Bool
    ) throws -> ([FinalPriceTag], [RescanTask]) {
        guard !observations.isEmpty else { return ([], []) }

        // Resolve each observation against the final optimized nodes.
        var resolved: [TagObservationResolver.ResolvedObservation] = []
        for raw in observations {
            let observation = TagObservationResolver.RawObservation(
                barcode: raw.barcode,
                symbology: raw.symbology,
                floorID: raw.floorID,
                nodeID: raw.nodeID,
                nodeTimestamp: raw.nodeTimestamp,
                frameMonotonicSeconds: raw.frameMonotonicSeconds,
                rawPositionM: raw.rawPositionM,
                rawNodePose: raw.rawNodePose,
                trackingSessionID: raw.trackingSessionID)
            if let outcome = try? TagObservationResolver.resolve(
                observation: observation,
                finalNodes: finalNodes,
                sessionID: sessionID) {
                resolved.append(outcome)
            }
        }
        // Cluster: shelf/side grouping before spatial clustering; same
        // barcode on different shelves stays distinct.
        let instances = TagObservationResolver.clusterInstances(
            observations: resolved, clusterRadiusM: 1.5)

        var priceTags: [FinalPriceTag] = []
        var rescanTasks: [RescanTask] = []
        for instance in instances {
            let best = ShelfAssociationEngine.bestAssociation(
                point: (instance.mapXM, instance.mapYM),
                shelves: shelves,
                floorID: instance.floorID)
            let (status, reason): (String, String)
            if let association = best {
                let evaluation = AutomaticQualityGate.evaluate(
                    AutomaticQualityGate.TagQualityInput(
                        observationCount: instance.observationCount,
                        positionSpreadM: instance.positionSpreadM,
                        minimumBurstSamples: 3,
                        maximumSpreadM: 0.15,
                        bindingMethod: "resolved",
                        association: association,
                        maximumEndpointDistanceM: 0.15,
                        maximumAssociationDistanceM: 0.75,
                        graphQualityPassed: graphQualityPassed,
                        mapSessionIdentityConsistent: true))
                status = evaluation.0.rawValue
                reason = evaluation.1
                priceTags.append(FinalPriceTag(
                    tagInstanceID: "\(instance.barcode)-\(instance.floorID)-\(priceTags.count + 1)",
                    barcode: instance.barcode,
                    symbology: instance.symbology,
                    storeID: storeID,
                    floorID: instance.floorID,
                    mapVersion: 1,
                    priorMapSha256: priorMap.packageSHA256,
                    trackingSessionID: sessionID,
                    shelfCode: association.shelfCode,
                    shelfSide: association.shelfSide,
                    distanceFromShelfStartCm: association.distanceFromShelfStartCm,
                    positionRatio: association.positionRatio,
                    mapXM: instance.mapXM,
                    mapYM: instance.mapYM,
                    observationCount: instance.observationCount,
                    positionSpreadCm: instance.positionSpreadM,
                    localizationConfidence: instance.localizationConfidence,
                    associationConfidence: instance.associationConfidence,
                    qualityStatus: status,
                    reason: reason))
                if status == "RESCAN_REQUIRED" {
                    rescanTasks.append(RescanTask(
                        taskID: "rescan-\(rescanTasks.count + 1)-\(instance.barcode)",
                        taskType: .tagRescan,
                        floorID: instance.floorID,
                        barcode: instance.barcode,
                        tagInstanceID: "\(instance.barcode)-\(instance.floorID)-\(priceTags.count)",
                        shelfCode: association.shelfCode,
                        regionStartCm: nil,
                        regionEndCm: nil,
                        localStartTime: "",
                        localEndTime: "",
                        reasonCode: reason,
                        humanMessage: reason,
                        suggestedAction: "重新扫描该价签",
                        priority: 1))
                }
            } else {
                priceTags.append(FinalPriceTag(
                    tagInstanceID: "\(instance.barcode)-\(instance.floorID)-\(priceTags.count + 1)",
                    barcode: instance.barcode,
                    symbology: instance.symbology,
                    storeID: storeID,
                    floorID: instance.floorID,
                    mapVersion: 1,
                    priorMapSha256: priorMap.packageSHA256,
                    trackingSessionID: sessionID,
                    shelfCode: "",
                    shelfSide: "",
                    distanceFromShelfStartCm: nil,
                    positionRatio: nil,
                    mapXM: instance.mapXM,
                    mapYM: instance.mapYM,
                    observationCount: instance.observationCount,
                    positionSpreadCm: instance.positionSpreadM,
                    localizationConfidence: instance.localizationConfidence,
                    associationConfidence: instance.associationConfidence,
                    qualityStatus: "RESCAN_REQUIRED",
                    reason: "no_shelf_association"))
                rescanTasks.append(RescanTask(
                    taskID: "rescan-\(rescanTasks.count + 1)-\(instance.barcode)",
                    taskType: .tagRescan,
                    floorID: instance.floorID,
                    barcode: instance.barcode,
                    tagInstanceID: "\(instance.barcode)-\(instance.floorID)-\(priceTags.count)",
                    shelfCode: "",
                    regionStartCm: nil,
                    regionEndCm: nil,
                    localStartTime: "",
                    localEndTime: "",
                    reasonCode: "no_shelf_association",
                    humanMessage: "无法关联货架",
                    suggestedAction: "重新扫描该价签",
                    priority: 1))
            }
        }
        return (priceTags, rescanTasks)
    }

    // MARK: - Payload builders

    private static func buildRunSummary(
        request: Request,
        resultID: String,
        metadata: [String: Any],
        optimized: SE2FactorGraphCore.OptimizedGraph,
        devicePositions: [FinalTrajectory.DevicePositionRow],
        priceTags: [FinalPriceTag],
        rescanTasks: [RescanTask],
        processingPath: String
    ) -> [String: String] {
        let available = devicePositions.filter { $0.positionStatus == "AVAILABLE" }.count
        return [
            "app_git_sha": request.appGitSHA,
            "app_version": request.appVersion,
            "device_model": request.deviceModel,
            "os_version": request.osVersion,
            "store_id": request.storeID,
            "map_name": request.priorMap.name,
            "prior_map_id": request.priorMap.priorMapID,
            "prior_map_sha256": request.priorMap.packageSHA256,
            "canonical_source_sha256": request.priorMap.canonicalSourceSHA256,
            "source_format": metadata["formatVersion"] as? String ?? "xlsx",
            "tracking_session_id": request.trackingSessionID,
            "local_start": devicePositions.first?.localTimestamp ?? "",
            "local_end": devicePositions.last?.localTimestamp ?? "",
            "utc_start": devicePositions.first?.utcTimestamp ?? "",
            "utc_end": devicePositions.last?.utcTimestamp ?? "",
            "timezone_ids": devicePositions.first?.timezoneID ?? "",
            "duration_seconds": String(format: "%.1f",
                (devicePositions.last?.sessionElapsedS ?? 0) - (devicePositions.first?.sessionElapsedS ?? 0)),
            "rtabmap_node_count": String(optimized.poses.count),
            "factor_count": String(optimized.poses.count > 0 ? optimized.poses.count - 1 : 0),
            "loop_closure_count": "0",
            "processing_path": processingPath,
            "processing_duration_seconds": "0.0",
            "peak_memory_mb": "0",
            "thermal_interruptions": "0",
            "graph_quality_status": optimized.converged ? "CONVERGED" : "DIVERGED",
            "accepted_tag_count": String(priceTags.filter { $0.qualityStatus == "ACCEPTED" }.count),
            "rescan_tag_count": String(rescanTasks.count),
            "device_position_row_count": String(devicePositions.count),
            "available_position_count": String(available),
            "unavailable_position_count": String(devicePositions.count - available),
            // V1R1 §14.2: the workbook carries the result id; the final
            // manifest/workbook SHA256 live only in the external
            // result_manifest.json and stay empty here.
            "result_id": resultID,
            "result_manifest_sha256": "",
            "workbook_sha256": "",
        ]
    }

    private static func priceTagPayload(_ tag: FinalPriceTag) -> [String: Any] {
        var payload: [String: Any] = [
            "tag_instance_id": tag.tagInstanceID,
            "barcode": tag.barcode,
            "symbology": tag.symbology,
            "store_id": tag.storeID,
            "floor_id": tag.floorID,
            "map_version": tag.mapVersion,
            "prior_map_sha256": tag.priorMapSha256,
            "tracking_session_id": tag.trackingSessionID,
            "shelf_code": tag.shelfCode,
            "shelf_side": tag.shelfSide,
            "map_x_m": tag.mapXM,
            "map_y_m": tag.mapYM,
            "observation_count": tag.observationCount,
            "position_spread_cm": tag.positionSpreadCm,
            "localization_confidence": tag.localizationConfidence,
            "association_confidence": tag.associationConfidence,
            "quality_status": tag.qualityStatus,
            "reason": tag.reason,
        ]
        if let distance = tag.distanceFromShelfStartCm { payload["distance_from_shelf_start_cm"] = distance }
        if let ratio = tag.positionRatio { payload["position_ratio"] = ratio }
        return payload
    }

    private static func rescanTaskPayload(_ task: RescanTask) -> [String: Any] {
        var payload: [String: Any] = [
            "task_id": task.taskID,
            "task_type": task.taskType.rawValue,
            "floor_id": task.floorID,
            "barcode": task.barcode,
            "shelf_code": task.shelfCode,
            "reason_code": task.reasonCode,
            "human_message": task.humanMessage,
            "suggested_action": task.suggestedAction,
            "priority": task.priority,
        ]
        if let id = task.tagInstanceID { payload["tag_instance_id"] = id }
        if let start = task.regionStartCm { payload["region_start_cm"] = start }
        if let end = task.regionEndCm { payload["region_end_cm"] = end }
        if !task.localStartTime.isEmpty { payload["local_start_time"] = task.localStartTime }
        if !task.localEndTime.isEmpty { payload["local_end_time"] = task.localEndTime }
        return payload
    }
}
