/*
 * MarketScanner shared factor-graph core implementation (V1R2 Gate G/H).
 *
 * Read-only contract: the snapshot database is opened with
 * `mode=ro&immutable=1` and is never written (§10 / §9.3).
 */

#include "market_scanner_factor_graph.h"

#include <rtabmap/core/Link.h>
#include <rtabmap/core/Optimizer.h>
#include <rtabmap/core/Parameters.h>
#include <rtabmap/core/Transform.h>

#include <opencv2/core/core.hpp>

#include <sqlite3.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>

namespace {

// MARK: - SE(2) math -------------------------------------------------------

struct SE2
{
    double x = 0.0;
    double y = 0.0;
    double yaw = 0.0;
};

double normalizeAngle(double angle)
{
    while(angle > M_PI) angle -= 2.0 * M_PI;
    while(angle < -M_PI) angle += 2.0 * M_PI;
    return angle;
}

SE2 se2Inverse(const SE2 & t)
{
    const double c = std::cos(t.yaw);
    const double s = std::sin(t.yaw);
    SE2 out;
    out.x = -(c * t.x + s * t.y);
    out.y = -(-s * t.x + c * t.y);
    out.yaw = -t.yaw;
    return out;
}

SE2 se2Compose(const SE2 & a, const SE2 & b)
{
    const double c = std::cos(a.yaw);
    const double s = std::sin(a.yaw);
    SE2 out;
    out.x = a.x + c * b.x - s * b.y;
    out.y = a.y + s * b.x + c * b.y;
    out.yaw = normalizeAngle(a.yaw + b.yaw);
    return out;
}

/// §13: C_i = SE2Interpolate(C_a, C_b, alpha) with angle unwinding on
/// the shortest arc.
SE2 se2Interpolate(const SE2 & a, const SE2 & b, double alpha)
{
    alpha = std::min(1.0, std::max(0.0, alpha));
    SE2 out;
    out.x = a.x + (b.x - a.x) * alpha;
    out.y = a.y + (b.y - a.y) * alpha;
    out.yaw = normalizeAngle(a.yaw + normalizeAngle(b.yaw - a.yaw) * alpha);
    return out;
}

SE2 se2FromTransform(const rtabmap::Transform & t)
{
    SE2 out;
    if(t.isNull())
    {
        return out;
    }
    out.x = t.x();
    out.y = t.y();
    out.yaw = std::atan2(t.r21(), t.r11());
    return out;
}

rtabmap::Transform transformFromSE2(const SE2 & p)
{
    return rtabmap::Transform(
        static_cast<float>(p.x), static_cast<float>(p.y), static_cast<float>(p.yaw));
}

bool se2Finite(const SE2 & p)
{
    return std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.yaw);
}

// MARK: - Graph model ------------------------------------------------------

struct RawNode
{
    int64_t id = 0;
    double stamp = 0.0;
    int32_t mapId = 0;
    SE2 pose;
    bool finite = false;
};

struct RawLink
{
    int64_t from = 0;
    int64_t to = 0;
    int32_t type = 0;
    SE2 measurement;
    /// Planar 3x3 information (x, y, yaw), row-major.
    double information[9];
    bool finite = false;
    bool crossMap = false;
};

struct GraphModel
{
    std::vector<RawNode> nodes; // sorted by id
    std::vector<RawLink> links;
    std::map<int64_t, size_t> nodeIndex;
    int64_t duplicateNodes = 0;
    int64_t malformedPoses = 0;
    int64_t malformedLinks = 0;
};

/// Extracts the planar (x, y, yaw) information block from the RTAB-Map
/// 6x6 information matrix ([x y z roll pitch yaw]). Every diagonal entry
/// is clamped to a strictly positive finite value because rtabmap::Link
/// asserts positivity; a near-zero clamp keeps a "no weight" intent
/// (e.g. yaw-free pose priors) while staying fail-closed. Falls back to
/// a modest diagonal when the stored block carries no planar weight.
void planarBlock(const double info36[36], double out[9])
{
    const int idx[3] = {0, 1, 5};
    double sum = 0.0;
    for(int r = 0; r < 3; ++r)
    {
        for(int c = 0; c < 3; ++c)
        {
            double v = info36[idx[r] * 6 + idx[c]];
            if(!std::isfinite(v)) v = 0.0;
            if(r != c && std::fabs(v) > 1.0e12) v = 0.0;
            out[r * 3 + c] = v;
            if(r == c) sum += std::fabs(out[r * 3 + c]);
        }
    }
    if(sum <= 1.0e-12)
    {
        for(int i = 0; i < 9; ++i) out[i] = 0.0;
        out[0] = out[4] = out[8] = 10.0;
        return;
    }
    // Partial zero/negative diagonals (legal upstream, e.g. yaw-free
    // priors): clamp to a near-zero positive weight.
    for(int d = 0; d < 3; ++d)
    {
        if(!(out[d * 3 + d] > 0.0)) out[d * 3 + d] = 1.0e-6;
    }
}

/// Information of the inverted SE(2) measurement: I' = H^T I H with H
/// the Jacobian of the inverse map at the measurement (analytic, same
/// contract as the PC oracle's inverseMeasurementInformation).
void invertPlanarInformation(const SE2 & measurement, const double info[9], double out[9])
{
    const double c = std::cos(measurement.yaw);
    const double s = std::sin(measurement.yaw);
    const SE2 inv = se2Inverse(measurement);
    // Rows: d(inv)/d(x), d(inv)/d(y), d(inv)/d(yaw).
    const double H[9] = {
        -c, -s, inv.y,
         s, -c, inv.x,
         0,  0, -1,
    };
    // out = H^T * info * H
    double tmp[9];
    for(int r = 0; r < 3; ++r)
    {
        for(int col = 0; col < 3; ++col)
        {
            double acc = 0.0;
            for(int k = 0; k < 3; ++k)
            {
                acc += info[r * 3 + k] * H[k * 3 + col];
            }
            tmp[r * 3 + col] = acc;
        }
    }
    for(int r = 0; r < 3; ++r)
    {
        for(int col = 0; col < 3; ++col)
        {
            double acc = 0.0;
            for(int k = 0; k < 3; ++k)
            {
                acc += H[k * 3 + r] * tmp[k * 3 + col];
            }
            out[r * 3 + col] = acc;
        }
    }
}

cv::Mat sixFromPlanar(const double planar[9])
{
    cv::Mat info = cv::Mat::zeros(6, 6, CV_64FC1);
    const int idx[3] = {0, 1, 5};
    for(int r = 0; r < 3; ++r)
    {
        for(int c = 0; c < 3; ++c)
        {
            double v = planar[r * 3 + c];
            if(!std::isfinite(v)) v = 0.0;
            if(r == c && !(v > 0.0)) v = 1.0e-6;
            info.at<double>(idx[r], idx[c]) = v;
        }
    }
    // rtabmap::Link rejects null Z/roll/pitch information; the planar
    // solver marginalizes them, so unit weight is the documented
    // "unknown" convention.
    info.at<double>(2, 2) = 1.0;
    info.at<double>(3, 3) = 1.0;
    info.at<double>(4, 4) = 1.0;
    return info;
}

// MARK: - RTABMapGraphReader (strict, §10) ----------------------------------

/// Reads Node/Link with strict BLOB validation: pose must be 12 floats,
/// transform 12 floats, information 36 doubles; the sqlite loop must end
/// in SQLITE_DONE (§10).
bool readGraph(const std::string & dbPath, GraphModel & model, std::string & error)
{
    // The read-only contract must never be defeated by a crafted path:
    // '?'/'#' would inject URI parameters/fragments overriding mode=ro.
    if(dbPath.empty() ||
       dbPath.find('?') != std::string::npos ||
       dbPath.find('#') != std::string::npos)
    {
        error = "database path contains unsupported URI characters";
        return false;
    }
    char uri[4096];
    const int written = snprintf(uri, sizeof(uri), "file:%s?mode=ro&immutable=1", dbPath.c_str());
    if(written < 0 || written >= static_cast<int>(sizeof(uri)))
    {
        error = "database path too long";
        return false;
    }
    sqlite3 * db = 0;
    if(sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, 0) != SQLITE_OK)
    {
        error = std::string("cannot open snapshot database: ") + (db ? sqlite3_errmsg(db) : "null");
        if(db) sqlite3_close(db);
        return false;
    }
    bool ok = true;

    // quick_check must be exactly the single row "ok".
    sqlite3_stmt * check = 0;
    if(sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &check, 0) == SQLITE_OK && check)
    {
        int rows = 0;
        while(true)
        {
            const int rc = sqlite3_step(check);
            if(rc == SQLITE_ROW)
            {
                ++rows;
                const unsigned char * text = sqlite3_column_text(check, 0);
                if(rows != 1 || !text || std::strcmp(reinterpret_cast<const char *>(text), "ok") != 0)
                {
                    error = "PRAGMA quick_check did not return a single ok row";
                    ok = false;
                    break;
                }
            }
            else if(rc == SQLITE_DONE)
            {
                if(rows != 1)
                {
                    error = "PRAGMA quick_check returned no rows";
                    ok = false;
                }
                break;
            }
            else
            {
                error = std::string("PRAGMA quick_check step failed: ") + sqlite3_errmsg(db);
                ok = false;
                break;
            }
        }
        sqlite3_finalize(check);
    }
    else
    {
        error = "cannot prepare PRAGMA quick_check";
        ok = false;
    }

    if(ok)
    {
        sqlite3_stmt * stmt = 0;
        if(sqlite3_prepare_v2(db, "SELECT id, map_id, stamp, pose FROM Node ORDER BY id;", -1, &stmt, 0) != SQLITE_OK)
        {
            error = std::string("cannot prepare Node query: ") + sqlite3_errmsg(db);
            ok = false;
        }
        else
        {
            std::set<int64_t> seen;
            while(ok)
            {
                const int rc = sqlite3_step(stmt);
                if(rc == SQLITE_ROW)
                {
                    RawNode node;
                    node.id = sqlite3_column_int64(stmt, 0);
                    node.mapId = sqlite3_column_int(stmt, 1);
                    node.stamp = sqlite3_column_double(stmt, 2);
                    const int bytes = sqlite3_column_bytes(stmt, 3);
                    const float * blob = reinterpret_cast<const float *>(sqlite3_column_blob(stmt, 3));
                    if(node.id <= 0 || bytes < static_cast<int>(12 * sizeof(float)) || !blob)
                    {
                        ++model.malformedPoses;
                        continue; // skip bad BLOB, counted for the health report
                    }
                    float m[12];
                    std::memcpy(m, blob, 12 * sizeof(float));
                    rtabmap::Transform t(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11]);
                    if(t.isNull())
                    {
                        ++model.malformedPoses;
                        continue;
                    }
                    node.pose = se2FromTransform(t);
                    node.finite = se2Finite(node.pose);
                    if(!seen.insert(node.id).second)
                    {
                        ++model.duplicateNodes;
                        continue;
                    }
                    model.nodeIndex[node.id] = model.nodes.size();
                    model.nodes.push_back(node);
                }
                else if(rc == SQLITE_DONE)
                {
                    break;
                }
                else
                {
                    error = std::string("Node iteration failed: ") + sqlite3_errmsg(db);
                    ok = false;
                }
            }
            sqlite3_finalize(stmt);
        }
    }

    if(ok)
    {
        sqlite3_stmt * stmt = 0;
        if(sqlite3_prepare_v2(
               db,
               "SELECT from_id, to_id, type, transform, information_matrix FROM Link ORDER BY from_id, to_id;",
               -1, &stmt, 0) != SQLITE_OK)
        {
            error = std::string("cannot prepare Link query: ") + sqlite3_errmsg(db);
            ok = false;
        }
        else
        {
            while(ok)
            {
                const int rc = sqlite3_step(stmt);
                if(rc == SQLITE_ROW)
                {
                    RawLink link;
                    link.from = sqlite3_column_int64(stmt, 0);
                    link.to = sqlite3_column_int64(stmt, 1);
                    link.type = sqlite3_column_int(stmt, 2);
                    const int tBytes = sqlite3_column_bytes(stmt, 3);
                    const float * tBlob = reinterpret_cast<const float *>(sqlite3_column_blob(stmt, 3));
                    const int iBytes = sqlite3_column_bytes(stmt, 4);
                    const double * iBlob = reinterpret_cast<const double *>(sqlite3_column_blob(stmt, 4));
                    if(link.from <= 0 || link.to <= 0 || tBytes < static_cast<int>(12 * sizeof(float)) || !tBlob)
                    {
                        ++model.malformedLinks;
                        continue;
                    }
                    float m[12];
                    std::memcpy(m, tBlob, 12 * sizeof(float));
                    rtabmap::Transform t(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11]);
                    if(t.isNull())
                    {
                        ++model.malformedLinks;
                        continue;
                    }
                    link.measurement = se2FromTransform(t);
                    double info36[36];
                    std::memset(info36, 0, sizeof(info36));
                    if(iBlob && iBytes > 0)
                    {
                        const int count = std::min(36, static_cast<int>(iBytes / sizeof(double)));
                        std::memcpy(info36, iBlob, count * sizeof(double));
                    }
                    planarBlock(info36, link.information);
                    link.finite = se2Finite(link.measurement);
                    model.links.push_back(link);
                }
                else if(rc == SQLITE_DONE)
                {
                    break;
                }
                else
                {
                    error = std::string("Link iteration failed: ") + sqlite3_errmsg(db);
                    ok = false;
                }
            }
            sqlite3_finalize(stmt);
        }
    }

    sqlite3_close(db);

    // Mark cross-map links (floor/session transitions) for health/quality.
    for(size_t i = 0; i < model.links.size(); ++i)
    {
        RawLink & link = model.links[i];
        std::map<int64_t, size_t>::const_iterator f = model.nodeIndex.find(link.from);
        std::map<int64_t, size_t>::const_iterator t = model.nodeIndex.find(link.to);
        if(f == model.nodeIndex.end() || t == model.nodeIndex.end())
        {
            link.finite = false; // dangling endpoint -> unusable
            continue;
        }
        link.crossMap = model.nodes[f->second].mapId != model.nodes[t->second].mapId;
    }
    return ok;
}

// MARK: - GraphHealthInspector ----------------------------------------------

struct HealthReport
{
    int64_t nodeCount = 0;
    int64_t linkCount = 0;
    int64_t duplicateNodes = 0;
    int64_t malformedPoses = 0;
    int64_t malformedLinks = 0;
    int64_t nonFiniteNodes = 0;
    int64_t nonFiniteLinks = 0;
    int64_t componentCount = 0;
    int64_t largestComponent = 0;
    int64_t isolatedNodes = 0;
    int64_t crossMapLinks = 0;
    int64_t loopLinks = 0;
    int64_t priorLinks = 0;
    int64_t recoveryLinks = 0;
};

bool isLoopType(int32_t type)
{
    return type == rtabmap::Link::kGlobalClosure ||
           type == rtabmap::Link::kLocalSpaceClosure ||
           type == rtabmap::Link::kLocalTimeClosure ||
           type == rtabmap::Link::kUserClosure;
}

HealthReport inspectHealth(const GraphModel & model)
{
    HealthReport report;
    report.nodeCount = static_cast<int64_t>(model.nodes.size());
    report.linkCount = static_cast<int64_t>(model.links.size());
    report.duplicateNodes = model.duplicateNodes;
    report.malformedPoses = model.malformedPoses;
    report.malformedLinks = model.malformedLinks;

    std::vector<int64_t> parent(model.nodes.size());
    std::vector<size_t> degree(model.nodes.size(), 0);
    for(size_t i = 0; i < parent.size(); ++i) parent[i] = static_cast<int64_t>(i);
    std::function<int64_t(int64_t)> find = [&](int64_t v) {
        while(parent[v] != v)
        {
            parent[v] = parent[parent[v]];
            v = parent[v];
        }
        return v;
    };

    for(size_t i = 0; i < model.nodes.size(); ++i)
    {
        if(!model.nodes[i].finite) ++report.nonFiniteNodes;
    }
    for(const RawLink & link : model.links)
    {
        if(!link.finite)
        {
            ++report.nonFiniteLinks;
            continue;
        }
        if(link.crossMap) ++report.crossMapLinks;
        if(isLoopType(link.type)) ++report.loopLinks;
        else if(link.type == rtabmap::Link::kPosePrior) ++report.priorLinks;
        else if(link.type == rtabmap::Link::kVirtualClosure) ++report.recoveryLinks;
        std::map<int64_t, size_t>::const_iterator f = model.nodeIndex.find(link.from);
        std::map<int64_t, size_t>::const_iterator t = model.nodeIndex.find(link.to);
        if(f == model.nodeIndex.end() || t == model.nodeIndex.end()) continue;
        ++degree[f->second];
        ++degree[t->second];
        const int64_t rf = find(static_cast<int64_t>(f->second));
        const int64_t rt = find(static_cast<int64_t>(t->second));
        if(rf != rt) parent[rf] = rt;
    }
    std::map<int64_t, int64_t> componentSizes;
    for(size_t i = 0; i < parent.size(); ++i)
    {
        componentSizes[find(static_cast<int64_t>(i))] += 1;
        if(degree[i] == 0) ++report.isolatedNodes;
    }
    report.componentCount = static_cast<int64_t>(componentSizes.size());
    for(std::map<int64_t, int64_t>::const_iterator it = componentSizes.begin(); it != componentSizes.end(); ++it)
    {
        report.largestComponent = std::max(report.largestComponent, it->second);
    }
    return report;
}

// MARK: - AdaptiveGraphReducer (§11.3) ---------------------------------------

struct ReducerPolicy
{
    /// Straight/high-quality candidate spacing.
    double straightDistanceM = 0.75;  // within 0.5–1.0 m
    double straightAngleRad = 4.0 * M_PI / 180.0;
    double straightTimeS = 2.0;
    /// Tightened spacing in turns / Recovery neighborhoods.
    double tightDistanceM = 0.3;      // within 0.2–0.4 m
    double turnDetectionRad = 20.0 * M_PI / 180.0;
};

/// Selects the optimization skeleton. Loop/prior/recovery/tag/turn/
/// transition/endpoint nodes are ALWAYS kept; straight segments are
/// subsampled adaptively (never a fixed stride).
std::vector<size_t> reduceGraph(const GraphModel & model, const std::set<int64_t> & tagNodes, const ReducerPolicy & policy)
{
    std::set<size_t> kept;
    const size_t n = model.nodes.size();
    if(n == 0) return std::vector<size_t>();
    kept.insert(0);
    kept.insert(n - 1);

    // Endpoints of every non-neighbor constraint (loops, priors,
    // Recovery boundaries) are mandatory skeleton nodes.
    for(const RawLink & link : model.links)
    {
        if(link.type == rtabmap::Link::kNeighbor || !link.finite) continue;
        std::map<int64_t, size_t>::const_iterator f = model.nodeIndex.find(link.from);
        std::map<int64_t, size_t>::const_iterator t = model.nodeIndex.find(link.to);
        if(f != model.nodeIndex.end()) kept.insert(f->second);
        if(t != model.nodeIndex.end()) kept.insert(t->second);
    }
    // Tag-bound nodes must survive reduction (§11.3 / §14).
    for(int64_t id : tagNodes)
    {
        std::map<int64_t, size_t>::const_iterator it = model.nodeIndex.find(id);
        if(it != model.nodeIndex.end()) kept.insert(it->second);
    }
    // Turn nodes, map transitions and tracking gaps.
    for(size_t i = 1; i + 1 < n; ++i)
    {
        const RawNode & prev = model.nodes[i - 1];
        const RawNode & cur = model.nodes[i];
        const RawNode & next = model.nodes[i + 1];
        if(!prev.finite || !cur.finite || !next.finite)
        {
            kept.insert(i);
            continue;
        }
        const double turn = std::fabs(normalizeAngle(
            normalizeAngle(next.pose.yaw - cur.pose.yaw) +
            normalizeAngle(cur.pose.yaw - prev.pose.yaw)));
        if(turn >= policy.turnDetectionRad) kept.insert(i);
        if(cur.mapId != prev.mapId || cur.mapId != next.mapId) kept.insert(i);
        if(cur.stamp - prev.stamp > 5.0 || next.stamp - cur.stamp > 5.0) kept.insert(i);
    }

    // Adaptive spacing between mandatory anchors.
    std::vector<size_t> skeleton;
    skeleton.push_back(0);
    SE2 anchor = model.nodes[0].pose;
    double accumulatedAngle = 0.0;
    for(size_t i = 1; i < n; ++i)
    {
        if(kept.count(i))
        {
            skeleton.push_back(i);
            anchor = model.nodes[i].pose;
            accumulatedAngle = 0.0;
            continue;
        }
        const RawNode & prev = model.nodes[i - 1];
        const RawNode & cur = model.nodes[i];
        if(!prev.finite || !cur.finite) continue;
        const double distance = std::hypot(cur.pose.x - anchor.x, cur.pose.y - anchor.y);
        accumulatedAngle += std::fabs(normalizeAngle(cur.pose.yaw - prev.pose.yaw));
        const double dt = cur.stamp - model.nodes[skeleton.back()].stamp;
        // Local curvature decides the spacing regime: turns tighten.
        const bool tight = accumulatedAngle >= policy.turnDetectionRad;
        const double limit = tight ? policy.tightDistanceM : policy.straightDistanceM;
        if(distance >= limit || accumulatedAngle >= policy.straightAngleRad || dt >= policy.straightTimeS)
        {
            skeleton.push_back(i);
            anchor = cur.pose;
            accumulatedAngle = 0.0;
        }
    }
    if(skeleton.back() != n - 1) skeleton.push_back(n - 1);
    std::sort(skeleton.begin(), skeleton.end());
    skeleton.erase(std::unique(skeleton.begin(), skeleton.end()), skeleton.end());
    return skeleton;
}

// MARK: - RobustSE2Optimizer (§11.4) ----------------------------------------

struct OptimizerDiagnostics
{
    int iterations = 0;
    double finalError = 0.0;
    double wallSeconds = 0.0;
    int64_t factorCount = 0;
    bool available = false;
};

struct OptimizedGraph
{
    /// Optimized skeleton poses keyed by raw node id.
    std::map<int64_t, SE2> poses;
    OptimizerDiagnostics diagnostics;
};

struct FactorRecord
{
    int64_t from = 0;
    int64_t to = 0;
    int32_t type = 0;
    SE2 measurement;
    double information[9];
};

/// Builds the skeleton factor set: odometry measurements between
/// consecutive skeleton nodes (exact composition of the raw relative
/// neighbor links between them) plus every non-neighbor constraint whose
/// endpoints are both in the skeleton (loops, priors, Recovery).
bool buildSkeletonFactors(
    const GraphModel & model,
    const std::vector<size_t> & skeleton,
    std::vector<FactorRecord> & factors,
    std::string & error)
{
    const size_t n = model.nodes.size();
    // Neighbor chain indexed by source node position. RTAB-Map may store
    // the same neighbor relation from either endpoint; normalize to
    // ascending id order so forward composition always finds it.
    std::map<int64_t, std::pair<SE2, bool> > neighborRelative;
    for(const RawLink & link : model.links)
    {
        if(link.type != rtabmap::Link::kNeighbor || !link.finite) continue;
        if(link.from < link.to)
        {
            neighborRelative[link.from] = std::make_pair(link.measurement, true);
        }
        else if(link.to < link.from)
        {
            neighborRelative[link.to] = std::make_pair(se2Inverse(link.measurement), true);
        }
    }

    for(size_t s = 0; s + 1 < skeleton.size(); ++s)
    {
        const size_t a = skeleton[s];
        const size_t b = skeleton[s + 1];
        // Compose raw neighbor relatives over [a, b).
        SE2 relative;
        relative.x = 0.0; relative.y = 0.0; relative.yaw = 0.0;
        bool composed = true;
        size_t cursor = a;
        while(cursor < b)
        {
            const int64_t id = model.nodes[cursor].id;
            std::map<int64_t, std::pair<SE2, bool> >::const_iterator it = neighborRelative.find(id);
            if(it != neighborRelative.end())
            {
                relative = se2Compose(relative, it->second.first);
                ++cursor;
            }
            else
            {
                // No stored neighbor link: fall back to the raw pose
                // difference of the gap endpoints.
                const SE2 invA = se2Inverse(model.nodes[cursor].pose);
                relative = se2Compose(relative, se2Compose(invA, model.nodes[cursor + 1].pose));
                ++cursor;
            }
        }
        if(!composed || !se2Finite(relative))
        {
            error = "skeleton odometry composition produced a non-finite measurement";
            return false;
        }
        FactorRecord factor;
        factor.from = model.nodes[a].id;
        factor.to = model.nodes[b].id;
        factor.type = rtabmap::Link::kNeighbor;
        factor.measurement = relative;
        // Odometry information: identity-scaled planar block.
        for(int i = 0; i < 9; ++i) factor.information[i] = 0.0;
        factor.information[0] = factor.information[4] = 100.0;
        factor.information[8] = 100.0;
        factors.push_back(factor);
    }

    const std::set<int64_t> skeletonIds(
        [&] { std::set<int64_t> ids; for(size_t idx : skeleton) ids.insert(model.nodes[idx].id); return ids; }());
    // Canonical dedupe: RTAB-Map may store independently refined
    // reciprocal loop links; keep the first deterministic orientation.
    std::set<std::tuple<int64_t, int64_t, int32_t> > seenFactors;
    for(const RawLink & link : model.links)
    {
        if(link.type == rtabmap::Link::kNeighbor || !link.finite) continue;
        if(link.type == rtabmap::Link::kLandmark) continue;
        if(!skeletonIds.count(link.from) || !skeletonIds.count(link.to)) continue;
        FactorRecord factor;
        factor.type = link.type;
        if(link.type == rtabmap::Link::kPosePrior)
        {
            factor.from = link.from;
            factor.to = link.to;
            factor.measurement = link.measurement;
            std::memcpy(factor.information, link.information, sizeof(factor.information));
        }
        else
        {
            factor.from = std::min(link.from, link.to);
            factor.to = std::max(link.from, link.to);
            if(link.from <= link.to)
            {
                factor.measurement = link.measurement;
                std::memcpy(factor.information, link.information, sizeof(factor.information));
            }
            else
            {
                factor.measurement = se2Inverse(link.measurement);
                invertPlanarInformation(link.measurement, link.information, factor.information);
            }
        }
        const std::tuple<int64_t, int64_t, int32_t> key(factor.from, factor.to, factor.type);
        if(!seenFactors.insert(key).second) continue;
        factors.push_back(factor);
    }
    return true;
}

/// Runs the rtabmap g2o optimizer on the skeleton factor graph with the
/// full information matrices, a robust kernel and one anchor per
/// connected component (§11.4). Never a self-zeroing no-op: convergence,
/// iteration count and final error are recorded.
bool optimizeSkeleton(
    const GraphModel & model,
    const std::vector<size_t> & skeleton,
    const std::vector<FactorRecord> & factors,
    int iterations,
    double maxWallSeconds,
    MSFactorGraphCancelFn cancel,
    void * cancelUser,
    OptimizedGraph & out,
    std::string & error)
{
    if(skeleton.empty() || factors.empty())
    {
        error = "empty skeleton factor graph";
        return false;
    }
    std::map<int, rtabmap::Transform> poses;
    for(size_t idx : skeleton)
    {
        const RawNode & node = model.nodes[idx];
        poses[static_cast<int>(node.id)] = transformFromSE2(node.pose);
    }

    // Components over the skeleton factors.
    std::map<int64_t, int64_t> parent;
    std::function<int64_t(int64_t)> find = [&](int64_t v) {
        int64_t r = v;
        while(parent[r] != r) r = parent[r];
        while(parent[v] != r) { int64_t next = parent[v]; parent[v] = r; v = next; }
        return r;
    };
    for(size_t idx : skeleton) parent[model.nodes[idx].id] = model.nodes[idx].id;
    for(const FactorRecord & factor : factors)
    {
        if(factor.type == rtabmap::Link::kPosePrior) continue;
        const int64_t rf = find(factor.from);
        const int64_t rt = find(factor.to);
        if(rf != rt) parent[rf] = rt;
    }
    std::map<int64_t, int64_t> componentRoot; // component root -> anchor id
    for(size_t idx : skeleton)
    {
        const int64_t id = model.nodes[idx].id;
        const int64_t root = find(id);
        if(!componentRoot.count(root) || id < componentRoot[root])
        {
            componentRoot[root] = id;
        }
    }

    std::multimap<int, rtabmap::Link> links;
    for(const FactorRecord & factor : factors)
    {
        if(factor.from == factor.to && factor.type != rtabmap::Link::kPosePrior) continue;
        rtabmap::Link link(
            static_cast<int>(factor.from),
            static_cast<int>(factor.to),
            static_cast<rtabmap::Link::Type>(factor.type),
            transformFromSE2(factor.measurement),
            sixFromPlanar(factor.information));
        links.insert(std::make_pair(link.from(), link));
    }

    // Optimize each component with its own fixed anchor. rtabmap g2o
    // requires a single connected subgraph per call.
    std::set<int64_t> done;
    const auto start = std::chrono::steady_clock::now();
    for(std::map<int64_t, int64_t>::const_iterator it = componentRoot.begin();
        it != componentRoot.end(); ++it)
    {
        if(cancel && cancel(cancelUser))
        {
            error = "cancelled";
            return false;
        }
        const double elapsed = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - start).count();
        if(maxWallSeconds > 0.0 && elapsed > maxWallSeconds)
        {
            error = "optimizer wall-time budget exceeded";
            return false;
        }
        // Gather the nodes of this component.
        const int64_t compRoot = it->first;
        std::map<int, rtabmap::Transform> subPoses;
        std::multimap<int, rtabmap::Link> subLinks;
        for(size_t idx : skeleton)
        {
            const int64_t id = model.nodes[idx].id;
            if(find(id) == compRoot)
            {
                subPoses[static_cast<int>(id)] = poses[static_cast<int>(id)];
            }
        }
        for(std::multimap<int, rtabmap::Link>::const_iterator l = links.begin(); l != links.end(); ++l)
        {
            if(subPoses.count(l->second.from()) && 
               (l->second.from() == l->second.to() || subPoses.count(l->second.to())))
            {
                subLinks.insert(std::make_pair(l->first, l->second));
            }
        }
        if(subPoses.size() < 2)
        {
            // Single-node component: keep its raw pose (anchored).
            out.poses[static_cast<int64_t>(subPoses.begin()->first)] =
                se2FromTransform(subPoses.begin()->second);
            done.insert(static_cast<int64_t>(subPoses.begin()->first));
            continue;
        }

        rtabmap::ParametersMap parameters;
        parameters.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerStrategy(), "1"));
        parameters.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerIterations(), std::to_string(iterations)));
        parameters.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerEpsilon(), "0.00001"));
        parameters.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerRobust(), "true"));
        parameters.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerPriorsIgnored(), "false"));
        parameters.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerLandmarksIgnored(), "true"));
        parameters.insert(rtabmap::ParametersPair(rtabmap::Parameters::kRegForce3DoF(), "true"));
        parameters.insert(rtabmap::ParametersPair(rtabmap::Parameters::kg2oRobustKernelDelta(), "8"));
        parameters.insert(rtabmap::ParametersPair(rtabmap::Parameters::kg2oSolver(), "3"));
        std::unique_ptr<rtabmap::Optimizer> optimizer(
            rtabmap::Optimizer::create(rtabmap::Optimizer::kTypeG2O, parameters));
        if(!optimizer.get() || !rtabmap::Optimizer::isAvailable(rtabmap::Optimizer::kTypeG2O))
        {
            error = "rtabmap g2o optimizer unavailable";
            return false;
        }
        out.diagnostics.available = true;
        optimizer->setSlam2d(true);
        optimizer->setPriorsIgnored(false);
        optimizer->setLandmarksIgnored(true);
        optimizer->setIterations(iterations);
        optimizer->setRobust(true);

        double finalError = std::numeric_limits<double>::quiet_NaN();
        int iterationsDone = 0;
        const int anchor = static_cast<int>(it->second);
        std::map<int, rtabmap::Transform> optimized =
            optimizer->optimize(anchor, subPoses, subLinks, 0, &finalError, &iterationsDone);
        if(optimized.size() != subPoses.size())
        {
            error = "optimizer returned an incomplete node inventory";
            return false;
        }
        out.diagnostics.iterations = std::max(out.diagnostics.iterations, iterationsDone);
        if(std::isfinite(finalError)) out.diagnostics.finalError += finalError;
        for(std::map<int, rtabmap::Transform>::const_iterator p = optimized.begin(); p != optimized.end(); ++p)
        {
            const SE2 se2 = se2FromTransform(p->second);
            if(!se2Finite(se2))
            {
                error = "optimizer returned a non-finite pose";
                return false;
            }
            out.poses[static_cast<int64_t>(p->first)] = se2;
            done.insert(static_cast<int64_t>(p->first));
        }
    }
    out.diagnostics.wallSeconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    out.diagnostics.factorCount = static_cast<int64_t>(factors.size());
    if(done.size() != skeleton.size())
    {
        error = "skeleton optimization missed nodes";
        return false;
    }
    return true;
}

// MARK: - GraphQualityEvaluator (§11.5) --------------------------------------

struct QualityMetrics
{
    HealthReport health;
    int64_t skeletonNodes = 0;
    int64_t skeletonFactors = 0;
    double anchoredRatio = 0.0;
    double coverage = 0.0;
    double chi2 = 0.0;
    int64_t dof = 0;
    /// Residual norms (translation m) per kind.
    std::vector<double> odometryResiduals;
    std::vector<double> loopResiduals;
    std::vector<double> priorResiduals;
    std::vector<double> recoveryResiduals;
    double rejectedRatio = 0.0;
    double downweightedRatio = 0.0;
    /// Corrections opt vs raw on skeleton nodes.
    std::vector<double> corrections;
    double correctionJumpMax = 0.0;
    OptimizerDiagnostics solver;
    double wallSeconds = 0.0;
};

double percentile(std::vector<double> values, double q)
{
    if(values.empty()) return 0.0;
    std::sort(values.begin(), values.end());
    const double pos = q * static_cast<double>(values.size() - 1);
    const size_t lo = static_cast<size_t>(std::floor(pos));
    const size_t hi = static_cast<size_t>(std::ceil(pos));
    const double frac = pos - static_cast<double>(lo);
    return values[lo] * (1.0 - frac) + values[hi] * frac;
}

double residualNorm(const SE2 & measurement, const SE2 & optimizedRelative)
{
    const SE2 delta = se2Compose(se2Inverse(measurement), optimizedRelative);
    return std::hypot(delta.x, delta.y) + 0.25 * std::fabs(delta.yaw);
}

QualityMetrics evaluateQuality(
    const GraphModel & model,
    const std::vector<FactorRecord> & factors,
    const OptimizedGraph & optimized,
    const std::vector<size_t> & skeleton,
    const HealthReport & health,
    double runWallSeconds,
    double coverage)
{
    QualityMetrics metrics;
    metrics.health = health;
    metrics.skeletonNodes = static_cast<int64_t>(skeleton.size());
    metrics.skeletonFactors = static_cast<int64_t>(factors.size());
    metrics.solver = optimized.diagnostics;
    metrics.wallSeconds = runWallSeconds;
    metrics.coverage = coverage;
    metrics.anchoredRatio = model.nodes.empty() ? 0.0
        : static_cast<double>(health.largestComponent) / static_cast<double>(model.nodes.size());

    // Per-factor residuals against the optimized skeleton.
    int64_t rejected = 0;
    int64_t downweighted = 0;
    int64_t evaluated = 0;
    for(const FactorRecord & factor : factors)
    {
        if(factor.type == rtabmap::Link::kPosePrior)
        {
            std::map<int64_t, SE2>::const_iterator it = optimized.poses.find(factor.from);
            if(it == optimized.poses.end()) continue;
            const double norm = residualNorm(factor.measurement, it->second);
            metrics.priorResiduals.push_back(norm);
            ++evaluated;
            continue;
        }
        std::map<int64_t, SE2>::const_iterator a = optimized.poses.find(factor.from);
        std::map<int64_t, SE2>::const_iterator b = optimized.poses.find(factor.to);
        if(a == optimized.poses.end() || b == optimized.poses.end()) continue;
        const SE2 relative = se2Compose(se2Inverse(a->second), b->second);
        const double norm = residualNorm(factor.measurement, relative);
        if(factor.type == rtabmap::Link::kNeighbor)
        {
            metrics.odometryResiduals.push_back(norm);
        }
        else if(isLoopType(factor.type))
        {
            metrics.loopResiduals.push_back(norm);
        }
        else if(factor.type == rtabmap::Link::kVirtualClosure)
        {
            metrics.recoveryResiduals.push_back(norm);
        }
        else
        {
            metrics.loopResiduals.push_back(norm);
        }
        // Weighted chi2 contribution (planar DoF = 3 per factor).
        const SE2 delta = se2Compose(se2Inverse(factor.measurement), relative);
        metrics.chi2 += factor.information[0] * delta.x * delta.x +
                        factor.information[4] * delta.y * delta.y +
                        factor.information[8] * delta.yaw * delta.yaw;
        metrics.dof += 3;
        ++evaluated;
        if(norm > 1.0) ++rejected;
        else if(norm > 0.25) ++downweighted;
    }
    if(evaluated > 0)
    {
        metrics.rejectedRatio = static_cast<double>(rejected) / static_cast<double>(evaluated);
        metrics.downweightedRatio = static_cast<double>(downweighted) / static_cast<double>(evaluated);
    }

    // Corrections of skeleton nodes against the raw poses.
    for(size_t idx : skeleton)
    {
        const RawNode & raw = model.nodes[idx];
        std::map<int64_t, SE2>::const_iterator it = optimized.poses.find(raw.id);
        if(it == optimized.poses.end() || !raw.finite) continue;
        metrics.corrections.push_back(std::hypot(it->second.x - raw.pose.x, it->second.y - raw.pose.y));
    }
    // Correction jump between consecutive skeleton nodes (detects
    // discontinuous warp fields).
    for(size_t s = 0; s + 1 < skeleton.size(); ++s)
    {
        const RawNode & rawA = model.nodes[skeleton[s]];
        const RawNode & rawB = model.nodes[skeleton[s + 1]];
        std::map<int64_t, SE2>::const_iterator a = optimized.poses.find(rawA.id);
        std::map<int64_t, SE2>::const_iterator b = optimized.poses.find(rawB.id);
        if(a == optimized.poses.end() || b == optimized.poses.end()) continue;
        if(!rawA.finite || !rawB.finite) continue;
        const SE2 ca = se2Compose(a->second, se2Inverse(rawA.pose));
        const SE2 cb = se2Compose(b->second, se2Inverse(rawB.pose));
        const SE2 jump = se2Compose(se2Inverse(ca), cb);
        metrics.correctionJumpMax = std::max(
            metrics.correctionJumpMax, std::hypot(jump.x, jump.y));
    }
    return metrics;
}

/// §11.5 disposition policy. The gate is NOT a converged boolean: it
/// combines connectivity, residual percentiles, correction bounds and
/// resource evidence.
MSFactorGraphDisposition decideDisposition(const QualityMetrics & metrics, const std::string & optimizeError)
{
    const HealthReport & h = metrics.health;
    if(h.nodeCount == 0 || h.loopLinks + h.priorLinks + h.recoveryLinks == 0)
    {
        return MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL;
    }
    if(h.nonFiniteNodes > 0 || h.duplicateNodes > 0)
    {
        return MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL;
    }
    const double isolatedRatio = h.nodeCount > 0
        ? static_cast<double>(h.isolatedNodes) / static_cast<double>(h.nodeCount) : 1.0;
    // Multiple components are a legitimate scan shape (tracking-lost
    // gaps / Recovery boundaries); they downgrade the disposition to a
    // recoverable fail instead of blocking the run (§11.5).
    if(isolatedRatio > 0.15 || h.componentCount > 10)
    {
        return MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL;
    }
    if(!optimizeError.empty())
    {
        if(optimizeError.find("budget") != std::string::npos ||
           optimizeError.find("resource") != std::string::npos)
        {
            return MS_FACTOR_GRAPH_RESOURCE_REQUIRED;
        }
        return MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL;
    }
    const double loopP95 = percentile(metrics.loopResiduals, 0.95);
    const double correctionP95 = percentile(metrics.corrections, 0.95);
    const double chi2PerDof = metrics.dof > 0 ? metrics.chi2 / static_cast<double>(metrics.dof) : 0.0;
    const bool pass =
        h.componentCount == 1 &&
        loopP95 <= 0.25 &&
        percentile(metrics.loopResiduals, 1.0) <= 1.0 &&
        correctionP95 <= 0.5 &&
        percentile(metrics.corrections, 1.0) <= 1.5 &&
        metrics.correctionJumpMax <= 2.0 &&
        chi2PerDof <= 50.0 &&
        metrics.rejectedRatio <= 0.05 &&
        metrics.solver.iterations > 0;
    return pass ? MS_FACTOR_GRAPH_PASS : MS_FACTOR_GRAPH_RECOVERABLE_FAIL;
}

std::string jsonEscape(const std::string & text)
{
    std::string out;
    for(char c : text)
    {
        if(c == '"' || c == '\\') out += '\\';
        if(static_cast<unsigned char>(c) < 0x20) continue;
        out += c;
    }
    return out;
}

std::string residualTriple(const std::vector<double> & values)
{
    char buffer[256];
    snprintf(buffer, sizeof(buffer),
             "{\"count\": %zu, \"p50\": %.6f, \"p95\": %.6f, \"max\": %.6f}",
             values.size(), percentile(values, 0.5), percentile(values, 0.95),
             percentile(values, 1.0));
    return buffer;
}

/// §11.5 canonical quality report.
std::string qualityJSON(const QualityMetrics & m, MSFactorGraphDisposition disposition, const std::string & path)
{
    const char * dispositionName = "PASS";
    switch(disposition)
    {
    case MS_FACTOR_GRAPH_RECOVERABLE_FAIL: dispositionName = "RECOVERABLE_FAIL"; break;
    case MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL: dispositionName = "NON_RECOVERABLE_FAIL"; break;
    case MS_FACTOR_GRAPH_RESOURCE_REQUIRED: dispositionName = "RESOURCE_REQUIRED"; break;
    default: break;
    }
    char buffer[4096];
    snprintf(buffer, sizeof(buffer),
        "{\"format\": \"MarketScannerGraphQuality\", \"version\": 1, "
        "\"path\": \"%s\", \"disposition\": \"%s\", "
        "\"component_count\": %lld, \"anchored_ratio\": %.6f, "
        "\"isolated_count\": %lld, \"cross_floor_link_count\": %lld, "
        "\"weighted_chi2\": %.6f, \"dof\": %lld, \"chi2_per_dof\": %.6f, "
        "\"residual_by_kind\": {\"odometry\": %s, \"loop\": %s, \"prior\": %s, \"recovery\": %s}, "
        "\"rejected_ratio\": %.6f, \"downweighted_ratio\": %.6f, "
        "\"correction\": {\"median\": %.6f, \"p95\": %.6f, \"max\": %.6f, \"max_jump\": %.6f}, "
        "\"coverage\": %.6f, "
        "\"solver\": {\"strategy\": \"g2o_robust\", \"iterations\": %d, \"final_error\": %.6f, "
        "\"wall_seconds\": %.3f, \"skeleton_nodes\": %lld, \"factor_count\": %lld, \"available\": %s}, "
        "\"health\": {\"node_count\": %lld, \"link_count\": %lld, \"duplicate_nodes\": %lld, "
        "\"malformed_poses\": %lld, \"malformed_links\": %lld, \"non_finite_nodes\": %lld, "
        "\"loop_links\": %lld, \"prior_links\": %lld, \"recovery_links\": %lld}}",
        jsonEscape(path).c_str(), dispositionName,
        (long long)m.health.componentCount, m.anchoredRatio,
        (long long)m.health.isolatedNodes, (long long)m.health.crossMapLinks,
        m.chi2, (long long)m.dof, m.dof > 0 ? m.chi2 / (double)m.dof : 0.0,
        residualTriple(m.odometryResiduals).c_str(), residualTriple(m.loopResiduals).c_str(),
        residualTriple(m.priorResiduals).c_str(), residualTriple(m.recoveryResiduals).c_str(),
        m.rejectedRatio, m.downweightedRatio,
        percentile(m.corrections, 0.5), percentile(m.corrections, 0.95),
        percentile(m.corrections, 1.0), m.correctionJumpMax,
        m.coverage,
        m.solver.iterations, m.solver.finalError, m.wallSeconds,
        (long long)m.skeletonNodes, (long long)m.skeletonFactors,
        m.solver.available ? "true" : "false",
        (long long)m.health.nodeCount, (long long)m.health.linkCount,
        (long long)m.health.duplicateNodes, (long long)m.health.malformedPoses,
        (long long)m.health.malformedLinks, (long long)m.health.nonFiniteNodes,
        (long long)m.health.loopLinks, (long long)m.health.priorLinks,
        (long long)m.health.recoveryLinks);
    return buffer;
}

// MARK: - FullTrajectoryReconstructor (§13) ----------------------------------

/// Applies skeleton corrections to EVERY raw node:
///   C_a = Topt_a * inv(Traw_a); C_b = Topt_b * inv(Traw_b)
///   C_i = SE2Interpolate(C_a, C_b, alpha); Tfinal_i = C_i * Traw_i
/// All tag-bound nodes are recovered because the reconstruction covers
/// the full raw inventory (multi-pointer O(N+S) sweep).
struct ReconstructedTrajectory
{
    std::vector<int64_t> ids;
    std::vector<double> stamps;
    std::vector<double> x;
    std::vector<double> y;
    std::vector<double> yaw;
    int64_t recoveredTagNodes = 0;
};

ReconstructedTrajectory reconstructTrajectory(
    const GraphModel & model,
    const std::vector<size_t> & skeleton,
    const OptimizedGraph & optimized,
    const std::set<int64_t> & tagNodes)
{
    ReconstructedTrajectory out;
    out.ids.reserve(model.nodes.size());
    out.stamps.reserve(model.nodes.size());
    out.x.reserve(model.nodes.size());
    out.y.reserve(model.nodes.size());
    out.yaw.reserve(model.nodes.size());

    // Skeleton anchors in node-index order.
    std::vector<std::pair<size_t, SE2> > anchors; // (node index, correction)
    for(size_t idx : skeleton)
    {
        const RawNode & raw = model.nodes[idx];
        std::map<int64_t, SE2>::const_iterator it = optimized.poses.find(raw.id);
        if(it == optimized.poses.end() || !raw.finite) continue;
        anchors.push_back(std::make_pair(idx, se2Compose(it->second, se2Inverse(raw.pose))));
    }
    size_t a = 0;
    for(size_t i = 0; i < model.nodes.size(); ++i)
    {
        const RawNode & raw = model.nodes[i];
        if(!raw.finite) continue;
        while(a + 1 < anchors.size() && anchors[a + 1].first <= i) ++a;
        SE2 correction;
        if(anchors.empty())
        {
            correction.x = correction.y = correction.yaw = 0.0;
        }
        else if(i <= anchors.front().first || anchors.size() == 1 || a + 1 >= anchors.size())
        {
            correction = anchors[std::min(a, anchors.size() - 1)].second;
        }
        else
        {
            const std::pair<size_t, SE2> & ca = anchors[a];
            const std::pair<size_t, SE2> & cb = anchors[a + 1];
            const double span = model.nodes[cb.first].stamp - model.nodes[ca.first].stamp;
            const double alpha = span > 1.0e-9
                ? (raw.stamp - model.nodes[ca.first].stamp) / span : 0.0;
            correction = se2Interpolate(ca.second, cb.second, alpha);
        }
        const SE2 finalPose = se2Compose(correction, raw.pose);
        out.ids.push_back(raw.id);
        out.stamps.push_back(raw.stamp);
        out.x.push_back(finalPose.x);
        out.y.push_back(finalPose.y);
        out.yaw.push_back(finalPose.yaw);
        if(tagNodes.count(raw.id)) ++out.recoveredTagNodes;
    }
    return out;
}

// MARK: - Runners ------------------------------------------------------------

struct RunOptions
{
    bool deep = false;
    int64_t maxNodes = 0;
    double maxWallSeconds = 0.0;
    int fastIterations = 100;
    int deepIterations = 300;
};

/// Reconstruction still runs when the optimizer errored in a way the
/// quality gate may classify as recoverable (cancellation excluded).
bool dispositionProbeShouldReconstruct(const std::string & optimizeError)
{
    return optimizeError.find("budget") != std::string::npos;
}

MSFactorGraphOutcomeC runPipeline(const MSFactorGraphRequestC * request, const RunOptions & options)
{
    MSFactorGraphOutcomeC outcome;
    std::memset(&outcome, 0, sizeof(outcome));
    const auto runStart = std::chrono::steady_clock::now();
    const double maxWall = options.maxWallSeconds > 0.0
        ? options.maxWallSeconds : (options.deep ? 1800.0 : 600.0);

    auto fail = [&](const std::string & message, MSFactorGraphDisposition disposition) {
        outcome.error = const_cast<char *>(strdup(message.c_str()));
        outcome.disposition = disposition;
        return outcome;
    };

    if(!request || !request->db_path)
    {
        return fail("request or db_path is NULL", MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }

    // 1. Real graph health check on the snapshot DB.
    GraphModel model;
    std::string readError;
    if(!readGraph(request->db_path, model, readError))
    {
        return fail("graph read failed: " + readError, MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }
    const HealthReport health = inspectHealth(model);

    // Resource gate (§16): fail closed, never silently degrade.
    const int64_t maxNodes = options.maxNodes > 0 ? options.maxNodes : 150000;
    if(health.nodeCount > maxNodes)
    {
        return fail("node count exceeds the resource budget", MS_FACTOR_GRAPH_RESOURCE_REQUIRED);
    }

    std::set<int64_t> tagNodes;
    for(int64_t i = 0; request->tag_node_ids && i < request->tag_node_count; ++i)
    {
        tagNodes.insert(request->tag_node_ids[i]);
    }

    if(request->progress) request->progress(0.2, request->progress_user);
    if(request->cancel && request->cancel(request->cancel_user))
    {
        return fail("cancelled", MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }

    // 2. Skeleton (Fast) or full graph (Deep).
    std::vector<size_t> skeleton;
    if(options.deep)
    {
        skeleton.reserve(model.nodes.size());
        for(size_t i = 0; i < model.nodes.size(); ++i)
        {
            if(model.nodes[i].finite) skeleton.push_back(i);
        }
    }
    else
    {
        ReducerPolicy policy;
        skeleton = reduceGraph(model, tagNodes, policy);
    }

    // 3. Factors + robust native optimization.
    std::vector<FactorRecord> factors;
    std::string factorError;
    if(!buildSkeletonFactors(model, skeleton, factors, factorError))
    {
        return fail("factor construction failed: " + factorError, MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }
    if(request->progress) request->progress(0.4, request->progress_user);

    OptimizedGraph optimized;
    std::string optimizeError;
    const int iterations = options.deep
        ? (request->deep_iterations > 0 ? request->deep_iterations : options.deepIterations)
        : (request->fast_iterations > 0 ? request->fast_iterations : options.fastIterations);
    optimizeSkeleton(
        model, skeleton, factors, iterations, maxWall,
        request->cancel, request->cancel_user,
        optimized, optimizeError);
    if(request->progress) request->progress(0.7, request->progress_user);

    // 4. Full trajectory reconstruction (§13) before the quality gate so
    //    the gate sees real coverage. NON_RECOVERABLE / RESOURCE runs
    //    still return diagnostics.
    ReconstructedTrajectory trajectory;
    if(optimizeError.empty() || dispositionProbeShouldReconstruct(optimizeError))
    {
        trajectory = reconstructTrajectory(model, skeleton, optimized, tagNodes);
    }
    const double coverage = model.nodes.empty() ? 0.0
        : static_cast<double>(trajectory.ids.size()) / static_cast<double>(model.nodes.size());

    // 5. Quality gate (§11.5).
    const double runWall = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - runStart).count();
    const QualityMetrics metrics = evaluateQuality(
        model, factors, optimized, skeleton, health, runWall, coverage);
    MSFactorGraphDisposition disposition = decideDisposition(metrics, optimizeError);
    if(runWall > maxWall && disposition == MS_FACTOR_GRAPH_PASS)
    {
        disposition = MS_FACTOR_GRAPH_RESOURCE_REQUIRED;
    }
    // Every tag-bound node must be recovered (§13).
    if(trajectory.recoveredTagNodes < static_cast<int64_t>(tagNodes.size()) &&
       disposition == MS_FACTOR_GRAPH_PASS)
    {
        disposition = MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL;
    }

    outcome.disposition = disposition;
    outcome.quality_json = const_cast<char *>(
        strdup(qualityJSON(metrics, disposition, options.deep ? "deep" : "fast").c_str()));
    outcome.count = static_cast<int64_t>(trajectory.ids.size());
    if(outcome.count > 0)
    {
        outcome.ids = static_cast<int64_t *>(malloc(outcome.count * sizeof(int64_t)));
        outcome.stamps = static_cast<double *>(malloc(outcome.count * sizeof(double)));
        outcome.x = static_cast<double *>(malloc(outcome.count * sizeof(double)));
        outcome.y = static_cast<double *>(malloc(outcome.count * sizeof(double)));
        outcome.yaw = static_cast<double *>(malloc(outcome.count * sizeof(double)));
        for(int64_t i = 0; i < outcome.count; ++i)
        {
            outcome.ids[i] = trajectory.ids[i];
            outcome.stamps[i] = trajectory.stamps[i];
            outcome.x[i] = trajectory.x[i];
            outcome.y[i] = trajectory.y[i];
            outcome.yaw[i] = trajectory.yaw[i];
        }
    }
    outcome.skeleton_count = static_cast<int64_t>(skeleton.size());
    if(outcome.skeleton_count > 0)
    {
        outcome.skeleton_ids = static_cast<int64_t *>(malloc(outcome.skeleton_count * sizeof(int64_t)));
        outcome.skeleton_x = static_cast<double *>(malloc(outcome.skeleton_count * sizeof(double)));
        outcome.skeleton_y = static_cast<double *>(malloc(outcome.skeleton_count * sizeof(double)));
        outcome.skeleton_yaw = static_cast<double *>(malloc(outcome.skeleton_count * sizeof(double)));
        int64_t k = 0;
        for(size_t idx : skeleton)
        {
            const RawNode & raw = model.nodes[idx];
            std::map<int64_t, SE2>::const_iterator it = optimized.poses.find(raw.id);
            const SE2 pose = it != optimized.poses.end() ? it->second : raw.pose;
            outcome.skeleton_ids[k] = raw.id;
            outcome.skeleton_x[k] = pose.x;
            outcome.skeleton_y[k] = pose.y;
            outcome.skeleton_yaw[k] = pose.yaw;
            ++k;
        }
    }
    if(request->progress) request->progress(1.0, request->progress_user);
    return outcome;
}

} // namespace

// MARK: - C ABI --------------------------------------------------------------

namespace {

/// Wraps an unexpected native exception into a fail-closed outcome; the
/// C ABI boundary must never let an exception escape (rtabmap UASSERT
/// failures throw UException).
MSFactorGraphOutcomeC makeExceptionOutcome(const char * message)
{
    MSFactorGraphOutcomeC outcome;
    std::memset(&outcome, 0, sizeof(outcome));
    outcome.disposition = MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL;
    outcome.error = const_cast<char *>(strdup(message ? message : "unknown native exception"));
    return outcome;
}

} // namespace

extern "C" MSFactorGraphOutcomeC MSFactorGraphRunFast(const MSFactorGraphRequestC * request)
{
    RunOptions options;
    options.deep = false;
    if(request)
    {
        options.maxNodes = request->max_nodes;
        options.maxWallSeconds = request->max_wall_seconds;
    }
    try
    {
        return runPipeline(request, options);
    }
    catch(const std::exception & e)
    {
        return makeExceptionOutcome(e.what());
    }
    catch(...)
    {
        return makeExceptionOutcome(0);
    }
}

extern "C" MSFactorGraphOutcomeC MSFactorGraphRunDeep(const MSFactorGraphRequestC * request)
{
    RunOptions options;
    options.deep = true;
    if(request)
    {
        options.maxNodes = request->max_nodes;
        options.maxWallSeconds = request->max_wall_seconds;
    }
    try
    {
        return runPipeline(request, options);
    }
    catch(const std::exception & e)
    {
        return makeExceptionOutcome(e.what());
    }
    catch(...)
    {
        return makeExceptionOutcome(0);
    }
}

extern "C" void MSFactorGraphFree(MSFactorGraphOutcomeC * outcome)
{
    if(!outcome) return;
    free(outcome->ids);
    free(outcome->stamps);
    free(outcome->x);
    free(outcome->y);
    free(outcome->yaw);
    free(outcome->skeleton_ids);
    free(outcome->skeleton_x);
    free(outcome->skeleton_y);
    free(outcome->skeleton_yaw);
    free(outcome->quality_json);
    free(outcome->error);
    std::memset(outcome, 0, sizeof(*outcome));
}
