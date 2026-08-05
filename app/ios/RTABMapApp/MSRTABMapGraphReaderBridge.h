//
//  MSRTABMapGraphReaderBridge.h
//  RTABMapApp
//
//  In-process reader for the raw RTAB-Map graph stored in a finalized
//  session database (Mobile-Only V1R1 Gate E, section 9.4).
//
//  Contract:
//  - The database is opened read-only with `immutable=1`; the source DB
//    is never modified.
//  - Nodes keep their raw 3D pose (row-major 3x4: R | t). The business
//    layer projects to SE(2) and records the projection policy/version.
//  - Links keep type, the raw SE(3) transform and the 6x6 information
//    matrix (inverse covariance, doubles).
//  - The caller frees the result with MSMobileGraphReaderFree.
//
//  Pure C ABI so both Swift and C++ callers can use it directly.
//

#ifndef MSRTABMapGraphReaderBridge_h
#define MSRTABMapGraphReaderBridge_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One raw graph node. `pose` is the raw 3D pose stored in the DB,
/// row-major 3x4 (r11 r12 r13 tx, r21 r22 r23 ty, r31 r32 r33 tz).
typedef struct {
    int64_t id;
    double stamp;
    int32_t map_id;
    double pose[12];
} MSMobileGraphNodeC;

/// One graph link. `transform` is row-major 3x4 (SE3), `information`
/// is the 6x6 information matrix in doubles (36 values, row-major).
typedef struct {
    int64_t from;
    int64_t to;
    int32_t type;
    double transform[12];
    double information[36];
} MSMobileGraphLinkC;

typedef struct {
    MSMobileGraphNodeC *nodes;
    int64_t node_count;
    MSMobileGraphLinkC *links;
    int64_t link_count;
    /// Projection policy applied by this reader (business layer projects
    /// the raw 3D poses to SE(2) using this version).
    int32_t projection_policy_version;
    /// NULL on success, otherwise a heap-allocated error message.
    char *error;
} MSMobileGraphReadResult;

/// Reads the raw graph of `dbPath`. On failure `nodes`/`links` are NULL
/// and `error` is set. The returned buffer must be freed with
/// MSMobileGraphReaderFree.
MSMobileGraphReadResult MSMobileGraphReaderRead(const char *dbPath);

/// Frees a result returned by MSMobileGraphReaderRead (safe on zeroed
/// results).
void MSMobileGraphReaderFree(MSMobileGraphReadResult *result);

#ifdef __cplusplus
}
#endif

#endif /* MSRTABMapGraphReaderBridge_h */
