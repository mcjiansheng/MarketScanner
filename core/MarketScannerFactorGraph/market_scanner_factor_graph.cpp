/*
 * MarketScanner shared factor-graph core implementation (V1R3).
 *
 * Read-only contract: the snapshot database is opened with
 * `mode=ro&immutable=1` (fully percent-encoded path) and never written.
 *
 * V1R3 correctness closeout highlights:
 * - exact BLOB sizes and value validation; corrupted required records
 *   fail closed (NON_RECOVERABLE_FAIL), never skipped into a PASS;
 * - topology order from the neighbor chains with monotonic stamp
 *   verification (never "ORDER BY id == trajectory order");
 * - SPD information policy (valid / regularized_with_audit / rejected);
 * - aggregate odometry covariance along chains (no fixed diag);
 * - missing neighbor links form gaps/components, never fabricated
 *   measurements;
 * - absolute prior-map constraints anchor components to the map frame;
 *   without them the run is LOCAL_FRAME_ONLY diagnostics;
 * - chunked, cancellable, wall/memory-bounded optimization;
 * - full rᵀΩr chi² including pose priors; streaming escaped quality
 *   JSON bound to policy/factor/graph/core identities.
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
#include <new>
#include <random>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>

namespace {

// MARK: - SE(2) math ---------------------------------------------------------

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

// MARK: - Small matrix utilities ----------------------------------------------

typedef double Mat3[9];

/// Boxed 3x3 so matrices can live in std::vector (C arrays cannot).
struct Mat3Box
{
    double m[9];
};

void mat3Symmetrize(Mat3 m)
{
    for(int r = 0; r < 3; ++r)
    {
        for(int c = r + 1; c < 3; ++c)
        {
            const double v = 0.5 * (m[r * 3 + c] + m[c * 3 + r]);
            m[r * 3 + c] = v;
            m[c * 3 + r] = v;
        }
    }
}

/// Real symmetric 3x3 eigenvalues (trigonometric method).
void mat3Eigenvalues(const Mat3 m, double out[3])
{
    const double p1 = m[1] * m[1] + m[2] * m[2] + m[5] * m[5];
    const double q = (m[0] + m[4] + m[8]) / 3.0;
    const double p2 = (m[0] - q) * (m[0] - q) + (m[4] - q) * (m[4] - q) +
                      (m[8] - q) * (m[8] - q) + 2.0 * p1;
    const double p = std::sqrt(p2 / 6.0);
    if(p <= 1.0e-300)
    {
        out[0] = out[1] = out[2] = q;
        return;
    }
    Mat3 b;
    for(int i = 0; i < 9; ++i) b[i] = (i % 4 == 0 ? m[i] - q : m[i]) / p;
    const double detB = b[0] * (b[4] * b[8] - b[5] * b[7]) -
                        b[1] * (b[3] * b[8] - b[5] * b[6]) +
                        b[2] * (b[3] * b[7] - b[4] * b[6]);
    double r = detB / 2.0;
    r = std::min(1.0, std::max(-1.0, r));
    const double phi = std::acos(r) / 3.0;
    out[0] = q + 2.0 * p * std::cos(phi);
    out[2] = q + 2.0 * p * std::cos(phi + 2.0 * M_PI / 3.0);
    out[1] = 3.0 * q - out[0] - out[2];
    std::sort(out, out + 3);
}

bool mat3Invert(const Mat3 m, Mat3 out)
{
    const double a = m[0], b = m[1], c = m[2];
    const double d = m[3], e = m[4], f = m[5];
    const double g = m[6], h = m[7], i = m[8];
    const double A = e * i - f * h;
    const double B = -(d * i - f * g);
    const double C = d * h - e * g;
    const double det = a * A + b * B + c * C;
    if(!std::isfinite(det) || std::fabs(det) < 1.0e-300) return false;
    const double inv = 1.0 / det;
    out[0] = A * inv;
    out[1] = -(b * i - c * h) * inv;
    out[2] = (b * f - c * e) * inv;
    out[3] = B * inv;
    out[4] = (a * i - c * g) * inv;
    out[5] = -(a * f - c * d) * inv;
    out[6] = C * inv;
    out[7] = -(a * h - b * g) * inv;
    out[8] = (a * e - b * d) * inv;
    return true;
}

/// Adjoint of an SE(2) pose acting on planar covariance/twist vectors:
///   Ad(T) = [ R  J t ; 0 0 1 ] with J = [[0,-1],[1,0]].
void se2Adjoint(const SE2 & t, Mat3 out)
{
    const double c = std::cos(t.yaw);
    const double s = std::sin(t.yaw);
    out[0] = c;  out[1] = -s; out[2] = -t.y;
    out[3] = s;  out[4] = c;  out[5] = t.x;
    out[6] = 0;  out[7] = 0;  out[8] = 1;
}

void mat3Multiply(const Mat3 a, const Mat3 b, Mat3 out)
{
    Mat3 tmp;
    for(int r = 0; r < 3; ++r)
    {
        for(int c = 0; c < 3; ++c)
        {
            double acc = 0.0;
            for(int k = 0; k < 3; ++k) acc += a[r * 3 + k] * b[k * 3 + c];
            tmp[r * 3 + c] = acc;
        }
    }
    std::memcpy(out, tmp, sizeof(Mat3));
}

// MARK: - Information policy (§11.1/§11.2) ------------------------------------

/// Information handling policy. Regularization is ALWAYS audited in the
/// quality report; silently substituting a default weight is forbidden.
enum class InfoPolicy
{
    Valid,
    RegularizedWithAudit,
    Rejected
};

struct InfoPolicyAudit
{
    int64_t valid = 0;
    int64_t regularized = 0;
    int64_t rejected = 0;
};

/// Validates and sanitizes one planar information block:
/// finite entries, symmetrization, eigenvalue floor and condition cap.
InfoPolicy sanitizePlanarInformation(Mat3 info, InfoPolicyAudit & audit)
{
    for(int i = 0; i < 9; ++i)
    {
        if(!std::isfinite(info[i]))
        {
            ++audit.rejected;
            return InfoPolicy::Rejected;
        }
    }
    mat3Symmetrize(info);
    double eig[3];
    mat3Eigenvalues(info, eig);
    const double minEig = eig[0];
    const double maxEig = eig[2];
    const double epsilon = 1.0e-9;
    const double maxCondition = 1.0e9;
    if(minEig <= 0.0 || maxEig / std::max(minEig, 1.0e-300) > maxCondition)
    {
        if(minEig > -1.0e-6 && maxEig > 0.0)
        {
            // Regularize: lift the spectrum just above the floor.
            const double lift = std::max(epsilon, maxEig / maxCondition);
            for(int d = 0; d < 3; ++d) info[d * 3 + d] += lift - std::min(minEig, 0.0);
            ++audit.regularized;
            return InfoPolicy::RegularizedWithAudit;
        }
        ++audit.rejected;
        return InfoPolicy::Rejected;
    }
    ++audit.valid;
    return InfoPolicy::Valid;
}

/// Information of the inverted SE(2) measurement (§11.1). The inverse
/// map f(z)=z⁻¹ has analytic Jacobian J at the measurement; covariance
/// propagates as Σ_w = J Σ_z Jᵀ and the result is I_w = Σ_w⁻¹. The
/// native test suite verifies this against finite differences on 1000+
/// random cases.
bool invertPlanarInformation(const SE2 & measurement, const Mat3 info, Mat3 out)
{
    const double c = std::cos(measurement.yaw);
    const double s = std::sin(measurement.yaw);
    const SE2 inv = se2Inverse(measurement);
    // J = d(z⁻¹)/dz at z = measurement, derived analytically:
    //   z⁻¹.x = -(c x + s y)   -> d/dyaw =  s x - c y = inv.y
    //   z⁻¹.y =  (s x - c y)   -> d/dyaw =  c x + s y = -inv.x
    const double J[9] = {
        -c, -s, inv.y,
         s, -c, -inv.x,
         0,  0, -1,
    };
    Mat3 cov;
    if(!mat3Invert(info, cov)) return false;
    // covW = J * cov * Jᵀ
    Mat3 Jt;
    for(int r = 0; r < 3; ++r)
        for(int col = 0; col < 3; ++col) Jt[r * 3 + col] = J[col * 3 + r];
    Mat3 Jcov, covW;
    mat3Multiply(J, cov, Jcov);
    mat3Multiply(Jcov, Jt, covW);
    mat3Symmetrize(covW);
    return mat3Invert(covW, out);
}

/// Aggregate covariance along an odometry chain (§11.3):
///   Σ_total = Σ1 + Ad(T1)Σ2Ad(T1)ᵀ + Ad(T1∘T2)Σ3...
/// Returns false when any segment covariance is unavailable.
bool aggregateChainInformation(
    const std::vector<SE2> & measurements,
    const std::vector<Mat3Box> & informations,
    Mat3 totalInformation)
{
    if(measurements.empty()) return false;
    Mat3 cov;
    if(!mat3Invert(informations[0].m, cov)) return false;
    SE2 composed = measurements[0];
    for(size_t i = 1; i < measurements.size(); ++i)
    {
        Mat3 segCov;
        if(!mat3Invert(informations[i].m, segCov)) return false;
        Mat3 adj, adjT, tmp, propagated;
        se2Adjoint(composed, adj);
        for(int r = 0; r < 3; ++r)
            for(int c = 0; c < 3; ++c) adjT[r * 3 + c] = adj[c * 3 + r];
        mat3Multiply(segCov, adjT, tmp);
        mat3Multiply(adj, tmp, propagated);
        for(int k = 0; k < 9; ++k) cov[k] += propagated[k];
        composed = se2Compose(composed, measurements[i]);
    }
    return mat3Invert(cov, totalInformation);
}

// MARK: - SHA-256 -------------------------------------------------------------

struct Sha256
{
    Sha256() : bitLength(0), bufferLength(0)
    {
        const uint32_t initial[8] = {
            0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
            0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U};
        std::memcpy(state, initial, sizeof(state));
    }

    void update(const void * data, size_t size)
    {
        const uint8_t * bytes = static_cast<const uint8_t *>(data);
        for(size_t i = 0; i < size; ++i)
        {
            buffer[bufferLength++] = bytes[i];
            bitLength += 8;
            if(bufferLength == 64)
            {
                transform(buffer);
                bufferLength = 0;
            }
        }
    }

    void update(const std::string & text) { update(text.data(), text.size()); }

    std::string hex()
    {
        uint8_t hash[32];
        finalize(hash);
        static const char * digits = "0123456789abcdef";
        std::string out;
        out.reserve(64);
        for(int i = 0; i < 32; ++i)
        {
            out += digits[hash[i] >> 4];
            out += digits[hash[i] & 0xF];
        }
        return out;
    }

private:
    static uint32_t rotr(uint32_t v, uint32_t n) { return (v >> n) | (v << (32 - n)); }

    void transform(const uint8_t * block)
    {
        static const uint32_t k[64] = {
            0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U,
            0x923f82a4U, 0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U,
            0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U,
            0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
            0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U,
            0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U,
            0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
            0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
            0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU,
            0x5b9cca4fU, 0x682e6ff3U, 0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
            0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U};
        uint32_t w[64];
        for(int i = 0; i < 16; ++i)
        {
            w[i] = (static_cast<uint32_t>(block[i * 4]) << 24) |
                   (static_cast<uint32_t>(block[i * 4 + 1]) << 16) |
                   (static_cast<uint32_t>(block[i * 4 + 2]) << 8) |
                   static_cast<uint32_t>(block[i * 4 + 3]);
        }
        for(int i = 16; i < 64; ++i)
        {
            const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
        uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
        for(int i = 0; i < 64; ++i)
        {
            const uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            const uint32_t ch = (e & f) ^ ((~e) & g);
            const uint32_t t1 = h + S1 + ch + k[i] + w[i];
            const uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            const uint32_t t2 = S0 + maj;
            h = g; g = f; f = e; e = d + t1;
            d = c; c = b; b = a; a = t1 + t2;
        }
        state[0] += a; state[1] += b; state[2] += c; state[3] += d;
        state[4] += e; state[5] += f; state[6] += g; state[7] += h;
    }

    void finalize(uint8_t hash[32])
    {
        buffer[bufferLength++] = 0x80;
        if(bufferLength > 56)
        {
            while(bufferLength < 64) buffer[bufferLength++] = 0;
            transform(buffer);
            bufferLength = 0;
        }
        while(bufferLength < 56) buffer[bufferLength++] = 0;
        for(int i = 7; i >= 0; --i)
        {
            buffer[bufferLength++] = static_cast<uint8_t>((bitLength >> (i * 8)) & 0xFF);
        }
        transform(buffer);
        for(int i = 0; i < 8; ++i)
        {
            hash[i * 4] = static_cast<uint8_t>((state[i] >> 24) & 0xFF);
            hash[i * 4 + 1] = static_cast<uint8_t>((state[i] >> 16) & 0xFF);
            hash[i * 4 + 2] = static_cast<uint8_t>((state[i] >> 8) & 0xFF);
            hash[i * 4 + 3] = static_cast<uint8_t>(state[i] & 0xFF);
        }
    }

    uint32_t state[8];
    uint64_t bitLength;
    uint8_t buffer[64];
    size_t bufferLength;
};

// MARK: - Graph model ----------------------------------------------------------

struct RawNode
{
    int64_t id = 0;
    double stamp = 0.0;
    int32_t mapId = 0;
    SE2 pose;
    /// Full 3x4 pose for rotation validation (row-major).
    double pose3x4[12];
};

struct RawLink
{
    int64_t from = 0;
    int64_t to = 0;
    int32_t type = 0;
    SE2 measurement;
    Mat3 information;
    InfoPolicy infoPolicy = InfoPolicy::Valid;
};

struct GraphModel
{
    /// Nodes in TOPOLOGY order (neighbor-chain / verified-stamp order),
    /// NOT necessarily id order (V1R3 §11.6).
    std::vector<RawNode> nodes;
    std::vector<RawLink> links;
    std::map<int64_t, size_t> nodeIndex;
    std::map<int64_t, size_t> topologyPosition;
    /// Health accounting.
    int64_t duplicateNodes = 0;
    int64_t malformedPoses = 0;
    int64_t malformedLinks = 0;
    /// Optional link types (landmarks/gravity) that are isolated and
    /// audited instead of failing the run (§10.3).
    int64_t ignoredOptionalLinks = 0;
    /// Null-transform constraints recorded as void by RTAB-Map (rejected
    /// loops etc.). Exact-size BLOBs with valid floats: isolated and
    /// audited, never used as factors, never fabricated (§10.3).
    int64_t voidLinks = 0;
    int64_t rejectedInfos = 0;
    int64_t regularizedInfos = 0;
    int64_t nonMonotonicStampChains = 0;
    int64_t reciprocalInconsistent = 0;
    int64_t missingNeighborGaps = 0;
    /// Graph input identity (all validated node/link bytes).
    std::string graphInputSha256;
};

/// Percent-encodes a path for a sqlite URI so no character can inject
/// parameters or fragments (V1R3 §10.4).
std::string uriEncodePath(const std::string & path)
{
    static const char * hex = "0123456789ABCDEF";
    std::string out;
    out.reserve(path.size() + 16);
    for(unsigned char c : path)
    {
        const bool unreserved =
            (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' ||
            c == '/' || c == '~';
        if(unreserved)
        {
            out += static_cast<char>(c);
        }
        else
        {
            out += '%';
            out += hex[c >> 4];
            out += hex[c & 0xF];
        }
    }
    return out;
}

cv::Mat sixFromPlanar(const Mat3 planar)
{
    cv::Mat info = cv::Mat::zeros(6, 6, CV_64FC1);
    const int idx[3] = {0, 1, 5};
    for(int r = 0; r < 3; ++r)
    {
        for(int c = 0; c < 3; ++c)
        {
            double v = planar[r * 3 + c];
            if(!std::isfinite(v)) v = 0.0;
            info.at<double>(idx[r], idx[c]) = v;
        }
    }
    // rtabmap::Link requires positive diagonal entries; the out-of-plane
    // dimensions are marginalized by the planar solver.
    info.at<double>(0, 0) = std::max(info.at<double>(0, 0), 1.0e-6);
    info.at<double>(1, 1) = std::max(info.at<double>(1, 1), 1.0e-6);
    info.at<double>(5, 5) = std::max(info.at<double>(5, 5), 1.0e-6);
    info.at<double>(2, 2) = 1.0;
    info.at<double>(3, 3) = 1.0;
    info.at<double>(4, 4) = 1.0;
    return info;
}

bool rotationLooksValid(const double m[12])
{
    // Column norms ~1 and determinant ~+1 (tolerance for float storage).
    const double c0[3] = {m[0], m[4], m[8]};
    const double c1[3] = {m[1], m[5], m[9]};
    const double c2[3] = {m[2], m[6], m[10]};
    auto norm = [](const double v[3]) {
        return std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    };
    if(std::fabs(norm(c0) - 1.0) > 0.05) return false;
    if(std::fabs(norm(c1) - 1.0) > 0.05) return false;
    if(std::fabs(norm(c2) - 1.0) > 0.05) return false;
    const double det =
        m[0] * (m[5] * m[10] - m[6] * m[9]) -
        m[1] * (m[4] * m[10] - m[6] * m[8]) +
        m[2] * (m[4] * m[9] - m[5] * m[8]);
    return std::fabs(det - 1.0) < 0.05;
}

// MARK: - RTABMapGraphReader (strict, §10) -------------------------------------

bool readGraph(const std::string & dbPath, GraphModel & model, std::string & error)
{
    if(dbPath.empty())
    {
        error = "database path is empty";
        return false;
    }
    std::string uri = "file:" + uriEncodePath(dbPath) + "?mode=ro&immutable=1";
    sqlite3 * db = 0;
    if(sqlite3_open_v2(uri.c_str(), &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, 0) != SQLITE_OK)
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
        while(ok)
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
            }
        }
        sqlite3_finalize(check);
    }
    else
    {
        error = "cannot prepare PRAGMA quick_check";
        ok = false;
    }

    Sha256 inputHash;
    {
        // ABI/projection policy marker (§9.5): the audit identity changes
        // when the reader contract itself changes.
        char line[96];
        snprintf(line, sizeof(line), "graph-input-v:abi=%d\n", MS_FACTOR_GRAPH_ABI_VERSION);
        inputHash.update(line, strlen(line));
    }
    std::map<int64_t, RawNode> nodesById;

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
            while(ok)
            {
                const int rc = sqlite3_step(stmt);
                if(rc == SQLITE_ROW)
                {
                    const int64_t id = sqlite3_column_int64(stmt, 0);
                    const int32_t mapId = sqlite3_column_int(stmt, 1);
                    const double stamp = sqlite3_column_double(stmt, 2);
                    const int bytes = sqlite3_column_bytes(stmt, 3);
                    const float * blob = reinterpret_cast<const float *>(sqlite3_column_blob(stmt, 3));
                    // Exact BLOB contract (§10.1) + id/value contract (§10.2).
                    if(id <= 0 || id > static_cast<int64_t>(INT32_MAX))
                    {
                        ++model.malformedPoses;
                        continue;
                    }
                    if(bytes != static_cast<int>(12 * sizeof(float)) || !blob)
                    {
                        // Required node records are never skipped into a
                        // PASS (§10.3); count and continue reading to
                        // report the full damage, then fail closed.
                        ++model.malformedPoses;
                        continue;
                    }
                    float m[12];
                    std::memcpy(m, blob, sizeof(m));
                    double pose[12];
                    bool finite = std::isfinite(stamp);
                    for(int i = 0; i < 12; ++i)
                    {
                        pose[i] = static_cast<double>(m[i]);
                        if(!std::isfinite(pose[i])) finite = false;
                    }
                    if(!finite || !rotationLooksValid(pose))
                    {
                        ++model.malformedPoses;
                        continue;
                    }
                    if(!nodesById.insert(std::make_pair(id, RawNode())).second)
                    {
                        ++model.duplicateNodes;
                        continue;
                    }
                    RawNode & node = nodesById[id];
                    node.id = id;
                    node.mapId = mapId;
                    node.stamp = stamp;
                    std::memcpy(node.pose3x4, pose, sizeof(pose));
                    rtabmap::Transform t(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11]);
                    node.pose = se2FromTransform(t);
                    // Audit identity binds the COMPLETE pose values (§9.5):
                    // any pose bit change alters graph_input_sha256.
                    char line[512];
                    int pos = snprintf(line, sizeof(line), "n:%lld:%d:%.17g:",
                                       (long long)id, mapId, stamp);
                    for(int i = 0; i < 12; ++i)
                    {
                        pos += snprintf(line + pos, sizeof(line) - pos, "%.17g,", pose[i]);
                    }
                    line[pos++] = '\n';
                    inputHash.update(line, pos);
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
                    const bool optionalType =
                        link.type == rtabmap::Link::kLandmark ||
                        link.type == rtabmap::Link::kGravity;
                    if(link.from <= 0 || link.to <= 0 ||
                       link.from > static_cast<int64_t>(INT32_MAX) ||
                       link.to > static_cast<int64_t>(INT32_MAX) ||
                       tBytes != static_cast<int>(12 * sizeof(float)) || !tBlob)
                    {
                        if(optionalType)
                        {
                            ++model.ignoredOptionalLinks;
                            continue;
                        }
                        ++model.malformedLinks;
                        continue;
                    }
                    float m[12];
                    std::memcpy(m, tBlob, sizeof(m));
                    bool finite = true;
                    bool allZero = true;
                    for(int i = 0; i < 12; ++i)
                    {
                        if(!std::isfinite(static_cast<double>(m[i]))) finite = false;
                        if(m[i] != 0.0f) allZero = false;
                    }
                    if(!finite)
                    {
                        if(optionalType)
                        {
                            ++model.ignoredOptionalLinks;
                            continue;
                        }
                        ++model.malformedLinks;
                        continue;
                    }
                    if(allZero)
                    {
                        // Void constraint (e.g. a loop RTAB-Map rejected
                        // during the scan): isolated + audited, never a
                        // factor.
                        ++model.voidLinks;
                        continue;
                    }
                    rtabmap::Transform t(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11]);
                    if(t.isNull() || t.inverse().isNull())
                    {
                        if(optionalType)
                        {
                            ++model.ignoredOptionalLinks;
                            continue;
                        }
                        ++model.malformedLinks;
                        continue;
                    }
                    double info36[36];
                    std::memset(info36, 0, sizeof(info36));
                    // EVERY factor-graph link type requires the exact
                    // 36-double information BLOB (§9.1); short or
                    // zero-filled weights are not trusted.
                    if(iBytes != static_cast<int>(36 * sizeof(double)) || !iBlob)
                    {
                        if(optionalType)
                        {
                            ++model.ignoredOptionalLinks;
                            continue;
                        }
                        ++model.malformedLinks;
                        continue;
                    }
                    std::memcpy(info36, iBlob, sizeof(info36));
                    link.measurement = se2FromTransform(t);
                    if(!se2Finite(link.measurement))
                    {
                        if(optionalType)
                        {
                            ++model.ignoredOptionalLinks;
                            continue;
                        }
                        ++model.malformedLinks;
                        continue;
                    }
                    if(optionalType)
                    {
                        // Gravity/landmark links do not participate in the
                        // planar factor graph; isolated, audited, skipped.
                        ++model.ignoredOptionalLinks;
                        continue;
                    }
                    const int idx[3] = {0, 1, 5};
                    for(int r = 0; r < 3; ++r)
                    {
                        for(int c = 0; c < 3; ++c)
                        {
                            link.information[r * 3 + c] = info36[idx[r] * 6 + idx[c]];
                        }
                    }
                    // Audit identity binds endpoints, type, the full
                    // normalized transform and the sanitized information
                    // (§9.5).
                    {
                        char line[768];
                        int pos = snprintf(line, sizeof(line), "l:%lld:%lld:%d:",
                                           (long long)link.from, (long long)link.to, link.type);
                        for(int i = 0; i < 12; ++i)
                        {
                            pos += snprintf(line + pos, sizeof(line) - pos, "%.9g,",
                                            static_cast<double>(m[i]));
                        }
                        for(int i = 0; i < 9; ++i)
                        {
                            pos += snprintf(line + pos, sizeof(line) - pos, "%.17g,",
                                            link.information[i]);
                        }
                        line[pos++] = '\n';
                        inputHash.update(line, pos);
                    }
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

    if(!ok) return false;

    // Corrupted REQUIRED records fail closed (§10.3).
    if(model.duplicateNodes > 0 || model.malformedPoses > 0)
    {
        error = "required node records are corrupted (duplicate/malformed)";
        return false;
    }
    // Dangling REQUIRED links (endpoint missing from the node inventory)
    // block the run (§9.2); they are never silently skipped.
    for(size_t i = 0; i < model.links.size(); ++i)
    {
        if(!nodesById.count(model.links[i].from) || !nodesById.count(model.links[i].to))
        {
            error = "dangling required link: endpoint missing from the node inventory";
            return false;
        }
    }
    if(model.malformedLinks > 0)
    {
        error = "required link records are corrupted (malformed BLOB/information)";
        return false;
    }

    model.graphInputSha256 = inputHash.hex();
    for(std::map<int64_t, RawNode>::const_iterator it = nodesById.begin();
        it != nodesById.end(); ++it)
    {
        model.nodeIndex[it->first] = model.nodes.size();
        model.nodes.push_back(it->second);
    }
    return true;
}

// MARK: - Topology order (§11.6) ----------------------------------------------

/// Builds the trajectory/topology order from the neighbor chains instead
/// of assuming id order. Chains are walked from their smallest-id node;
/// stamps must be strictly monotonic along a chain, otherwise the chain
/// is rejected (fail closed below). Isolated nodes keep id order and are
/// audited.
bool buildTopologyOrder(GraphModel & model, std::string & error)
{
    // Neighbor successor map (ascending direction).
    std::map<int64_t, std::vector<int64_t> > successor;
    std::set<int64_t> hasIncoming;
    for(const RawLink & link : model.links)
    {
        if(link.type != rtabmap::Link::kNeighbor) continue;
        if(model.nodeIndex.count(link.from) && model.nodeIndex.count(link.to))
        {
            if(link.from < link.to)
            {
                successor[link.from].push_back(link.to);
                hasIncoming.insert(link.to);
            }
            else
            {
                successor[link.to].push_back(link.from);
                hasIncoming.insert(link.from);
            }
        }
    }

    std::set<int64_t> ordered;
    std::vector<RawNode> topology;
    // Chain roots: nodes with no incoming neighbor edge.
    std::vector<int64_t> roots;
    for(const RawNode & node : model.nodes)
    {
        if(!hasIncoming.count(node.id)) roots.push_back(node.id);
    }
    std::sort(roots.begin(), roots.end());
    for(size_t r = 0; r < roots.size(); ++r)
    {
        int64_t cursor = roots[r];
        std::set<int64_t> visited;
        double lastStamp = -std::numeric_limits<double>::infinity();
        bool monotonic = true;
        while(true)
        {
            if(!visited.insert(cursor).second) break; // cycle guard
            std::map<int64_t, size_t>::const_iterator idx = model.nodeIndex.find(cursor);
            if(idx == model.nodeIndex.end()) break;
            const RawNode & node = model.nodes[idx->second];
            if(node.stamp <= lastStamp && std::isfinite(lastStamp))
            {
                monotonic = false;
            }
            lastStamp = node.stamp;
            if(ordered.insert(cursor).second)
            {
                topology.push_back(node);
            }
            std::map<int64_t, std::vector<int64_t> >::const_iterator next = successor.find(cursor);
            if(next == successor.end() || next->second.empty()) break;
            // Deterministic walk: smallest successor not yet visited.
            std::vector<int64_t> candidates = next->second;
            std::sort(candidates.begin(), candidates.end());
            int64_t chosen = -1;
            for(size_t i = 0; i < candidates.size(); ++i)
            {
                if(!visited.count(candidates[i])) { chosen = candidates[i]; break; }
            }
            if(chosen < 0) break;
            cursor = chosen;
        }
        if(!monotonic)
        {
            ++model.nonMonotonicStampChains;
        }
    }
    // Nodes never reached by a chain (isolated): append in id order.
    for(const RawNode & node : model.nodes)
    {
        if(ordered.insert(node.id).second)
        {
            topology.push_back(node);
        }
    }
    if(topology.size() != model.nodes.size())
    {
        error = "topology order lost nodes";
        return false;
    }
    if(model.nonMonotonicStampChains > 0)
    {
        error = "neighbor chains carry non-monotonic stamps";
        return false;
    }
    model.nodes.swap(topology);
    model.nodeIndex.clear();
    for(size_t i = 0; i < model.nodes.size(); ++i)
    {
        model.nodeIndex[model.nodes[i].id] = i;
        model.topologyPosition[model.nodes[i].id] = i;
    }
    return true;
}

// MARK: - GraphHealthInspector --------------------------------------------------

struct HealthReport
{
    int64_t nodeCount = 0;
    int64_t linkCount = 0;
    int64_t malformedLinks = 0;
    int64_t voidLinks = 0;
    int64_t ignoredOptionalLinks = 0;
    int64_t rejectedInfos = 0;
    int64_t regularizedInfos = 0;
    int64_t reciprocalInconsistent = 0;
    int64_t missingNeighborGaps = 0;
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

/// Validates every link information matrix under the SPD policy and
/// inspects connectivity. Rejected neighbor information is a hard
/// failure (odometry weights are required); rejected non-neighbor
/// information downgrades the link to an audited skip.
bool inspectHealth(GraphModel & model, HealthReport & report, std::string & error)
{
    InfoPolicyAudit audit;
    report.nodeCount = static_cast<int64_t>(model.nodes.size());
    report.malformedLinks = model.malformedLinks;
    report.voidLinks = model.voidLinks;
    report.ignoredOptionalLinks = model.ignoredOptionalLinks;

    std::vector<RawLink> kept;
    kept.reserve(model.links.size());
    // Reciprocal-duplicate detection (§11.5): canonical (min,max,type)
    // with a consistency probe instead of silent overwrite.
    std::map<std::tuple<int64_t, int64_t, int32_t>, size_t> canonicalSeen;
    for(size_t i = 0; i < model.links.size(); ++i)
    {
        RawLink link = model.links[i];
        if(link.type == rtabmap::Link::kLandmark) continue;
        std::map<int64_t, size_t>::const_iterator f = model.nodeIndex.find(link.from);
        std::map<int64_t, size_t>::const_iterator t = model.nodeIndex.find(link.to);
        if(f == model.nodeIndex.end() || t == model.nodeIndex.end())
        {
            continue; // dangling endpoints: audited, not counted as damage
        }
        // Information policy (§11.2).
        Mat3 info;
        std::memcpy(info, link.information, sizeof(Mat3));
        const InfoPolicy policy = sanitizePlanarInformation(info, audit);
        if(policy == InfoPolicy::Rejected)
        {
            if(link.type == rtabmap::Link::kNeighbor)
            {
                error = "required neighbor information rejected by the SPD policy";
                return false;
            }
            ++model.rejectedInfos;
            continue; // audited skip of an optional constraint
        }
        if(policy == InfoPolicy::RegularizedWithAudit)
        {
            ++model.regularizedInfos;
        }
        std::memcpy(link.information, info, sizeof(Mat3));
        link.infoPolicy = policy;

        if(link.type != rtabmap::Link::kPosePrior)
        {
            const int64_t a = std::min(link.from, link.to);
            const int64_t b = std::max(link.from, link.to);
            const std::tuple<int64_t, int64_t, int32_t> key(a, b, link.type);
            std::map<std::tuple<int64_t, int64_t, int32_t>, size_t>::const_iterator seen =
                canonicalSeen.find(key);
            if(seen != canonicalSeen.end())
            {
                // Reciprocal/refined duplicate: probe measurement
                // consistency; keep the first deterministic orientation.
                const RawLink & first = kept[seen->second];
                SE2 firstM = first.from <= first.to
                    ? first.measurement : se2Inverse(first.measurement);
                SE2 thisM = link.from <= link.to
                    ? link.measurement : se2Inverse(link.measurement);
                const SE2 delta = se2Compose(se2Inverse(firstM), thisM);
                if(std::hypot(delta.x, delta.y) > 0.5 || std::fabs(delta.yaw) > 0.2)
                {
                    ++model.reciprocalInconsistent;
                }
                continue;
            }
            canonicalSeen[key] = kept.size();
        }
        kept.push_back(link);
    }
    model.links.swap(kept);
    report.rejectedInfos = model.rejectedInfos;
    report.regularizedInfos = model.regularizedInfos;
    report.reciprocalInconsistent = model.reciprocalInconsistent;
    report.linkCount = static_cast<int64_t>(model.links.size());

    // Connectivity over kept links.
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
    for(const RawLink & link : model.links)
    {
        if(link.type == rtabmap::Link::kPosePrior) continue;
        if(isLoopType(link.type)) ++report.loopLinks;
        else if(link.type == rtabmap::Link::kVirtualClosure) ++report.recoveryLinks;
        std::map<int64_t, size_t>::const_iterator f = model.nodeIndex.find(link.from);
        std::map<int64_t, size_t>::const_iterator t = model.nodeIndex.find(link.to);
        if(f == model.nodeIndex.end() || t == model.nodeIndex.end()) continue;
        if(model.nodes[f->second].mapId != model.nodes[t->second].mapId)
        {
            ++report.crossMapLinks;
        }
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
    for(std::map<int64_t, int64_t>::const_iterator it = componentSizes.begin();
        it != componentSizes.end(); ++it)
    {
        report.largestComponent = std::max(report.largestComponent, it->second);
    }
    if(model.malformedLinks > 0)
    {
        error = "required link records are corrupted";
        return false;
    }
    return true;
}

// MARK: - AdaptiveGraphReducer (§11.3/§11.7) ------------------------------------

struct ReducerPolicy
{
    double straightDistanceM = 0.75;
    double straightAngleRad = 4.0 * M_PI / 180.0;
    double straightTimeS = 2.0;
    double tightDistanceM = 0.3;
    double turnDetectionRad = 20.0 * M_PI / 180.0;
};

/// V1R4 §11.7 fix: heading estimates from travel displacement are only
/// meaningful when the displacement is large enough to dominate the raw
/// pose noise. Below this distance (0.05 m) atan2(dy,dx) of a dense
/// trajectory (e.g. 60k nodes on a 100 m route -> 1.7 mm spacing) is
/// noise-dominated and must never drive skeleton decisions, otherwise a
/// random walk drift (0.004 m/step) makes every node look like a turn
/// and the reducer keeps nearly the whole graph (O(N) optimizer
/// vertices -> g2o marginal covariance recursion overflows the stack).
const double kMinHeadingDistanceM = 0.05;

/// V1R4 §10.1 depth defense: the optimizer problem must stay bounded
/// even for huge single components. rtabmap's g2o wrapper computes the
/// marginal covariance of the last vertex after every optimize() call
/// and MarginalCovarianceCholesky::computeEntry recurses over the
/// vertices, so an unbounded skeleton would overflow the stack. Mandatory
/// nodes (constraint endpoints / tags / gaps / map transitions / path
/// turns) always survive the uniform downsampling below this cap.
const size_t kSkeletonMaxNodes = 4096;

/// Selects the optimization skeleton over the TOPOLOGY order. Mandatory
/// nodes: endpoints, loop/prior/recovery endpoints, tag nodes, map
/// transitions, neighbor gaps, and path-curvature turns measured with
/// the true travel heading atan2(Δy,Δx) (§11.7).
std::vector<size_t> reduceGraph(
    const GraphModel & model,
    const std::set<int64_t> & tagNodes,
    const ReducerPolicy & policy)
{
    const size_t n = model.nodes.size();
    std::set<size_t> kept;
    if(n == 0) return std::vector<size_t>();
    kept.insert(0);
    kept.insert(n - 1);

    // Constraint endpoints.
    for(const RawLink & link : model.links)
    {
        if(link.type == rtabmap::Link::kNeighbor || link.type == rtabmap::Link::kPosePrior) continue;
        std::map<int64_t, size_t>::const_iterator f = model.nodeIndex.find(link.from);
        std::map<int64_t, size_t>::const_iterator t = model.nodeIndex.find(link.to);
        if(f != model.nodeIndex.end()) kept.insert(f->second);
        if(t != model.nodeIndex.end()) kept.insert(t->second);
    }
    // Tag-bound nodes.
    for(std::set<int64_t>::const_iterator it = tagNodes.begin(); it != tagNodes.end(); ++it)
    {
        std::map<int64_t, size_t>::const_iterator idx = model.nodeIndex.find(*it);
        if(idx != model.nodeIndex.end()) kept.insert(idx->second);
    }
    // Neighbor-chain gaps and map transitions (no fake measurements may
    // bridge them, so they bound segments).
    std::set<std::pair<int64_t, int64_t> > neighborPairs;
    for(const RawLink & link : model.links)
    {
        if(link.type != rtabmap::Link::kNeighbor) continue;
        neighborPairs.insert(std::make_pair(
            std::min(link.from, link.to), std::max(link.from, link.to)));
    }
    for(size_t i = 1; i < n; ++i)
    {
        const RawNode & prev = model.nodes[i - 1];
        const RawNode & cur = model.nodes[i];
        if(prev.mapId != cur.mapId)
        {
            kept.insert(i - 1);
            kept.insert(i);
            continue;
        }
        const std::pair<int64_t, int64_t> edge(
            std::min(prev.id, cur.id), std::max(prev.id, cur.id));
        if(!neighborPairs.count(edge))
        {
            kept.insert(i - 1);
            kept.insert(i);
        }
    }
    // Curvature turns from travel heading (§11.7).
    for(size_t i = 1; i + 1 < n; ++i)
    {
        const RawNode & prev = model.nodes[i - 1];
        const RawNode & cur = model.nodes[i];
        const RawNode & next = model.nodes[i + 1];
        const double h1 = std::atan2(cur.pose.y - prev.pose.y, cur.pose.x - prev.pose.x);
        const double h2 = std::atan2(next.pose.y - cur.pose.y, next.pose.x - cur.pose.x);
        const double d1 = std::hypot(cur.pose.x - prev.pose.x, cur.pose.y - prev.pose.y);
        const double d2 = std::hypot(next.pose.x - cur.pose.x, next.pose.y - cur.pose.y);
        if(d1 >= kMinHeadingDistanceM && d2 >= kMinHeadingDistanceM &&
           std::fabs(normalizeAngle(h2 - h1)) >= policy.turnDetectionRad)
        {
            kept.insert(i);
        }
    }

    // Adaptive spacing between mandatory anchors.
    std::vector<size_t> skeleton;
    skeleton.push_back(0);
    for(size_t i = 1; i < n; ++i)
    {
        if(kept.count(i))
        {
            skeleton.push_back(i);
            continue;
        }
        const size_t anchor = skeleton.back();
        const RawNode & a = model.nodes[anchor];
        const RawNode & cur = model.nodes[i];
        const double distance = std::hypot(cur.pose.x - a.pose.x, cur.pose.y - a.pose.y);
        double headingChange = 0.0;
        if(i > anchor && distance >= kMinHeadingDistanceM)
        {
            const RawNode & prev = model.nodes[i - 1];
            const double dPrev = std::hypot(cur.pose.x - prev.pose.x, cur.pose.y - prev.pose.y);
            if(dPrev >= kMinHeadingDistanceM)
            {
                const double h1 = std::atan2(prev.pose.y - a.pose.y, prev.pose.x - a.pose.x);
                const double h2 = std::atan2(cur.pose.y - prev.pose.y, cur.pose.x - prev.pose.x);
                headingChange = std::fabs(normalizeAngle(h2 - h1));
            }
        }
        const bool tight = headingChange >= policy.turnDetectionRad * 0.5;
        const double limit = tight ? policy.tightDistanceM : policy.straightDistanceM;
        const double dt = cur.stamp - a.stamp;
        if(distance >= limit || headingChange >= policy.straightAngleRad || dt >= policy.straightTimeS)
        {
            skeleton.push_back(i);
        }
    }
    if(skeleton.back() != n - 1) skeleton.push_back(n - 1);
    std::sort(skeleton.begin(), skeleton.end());
    skeleton.erase(std::unique(skeleton.begin(), skeleton.end()), skeleton.end());

    // Uniform cap (§10.1 depth defense): beyond kSkeletonMaxNodes keep
    // every mandatory anchor and one uniformly-spaced representative per
    // stride bucket so the optimizer stays O(cap) bounded.
    if(skeleton.size() > kSkeletonMaxNodes)
    {
        std::vector<size_t> capped;
        capped.reserve(kSkeletonMaxNodes + kept.size());
        const double stride =
            static_cast<double>(skeleton.size()) / static_cast<double>(kSkeletonMaxNodes);
        size_t lastBucket = static_cast<size_t>(-1);
        for(size_t s = 0; s < skeleton.size(); ++s)
        {
            const size_t bucket = static_cast<size_t>(std::floor(s / stride));
            const bool mandatory = kept.count(skeleton[s]) != 0;
            if(mandatory || bucket != lastBucket)
            {
                capped.push_back(skeleton[s]);
                lastBucket = bucket;
            }
        }
        if(capped.back() != n - 1) capped.push_back(n - 1);
        skeleton.swap(capped);
    }
    return skeleton;
}

// MARK: - Factor construction (§11.3/§11.4/§6) ---------------------------------

struct AbsolutePrior
{
    int64_t nodeId = 0;
    SE2 mapPose;
    Mat3 information;
    int32_t kind = MS_PRIOR_KIND_LOCALIZATION;
    int64_t episodeId = 0;
};

struct FactorRecord
{
    int64_t from = 0;
    int64_t to = 0;
    int32_t type = 0;
    SE2 measurement;
    Mat3 information;
    /// "odometry", "loop", "prior", "recovery".
    std::string kind;
};

struct FactorSetAudit
{
    int64_t gapSegments = 0;
    int64_t aggregatedChains = 0;
    int64_t priorCount = 0;
    int64_t priorConflicts = 0;
    /// V1R4 §6.5 count contract: only evidence that ACTUALLY became a
    /// factor counts. Raw input counts must never gate the run.
    int64_t appliedUniquePriorNodes = 0;
    int64_t rejectedPriors = 0;
    int64_t fusedPriorDuplicates = 0;
    std::string factorSetSha256;
};

/// Hashes a planar information matrix into the factor-set audit SHA so
/// ANY information bit change alters the identity (§9.5).
void hashInformation(Sha256 & hash, const char * prefix, const Mat3 info)
{
    char line[320];
    int pos = snprintf(line, sizeof(line), "%s:", prefix);
    for(int i = 0; i < 9; ++i)
    {
        pos += snprintf(line + pos, sizeof(line) - pos, "%.17g,", info[i]);
    }
    line[pos++] = '\n';
    hash.update(line, pos);
}

/// Builds the skeleton factor set.
/// - Odometry between consecutive skeleton nodes is the composition of
///   the raw neighbor chain between them with AGGREGATED covariance
///   (§11.3). A missing neighbor link ends the chain and forms a gap:
///   no factor is fabricated from raw poses (§11.4).
/// - Loop/Recovery/User constraints between skeleton nodes enter with
///   their sanitized information (canonical direction, audited dedupe).
/// - Absolute prior-map constraints enter as pose priors in the MAP
///   frame (§6.3).
bool buildSkeletonFactors(
    const GraphModel & model,
    const std::vector<size_t> & skeleton,
    const std::vector<AbsolutePrior> & priors,
    FactorSetAudit & audit,
    std::vector<FactorRecord> & factors,
    std::string & error)
{
    // Neighbor lookup keyed (min,max); measurement AND information are
    // oriented low-id -> high-id. When a link is stored high->low, the
    // inverted measurement REQUIRES the inverted information propagated
    // through the analytic inverse Jacobian (V1R4 §9.4 / B-06).
    struct NeighborEdge
    {
        SE2 measurement; // low -> high
        Mat3Box information; // low -> high
    };
    std::map<std::pair<int64_t, int64_t>, NeighborEdge> neighbor;
    for(const RawLink & link : model.links)
    {
        if(link.type != rtabmap::Link::kNeighbor) continue;
        if(!model.nodeIndex.count(link.from) || !model.nodeIndex.count(link.to)) continue;
        NeighborEdge edge;
        if(link.from < link.to)
        {
            edge.measurement = link.measurement;
            std::memcpy(edge.information.m, link.information, sizeof(Mat3));
        }
        else
        {
            edge.measurement = se2Inverse(link.measurement);
            if(!invertPlanarInformation(link.measurement, link.information, edge.information.m))
            {
                continue; // unusable information: audited skip (§10.3)
            }
        }
        neighbor[std::make_pair(std::min(link.from, link.to), std::max(link.from, link.to))] = edge;
    }

    Sha256 factorHash;

    // Odometry segments between consecutive skeleton nodes.
    for(size_t s = 0; s + 1 < skeleton.size(); ++s)
    {
        const size_t a = skeleton[s];
        const size_t b = skeleton[s + 1];
        std::vector<SE2> measurements;
        std::vector<Mat3Box> infos;
        bool chainOk = true;
        for(size_t k = a; k < b; ++k)
        {
            const int64_t idA = model.nodes[k].id;
            const int64_t idB = model.nodes[k + 1].id;
            if(model.nodes[k].mapId != model.nodes[k + 1].mapId)
            {
                chainOk = false;
                break;
            }
            std::map<std::pair<int64_t, int64_t>, NeighborEdge>::const_iterator e =
                neighbor.find(std::make_pair(std::min(idA, idB), std::max(idA, idB)));
            if(e == neighbor.end())
            {
                chainOk = false; // gap: never fabricate (§11.4)
                break;
            }
            SE2 m = e->second.measurement;
            Mat3Box info;
            std::memcpy(info.m, e->second.information.m, sizeof(Mat3));
            if(idA > idB)
            {
                // Edge stored low->high but the chain walks high->low:
                // invert measurement AND information together (§9.4).
                m = se2Inverse(m);
                Mat3 invInfo;
                if(!invertPlanarInformation(e->second.measurement, e->second.information.m, invInfo))
                {
                    chainOk = false;
                    break;
                }
                std::memcpy(info.m, invInfo, sizeof(Mat3));
            }
            measurements.push_back(m);
            infos.push_back(info);
        }
        if(!chainOk || measurements.empty())
        {
            ++audit.gapSegments;
            continue;
        }
        Mat3 total;
        std::memset(total, 0, sizeof(total));
        if(!aggregateChainInformation(measurements, infos, total))
        {
            error = "odometry chain covariance aggregation failed";
            return false;
        }
        {
            InfoPolicyAudit chainAudit;
            if(sanitizePlanarInformation(total, chainAudit) == InfoPolicy::Rejected)
            {
                // Aggregated information is not usable: treat the segment
                // as a gap instead of feeding g2o a non-SPD matrix.
                ++audit.gapSegments;
                continue;
            }
        }
        SE2 rel;
        rel.x = rel.y = rel.yaw = 0.0;
        for(size_t i = 0; i < measurements.size(); ++i) rel = se2Compose(rel, measurements[i]);
        FactorRecord factor;
        factor.from = model.nodes[a].id;
        factor.to = model.nodes[b].id;
        factor.type = rtabmap::Link::kNeighbor;
        factor.measurement = rel;
        std::memcpy(factor.information, total, sizeof(Mat3));
        factor.kind = "odometry";
        factors.push_back(factor);
        ++audit.aggregatedChains;
        char line[160];
        snprintf(line, sizeof(line), "f:odom:%lld:%lld:%.9f:%.9f:%.9f\n",
                 (long long)factor.from, (long long)factor.to,
                 rel.x, rel.y, rel.yaw);
        factorHash.update(line, strlen(line));
        hashInformation(factorHash, "f:odom:info", total);
    }

    // Relative constraints (loops / recovery / user).
    for(const RawLink & link : model.links)
    {
        if(link.type == rtabmap::Link::kNeighbor || link.type == rtabmap::Link::kPosePrior ||
           link.type == rtabmap::Link::kLandmark)
        {
            continue;
        }
        if(!model.nodeIndex.count(link.from) || !model.nodeIndex.count(link.to)) continue;
        const bool inSkeletonA = std::binary_search(skeleton.begin(), skeleton.end(), model.nodeIndex.at(link.from));
        const bool inSkeletonB = std::binary_search(skeleton.begin(), skeleton.end(), model.nodeIndex.at(link.to));
        if(!inSkeletonA || !inSkeletonB) continue;
        FactorRecord factor;
        factor.from = std::min(link.from, link.to);
        factor.to = std::max(link.from, link.to);
        factor.type = link.type;
        if(link.from <= link.to)
        {
            factor.measurement = link.measurement;
            std::memcpy(factor.information, link.information, sizeof(Mat3));
        }
        else
        {
            factor.measurement = se2Inverse(link.measurement);
            if(!invertPlanarInformation(link.measurement, link.information, factor.information))
            {
                continue; // information unusable: audited skip
            }
        }
        // g2o verifies every information matrix (symmetric + SPD); the
        // analytic inverse transform can drift numerically, so re-sanitize.
        {
            InfoPolicyAudit relAudit;
            if(sanitizePlanarInformation(factor.information, relAudit) == InfoPolicy::Rejected)
            {
                continue; // audited skip, never a factor
            }
        }
        factor.kind = isLoopType(link.type) ? "loop"
            : (link.type == rtabmap::Link::kVirtualClosure ? "recovery" : "loop");
        factors.push_back(factor);
        char line[160];
        snprintf(line, sizeof(line), "f:rel:%d:%lld:%lld:%.9f:%.9f:%.9f\n",
                 link.type, (long long)factor.from, (long long)factor.to,
                 factor.measurement.x, factor.measurement.y, factor.measurement.yaw);
        factorHash.update(line, strlen(line));
        hashInformation(factorHash, "f:rel:info", factor.information);
    }

    // Absolute prior-map constraints (§6). Multiple CONSISTENT priors on
    // the same node are information-weighted fused (§6.3); contradicting
    // clusters are audited and block the factor (never "first wins").
    struct NodePriorBundle
    {
        std::vector<const AbsolutePrior *> records;
    };
    std::map<int64_t, NodePriorBundle> bundles;
    for(size_t i = 0; i < priors.size(); ++i)
    {
        const AbsolutePrior & prior = priors[i];
        std::map<int64_t, size_t>::const_iterator idx = model.nodeIndex.find(prior.nodeId);
        if(idx == model.nodeIndex.end())
        {
            ++audit.rejectedPriors; // out-of-graph: never counted (§6.5)
            continue;
        }
        if(!std::binary_search(skeleton.begin(), skeleton.end(), idx->second))
        {
            ++audit.rejectedPriors;
            continue;
        }
        bundles[prior.nodeId].records.push_back(&prior);
    }
    const double kPriorFusionTranslationM = 0.75;
    const double kPriorFusionYawRad = 0.35;
    for(std::map<int64_t, NodePriorBundle>::const_iterator b = bundles.begin();
        b != bundles.end(); ++b)
    {
        const std::vector<const AbsolutePrior *> & records = b->second.records;
        // Largest consistent cluster by greedy agreement with record 0
        // seed, then every seed (cluster enumeration, §6.3).
        std::vector<size_t> bestCluster;
        for(size_t seed = 0; seed < records.size(); ++seed)
        {
            std::vector<size_t> cluster;
            for(size_t j = 0; j < records.size(); ++j)
            {
                const SE2 d = se2Compose(
                    se2Inverse(records[seed]->mapPose), records[j]->mapPose);
                if(std::hypot(d.x, d.y) <= kPriorFusionTranslationM &&
                   std::fabs(normalizeAngle(d.yaw)) <= kPriorFusionYawRad)
                {
                    cluster.push_back(j);
                }
            }
            if(cluster.size() > bestCluster.size()) bestCluster = cluster;
        }
        if(bestCluster.size() < records.size())
        {
            audit.priorConflicts += static_cast<int64_t>(records.size() - bestCluster.size());
        }
        if(bestCluster.empty())
        {
            audit.rejectedPriors += static_cast<int64_t>(records.size());
            continue;
        }
        // Information-weighted fusion of the winning cluster.
        double wSum = 0.0;
        SE2 fused;
        fused.x = fused.y = fused.yaw = 0.0;
        Mat3 fusedInfo;
        std::memset(fusedInfo, 0, sizeof(fusedInfo));
        double yawSin = 0.0, yawCos = 0.0;
        bool usable = true;
        for(size_t k = 0; k < bestCluster.size(); ++k)
        {
            const AbsolutePrior & prior = *records[bestCluster[k]];
            Mat3 info;
            std::memcpy(info, prior.information, sizeof(Mat3));
            InfoPolicyAudit priorAudit;
            if(sanitizePlanarInformation(info, priorAudit) == InfoPolicy::Rejected)
            {
                ++audit.rejectedPriors; // rejected info never anchors (§6.6)
                continue;
            }
            const double w = std::max(1.0e-9, 0.5 * (info[0] + info[4]));
            fused.x += w * prior.mapPose.x;
            fused.y += w * prior.mapPose.y;
            yawSin += w * std::sin(prior.mapPose.yaw);
            yawCos += w * std::cos(prior.mapPose.yaw);
            wSum += w;
            for(int e = 0; e < 9; ++e) fusedInfo[e] += info[e];
        }
        if(wSum <= 0.0)
        {
            audit.rejectedPriors += static_cast<int64_t>(bestCluster.size());
            continue;
        }
        fused.x /= wSum;
        fused.y /= wSum;
        fused.yaw = std::atan2(yawSin, yawCos);
        (void)usable;
        if(bestCluster.size() > 1) audit.fusedPriorDuplicates += static_cast<int64_t>(bestCluster.size()) - 1;
        InfoPolicyAudit fusedAudit;
        if(sanitizePlanarInformation(fusedInfo, fusedAudit) == InfoPolicy::Rejected)
        {
            audit.rejectedPriors += static_cast<int64_t>(bestCluster.size());
            continue;
        }
        FactorRecord factor;
        factor.from = b->first;
        factor.to = b->first;
        factor.type = rtabmap::Link::kPosePrior;
        factor.measurement = fused;
        std::memcpy(factor.information, fusedInfo, sizeof(Mat3));
        factor.kind = "prior";
        factors.push_back(factor);
        ++audit.priorCount;
        ++audit.appliedUniquePriorNodes;
        char line[160];
        snprintf(line, sizeof(line), "f:prior:%lld:%.9f:%.9f:%.9f\n",
                 (long long)b->first, fused.x, fused.y, fused.yaw);
        factorHash.update(line, strlen(line));
        hashInformation(factorHash, "f:prior:info", fusedInfo);
    }

    audit.factorSetSha256 = factorHash.hex();
    if(factors.empty())
    {
        error = "the skeleton factor graph is empty";
        return false;
    }
    return true;
}

// MARK: - Robust map-frame gauge estimation (§8.4 / V1R5 H-18) ----------------

/// Per-component gauge diagnostics surfaced in the quality report
/// (V1R5 §8.4/§10.3). The V1R4 information-weighted mean was flagged by
/// the independent review (B-15): a single high-information wrong prior
/// could drag the gauge, there was no cross-node robust outlier
/// estimation, and an equal-size bimodal cluster passed without any
/// ambiguity gate. The V1R5 estimator RANSACs the prior candidates in
/// SE(2) and gates on consensus margin (H-18) + trajectory span before
/// a component is allowed to anchor.
struct GaugeDiagnostics
{
    int64_t componentId = 0;
    int64_t candidateCount = 0;
    int64_t inlierCount = 0;
    int64_t outlierCount = 0;
    /// Best RANSAC consensus / total candidates.
    double consensusRatio = 0.0;
    /// Second-best consensus / total candidates (0 when unique).
    double secondClusterRatio = 0.0;
    /// Max raw-node distance spanned by the prior candidates (m) — the
    /// §8.4 trajectory-span gate input.
    double translationSpreadM = 0.0;
    /// Max pairwise yaw spread of the candidates (rad), diagnostic.
    double yawSpreadRad = 0.0;
    bool anchored = false;
    /// Valid when anchored: T_map_local robust gauge.
    SE2 mapFromLocal;
    /// Machine-readable reason when not anchored ("no_priors",
    /// "insufficient_candidates", "trajectory_span_too_small",
    /// "insufficient_consensus", "ambiguous_clusters",
    /// "low_consensus_ratio", "non_finite_candidates",
    /// "non_finite_gauge"). Carried verbatim into the quality report.
    std::string rejectReason;
};

/// One prior candidate for the map-frame gauge: candidate = T_map ×
/// inv(T_raw) plus the raw node pose (for the trajectory-span gate).
struct GaugeCandidate
{
    SE2 gauge;
    SE2 rawPose;
    /// Information-derived weight used by the IRLS initializer only;
    /// RANSAC inlier counting is weight-free so one high-information
    /// wrong prior cannot dominate the consensus (B-15).
    double weight = 1.0;
};

// V1R5 §8.4 gate constants (candidate policy until the Replay Pareto
// freezes production values — same status as MS_QUALITY_POLICY_VERSION).
const int kGaugeRansacIterations = 64;
const int kGaugeRansacSampleCount = 2;
const int kGaugeMinimumCandidateCount = 3;
const double kGaugeMinimumTrajectorySpanM = 2.0;
/// Normalization scales for the joint residual (raw-drift audit scales
/// carried over from the V1R4 gauge bounds).
const double kGaugeSigmaTranslationM = 0.5;
const double kGaugeSigmaYawRad = 0.2;
/// Inlier threshold in normalized joint-residual units ("1.0 or 2.0"
/// per §8.4; 2.0 is chosen so 1.0 m or 0.4 rad alone still passes).
const double kGaugeInlierThreshold = 2.0;
const int kGaugeMinimumInlierCount = 3;
const double kGaugeMinimumConsensusRatio = 0.5;
/// H-18: the second cluster must trail the winner by at least this
/// fraction of all candidates, or the split is ambiguous.
const double kGaugeConsensusMargin = 0.15;
const int kGaugeIrisIterations = 4;
const double kGaugeIrisHuberDelta = 2.0;

/// Normalized SE(2) joint residual of one candidate against a model:
/// translation error / sigma_xy + yaw error / sigma_yaw (§8.4).
double gaugeJointResidual(const SE2 & model, const SE2 & candidate)
{
    const double translationError =
        std::hypot(candidate.x - model.x, candidate.y - model.y);
    const double yawError =
        std::fabs(normalizeAngle(candidate.yaw - model.yaw));
    return translationError / kGaugeSigmaTranslationM +
           yawError / kGaugeSigmaYawRad;
}

/// SE(2) model from a candidate pair (§8.4): translation is the pair
/// mean, yaw the atan2 average of the two unit vectors.
SE2 gaugeModelFromPair(const GaugeCandidate & a, const GaugeCandidate & b)
{
    SE2 model;
    model.x = 0.5 * (a.gauge.x + b.gauge.x);
    model.y = 0.5 * (a.gauge.y + b.gauge.y);
    model.yaw = std::atan2(
        std::sin(a.gauge.yaw) + std::sin(b.gauge.yaw),
        std::cos(a.gauge.yaw) + std::cos(b.gauge.yaw));
    return model;
}

/// Huber IRLS refinement of the RANSAC consensus set (§8.4). The
/// initializer is the information-weighted circular mean; each of the
/// few iterations re-weights every inlier by the Huber penalty of its
/// normalized joint residual, so no single high-information candidate
/// can dominate the final gauge (B-15).
SE2 refineGaugeIRLS(const std::vector<GaugeCandidate> & inliers)
{
    SE2 mean;
    if(inliers.empty()) return mean;
    double wSum = 0.0;
    for(size_t i = 0; i < inliers.size(); ++i)
    {
        mean.x += inliers[i].weight * inliers[i].gauge.x;
        mean.y += inliers[i].weight * inliers[i].gauge.y;
        wSum += inliers[i].weight;
    }
    if(wSum <= 0.0) return mean;
    mean.x /= wSum;
    mean.y /= wSum;
    double yawSin = 0.0, yawCos = 0.0;
    for(size_t i = 0; i < inliers.size(); ++i)
    {
        yawSin += inliers[i].weight * std::sin(inliers[i].gauge.yaw);
        yawCos += inliers[i].weight * std::cos(inliers[i].gauge.yaw);
    }
    mean.yaw = std::atan2(yawSin, yawCos);
    for(int it = 0; it < kGaugeIrisIterations; ++it)
    {
        double sx = 0.0, sy = 0.0, sSin = 0.0, sCos = 0.0, sw = 0.0;
        for(size_t i = 0; i < inliers.size(); ++i)
        {
            const double joint = gaugeJointResidual(mean, inliers[i].gauge);
            const double huber = joint <= kGaugeIrisHuberDelta
                ? 1.0 : kGaugeIrisHuberDelta / joint;
            const double w = inliers[i].weight * huber;
            sx += w * inliers[i].gauge.x;
            sy += w * inliers[i].gauge.y;
            sSin += w * std::sin(inliers[i].gauge.yaw);
            sCos += w * std::cos(inliers[i].gauge.yaw);
            sw += w;
        }
        if(sw <= 0.0) break;
        mean.x = sx / sw;
        mean.y = sy / sw;
        mean.yaw = std::atan2(sSin, sCos);
    }
    return mean;
}

/// Robust SE(2) map-frame gauge (§8.4, H-18). FAIL-CLOSED: when the
/// RANSAC consensus, the H-18 margin or the §8.4 span/ratio gates are
/// not met the component is NOT anchored and `anchored` stays false —
/// there is never a fallback to the V1R4 information-weighted mean.
void estimateRobustGauge(
    const std::vector<GaugeCandidate> & candidates,
    GaugeDiagnostics & out)
{
    out.candidateCount = static_cast<int64_t>(candidates.size());
    if(candidates.size() < static_cast<size_t>(kGaugeRansacSampleCount))
    {
        out.rejectReason = "insufficient_candidates";
        return;
    }
    // §8.4 trajectory-span gate: priors that all sit at the same raw
    // location cannot constrain an SE(2) gauge (geometrically
    // degenerate). The gate passes when the prior nodes span more than
    // kGaugeMinimumTrajectorySpanM OR when at least
    // kGaugeMinimumCandidateCount candidates exist.
    double minX = candidates[0].rawPose.x, maxX = minX;
    double minY = candidates[0].rawPose.y, maxY = minY;
    for(size_t i = 1; i < candidates.size(); ++i)
    {
        minX = std::min(minX, candidates[i].rawPose.x);
        maxX = std::max(maxX, candidates[i].rawPose.x);
        minY = std::min(minY, candidates[i].rawPose.y);
        maxY = std::max(maxY, candidates[i].rawPose.y);
    }
    out.translationSpreadM = std::hypot(maxX - minX, maxY - minY);
    for(size_t i = 0; i < candidates.size(); ++i)
    {
        for(size_t j = i + 1; j < candidates.size(); ++j)
        {
            out.yawSpreadRad = std::max(out.yawSpreadRad,
                std::fabs(normalizeAngle(candidates[i].gauge.yaw -
                                         candidates[j].gauge.yaw)));
        }
    }
    if(candidates.size() < static_cast<size_t>(kGaugeMinimumCandidateCount) &&
       out.translationSpreadM <= kGaugeMinimumTrajectorySpanM)
    {
        out.rejectReason = "trajectory_span_too_small";
        return;
    }
    // RANSAC: sample candidate pairs, fit the pair-mean SE(2) model,
    // count inliers by normalized joint residual. Deterministic seed
    // so the estimate is reproducible across runs.
    std::mt19937 rng(0x5EEDC0DEu);
    std::uniform_int_distribution<size_t> dist(0, candidates.size() - 1);
    std::vector<bool> bestMask;
    size_t bestCount = 0;
    size_t secondCount = 0;
    for(int iter = 0; iter < kGaugeRansacIterations; ++iter)
    {
        const size_t i0 = dist(rng);
        size_t i1 = dist(rng);
        if(i0 == i1) continue;
        const SE2 model = gaugeModelFromPair(candidates[i0], candidates[i1]);
        std::vector<bool> mask(candidates.size(), false);
        size_t count = 0;
        for(size_t i = 0; i < candidates.size(); ++i)
        {
            if(gaugeJointResidual(model, candidates[i].gauge) < kGaugeInlierThreshold)
            {
                mask[i] = true;
                ++count;
            }
        }
        if(bestMask.empty() || (count > bestCount && mask != bestMask))
        {
            if(!bestMask.empty())
            {
                // The previous winner becomes the runner-up so the H-18
                // margin always compares against the strongest rival.
                secondCount = bestCount;
            }
            bestMask = mask;
            bestCount = count;
        }
        else if(count > secondCount && mask != bestMask)
        {
            secondCount = count;
        }
    }
    out.inlierCount = static_cast<int64_t>(bestCount);
    out.outlierCount = static_cast<int64_t>(candidates.size()) - out.inlierCount;
    out.consensusRatio = static_cast<double>(bestCount) /
        static_cast<double>(candidates.size());
    out.secondClusterRatio = static_cast<double>(secondCount) /
        static_cast<double>(candidates.size());
    // H-18 gate: the winning cluster must be large enough and the
    // second cluster (if any) far enough behind — an equal-size
    // bimodal split is ambiguous and must not anchor.
    if(out.inlierCount < kGaugeMinimumInlierCount)
    {
        out.rejectReason = "insufficient_consensus";
        return;
    }
    if(secondCount > 0 &&
       (out.consensusRatio - out.secondClusterRatio) < kGaugeConsensusMargin)
    {
        out.rejectReason = "ambiguous_clusters";
        return;
    }
    if(out.consensusRatio < kGaugeMinimumConsensusRatio)
    {
        out.rejectReason = "low_consensus_ratio";
        return;
    }
    // Collect the consensus set and refine it with Huber IRLS (§8.4).
    std::vector<GaugeCandidate> inliers;
    inliers.reserve(bestCount);
    for(size_t i = 0; i < candidates.size(); ++i)
    {
        if(bestMask[i]) inliers.push_back(candidates[i]);
    }
    out.mapFromLocal = refineGaugeIRLS(inliers);
    if(!se2Finite(out.mapFromLocal))
    {
        out.rejectReason = "non_finite_gauge";
        return;
    }
    out.anchored = true;
}

// MARK: - RobustSE2Optimizer (§11.4/§12) ----------------------------------------

struct OptimizerDiagnostics
{
    int iterations = 0;
    double finalError = 0.0;
    double wallSeconds = 0.0;
    int64_t factorCount = 0;
    bool available = false;
    bool cancelled = false;
    bool budgetExhausted = false;
    int64_t chunks = 0;
    // V1R5 H-17: convergence provenance for the quality report. The
    // g2o error is only returned per chunk, so the chunk loop also
    // tracks the max vertex delta as the improvement proxy.
    bool converged = false;
    std::string stoppedReason = "iteration_budget_exhausted";
    double initialError = std::numeric_limits<double>::quiet_NaN();
    double relativeImprovement = std::numeric_limits<double>::quiet_NaN();
    /// Max per-vertex pose delta of the LAST chunk (m); NaN when no
    /// chunk finished yet.
    double lastChunkMaxVertexDelta = std::numeric_limits<double>::quiet_NaN();
};

struct OptimizedGraph
{
    std::map<int64_t, SE2> poses;
    OptimizerDiagnostics diagnostics;
};

/// Runs rtabmap g2o per component with chunked iterations so cancel /
/// wall-time / memory probes fire BETWEEN chunks (§12.1) — a run can be
/// stopped mid-optimization, not only after completion.
///
/// V1R4 correctness (§6.4 / B-01 / B-05):
/// - optimizer vertices are ONLY factor endpoints; raw non-skeleton nodes
///   never become vertices, so the Fast path is O(S + F), never O(N²);
/// - each prior-anchored component closes the map-frame gauge: a
///   consistent `T_map_local` is estimated from the applied priors
///   (candidate_i = T_map_i × inv(T_raw_i)), the whole component's
///   initial poses are rigidly transformed into the map frame, and only
///   then is the anchor fixed. The component may still translate/rotate
///   as a rigid body under the solver; a raw local root is NEVER frozen
///   while expecting priors to do the alignment.
/// V1R5 (B-15 / §8.4 / §8.5 / H-17 / H-18):
/// - the gauge is now estimated with SE(2) RANSAC + Huber IRLS and gated
///   on consensus margin (H-18), trajectory span and inlier ratio (§8.4)
///   instead of the V1R4 information-weighted mean; a rejected gauge
///   FAILS CLOSED (the component is not anchored, its prior nodes land in
///   `gaugeFailedPriorNodes`) — there is never a fallback to the mean;
/// - per-component gauge diagnostics are emitted through
///   `gaugeDiagnostics` for the quality report (§10.3);
/// - the chunk loop now records convergence provenance (converged /
///   stopped reason / initial-final error / relative improvement) on
///   `out.diagnostics` for the quality report (H-17).
bool optimizeSkeleton(
    const GraphModel & model,
    const std::vector<FactorRecord> & factors,
    int totalIterations,
    double maxWallSeconds,
    MSFactorGraphCancelFn cancel,
    void * cancelUser,
    OptimizedGraph & out,
    std::set<int64_t> & gaugeFailedPriorNodes,
    std::map<int64_t, SE2> & componentGauge,
    std::vector<GaugeDiagnostics> & gaugeDiagnostics,
    std::string & error)
{
    if(factors.empty())
    {
        error = "empty factor graph";
        return false;
    }
    // Vertices: factor endpoints only (§10.1).
    std::map<int64_t, SE2> vertexPose;
    std::map<int64_t, int64_t> parent;
    for(const FactorRecord & factor : factors)
    {
        const int64_t endpoints[2] = {factor.from, factor.to};
        for(int e = 0; e < 2; ++e)
        {
            const int64_t id = endpoints[e];
            std::map<int64_t, size_t>::const_iterator it = model.nodeIndex.find(id);
            if(it == model.nodeIndex.end()) continue;
            if(!vertexPose.count(id))
            {
                vertexPose[id] = model.nodes[it->second].pose;
                parent[id] = id;
            }
        }
    }

    // Components over relative factors (O(F)).
    std::function<int64_t(int64_t)> find = [&](int64_t v) {
        int64_t r = v;
        while(parent[r] != r) r = parent[r];
        while(parent[v] != r) { int64_t next = parent[v]; parent[v] = r; v = next; }
        return r;
    };
    for(const FactorRecord & factor : factors)
    {
        if(factor.type == rtabmap::Link::kPosePrior) continue;
        if(!parent.count(factor.from) || !parent.count(factor.to)) continue;
        const int64_t rf = find(factor.from);
        const int64_t rt = find(factor.to);
        if(rf != rt) parent[rf] = rt;
    }

    // Group vertices and factors per component (O(S + F), never a full
    // node scan per component).
    std::map<int64_t, std::vector<int64_t> > componentNodes;
    for(std::map<int64_t, SE2>::const_iterator v = vertexPose.begin();
        v != vertexPose.end(); ++v)
    {
        componentNodes[find(v->first)].push_back(v->first);
    }
    std::map<int64_t, std::vector<const FactorRecord *> > componentFactors;
    for(size_t f = 0; f < factors.size(); ++f)
    {
        const FactorRecord & factor = factors[f];
        if(!parent.count(factor.from)) continue;
        componentFactors[find(factor.from)].push_back(&factor);
    }

    const auto start = std::chrono::steady_clock::now();
    const int chunkIterations = 5;
    // Frozen map-frame gauge consistency bounds (§6.4, V1R4): kept as a
    // documented audit reference only — drift-dominated on long scans, so
    // they no longer gate anchoring (see below).
    const double kGaugeTranslationM = 0.5;
    const double kGaugeYawRad = 0.2;
    (void)kGaugeTranslationM;
    (void)kGaugeYawRad;
    for(std::map<int64_t, std::vector<int64_t> >::const_iterator it = componentNodes.begin();
        it != componentNodes.end(); ++it)
    {
        if(cancel && cancel(cancelUser))
        {
            out.diagnostics.cancelled = true;
            error = "cancelled";
            return false;
        }
        const double elapsed = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - start).count();
        if(maxWallSeconds > 0.0 && elapsed > maxWallSeconds)
        {
            out.diagnostics.budgetExhausted = true;
            error = "optimizer wall-time budget exhausted";
            return false;
        }
        const std::vector<int64_t> & nodes = it->second;
        const std::vector<const FactorRecord *> & compFactors = componentFactors[it->first];

        // --- Map-frame gauge estimation from applied priors (§6.4/§8.4) -
        std::vector<const FactorRecord *> priorsApplied;
        std::vector<const FactorRecord *> relativeFactors;
        for(size_t f = 0; f < compFactors.size(); ++f)
        {
            if(compFactors[f]->type == rtabmap::Link::kPosePrior)
                priorsApplied.push_back(compFactors[f]);
            else
                relativeFactors.push_back(compFactors[f]);
        }
        bool gaugeAnchored = false;
        SE2 mapFromLocal;
        mapFromLocal.x = mapFromLocal.y = mapFromLocal.yaw = 0.0;
        GaugeDiagnostics gaugeDiag;
        gaugeDiag.componentId = it->first;
        if(!priorsApplied.empty())
        {
            // V1R5 §8.4: robust SE(2) gauge. candidate_i = T_map_i ×
            // inv(T_raw_i); RANSAC + Huber IRLS replace the V1R4
            // information-weighted mean (B-15: a single high-information
            // wrong prior could drag the gauge, there was no cross-node
            // outlier rejection, and equal bimodal clusters passed
            // without an ambiguity gate). Fail-closed: a rejected gauge
            // un-anchors the component instead of falling back.
            std::vector<GaugeCandidate> candidates;
            bool finite = true;
            for(size_t p = 0; p < priorsApplied.size(); ++p)
            {
                const FactorRecord & prior = *priorsApplied[p];
                std::map<int64_t, SE2>::const_iterator raw = vertexPose.find(prior.from);
                if(raw == vertexPose.end()) { finite = false; break; }
                const SE2 candidate = se2Compose(prior.measurement, se2Inverse(raw->second));
                if(!se2Finite(candidate)) { finite = false; break; }
                GaugeCandidate c;
                c.gauge = candidate;
                c.rawPose = raw->second;
                c.weight = std::max(1.0e-9,
                    0.5 * (prior.information[0] + prior.information[4]));
                candidates.push_back(c);
            }
            if(!finite || candidates.empty())
            {
                gaugeDiag.rejectReason = "non_finite_candidates";
            }
            else
            {
                estimateRobustGauge(candidates, gaugeDiag);
                if(gaugeDiag.anchored)
                {
                    gaugeAnchored = true;
                    mapFromLocal = gaugeDiag.mapFromLocal;
                    componentGauge[it->first] = gaugeDiag.mapFromLocal;
                }
            }
            if(!gaugeAnchored)
            {
                // V1R5 fail-closed (§8.4/H-18): a component whose robust
                // gauge failed its gates must not anchor. Populating
                // gaugeFailedPriorNodes keeps it out of the anchored
                // set, so its rows are never publish eligible.
                for(size_t p = 0; p < priorsApplied.size(); ++p)
                {
                    gaugeFailedPriorNodes.insert(priorsApplied[p]->from);
                }
            }
        }
        else
        {
            gaugeDiag.rejectReason = "no_priors";
        }
        gaugeDiagnostics.push_back(gaugeDiag);

        // --- Build the optimizer problem for this component ------------
        std::map<int, rtabmap::Transform> subPoses;
        for(size_t n = 0; n < nodes.size(); ++n)
        {
            SE2 pose = vertexPose.at(nodes[n]);
            if(gaugeAnchored) pose = se2Compose(mapFromLocal, pose);
            subPoses[static_cast<int>(nodes[n])] = transformFromSE2(pose);
        }
        std::multimap<int, rtabmap::Link> subLinks;
        for(size_t f = 0; f < relativeFactors.size(); ++f)
        {
            const FactorRecord & factor = *relativeFactors[f];
            if(factor.from == factor.to) continue;
            rtabmap::Link link(
                static_cast<int>(factor.from),
                static_cast<int>(factor.to),
                static_cast<rtabmap::Link::Type>(factor.type),
                transformFromSE2(factor.measurement),
                sixFromPlanar(factor.information));
            subLinks.insert(std::make_pair(link.from(), link));
        }
        for(size_t p = 0; p < priorsApplied.size(); ++p)
        {
            if(!gaugeAnchored) continue; // conflicting gauge: no anchoring
            const FactorRecord & prior = *priorsApplied[p];
            rtabmap::Link link(
                static_cast<int>(prior.from),
                static_cast<int>(prior.to),
                rtabmap::Link::kPosePrior,
                transformFromSE2(prior.measurement),
                sixFromPlanar(prior.information));
            subLinks.insert(std::make_pair(link.from(), link));
        }
        if(subPoses.size() < 2 && subLinks.empty())
        {
            if(!subPoses.empty())
            {
                out.poses[static_cast<int64_t>(subPoses.begin()->first)] =
                    se2FromTransform(subPoses.begin()->second);
            }
            continue;
        }

        rtabmap::ParametersMap parameters;
        parameters.insert(rtabmap::ParametersPair(rtabmap::Parameters::kOptimizerStrategy(), "1"));
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
        optimizer->setRobust(true);

        // Anchor: smallest node id of the component. Its initial pose is
        // already in the map frame when the gauge is anchored, so fixing
        // it never fights the prior alignment.
        int64_t anchorId = nodes[0];
        for(size_t n = 1; n < nodes.size(); ++n) anchorId = std::min(anchorId, nodes[n]);
        const int anchor = static_cast<int>(anchorId);
        std::map<int, rtabmap::Transform> current = subPoses;
        int remaining = totalIterations;
        bool converged = false;
        bool numericalStagnation = false;
        double prevError = std::numeric_limits<double>::quiet_NaN();
        while(remaining > 0)
        {
            if(cancel && cancel(cancelUser))
            {
                out.diagnostics.cancelled = true;
                out.diagnostics.stoppedReason = "cancelled";
                error = "cancelled";
                return false;
            }
            const double now = std::chrono::duration<double>(
                std::chrono::steady_clock::now() - start).count();
            if(maxWallSeconds > 0.0 && now > maxWallSeconds)
            {
                out.diagnostics.budgetExhausted = true;
                out.diagnostics.stoppedReason = "wall_time";
                error = "optimizer wall-time budget exhausted";
                return false;
            }
            const int chunk = std::min(chunkIterations, remaining);
            optimizer->setIterations(chunk);
            double chunkError = std::numeric_limits<double>::quiet_NaN();
            int chunkDone = 0;
            std::map<int, rtabmap::Transform> prevPoses = current;
            std::map<int, rtabmap::Transform> optimized =
                optimizer->optimize(anchor, current, subLinks, 0, &chunkError, &chunkDone);
            if(optimized.size() != subPoses.size())
            {
                error = "optimizer returned an incomplete node inventory";
                return false;
            }
            // V1R5 H-17: the g2o error is only returned per chunk, so
            // the max per-vertex pose delta of the chunk is the
            // improvement proxy used for numerical-stagnation detection.
            double maxVertexDelta = 0.0;
            for(std::map<int, rtabmap::Transform>::const_iterator p = optimized.begin();
                p != optimized.end(); ++p)
            {
                std::map<int, rtabmap::Transform>::const_iterator q = prevPoses.find(p->first);
                if(q == prevPoses.end()) continue;
                maxVertexDelta = std::max(maxVertexDelta, static_cast<double>(std::hypot(
                    p->second.x() - q->second.x(), p->second.y() - q->second.y())));
            }
            current = optimized;
            remaining -= chunk;
            out.diagnostics.iterations += chunkDone;
            out.diagnostics.chunks += 1;
            out.diagnostics.lastChunkMaxVertexDelta = maxVertexDelta;
            if(std::isfinite(chunkError))
            {
                if(!std::isfinite(out.diagnostics.initialError))
                    out.diagnostics.initialError = chunkError;
                out.diagnostics.finalError = chunkError;
            }
            if(chunkDone < chunk)
            {
                // The optimizer reports it needs no more iterations.
                converged = true;
                break;
            }
            // Numerical stagnation (H-17): a full chunk that moved
            // nothing while the error barely changed means the solver is
            // stuck; stop instead of burning the iteration budget.
            if(std::isfinite(prevError) && std::isfinite(chunkError) &&
               maxVertexDelta < 1.0e-4 &&
               prevError - chunkError < 1.0e-6 * std::max(1.0, prevError))
            {
                numericalStagnation = true;
                break;
            }
            prevError = chunkError;
        }
        if(converged)
        {
            out.diagnostics.converged = true;
            out.diagnostics.stoppedReason = "converged";
        }
        else if(numericalStagnation)
        {
            out.diagnostics.stoppedReason = "numerical_stagnation";
        }
        else
        {
            out.diagnostics.stoppedReason = "iteration_budget_exhausted";
        }
        if(std::isfinite(out.diagnostics.initialError) &&
           std::isfinite(out.diagnostics.finalError) &&
           out.diagnostics.initialError > 0.0)
        {
            out.diagnostics.relativeImprovement =
                (out.diagnostics.initialError - out.diagnostics.finalError) /
                out.diagnostics.initialError;
        }
        for(std::map<int, rtabmap::Transform>::const_iterator p = current.begin();
            p != current.end(); ++p)
        {
            const SE2 se2 = se2FromTransform(p->second);
            if(!se2Finite(se2))
            {
                error = "optimizer returned a non-finite pose";
                return false;
            }
            out.poses[static_cast<int64_t>(p->first)] = se2;
        }
    }
    out.diagnostics.wallSeconds = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - start).count();
    out.diagnostics.factorCount = static_cast<int64_t>(factors.size());
    return true;
}

// MARK: - GraphQualityEvaluator (§11.5/§14) -------------------------------------

/// Frozen yaw-aware quality policy (§11.1, V1R4). Translation alone can
/// never represent a full SE(2) error: every factor kind records its
/// translation (m), yaw (rad) and chi² contributions separately and the
/// gate freezes thresholds for BOTH axes. File-scope constants (this
/// translation unit lives in an anonymous namespace) avoid ODR issues.
///
/// V1R4 §11.1 fix: the absolute correction gates were drift-dominated —
/// the optimizer must compensate the raw random-walk drift (0.004 m/step
/// accumulates 0.5 m over ~15k nodes, unbounded with scan length), which
/// is a legitimate smooth deformation, not damage. The gates now only
/// reject catastrophic deformation (wrong loops / prior explosions);
/// local damage is the jump gates below, which never changed.
const double kLoopTranslationP95M = 0.25;
const double kLoopTranslationMaxM = 1.0;
const double kLoopYawP95Rad = 0.10;
const double kLoopYawMaxRad = 0.5;
const double kPriorTranslationP95M = 0.5;
const double kPriorTranslationMaxM = 1.5;
const double kPriorYawP95Rad = 0.15;
const double kPriorYawMaxRad = 0.6;
const double kCorrectionTranslationP95M = 3.0;
const double kCorrectionTranslationMaxM = 5.0;
const double kCorrectionYawP95Rad = 0.5;
const double kCorrectionYawMaxRad = 1.2;
const double kCorrectionJumpMaxM = 2.0;
const double kCorrectionYawJumpMaxRad = 0.6;
const double kChi2PerDofMax = 50.0;
const double kResidualThresholdRatioMax = 0.05;
const double kPublishRatioMin = 0.95;
const int64_t kMinimumAppliedPriors = 3;

struct QualityMetrics
{
    HealthReport health;
    FactorSetAudit factorAudit;
    int64_t skeletonNodes = 0;
    int64_t skeletonFactors = 0;
    double anchoredRatio = 0.0;
    double coverage = 0.0;
    double chi2 = 0.0;
    int64_t dof = 0;
    /// Translation residual (m) per kind.
    std::vector<double> odometryResiduals;
    std::vector<double> loopResiduals;
    std::vector<double> priorResiduals;
    std::vector<double> recoveryResiduals;
    /// Yaw residual (rad) per kind (§11.1).
    std::vector<double> odometryYawResiduals;
    std::vector<double> loopYawResiduals;
    std::vector<double> priorYawResiduals;
    std::vector<double> recoveryYawResiduals;
    double residualThresholdRatio = 0.0;
    double yawThresholdRatio = 0.0;
    /// Corrections: translation (m) and yaw (rad).
    std::vector<double> corrections;
    std::vector<double> correctionYaws;
    double correctionJumpMax = 0.0;
    double correctionYawJumpMax = 0.0;
    int64_t anchoredComponents = 0;
    int64_t totalComponents = 0;
    int64_t publishNodes = 0;
    std::string optimizerError;
    OptimizerDiagnostics solver;
    double wallSeconds = 0.0;
    /// V1R5 §8.4/§10.3: per-component robust gauge diagnostics, one
    /// entry per skeleton component (including non-anchored ones, with
    /// the exact reject reason).
    std::vector<GaugeDiagnostics> gaugeDiagnostics;
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

/// Distance-equivalent residual norm kept for tests; the quality gate
/// uses the explicit translation/yaw split (§11.1).
double residualChi2(const SE2 & measurement, const SE2 & optimizedRelative, const Mat3 info)
{
    const SE2 delta = se2Compose(se2Inverse(measurement), optimizedRelative);
    const double r[3] = {delta.x, delta.y, delta.yaw};
    double quad = 0.0;
    for(int i = 0; i < 3; ++i)
        for(int j = 0; j < 3; ++j)
            quad += r[i] * info[i * 3 + j] * r[j];
    return quad;
}

QualityMetrics evaluateQuality(
    const GraphModel & model,
    const std::vector<FactorRecord> & factors,
    const OptimizedGraph & optimized,
    const std::vector<size_t> & skeleton,
    const HealthReport & health,
    const FactorSetAudit & factorAudit,
    double runWallSeconds,
    double coverage,
    const std::map<int64_t, SE2> & nodeGauge,
    const std::vector<GaugeDiagnostics> & gaugeDiagnostics)
{
    QualityMetrics metrics;
    metrics.health = health;
    metrics.factorAudit = factorAudit;
    metrics.skeletonNodes = static_cast<int64_t>(skeleton.size());
    metrics.skeletonFactors = static_cast<int64_t>(factors.size());
    metrics.solver = optimized.diagnostics;
    metrics.wallSeconds = runWallSeconds;
    metrics.coverage = coverage;
    metrics.gaugeDiagnostics = gaugeDiagnostics;
    metrics.anchoredRatio = model.nodes.empty() ? 0.0
        : static_cast<double>(health.largestComponent) / static_cast<double>(model.nodes.size());

    // Per-factor residuals and full chi² (§14.1). Pose priors enter chi².
    // Translation and yaw are thresholded SEPARATELY (§11.1).
    int64_t evaluated = 0;
    int64_t aboveThreshold = 0;
    int64_t aboveYawThreshold = 0;
    const double rejectThresholdM = 1.0;
    const double rejectYawThresholdRad = 0.5;
    for(const FactorRecord & factor : factors)
    {
        SE2 delta;
        bool have = false;
        if(factor.type == rtabmap::Link::kPosePrior)
        {
            std::map<int64_t, SE2>::const_iterator it = optimized.poses.find(factor.from);
            if(it == optimized.poses.end()) continue;
            delta = se2Compose(se2Inverse(factor.measurement), it->second);
            have = true;
        }
        else
        {
            std::map<int64_t, SE2>::const_iterator a = optimized.poses.find(factor.from);
            std::map<int64_t, SE2>::const_iterator b = optimized.poses.find(factor.to);
            if(a == optimized.poses.end() || b == optimized.poses.end()) continue;
            const SE2 relative = se2Compose(se2Inverse(a->second), b->second);
            delta = se2Compose(se2Inverse(factor.measurement), relative);
            have = true;
        }
        if(!have) continue;
        const double norm = std::hypot(delta.x, delta.y);
        const double yaw = std::fabs(normalizeAngle(delta.yaw));
        metrics.chi2 += residualChi2(factor.measurement,
            factor.type == rtabmap::Link::kPosePrior
                ? optimized.poses.at(factor.from)
                : se2Compose(se2Inverse(optimized.poses.at(factor.from)),
                             optimized.poses.at(factor.to)),
            factor.information);
        metrics.dof += 3;
        if(factor.type == rtabmap::Link::kPosePrior)
        {
            metrics.priorResiduals.push_back(norm);
            metrics.priorYawResiduals.push_back(yaw);
        }
        else if(factor.type == rtabmap::Link::kNeighbor)
        {
            metrics.odometryResiduals.push_back(norm);
            metrics.odometryYawResiduals.push_back(yaw);
        }
        else if(isLoopType(factor.type))
        {
            metrics.loopResiduals.push_back(norm);
            metrics.loopYawResiduals.push_back(yaw);
        }
        else if(factor.type == rtabmap::Link::kVirtualClosure)
        {
            metrics.recoveryResiduals.push_back(norm);
            metrics.recoveryYawResiduals.push_back(yaw);
        }
        else
        {
            metrics.loopResiduals.push_back(norm);
            metrics.loopYawResiduals.push_back(yaw);
        }
        ++evaluated;
        if(norm > rejectThresholdM) ++aboveThreshold;
        if(yaw > rejectYawThresholdRad) ++aboveYawThreshold;
    }
    if(evaluated > 0)
    {
        metrics.residualThresholdRatio =
            static_cast<double>(aboveThreshold) / static_cast<double>(evaluated);
        metrics.yawThresholdRatio =
            static_cast<double>(aboveYawThreshold) / static_cast<double>(evaluated);
    }

    // Corrections of skeleton nodes against the raw poses — translation
    // AND yaw (§11.1). For components with an estimated map-frame gauge
    // the metric measures DEFORMATION: the correction relative to the
    // component gauge, so a legitimate non-identity global alignment is
    // not mistaken for damage (§6.4 golden).
    for(size_t s = 0; s < skeleton.size(); ++s)
    {
        const RawNode & raw = model.nodes[skeleton[s]];
        std::map<int64_t, SE2>::const_iterator it = optimized.poses.find(raw.id);
        if(it == optimized.poses.end()) continue;
        SE2 correction = se2Compose(it->second, se2Inverse(raw.pose));
        std::map<int64_t, SE2>::const_iterator g = nodeGauge.find(raw.id);
        if(g != nodeGauge.end())
        {
            correction = se2Compose(se2Inverse(g->second), correction);
        }
        metrics.corrections.push_back(std::hypot(correction.x, correction.y));
        metrics.correctionYaws.push_back(std::fabs(normalizeAngle(correction.yaw)));
    }
    for(size_t s = 0; s + 1 < skeleton.size(); ++s)
    {
        const RawNode & rawA = model.nodes[skeleton[s]];
        const RawNode & rawB = model.nodes[skeleton[s + 1]];
        std::map<int64_t, SE2>::const_iterator a = optimized.poses.find(rawA.id);
        std::map<int64_t, SE2>::const_iterator b = optimized.poses.find(rawB.id);
        if(a == optimized.poses.end() || b == optimized.poses.end()) continue;
        SE2 ca = se2Compose(a->second, se2Inverse(rawA.pose));
        SE2 cb = se2Compose(b->second, se2Inverse(rawB.pose));
        std::map<int64_t, SE2>::const_iterator ga = nodeGauge.find(rawA.id);
        std::map<int64_t, SE2>::const_iterator gb = nodeGauge.find(rawB.id);
        if(ga != nodeGauge.end() && gb != nodeGauge.end() &&
           std::hypot(ga->second.x - gb->second.x, ga->second.y - gb->second.y) < 1e-9)
        {
            // Same component gauge on both anchors: jump measures pure
            // deformation.
            ca = se2Compose(se2Inverse(ga->second), ca);
            cb = se2Compose(se2Inverse(gb->second), cb);
        }
        const SE2 jump = se2Compose(se2Inverse(ca), cb);
        metrics.correctionJumpMax = std::max(
            metrics.correctionJumpMax, std::hypot(jump.x, jump.y));
        metrics.correctionYawJumpMax = std::max(
            metrics.correctionYawJumpMax, std::fabs(normalizeAngle(jump.yaw)));
    }
    return metrics;
}

/// Global-anchor gate (§6.4/§12.2/§14.3). A PASS additionally requires
/// enough APPLIED absolute priors anchoring the publish component, no
/// conflicting prior clusters, and bounded translation AND yaw
/// residuals (§11.1/§11.2).
MSFactorGraphDisposition decideDisposition(
    const QualityMetrics & metrics,
    const std::string & optimizeError,
    bool optimizerCancelled,
    bool budgetExhausted)
{
    const HealthReport & h = metrics.health;
    if(optimizerCancelled)
    {
        return MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL;
    }
    if(budgetExhausted)
    {
        return MS_FACTOR_GRAPH_RESOURCE_REQUIRED;
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
    if(h.nodeCount == 0)
    {
        return MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL;
    }
    const double isolatedRatio = h.nodeCount > 0
        ? static_cast<double>(h.isolatedNodes) / static_cast<double>(h.nodeCount) : 1.0;
    // Dominance instead of a raw component cap (§12.2): small tracking-
    // lost fragments are legitimate; a graph with no dominant component
    // is not publishable.
    const double dominantRatio = h.nodeCount > 0
        ? static_cast<double>(h.largestComponent) / static_cast<double>(h.nodeCount) : 0.0;
    if(isolatedRatio > 0.15 || dominantRatio < 0.5)
    {
        return MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL;
    }
    // §6.5 count contract: only APPLIED priors (factors actually built
    // from valid evidence) count — never raw input counts.
    const int64_t appliedPriors = metrics.factorAudit.priorCount;
    const int64_t appliedUniqueNodes = metrics.factorAudit.appliedUniquePriorNodes;
    if(appliedPriors < kMinimumAppliedPriors || appliedUniqueNodes < kMinimumAppliedPriors ||
       metrics.anchoredComponents < 1)
    {
        return MS_FACTOR_GRAPH_LOCAL_FRAME_ONLY;
    }
    if(metrics.factorAudit.priorConflicts > 0)
    {
        return MS_FACTOR_GRAPH_RECOVERABLE_FAIL;
    }
    // Frozen damage gates (§11.5): reciprocal inconsistency, void links,
    // cross-map links and solver sanity downgrade the run; a non-finite
    // solver error is never publishable.
    if(h.linkCount > 0)
    {
        const double reciprocalRatio =
            static_cast<double>(h.reciprocalInconsistent) / static_cast<double>(h.linkCount);
        const double voidRatio =
            static_cast<double>(h.voidLinks) / static_cast<double>(h.linkCount);
        if(reciprocalRatio > 0.05 || voidRatio > 0.20 || h.crossMapLinks > 0)
        {
            return MS_FACTOR_GRAPH_RECOVERABLE_FAIL;
        }
    }
    if(metrics.solver.available &&
       metrics.solver.iterations > 0 &&
       !std::isfinite(metrics.solver.finalError))
    {
        return MS_FACTOR_GRAPH_RECOVERABLE_FAIL;
    }
    const double loopP95 = percentile(metrics.loopResiduals, 0.95);
    const double loopYawP95 = percentile(metrics.loopYawResiduals, 0.95);
    const double priorP95 = percentile(metrics.priorResiduals, 0.95);
    const double priorYawP95 = percentile(metrics.priorYawResiduals, 0.95);
    const double correctionP95 = percentile(metrics.corrections, 0.95);
    const double correctionYawP95 = percentile(metrics.correctionYaws, 0.95);
    const double chi2PerDof = metrics.dof > 0 ? metrics.chi2 / static_cast<double>(metrics.dof) : 0.0;
    // Publish-component coverage (§6.4/§14.3): almost every node must sit
    // in a component anchored by accepted prior-map constraints. The
    // ratio is recomputed AFTER reconstruction (§11.3).
    const double publishRatio = h.nodeCount > 0
        ? static_cast<double>(metrics.publishNodes) / static_cast<double>(h.nodeCount) : 0.0;
    const bool pass =
        h.componentCount >= 1 &&
        publishRatio >= kPublishRatioMin &&
        priorP95 <= kPriorTranslationP95M &&
        percentile(metrics.priorResiduals, 1.0) <= kPriorTranslationMaxM &&
        priorYawP95 <= kPriorYawP95Rad &&
        percentile(metrics.priorYawResiduals, 1.0) <= kPriorYawMaxRad &&
        loopP95 <= kLoopTranslationP95M &&
        percentile(metrics.loopResiduals, 1.0) <= kLoopTranslationMaxM &&
        loopYawP95 <= kLoopYawP95Rad &&
        percentile(metrics.loopYawResiduals, 1.0) <= kLoopYawMaxRad &&
        correctionP95 <= kCorrectionTranslationP95M &&
        percentile(metrics.corrections, 1.0) <= kCorrectionTranslationMaxM &&
        correctionYawP95 <= kCorrectionYawP95Rad &&
        percentile(metrics.correctionYaws, 1.0) <= kCorrectionYawMaxRad &&
        metrics.correctionJumpMax <= kCorrectionJumpMaxM &&
        metrics.correctionYawJumpMax <= kCorrectionYawJumpMaxRad &&
        chi2PerDof <= kChi2PerDofMax &&
        metrics.residualThresholdRatio <= kResidualThresholdRatioMax &&
        metrics.yawThresholdRatio <= kResidualThresholdRatioMax &&
        metrics.solver.iterations > 0;
    return pass ? MS_FACTOR_GRAPH_PASS : MS_FACTOR_GRAPH_RECOVERABLE_FAIL;
}

// MARK: - Streaming escaped JSON builder (§14.4) ----------------------------------

std::string jsonEscape(const std::string & text)
{
    std::string out;
    out.reserve(text.size() + 8);
    for(char c : text)
    {
        switch(c)
        {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if(static_cast<unsigned char>(c) < 0x20)
            {
                char buf[8];
                snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(c));
                out += buf;
            }
            else
            {
                out += c;
            }
        }
    }
    return out;
}

/// NaN / ±inf cannot be emitted as bare JSON numbers; serialize them
/// as null (V1R5 H-17: initial_error / relative_improvement are NaN
/// until the first chunk reports).
std::string jsonNum(double value)
{
    if(!std::isfinite(value)) return "null";
    std::ostringstream os;
    os.precision(9);
    os << value;
    return os.str();
}

std::string residualTriple(const std::vector<double> & values)
{
    std::ostringstream os;
    os << "{\"count\": " << values.size()
       << ", \"p50\": " << percentile(values, 0.5)
       << ", \"p95\": " << percentile(values, 0.95)
       << ", \"max\": " << percentile(values, 1.0) << "}";
    return os.str();
}

std::string qualityJSON(
    const QualityMetrics & m,
    MSFactorGraphDisposition disposition,
    const std::string & path,
    const std::string & graphInputSha,
    int64_t absolutePriorCount,
    const char * priorMapId,
    const char * priorMapSha,
    const char * trackingSessionId,
    int32_t projectionPolicyVersion)
{
    const char * dispositionName = "PASS";
    switch(disposition)
    {
    case MS_FACTOR_GRAPH_RECOVERABLE_FAIL: dispositionName = "RECOVERABLE_FAIL"; break;
    case MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL: dispositionName = "NON_RECOVERABLE_FAIL"; break;
    case MS_FACTOR_GRAPH_RESOURCE_REQUIRED: dispositionName = "RESOURCE_REQUIRED"; break;
    case MS_FACTOR_GRAPH_LOCAL_FRAME_ONLY: dispositionName = "LOCAL_FRAME_ONLY"; break;
    default: break;
    }
    std::ostringstream os;
    os.precision(9);
    os << "{\"format\": \"MarketScannerGraphQuality\", \"version\": 2, "
       << "\"policy_version\": \"" << MS_QUALITY_POLICY_VERSION << "\", "
       << "\"abi_version\": " << MS_FACTOR_GRAPH_ABI_VERSION << ", "
       << "\"path\": \"" << jsonEscape(path) << "\", "
       << "\"disposition\": \"" << dispositionName << "\", "
       << "\"graph_input_sha256\": \"" << jsonEscape(graphInputSha) << "\", "
       << "\"factor_set_sha256\": \"" << jsonEscape(m.factorAudit.factorSetSha256) << "\", "
       << "\"projection_policy_version\": " << projectionPolicyVersion << ", "
       << "\"prior_map_id\": \"" << jsonEscape(priorMapId ? priorMapId : "") << "\", "
       << "\"prior_map_sha256\": \"" << jsonEscape(priorMapSha ? priorMapSha : "") << "\", "
       << "\"tracking_session_id\": \"" << jsonEscape(trackingSessionId ? trackingSessionId : "") << "\", "
       << "\"absolute_prior_count\": " << absolutePriorCount << ", "
       << "\"parsed_valid_prior_count\": " << absolutePriorCount << ", "
       << "\"applied_prior_factor_count\": " << m.factorAudit.priorCount << ", "
       << "\"unique_prior_node_count\": " << m.factorAudit.appliedUniquePriorNodes << ", "
       << "\"applied_prior_count\": " << m.factorAudit.priorCount << ", "
       << "\"rejected_priors\": " << m.factorAudit.rejectedPriors << ", "
       << "\"fused_prior_duplicates\": " << m.factorAudit.fusedPriorDuplicates << ", "
       << "\"prior_conflicts\": " << m.factorAudit.priorConflicts << ", "
       << "\"component_count\": " << m.health.componentCount << ", "
       << "\"total_components\": " << m.totalComponents << ", "
       << "\"anchored_components\": " << m.anchoredComponents << ", "
       << "\"publish_nodes\": " << m.publishNodes << ", "
       << "\"publish_ratio\": " << (m.health.nodeCount > 0
              ? static_cast<double>(m.publishNodes) / static_cast<double>(m.health.nodeCount) : 0.0) << ", "
       << "\"anchored_ratio\": " << m.anchoredRatio << ", "
       << "\"isolated_count\": " << m.health.isolatedNodes << ", "
       << "\"cross_floor_link_count\": " << m.health.crossMapLinks << ", "
       << "\"gap_segments\": " << m.factorAudit.gapSegments << ", "
       << "\"aggregated_chains\": " << m.factorAudit.aggregatedChains << ", "
       << "\"reciprocal_inconsistent\": " << m.health.reciprocalInconsistent << ", "
       << "\"weighted_chi2\": " << m.chi2 << ", "
       << "\"dof\": " << m.dof << ", "
       << "\"chi2_per_dof\": " << (m.dof > 0 ? m.chi2 / (double)m.dof : 0.0) << ", "
       << "\"residual_by_kind\": {\"odometry\": " << residualTriple(m.odometryResiduals)
       << ", \"loop\": " << residualTriple(m.loopResiduals)
       << ", \"prior\": " << residualTriple(m.priorResiduals)
       << ", \"recovery\": " << residualTriple(m.recoveryResiduals) << "}, "
       << "\"yaw_residual_by_kind\": {\"odometry\": " << residualTriple(m.odometryYawResiduals)
       << ", \"loop\": " << residualTriple(m.loopYawResiduals)
       << ", \"prior\": " << residualTriple(m.priorYawResiduals)
       << ", \"recovery\": " << residualTriple(m.recoveryYawResiduals) << "}, "
       << "\"residual_threshold_ratio\": " << m.residualThresholdRatio << ", "
       << "\"yaw_threshold_ratio\": " << m.yawThresholdRatio << ", "
       << "\"info_policy\": {\"regularized\": " << m.health.regularizedInfos
       << ", \"rejected\": " << m.health.rejectedInfos << "}, "
       << "\"correction\": {\"median\": " << percentile(m.corrections, 0.5)
       << ", \"p95\": " << percentile(m.corrections, 0.95)
       << ", \"max\": " << percentile(m.corrections, 1.0)
       << ", \"max_jump\": " << m.correctionJumpMax
       << ", \"yaw_median\": " << percentile(m.correctionYaws, 0.5)
       << ", \"yaw_p95\": " << percentile(m.correctionYaws, 0.95)
       << ", \"yaw_max\": " << percentile(m.correctionYaws, 1.0)
       << ", \"yaw_max_jump\": " << m.correctionYawJumpMax << "}, "
       << "\"coverage\": " << m.coverage << ", "
       << "\"optimizer_error\": \"" << jsonEscape(m.optimizerError) << "\", "
       << "\"solver\": {\"strategy\": \"g2o_robust\", \"iterations\": " << m.solver.iterations
       << ", \"final_error\": " << m.solver.finalError
       // V1R5 H-17: convergence provenance.
       << ", \"converged\": " << (m.solver.converged ? "true" : "false")
       << ", \"stopped_reason\": \"" << jsonEscape(m.solver.stoppedReason) << "\""
       << ", \"initial_error\": " << jsonNum(m.solver.initialError)
       << ", \"relative_improvement\": " << jsonNum(m.solver.relativeImprovement)
       << ", \"wall_seconds\": " << m.wallSeconds
       << ", \"chunks\": " << m.solver.chunks
       << ", \"skeleton_nodes\": " << m.skeletonNodes
       << ", \"factor_count\": " << m.skeletonFactors
       << ", \"available\": " << (m.solver.available ? "true" : "false") << "}, "
       // V1R5 §8.4/§10.3: one gauge diagnostic per component.
       << "\"gauge_by_component\": [";
    for(size_t gi = 0; gi < m.gaugeDiagnostics.size(); ++gi)
    {
        if(gi > 0) os << ", ";
        const GaugeDiagnostics & g = m.gaugeDiagnostics[gi];
        os << "{\"component_id\": " << g.componentId
           << ", \"gauge_candidate_count\": " << g.candidateCount
           << ", \"gauge_inlier_count\": " << g.inlierCount
           << ", \"gauge_outlier_count\": " << g.outlierCount
           << ", \"gauge_consensus_ratio\": " << g.consensusRatio
           << ", \"gauge_second_cluster_ratio\": " << g.secondClusterRatio
           << ", \"gauge_translation_spread_m\": " << g.translationSpreadM
           << ", \"gauge_yaw_spread_rad\": " << g.yawSpreadRad
           << ", \"gauge_anchored\": " << (g.anchored ? "true" : "false")
           << ", \"gauge_reject_reason\": \"" << jsonEscape(g.rejectReason) << "\"}";
    }
    os << "]";
    os << ", "
       << "\"health\": {\"node_count\": " << m.health.nodeCount
       << ", \"link_count\": " << m.health.linkCount
       << ", \"malformed_links\": " << m.health.malformedLinks
       << ", \"void_links\": " << m.health.voidLinks
       << ", \"ignored_optional_links\": " << m.health.ignoredOptionalLinks
       << ", \"loop_links\": " << m.health.loopLinks
       << ", \"prior_links\": " << m.health.priorLinks
       << ", \"recovery_links\": " << m.health.recoveryLinks << "}}";
    return os.str();
}

// MARK: - FullTrajectoryReconstructor (§15) --------------------------------------

struct ReconstructedRow
{
    int64_t id = 0;
    double stamp = 0.0;
    SE2 pose;
    int32_t mapId = 0;
    int64_t componentId = -1;
    bool publishEligible = false;
    bool hasCorrection = false;
    double uncertaintyM = std::numeric_limits<double>::quiet_NaN();
};

struct ReconstructedTrajectory
{
    std::vector<ReconstructedRow> rows;
    int64_t recoveredTagNodes = 0;
};

/// Applies skeleton corrections to EVERY raw node WITHOUT crossing
/// components, neighbor gaps or map transitions (§15.1/§15.2):
///   C_a = Topt_a * inv(Traw_a); C_b = Topt_b * inv(Traw_b)
///   C_i = interpolate(C_a, C_b, alpha); Tfinal_i = C_i * Traw_i
/// Uncertainty (§15.3) blends anchor distance with the graph residual
/// scale; it is NaN when it cannot be estimated — never fabricated as 0.
ReconstructedTrajectory reconstructTrajectory(
    const GraphModel & model,
    const std::vector<size_t> & skeleton,
    const OptimizedGraph & optimized,
    const std::set<int64_t> & tagNodes,
    const std::map<int64_t, int64_t> & nodeComponent,
    const std::set<int64_t> & anchoredComponents,
    const QualityMetrics & metrics)
{
    ReconstructedTrajectory out;
    out.rows.reserve(model.nodes.size());

    // Neighbor adjacency for gap detection.
    std::set<std::pair<int64_t, int64_t> > neighborPairs;
    for(const RawLink & link : model.links)
    {
        if(link.type != rtabmap::Link::kNeighbor) continue;
        neighborPairs.insert(std::make_pair(
            std::min(link.from, link.to), std::max(link.from, link.to)));
    }

    // Prefix count of chain breaks (§10.1 complexity): breakPrefix[i+1]
    // counts topology breaks among node pairs (k, k+1) with k < i+1, so
    // "is the path between anchor a and node i continuous" is an O(1)
    // range query instead of an O(N) walk per node (was O(N²)).
    std::vector<int64_t> breakPrefix(model.nodes.size() + 1, 0);
    for(size_t i = 0; i < model.nodes.size(); ++i)
    {
        breakPrefix[i + 1] = breakPrefix[i];
        if(i + 1 < model.nodes.size())
        {
            const RawNode & p = model.nodes[i];
            const RawNode & q = model.nodes[i + 1];
            const bool connected = p.mapId == q.mapId &&
                neighborPairs.count(std::make_pair(
                    std::min(p.id, q.id), std::max(p.id, q.id))) > 0;
            if(!connected) ++breakPrefix[i + 1];
        }
    }

    // Skeleton anchors (correction) in topology order.
    std::vector<std::pair<size_t, SE2> > anchors;
    for(size_t s = 0; s < skeleton.size(); ++s)
    {
        const size_t idx = skeleton[s];
        const RawNode & raw = model.nodes[idx];
        std::map<int64_t, SE2>::const_iterator it = optimized.poses.find(raw.id);
        if(it == optimized.poses.end()) continue;
        anchors.push_back(std::make_pair(idx, se2Compose(it->second, se2Inverse(raw.pose))));
    }

    const double residualScale = std::max(
        0.02, percentile(metrics.loopResiduals, 0.95));

    size_t a = 0;
    for(size_t i = 0; i < model.nodes.size(); ++i)
    {
        const RawNode & raw = model.nodes[i];
        ReconstructedRow row;
        row.id = raw.id;
        row.stamp = raw.stamp;
        row.mapId = raw.mapId;
        std::map<int64_t, int64_t>::const_iterator comp = nodeComponent.find(raw.id);
        if(comp != nodeComponent.end())
        {
            row.componentId = comp->second;
            row.publishEligible = anchoredComponents.count(comp->second) > 0;
        }

        // Advance the anchor window; segment boundaries reset at
        // component changes, map transitions and neighbor gaps.
        while(a + 1 < anchors.size() && anchors[a + 1].first <= i) ++a;
        bool sameSegment = anchors.size() > 0;
        if(anchors.size() > 0)
        {
            const size_t anchorIdx = anchors[std::min(a, anchors.size() - 1)].first;
            if(model.nodes[anchorIdx].mapId != raw.mapId) sameSegment = false;
            if(a + 1 < anchors.size() && i > anchors[a].first)
            {
                // O(1) continuity query over the precomputed break prefix.
                if(breakPrefix[i] - breakPrefix[anchors[a].first + 1] != 0)
                {
                    sameSegment = false;
                }
            }
        }

        SE2 correction;
        bool hasCorrection = false;
        if(sameSegment && anchors.size() > 0)
        {
            if(i <= anchors.front().first || anchors.size() == 1 || a + 1 >= anchors.size())
            {
                correction = anchors[std::min(a, anchors.size() - 1)].second;
                hasCorrection = true;
            }
            else
            {
                const std::pair<size_t, SE2> & ca = anchors[a];
                const std::pair<size_t, SE2> & cb = anchors[a + 1];
                const double span = model.nodes[cb.first].stamp - model.nodes[ca.first].stamp;
                const double alpha = span > 1.0e-9
                    ? (raw.stamp - model.nodes[ca.first].stamp) / span : 0.0;
                correction = se2Interpolate(ca.second, cb.second, alpha);
                hasCorrection = true;
            }
        }

        if(hasCorrection)
        {
            row.pose = se2Compose(correction, raw.pose);
            row.hasCorrection = true;
            // Uncertainty: residual scale grows with distance from the
            // nearest anchor (§15.3 heuristic, documented). Nodes and
            // anchors are both in topology order, so the geometrically
            // nearest anchor lies within a small index window around the
            // correction anchor `a`; search only that window to keep the
            // reconstruction O(N) instead of O(N*S) on full graphs.
            double anchorDist = std::numeric_limits<double>::infinity();
            const size_t kWindow = 2;
            const size_t lo = a > kWindow ? a - kWindow : 0;
            const size_t hi = std::min(anchors.size() - 1, a + kWindow);
            for(size_t s = lo; s <= hi; ++s)
            {
                const RawNode & an = model.nodes[anchors[s].first];
                anchorDist = std::min(anchorDist,
                    std::hypot(raw.pose.x - an.pose.x, raw.pose.y - an.pose.y));
            }
            row.uncertaintyM = std::isfinite(anchorDist)
                ? residualScale * (1.0 + anchorDist) : std::numeric_limits<double>::quiet_NaN();
        }
        else
        {
            // No valid correction segment: keep the raw pose, mark not
            // publishable and leave uncertainty NaN (§15.3).
            row.pose = raw.pose;
            row.publishEligible = false;
            row.uncertaintyM = std::numeric_limits<double>::quiet_NaN();
        }

        if(tagNodes.count(raw.id) && row.hasCorrection && row.publishEligible &&
           std::isfinite(row.uncertaintyM))
        {
            // §11.4: a tag node is only "recovered" with a map-frame
            // correction, publish eligibility and usable uncertainty.
            ++out.recoveredTagNodes;
        }
        out.rows.push_back(row);
    }
    return out;
}

// MARK: - Runner ------------------------------------------------------------------

struct RunOptions
{
    bool fullGraph = false;
    int64_t maxNodes = 0;
    double maxWallSeconds = 0.0;
    int fastIterations = 100;
    int fullGraphIterations = 300;
};

MSFactorGraphOutcomeC makeErrorOutcome(const std::string & message, MSFactorGraphDisposition disposition)
{
    MSFactorGraphOutcomeC outcome;
    std::memset(&outcome, 0, sizeof(outcome));
    outcome.disposition = disposition;
    outcome.error = const_cast<char *>(strdup(message.c_str()));
    if(!outcome.error)
    {
        // H-06: OOM while materializing the error string itself must not
        // be lost — surface RESOURCE_REQUIRED so the caller can retry
        // instead of misreading a silent success.
        outcome.disposition = MS_FACTOR_GRAPH_RESOURCE_REQUIRED;
    }
    return outcome;
}

MSFactorGraphOutcomeC runPipeline(const MSFactorGraphRequestC * request, const RunOptions & options)
{
    MSFactorGraphOutcomeC outcome;
    std::memset(&outcome, 0, sizeof(outcome));
    const auto runStart = std::chrono::steady_clock::now();
    const double maxWall = options.maxWallSeconds > 0.0
        ? options.maxWallSeconds : (options.fullGraph ? 1800.0 : 600.0);

    if(!request || !request->db_path)
    {
        return makeErrorOutcome("request or db_path is NULL", MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }

    // 1. Real graph health check on the snapshot DB.
    GraphModel model;
    std::string readError;
    if(!readGraph(request->db_path, model, readError))
    {
        return makeErrorOutcome("graph read failed: " + readError, MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }
    std::string topologyError;
    if(!buildTopologyOrder(model, topologyError))
    {
        return makeErrorOutcome("topology order failed: " + topologyError, MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }
    HealthReport health;
    std::string healthError;
    if(!inspectHealth(model, health, healthError))
    {
        return makeErrorOutcome("health inspection failed: " + healthError, MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }

    const int64_t maxNodes = options.maxNodes > 0 ? options.maxNodes : 150000;
    if(health.nodeCount > maxNodes)
    {
        return makeErrorOutcome("node count exceeds the resource budget", MS_FACTOR_GRAPH_RESOURCE_REQUIRED);
    }

    // §11.4: the reducer keeps tag nodes AND prior nodes mandatory, but
    // tag RECOVERY statistics count ONLY tag-bound nodes.
    std::set<int64_t> tagNodes;
    std::set<int64_t> mandatoryNodes;
    for(int64_t i = 0; request->tag_node_ids && i < request->tag_node_count; ++i)
    {
        mandatoryNodes.insert(request->tag_node_ids[i]);
        tagNodes.insert(request->tag_node_ids[i]);
    }

    // Accepted absolute priors (§6).
    std::vector<AbsolutePrior> priors;
    for(int64_t i = 0; request->absolute_priors && i < request->absolute_prior_count; ++i)
    {
        const MSAbsolutePriorC & src = request->absolute_priors[i];
        if(!std::isfinite(src.map_x) || !std::isfinite(src.map_y) || !std::isfinite(src.map_yaw))
        {
            continue; // non-finite evidence is rejected, never applied
        }
        AbsolutePrior prior;
        prior.nodeId = src.node_id;
        prior.mapPose.x = src.map_x;
        prior.mapPose.y = src.map_y;
        prior.mapPose.yaw = src.map_yaw;
        std::memcpy(prior.information, src.information_3x3, sizeof(Mat3));
        prior.kind = src.kind;
        prior.episodeId = src.episode_id;
        priors.push_back(prior);
        mandatoryNodes.insert(src.node_id);
    }

    if(request->progress) request->progress(0.2, request->progress_user);
    if(request->cancel && request->cancel(request->cancel_user))
    {
        return makeErrorOutcome("cancelled", MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }

    // 2. Skeleton (Fast) or full graph (full-graph optimization).
    std::vector<size_t> skeleton;
    if(options.fullGraph)
    {
        skeleton.reserve(model.nodes.size());
        for(size_t i = 0; i < model.nodes.size(); ++i) skeleton.push_back(i);
    }
    else
    {
        ReducerPolicy policy;
        skeleton = reduceGraph(model, mandatoryNodes, policy);
    }

    // 3. Factors + robust native optimization.
    std::vector<FactorRecord> factors;
    FactorSetAudit factorAudit;
    std::string factorError;
    if(!buildSkeletonFactors(model, skeleton, priors, factorAudit, factors, factorError))
    {
        return makeErrorOutcome("factor construction failed: " + factorError, MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }
    if(request->progress) request->progress(0.4, request->progress_user);

    OptimizedGraph optimized;
    std::string optimizeError;
    std::set<int64_t> gaugeFailedPriorNodes;
    std::map<int64_t, SE2> componentGauge;
    // V1R5 §8.4/§10.3: per-component robust gauge diagnostics.
    std::vector<GaugeDiagnostics> gaugeDiagnostics;
    const int iterations = options.fullGraph
        ? (request->deep_iterations > 0 ? request->deep_iterations : options.fullGraphIterations)
        : (request->fast_iterations > 0 ? request->fast_iterations : options.fastIterations);
    optimizeSkeleton(
        model, factors, iterations, maxWall,
        request->cancel, request->cancel_user,
        optimized, gaugeFailedPriorNodes, componentGauge, gaugeDiagnostics, optimizeError);
    if(request->progress) request->progress(0.7, request->progress_user);

    // Node -> component mapping (§15.2). Union-find over the skeleton
    // factors gives the skeleton components; every raw node between two
    // CONNECTED skeleton anchors inherits that segment's component, and
    // nodes inside broken segments (gaps/map transitions/disconnected
    // anchors) get their own fragment components that are never publish
    // eligible unless a prior anchors them.
    std::map<int64_t, int64_t> nodeComponent;
    std::set<int64_t> anchoredComponents;
    std::map<int64_t, SE2> nodeGauge;
    {
        std::map<int64_t, int64_t> parent;
        std::function<int64_t(int64_t)> find = [&](int64_t v) {
            int64_t r = v;
            while(parent[r] != r) r = parent[r];
            while(parent[v] != r) { int64_t next = parent[v]; parent[v] = r; v = next; }
            return r;
        };
        for(size_t s = 0; s < skeleton.size(); ++s)
        {
            const int64_t id = model.nodes[skeleton[s]].id;
            parent[id] = id;
        }
        for(const FactorRecord & factor : factors)
        {
            if(factor.type == rtabmap::Link::kPosePrior) continue;
            if(!parent.count(factor.from) || !parent.count(factor.to)) continue;
            const int64_t rf = find(factor.from);
            const int64_t rt = find(factor.to);
            if(rf != rt) parent[rf] = rt;
        }
        // Component ids for skeleton roots.
        std::map<int64_t, int64_t> rootToComponent;
        int64_t nextComponent = 0;
        std::vector<int64_t> skeletonComponent(skeleton.size(), -1);
        for(size_t s = 0; s < skeleton.size(); ++s)
        {
            const int64_t root = find(model.nodes[skeleton[s]].id);
            if(!rootToComponent.count(root))
            {
                rootToComponent[root] = nextComponent++;
            }
            skeletonComponent[s] = rootToComponent[root];
        }
        // Walk topology order and assign every raw node.
        int64_t activeComponent = -1;
        bool segmentConnected = false;
        size_t sIdx = 0;
        for(size_t i = 0; i < model.nodes.size(); ++i)
        {
            if(sIdx < skeleton.size() && skeleton[sIdx] == i)
            {
                const int64_t comp = skeletonComponent[sIdx];
                if(sIdx + 1 < skeleton.size())
                {
                    segmentConnected =
                        skeletonComponent[sIdx + 1] == comp;
                }
                activeComponent = comp;
                nodeComponent[model.nodes[i].id] = comp;
                ++sIdx;
            }
            else if(activeComponent >= 0 && segmentConnected)
            {
                nodeComponent[model.nodes[i].id] = activeComponent;
            }
            else
            {
                // Broken segment / before-first / after-last: fragment
                // component (never anchored by construction).
                nodeComponent[model.nodes[i].id] = nextComponent++;
            }
        }
        // Anchored components: those containing an applied prior node
        // whose map-frame gauge was ESTIMATED (§6.4). V1R5 fail-closed
        // (§8.4/H-18): a component whose robust gauge failed its gates
        // (or whose candidates were non-finite) lands in
        // gaugeFailedPriorNodes and is NOT anchored here, so its rows
        // are never publish eligible.
        std::map<int64_t, int64_t> priorComponentOfNode;
        for(size_t s = 0; s < skeleton.size(); ++s)
        {
            priorComponentOfNode[model.nodes[skeleton[s]].id] = skeletonComponent[s];
        }
        for(size_t i = 0; i < priors.size(); ++i)
        {
            if(gaugeFailedPriorNodes.count(priors[i].nodeId)) continue;
            std::map<int64_t, int64_t>::const_iterator c =
                priorComponentOfNode.find(priors[i].nodeId);
            if(c != priorComponentOfNode.end())
            {
                anchoredComponents.insert(c->second);
            }
        }
        // Per-skeleton-node gauge mapping (§6.4): quality deformation
        // metrics factor out the component's map-frame gauge.
        for(size_t s = 0; s < skeleton.size(); ++s)
        {
            const int64_t id = model.nodes[skeleton[s]].id;
            std::map<int64_t, SE2>::const_iterator g = componentGauge.find(find(id));
            if(g != componentGauge.end())
            {
                nodeGauge[id] = g->second;
            }
        }
    }

    // 4. Full trajectory reconstruction (§15) runs BEFORE the publish
    // coverage recompute (§11.3): publishRatio/coverage reflect the
    // FINAL rows, never a pre-reconstruction estimate.
    const double runWall = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - runStart).count();
    QualityMetrics metrics = evaluateQuality(
        model, factors, optimized, skeleton, health, factorAudit, runWall, 0.0,
        nodeGauge, gaugeDiagnostics);
    metrics.optimizerError = optimizeError;

    ReconstructedTrajectory trajectory;
    if(optimizeError.empty() || optimizeError.find("budget") != std::string::npos)
    {
        trajectory = reconstructTrajectory(
            model, skeleton, optimized, tagNodes,
            nodeComponent, anchoredComponents, metrics);
    }

    // Recompute publish coverage from the reconstructed rows (§11.3).
    {
        std::set<int64_t> comps;
        for(std::map<int64_t, int64_t>::const_iterator it = nodeComponent.begin();
            it != nodeComponent.end(); ++it) comps.insert(it->second);
        metrics.totalComponents = static_cast<int64_t>(comps.size());
        metrics.anchoredComponents = static_cast<int64_t>(anchoredComponents.size());
        int64_t publishNodes = 0;
        for(size_t r = 0; r < trajectory.rows.size(); ++r)
        {
            if(trajectory.rows[r].publishEligible) ++publishNodes;
        }
        metrics.publishNodes = publishNodes;
        metrics.coverage = trajectory.rows.empty() ? 0.0
            : static_cast<double>(publishNodes) / static_cast<double>(trajectory.rows.size());
    }

    MSFactorGraphDisposition disposition = decideDisposition(
        metrics, optimizeError,
        optimized.diagnostics.cancelled, optimized.diagnostics.budgetExhausted);
    if(runWall > maxWall && disposition == MS_FACTOR_GRAPH_PASS)
    {
        disposition = MS_FACTOR_GRAPH_RESOURCE_REQUIRED;
    }
    if(trajectory.rows.empty() && optimizeError.empty() && !model.nodes.empty())
    {
        // Reconstruction was skipped without a budget reason: fail closed.
        disposition = MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL;
    }
    if(trajectory.recoveredTagNodes < static_cast<int64_t>(tagNodes.size()) &&
       disposition == MS_FACTOR_GRAPH_PASS)
    {
        // §11.4: unrecovered tag nodes must surface as RESCAN via the
        // pipeline, never a silent PASS.
        disposition = MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL;
    }

    // Fill the outcome.
    outcome.disposition = disposition;
    outcome.quality_json = const_cast<char *>(strdup(qualityJSON(
        metrics, disposition,
        options.fullGraph ? "full_graph_optimization" : "fast",
        model.graphInputSha256,
        static_cast<int64_t>(priors.size()),
        request->prior_map_id, request->prior_map_sha256,
        request->tracking_session_id,
        request->projection_policy_version).c_str()));
    if(!outcome.quality_json)
    {
        // H-06: OOM on diagnostics must still be observable as
        // RESOURCE_REQUIRED, never a silent PASS with a NULL payload.
        outcome.disposition = MS_FACTOR_GRAPH_RESOURCE_REQUIRED;
        goto outcome_alloc_failed;
    }
    outcome.count = static_cast<int64_t>(trajectory.rows.size());
    if(outcome.count > 0)
    {
        outcome.rows = static_cast<MSTrajectoryRowC *>(
            malloc(static_cast<size_t>(outcome.count) * sizeof(MSTrajectoryRowC)));
        if(!outcome.rows)
        {
            outcome.disposition = MS_FACTOR_GRAPH_RESOURCE_REQUIRED;
            outcome.count = 0;
            goto outcome_alloc_failed;
        }
        for(int64_t i = 0; i < outcome.count; ++i)
        {
            const ReconstructedRow & src = trajectory.rows[i];
            MSTrajectoryRowC & dst = outcome.rows[i];
            dst.id = src.id;
            dst.stamp = src.stamp;
            dst.x = src.pose.x;
            dst.y = src.pose.y;
            dst.yaw = src.pose.yaw;
            dst.map_id = src.mapId;
            dst.component_id = src.componentId;
            dst.publish_eligible = src.publishEligible ? 1 : 0;
            dst.uncertainty_m = src.uncertaintyM;
        }
    }
    outcome.skeleton_count = static_cast<int64_t>(skeleton.size());
    if(outcome.skeleton_count > 0)
    {
        outcome.skeleton_ids = static_cast<int64_t *>(malloc(static_cast<size_t>(outcome.skeleton_count) * sizeof(int64_t)));
        outcome.skeleton_x = static_cast<double *>(malloc(static_cast<size_t>(outcome.skeleton_count) * sizeof(double)));
        outcome.skeleton_y = static_cast<double *>(malloc(static_cast<size_t>(outcome.skeleton_count) * sizeof(double)));
        outcome.skeleton_yaw = static_cast<double *>(malloc(static_cast<size_t>(outcome.skeleton_count) * sizeof(double)));
        if(!outcome.skeleton_ids || !outcome.skeleton_x || !outcome.skeleton_y || !outcome.skeleton_yaw)
        {
            // H-06: any partial skeleton allocation failure is reported
            // as RESOURCE_REQUIRED; MSFactorGraphFree frees NULLs safely.
            outcome.disposition = MS_FACTOR_GRAPH_RESOURCE_REQUIRED;
            outcome.skeleton_count = 0;
            goto outcome_alloc_failed;
        }
        int64_t k = 0;
        for(size_t s = 0; s < skeleton.size(); ++s)
        {
            const RawNode & raw = model.nodes[skeleton[s]];
            std::map<int64_t, SE2>::const_iterator it = optimized.poses.find(raw.id);
            const SE2 pose = it != optimized.poses.end() ? it->second : raw.pose;
            outcome.skeleton_ids[k] = raw.id;
            outcome.skeleton_x[k] = pose.x;
            outcome.skeleton_y[k] = pose.y;
            outcome.skeleton_yaw[k] = pose.yaw;
            ++k;
        }
    }
outcome_alloc_failed:
    if(request->progress) request->progress(1.0, request->progress_user);
    return outcome;
}

} // namespace

// MARK: - C ABI -------------------------------------------------------------------

extern "C" MSFactorGraphOutcomeC MSFactorGraphRunFast(const MSFactorGraphRequestC * request)
{
    RunOptions options;
    options.fullGraph = false;
    if(request)
    {
        options.maxNodes = request->max_nodes;
        options.maxWallSeconds = request->max_wall_seconds;
    }
    try
    {
        return runPipeline(request, options);
    }
    catch(const std::bad_alloc & e)
    {
        // H-06: allocation failure maps to RESOURCE_REQUIRED.
        return makeErrorOutcome(e.what(), MS_FACTOR_GRAPH_RESOURCE_REQUIRED);
    }
    catch(const std::exception & e)
    {
        return makeErrorOutcome(e.what(), MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }
    catch(...)
    {
        return makeErrorOutcome("unknown native exception", MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }
}

extern "C" MSFactorGraphOutcomeC MSFactorGraphRunFullGraph(const MSFactorGraphRequestC * request)
{
    RunOptions options;
    options.fullGraph = true;
    if(request)
    {
        options.maxNodes = request->max_nodes;
        options.maxWallSeconds = request->max_wall_seconds;
    }
    try
    {
        return runPipeline(request, options);
    }
    catch(const std::bad_alloc & e)
    {
        // H-06: allocation failure maps to RESOURCE_REQUIRED.
        return makeErrorOutcome(e.what(), MS_FACTOR_GRAPH_RESOURCE_REQUIRED);
    }
    catch(const std::exception & e)
    {
        return makeErrorOutcome(e.what(), MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }
    catch(...)
    {
        return makeErrorOutcome("unknown native exception", MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL);
    }
}

extern "C" void MSFactorGraphFree(MSFactorGraphOutcomeC * outcome)
{
    if(!outcome) return;
    free(outcome->rows);
    free(outcome->skeleton_ids);
    free(outcome->skeleton_x);
    free(outcome->skeleton_y);
    free(outcome->skeleton_yaw);
    free(outcome->quality_json);
    free(outcome->error);
    std::memset(outcome, 0, sizeof(*outcome));
}
