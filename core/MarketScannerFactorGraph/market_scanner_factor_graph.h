/*
 * MarketScanner shared factor-graph core (V1R2 Gate G §11 / Gate H §12).
 *
 * One native implementation serves both product surfaces:
 * - the iOS app links this translation unit directly (pure C ABI below);
 * - the PC diagnostic CLI (tools/Reprocess) calls the same core as a
 *   development oracle.
 *
 * Components (§11.1):
 *   RTABMapGraphReader       raw graph read (sqlite ro+immutable, strict)
 *   GraphHealthInspector     inventory/finite/component/cross-floor checks
 *   AdaptiveGraphReducer     skeleton selection (never fixed stride)
 *   RobustSE2Optimizer       rtabmap g2o, information + robust kernel
 *   GraphQualityEvaluator    metrics + PASS/RECOVERABLE_FAIL/... verdict
 *   FullTrajectoryReconstructor  C_i interpolation, recovers every node
 *
 * The Swift SE(2) solver stays a host-test reference only; production
 * runs through this core (§11.5).
 */

#ifndef MARKETSCANNER_FACTOR_GRAPH_H
#define MARKETSCANNER_FACTOR_GRAPH_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Quality gate dispositions (§11.5 / §2).
typedef enum {
    MS_FACTOR_GRAPH_PASS = 0,
    MS_FACTOR_GRAPH_RECOVERABLE_FAIL = 1,
    MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL = 2,
    MS_FACTOR_GRAPH_RESOURCE_REQUIRED = 3
} MSFactorGraphDisposition;

/// Cancellation probe: returns non-zero to abort the run.
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

typedef struct {
    /// Reconstructed full trajectory (§13): one row per raw DB node,
    /// skeleton corrections interpolated between anchors. All arrays
    /// share `count` and are heap-allocated.
    int64_t *ids;
    double *stamps;
    double *x;
    double *y;
    double *yaw;
    int64_t count;

    /// Optimized skeleton (subset of the trajectory): ids + SE2 poses.
    int64_t *skeleton_ids;
    double *skeleton_x;
    double *skeleton_y;
    double *skeleton_yaw;
    int64_t skeleton_count;

    /// §11.5 quality metrics serialized as canonical JSON.
    char *quality_json;

    /// Disposition deciding the pipeline branch (§2).
    int32_t disposition;

    /// NULL on success, otherwise a heap-allocated error message.
    char *error;
} MSFactorGraphOutcomeC;

/// Fast Path (§2): health check → adaptive skeleton → robust SE(2)
/// optimization → quality gate → full trajectory reconstruction.
MSFactorGraphOutcomeC MSFactorGraphRunFast(const MSFactorGraphRequestC *request);

/// Deep Path (§12): resource-controlled full-graph rebuild. Callers must
/// run it AT MOST once, only after a Fast RECOVERABLE_FAIL.
MSFactorGraphOutcomeC MSFactorGraphRunDeep(const MSFactorGraphRequestC *request);

void MSFactorGraphFree(MSFactorGraphOutcomeC *outcome);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* MARKETSCANNER_FACTOR_GRAPH_H */
