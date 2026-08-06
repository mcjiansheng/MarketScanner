import Foundation

/// Fixed column contracts for the four business worksheets, matching
/// the Mobile-Only V1 product contract exactly.
enum MobileWorksheets {
    static let priceTagsHeaders = [
        "tag_instance_id", "barcode", "symbology", "store_id", "floor_id",
        "map_version", "prior_map_sha256", "tracking_session_id",
        "shelf_code", "shelf_side", "distance_from_shelf_start_cm",
        "position_ratio", "map_x_m", "map_y_m", "observation_count",
        "position_spread_cm", "localization_confidence",
        "association_confidence", "quality_status", "reason",
    ]

    static let devicePositionsHeaders = [
        "sequence", "local_timestamp", "utc_timestamp", "unix_time_s",
        "timezone_id", "utc_offset", "session_elapsed_s", "store_id",
        "floor_id", "map_x_m", "map_y_m", "yaw_deg", "position_status",
        "position_source", "before_node_id", "after_node_id",
        "interpolation_ratio", "localization_confidence",
        "estimated_uncertainty_m", "tracking_state",
        "graph_quality_status", "prior_map_id", "prior_map_sha256",
        "tracking_session_id", "app_git_sha",
    ]

    static let runSummaryHeaders = [
        "app_git_sha", "app_version", "device_model", "os_version",
        "store_id", "map_name", "prior_map_id", "prior_map_sha256",
        "canonical_source_sha256", "source_format",
        "tracking_session_id", "local_start", "local_end", "utc_start",
        "utc_end", "timezone_ids", "duration_seconds",
        "rtabmap_node_count", "factor_count", "loop_closure_count",
        "recovery_count", "prior_count",
        "processing_path", "processing_duration_seconds",
        "peak_memory_mb", "thermal_interruptions",
        "cancel_latency_seconds",
        "graph_quality_status", "accepted_tag_count",
        "rescan_tag_count", "device_position_row_count",
        "available_position_count", "unavailable_position_count",
        "result_id", "graph_input_sha256", "factor_set_sha256",
        "native_core_sha256", "policy_sha",
        "result_manifest_sha256", "workbook_sha256",
    ]

    static let rescanRequiredHeaders = [
        "task_id", "task_type", "floor_id", "barcode", "tag_instance_id",
        "shelf_code", "region_start_cm", "region_end_cm",
        "local_start_time", "local_end_time", "reason_code",
        "human_message", "suggested_action", "priority",
    ]

    enum RescanTaskType: String {
        case tagRescan = "TAG_RESCAN"
        case trajectoryGap = "TRAJECTORY_GAP"
        case weakLocalization = "WEAK_LOCALIZATION"
        case aisleAmbiguity = "AISLE_AMBIGUITY"
        case mapMismatch = "MAP_MISMATCH"
        case insufficientLoop = "INSUFFICIENT_LOOP"
    }
}

/// A finalized price tag row for the PriceTags worksheet.
struct FinalPriceTag: Equatable {
    var tagInstanceID: String
    var barcode: String
    var symbology: String
    var storeID: String
    var floorID: String
    var mapVersion: Int
    var priorMapSha256: String
    var trackingSessionID: String
    var shelfCode: String
    var shelfSide: String
    var distanceFromShelfStartCm: Double?
    var positionRatio: Double?
    var mapXM: Double
    var mapYM: Double
    var observationCount: Int
    var positionSpreadCm: Double
    var localizationConfidence: Double
    var associationConfidence: Double
    var qualityStatus: String
    var reason: String
}

/// A rescan task row for the RescanRequired worksheet.
struct RescanTask: Equatable {
    var taskID: String
    var taskType: MobileWorksheets.RescanTaskType
    var floorID: String
    var barcode: String
    var tagInstanceID: String?
    var shelfCode: String
    var regionStartCm: Double?
    var regionEndCm: Double?
    var localStartTime: String
    var localEndTime: String
    var reasonCode: String
    var humanMessage: String
    var suggestedAction: String
    var priority: Int
}
