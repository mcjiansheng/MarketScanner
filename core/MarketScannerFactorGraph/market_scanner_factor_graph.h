/*
 * MarketScanner shared factor-graph core (V1R2 Gate G, V1R3 native
 * correctness closeout).
 *
 * One native implementation serves both product surfaces:
 * - the iOS app links this translation unit directly (pure C ABI below);
 * - the PC diagnostic CLI (tools/Reprocess) calls the same core as a
 *   development oracle.
 *
 * Components (§11.1):
 *   RTABMapGraphReader       raw graph read (sqlite ro+immutable, strict
 *                            exact-BLOB contracts, V1R3 §10)
 *   GraphHealthInspector     inventory/finite/component/cross-map checks
 *   AdaptiveGraphReducer     skeleton selection (never fixed stride,
 *                            topology-ordered, V1R3 §11.6/§11.7)
 *   RobustSE2Optimizer       rtabmap g2o, information + robust kernel,
 *                            cancellable per iteration chunk (V1R3 §12)
 *   GraphQualityEvaluator    full rᵀΩr chi² incl. pose priors, global
 *                            anchor gate (V1R3 §14)
 *   FullTrajectoryReconstructor  C_i interpolation that never crosses
 *                            components/gaps, per-row component/floor
 *                            (V1R3 §15)
 *
 * V1R3 naming: the "full-graph optimization" entry point is exactly that
 * — it is NOT a sensor reprocess. True RTAB-Map sensor reprocessing is
 * not implemented on device this round and the pipeline fails closed
 * instead of silently substituting (§13).
 */

#ifndef MARKETSCANNER_FACTOR_GRAPH_H
#define MARKETSCANNER_FACTOR_GRAPH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Core ABI version; bumped on any semantic change.
#define MS_FACTOR_GRAPH_ABI_VERSION 4

/// Policy version of the built-in quality thresholds. Thresholds are
/// CANDIDATES until the Replay Pareto freezes a production policy
/// (V1R3 §14.5); the version travels with every quality report.
#define MS_QUALITY_POLICY_VERSION "candidate-1"

/// The on-device optimizer's non-negotiable stack/resource boundary.
/// Both vertices and factors must remain at or below this value before
/// entering g2o. Raw input and reconstructed trajectory may be larger.
#define MS_FACTOR_GRAPH_HARD_OPTIMIZER_NODES INT64_C(4096)
#define MS_FACTOR_GRAPH_HARD_OPTIMIZER_FACTORS INT64_C(4096)
#define MS_FACTOR_GRAPH_MAX_TRAJECTORY_ROWS INT64_C(200000)

/// Quality gate dispositions (§11.5 / §2).
typedef enum {
    MS_FACTOR_GRAPH_PASS = 0,
    MS_FACTOR_GRAPH_RECOVERABLE_FAIL = 1,
    MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL = 2,
    MS_FACTOR_GRAPH_RESOURCE_REQUIRED = 3,
    /// The graph could only be solved in its local frame: no accepted
    /// prior-map absolute constraint anchors it to the map. Diagnostic
    /// output only — never publishable (§6.4).
    MS_FACTOR_GRAPH_LOCAL_FRAME_ONLY = 4
} MSFactorGraphDisposition;

/// Absolute prior-map constraint kind (V1R3 §6.3).
typedef enum {
    MS_PRIOR_KIND_LOCALIZATION = 0,
    MS_PRIOR_KIND_RECOVERY = 1,
    MS_PRIOR_KIND_MANUAL = 2
} MSPriorKind;

/// One absolute prior: the node pose expressed in the PRIOR-MAP frame
/// (T_map_node). Never confused with the DB raw node pose (§6.3).
typedef struct {
    int64_t node_id;
    double map_x;
    double map_y;
    double map_yaw;
    /// Planar 3x3 information (row-major). Must come from the evidence
    /// policy (matcher uncertainty / recovery quality / manual policy),
    /// never an undocumented constant (§6.3).
    double information_3x3[9];
    int32_t kind;
    int64_t episode_id;
} MSAbsolutePriorC;

/// Cancellation probe: returns non-zero to abort the run. Probed at
/// least once per optimizer iteration chunk and between stages (§12.1).
typedef int (*MSFactorGraphCancelFn)(void *user);

/// Progress callback: fraction in [0,1].
typedef void (*MSFactorGraphProgressFn)(double fraction, void *user);

typedef struct {
    /// Snapshot database path (read-only, immutable; never written).
    const char *db_path;
    /// Node ids carrying tag evidence; the reducer always keeps them and
    /// the trajectory reconstruction must recover all of them.
    const int64_t *tag_node_ids;
    int64_t tag_node_count;
    /// Accepted prior-map absolute constraints (V1R3 Gate C). May be
    /// empty: the run then only yields LOCAL_FRAME_ONLY diagnostics.
    const MSAbsolutePriorC *absolute_priors;
    int64_t absolute_prior_count;
    /// Identity bindings carried into the quality report (§14.4).
    const char *prior_map_id;
    const char *prior_map_sha256;
    const char *tracking_session_id;
    int32_t projection_policy_version;
    /// Resource budgets (§16 / Gate L). Zero keeps the built-in default.
    int64_t max_nodes;
    double max_wall_seconds;
    /// Optimizer budgets (zero -> policy defaults).
    int32_t fast_iterations;
    int32_t deep_iterations;
    /// Cancellation + progress hooks (may be NULL).
    MSFactorGraphCancelFn cancel;
    void *cancel_user;
    MSFactorGraphProgressFn progress;
    void *progress_user;
} MSFactorGraphRequestC;

/// One reconstructed trajectory row (V1R3 §15): component and floor
/// identity travel with every node; uncertainty is NaN when it cannot be
/// estimated (never fabricated as 0).
typedef struct {
    int64_t id;
    double stamp;
    double x;
    double y;
    double yaw;
    int32_t map_id;
    int64_t component_id;
    /// Non-zero when the component is anchored by accepted prior-map
    /// constraints and may emit AVAILABLE positions.
    int32_t publish_eligible;
    double uncertainty_m;
} MSTrajectoryRowC;

typedef struct {
    /// Runtime ABI identity. Swift rejects an outcome whose runtime value
    /// differs from the ABI version compiled into its strict quality DTO.
    int32_t abi_version;

    /// Reconstructed full trajectory (§13): one row per raw DB node.
    MSTrajectoryRowC *rows;
    int64_t count;

    /// Optimized skeleton (subset): ids + SE2 poses.
    int64_t *skeleton_ids;
    double *skeleton_x;
    double *skeleton_y;
    double *skeleton_yaw;
    int64_t skeleton_count;

    /// §11.5/§14 quality metrics serialized as canonical JSON (streaming
    /// builder, fully escaped — no fixed buffer, V1R3 §14.4).
    char *quality_json;
    /// Exact UTF-8 byte count, excluding the trailing NUL. The Swift bridge
    /// never performs an unbounded strlen() over native-owned memory.
    int64_t quality_json_size;

    /// Independent C-ABI copies of the two native audit identities. Swift
    /// requires exact equality with the strict quality JSON before either
    /// value can reach RunSummary.
    char *graph_input_sha256;
    int64_t graph_input_sha256_size;
    char *factor_set_sha256;
    int64_t factor_set_sha256_size;

    /// Canonical native counts duplicated outside JSON so the bridge can
    /// detect a forged/stale report. `factor_count` mirrors the optimizer
    /// factor inventory; `publish_count` mirrors publish-eligible C rows.
    int64_t factor_count;
    int64_t publish_count;

    /// Disposition deciding the pipeline branch (§2).
    int32_t disposition;

    /// NULL on success, otherwise a heap-allocated error message.
    char *error;
} MSFactorGraphOutcomeC;

/// Fast Path (§2): health check → adaptive skeleton → robust SE(2)
/// optimization → quality gate → full trajectory reconstruction.
MSFactorGraphOutcomeC MSFactorGraphRunFast(const MSFactorGraphRequestC *request);

/// Full-graph optimization (V1R3 §13.1): every finite node participates;
/// this is NOT a sensor reprocess. Callers must run it AT MOST once and
/// only after a Fast RECOVERABLE_FAIL whose recovery policy allows it.
MSFactorGraphOutcomeC MSFactorGraphRunFullGraph(const MSFactorGraphRequestC *request);

void MSFactorGraphFree(MSFactorGraphOutcomeC *outcome);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* MARKETSCANNER_FACTOR_GRAPH_H */
