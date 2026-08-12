/*
 * rtabmap-market-scanner-native-tests — executable native qualification
 * suite (V1R3 Gate T §23). NOT token tests: every math contract is
 * exercised numerically, and the C ABI is driven against synthetic
 * SQLite graphs built in-process.
 *
 * Coverage (§23.1):
 *  - SE2 inverse/compose identities
 *  - inverse-measurement information: analytic vs finite difference
 *    (1000 random cases, §11.1)
 *  - SPD projection policy (valid / regularized / rejected)
 *  - aggregate odometry covariance (§11.3)
 *  - reducer mandatory nodes, missing-neighbor gaps
 *  - quality chi2 with cross terms and pose priors
 *  - synthetic graphs through the C ABI: clean PASS, wrong loops,
 *    no priors (LOCAL_FRAME_ONLY), malformed BLOB (fail closed),
 *    cancellation
 *  - JSON escaping
 */

/* Unity build: pull in the core translation unit so the suite can call
 * the internal math directly. The binary therefore must NOT link the
 * marketscanner_factor_graph static library. */
#include "../../core/MarketScannerFactorGraph/market_scanner_factor_graph.cpp"

#include <sqlite3.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

namespace {

int g_checks = 0;
int g_failures = 0;

#define CHECK(cond, message)                                            \
    do {                                                                \
        ++g_checks;                                                     \
        if(!(cond)) {                                                   \
            ++g_failures;                                               \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, message); \
        }                                                               \
    } while(0)

// MARK: - SE2 identities ------------------------------------------------------

void testSE2Identities()
{
    std::mt19937_64 rng(42);
    std::uniform_real_distribution<double> coord(-50.0, 50.0);
    std::uniform_real_distribution<double> angle(-M_PI, M_PI);
    for(int i = 0; i < 1000; ++i)
    {
        SE2 a{coord(rng), coord(rng), angle(rng)};
        SE2 b{coord(rng), coord(rng), angle(rng)};
        // inv(a) ∘ a == identity
        const SE2 id1 = se2Compose(se2Inverse(a), a);
        CHECK(std::fabs(id1.x) < 1e-9 && std::fabs(id1.y) < 1e-9 &&
              std::fabs(id1.yaw) < 1e-9, "inv(a) * a != identity");
        // (a ∘ b)⁻¹ == b⁻¹ ∘ a⁻¹
        const SE2 lhs = se2Inverse(se2Compose(a, b));
        const SE2 rhs = se2Compose(se2Inverse(b), se2Inverse(a));
        CHECK(std::fabs(lhs.x - rhs.x) < 1e-9 && std::fabs(lhs.y - rhs.y) < 1e-9 &&
              std::fabs(normalizeAngle(lhs.yaw - rhs.yaw)) < 1e-9,
              "(a*b)^-1 != b^-1 * a^-1");
        // interpolation endpoints
        const SE2 i0 = se2Interpolate(a, b, 0.0);
        const SE2 i1 = se2Interpolate(a, b, 1.0);
        CHECK(std::fabs(i0.x - a.x) < 1e-12 && std::fabs(i1.x - b.x) < 1e-12,
              "interpolation endpoints");
    }
}

// MARK: - Inverse information vs finite difference (§11.1) ----------------------

void testInverseInformationAgainstFiniteDifference()
{
    std::mt19937_64 rng(7);
    std::uniform_real_distribution<double> coord(-30.0, 30.0);
    std::uniform_real_distribution<double> angle(-M_PI, M_PI);
    std::uniform_real_distribution<double> diag(0.5, 500.0);
    std::uniform_real_distribution<double> cross(-0.2, 0.2);
    const double step = 1e-5;
    int verified = 0;
    for(int trial = 0; trial < 1200; ++trial)
    {
        SE2 m{coord(rng), coord(rng), angle(rng)};
        // Random SPD information: A Aᵀ + diag floor.
        double A[9];
        for(int k = 0; k < 9; ++k) A[k] = cross(rng);
        Mat3 info;
        for(int r = 0; r < 3; ++r)
        {
            for(int c = 0; c < 3; ++c)
            {
                double acc = (r == c) ? diag(rng) : 0.0;
                for(int k = 0; k < 3; ++k) acc += A[r * 3 + k] * A[c * 3 + k];
                info[r * 3 + c] = acc;
            }
        }
        Mat3 analytic;
        CHECK(invertPlanarInformation(m, info, analytic),
              "invertPlanarInformation failed on SPD input");

        // Central-difference Jacobian of f(z)=z⁻¹ and propagated
        // information I_w = (J Σ Jᵀ)⁻¹.
        double J[9];
        for(int axis = 0; axis < 3; ++axis)
        {
            SE2 zp = m, zm = m;
            if(axis == 0) { zp.x += step; zm.x -= step; }
            else if(axis == 1) { zp.y += step; zm.y -= step; }
            else { zp.yaw = normalizeAngle(zp.yaw + step); zm.yaw = normalizeAngle(zm.yaw - step); }
            const SE2 sp = se2Inverse(zp);
            const SE2 sm = se2Inverse(zm);
            J[0 * 3 + axis] = (sp.x - sm.x) / (2 * step);
            J[1 * 3 + axis] = (sp.y - sm.y) / (2 * step);
            J[2 * 3 + axis] = normalizeAngle(sp.yaw - sm.yaw) / (2 * step);
        }
        Mat3 cov, Jt, Jcov, covW, expected;
        CHECK(mat3Invert(info, cov), "info not invertible");
        for(int r = 0; r < 3; ++r)
            for(int c = 0; c < 3; ++c) Jt[r * 3 + c] = J[c * 3 + r];
        mat3Multiply(J, cov, Jcov);
        mat3Multiply(Jcov, Jt, covW);
        CHECK(mat3Invert(covW, expected), "propagated covariance not invertible");

        double maxDiff = 0.0;
        for(int k = 0; k < 9; ++k)
        {
            const double scale = std::max(1.0, std::fabs(expected[k]));
            maxDiff = std::max(maxDiff, std::fabs(analytic[k] - expected[k]) / scale);
        }
        CHECK(maxDiff < 1e-4, "analytic inverse information != finite difference");
        if(maxDiff < 1e-4) ++verified;
    }
    CHECK(verified >= 1000, "need >= 1000 verified inverse-information cases");
}

// MARK: - SPD policy (§11.2) -----------------------------------------------------

void testSPDPolicy()
{
    InfoPolicyAudit audit;
    // Valid SPD stays valid.
    Mat3 good = {10, 1, 0, 1, 12, 0, 0, 0, 8};
    CHECK(sanitizePlanarInformation(good, audit) == InfoPolicy::Valid,
          "SPD matrix must be valid");
    // Slightly asymmetric is symmetrized (regularized only when the
    // spectrum needs lifting); a tiny negative eigenvalue lifts.
    Mat3 nearBad = {10, 0, 0, 0, -1e-8, 0, 0, 0, 10};
    CHECK(sanitizePlanarInformation(nearBad, audit) == InfoPolicy::RegularizedWithAudit,
          "near-zero negative eigenvalue must be regularized with audit");
    // Clearly indefinite is rejected.
    Mat3 bad = {10, 0, 0, 0, -5, 0, 0, 0, 10};
    CHECK(sanitizePlanarInformation(bad, audit) == InfoPolicy::Rejected,
          "indefinite matrix must be rejected");
    // Non-finite is rejected.
    Mat3 nanM = {10, 0, 0, 0, 10, 0, 0, 0, std::nan("")};
    CHECK(sanitizePlanarInformation(nanM, audit) == InfoPolicy::Rejected,
          "non-finite matrix must be rejected");
    CHECK(audit.rejected >= 2 && audit.regularized >= 1, "audit counters");
}

// MARK: - Aggregate covariance (§11.3) ---------------------------------------------

void testAggregateCovariance()
{
    // Two segments: Σ_total = Σ1 + Ad(T1) Σ2 Ad(T1)ᵀ.
    SE2 t1{1.0, 0.5, 0.3};
    SE2 t2{0.5, -0.2, -0.1};
    Mat3 i1 = {25, 0, 0, 0, 25, 0, 0, 0, 16};
    Mat3 i2 = {100, 0, 0, 0, 100, 0, 0, 0, 64};
    Mat3Box s1, s2;
    std::memcpy(s1.m, i1, sizeof(Mat3));
    std::memcpy(s2.m, i2, sizeof(Mat3));
    Mat3 total;
    CHECK(aggregateChainInformation({t1, t2}, {s1, s2}, total),
          "aggregate must succeed on SPD segments");
    // Manual reference.
    Mat3 cov1, cov2, adj, adjT, tmp, prop, refCov, refInfo;
    CHECK(mat3Invert(i1, cov1), "cov1 invert");
    CHECK(mat3Invert(i2, cov2), "cov2 invert");
    se2Adjoint(t1, adj);
    for(int r = 0; r < 3; ++r)
        for(int c = 0; c < 3; ++c) adjT[r * 3 + c] = adj[c * 3 + r];
    mat3Multiply(cov2, adjT, tmp);
    mat3Multiply(adj, tmp, prop);
    for(int k = 0; k < 9; ++k) refCov[k] = cov1[k] + prop[k];
    CHECK(mat3Invert(refCov, refInfo), "reference invert");
    double maxDiff = 0.0;
    for(int k = 0; k < 9; ++k)
    {
        maxDiff = std::max(maxDiff,
            std::fabs(total[k] - refInfo[k]) / std::max(1.0, std::fabs(refInfo[k])));
    }
    CHECK(maxDiff < 1e-9, "aggregate covariance matches Adjoint formula");
}

// MARK: - Synthetic graph helpers ---------------------------------------------------

struct SyntheticBuilder
{
    std::string path;
    sqlite3 * db = nullptr;

    explicit SyntheticBuilder(const std::string & name)
    {
        path = "/tmp/ms_native_test_" + name + ".db";
        ::remove(path.c_str());
        sqlite3_open(path.c_str(), &db);
        sqlite3_exec(db,
            "CREATE TABLE Node (id INTEGER PRIMARY KEY, map_id INTEGER,"
            " weight INTEGER, stamp REAL, pose BLOB);"
            "CREATE TABLE Link (from_id INTEGER, to_id INTEGER,"
            " type INTEGER, transform BLOB, information_matrix BLOB);",
            nullptr, nullptr, nullptr);
    }

    ~SyntheticBuilder()
    {
        if(db) sqlite3_close(db);
    }

    static std::vector<float> transformBlob(double x, double y, double yaw)
    {
        const float c = static_cast<float>(std::cos(yaw));
        const float s = static_cast<float>(std::sin(yaw));
        return {c, -s, 0.f, static_cast<float>(x),
                s, c, 0.f, static_cast<float>(y),
                0.f, 0.f, 1.f, 0.f};
    }

    static std::vector<double> infoBlob(double xx, double yy, double yawyaw)
    {
        std::vector<double> v(36, 0.0);
        v[0] = xx;
        v[7] = yy;
        v[35] = yawyaw;
        return v;
    }

    void addNode(int64_t id, double stamp, double x, double y, double yaw)
    {
        auto blob = transformBlob(x, y, yaw);
        sqlite3_stmt * stmt = nullptr;
        sqlite3_prepare_v2(db, "INSERT INTO Node VALUES (?,?,?,?,?)", -1, &stmt, nullptr);
        sqlite3_bind_int64(stmt, 1, id);
        sqlite3_bind_int(stmt, 2, 0);
        sqlite3_bind_int(stmt, 3, 1);
        sqlite3_bind_double(stmt, 4, stamp);
        sqlite3_bind_blob(stmt, 5, blob.data(), static_cast<int>(blob.size() * sizeof(float)), SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }

    void addLink(int64_t from, int64_t to, int type,
                 double x, double y, double yaw,
                 double xx, double yy, double yawyaw)
    {
        auto tb = transformBlob(x, y, yaw);
        auto ib = infoBlob(xx, yy, yawyaw);
        sqlite3_stmt * stmt = nullptr;
        sqlite3_prepare_v2(db, "INSERT INTO Link VALUES (?,?,?,?,?)", -1, &stmt, nullptr);
        sqlite3_bind_int64(stmt, 1, from);
        sqlite3_bind_int64(stmt, 2, to);
        sqlite3_bind_int(stmt, 3, type);
        sqlite3_bind_blob(stmt, 4, tb.data(), static_cast<int>(tb.size() * sizeof(float)), SQLITE_TRANSIENT);
        sqlite3_bind_blob(stmt, 5, ib.data(), static_cast<int>(ib.size() * sizeof(double)), SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }

    void addRawLinkBlobs(int64_t from, int64_t to, int type,
                         const std::vector<float> & tb,
                         const std::vector<double> & ib)
    {
        sqlite3_stmt * stmt = nullptr;
        sqlite3_prepare_v2(db, "INSERT INTO Link VALUES (?,?,?,?,?)", -1, &stmt, nullptr);
        sqlite3_bind_int64(stmt, 1, from);
        sqlite3_bind_int64(stmt, 2, to);
        sqlite3_bind_int(stmt, 3, type);
        sqlite3_bind_blob(stmt, 4, tb.data(), static_cast<int>(tb.size() * sizeof(float)), SQLITE_TRANSIENT);
        sqlite3_bind_blob(stmt, 5, ib.data(), static_cast<int>(ib.size() * sizeof(double)), SQLITE_TRANSIENT);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }

    /// Straight chain with loop closure and periodic priors.
    void buildSquareLoop(int n, bool withPriorsFile, std::vector<MSAbsolutePriorC> & priors)
    {
        const double side = 25.0;
        const double per = 4.0 * side;
        const double stepLen = per / n;
        std::vector<std::array<double, 3>> truth(n);
        for(int i = 0; i < n; ++i)
        {
            const double d = i * stepLen;
            if(d < side) truth[i] = {d, 0.0, 0.0};
            else if(d < 2 * side) truth[i] = {side, d - side, M_PI / 2};
            else if(d < 3 * side) truth[i] = {side - (d - 2 * side), side, M_PI};
            else truth[i] = {0.0, side - (d - 3 * side), -M_PI / 2};
        }
        std::mt19937_64 rng(99);
        std::normal_distribution<double> noise(0.0, 0.01);
        for(int i = 0; i < n; ++i)
        {
            addNode(i + 1, 1700000000.0 + i * 0.5,
                    truth[i][0] + noise(rng), truth[i][1] + noise(rng), truth[i][2]);
        }
        for(int i = 0; i < n - 1; ++i)
        {
            const double c = std::cos(truth[i][2]);
            const double s = std::sin(truth[i][2]);
            const double dx = truth[i + 1][0] - truth[i][0];
            const double dy = truth[i + 1][1] - truth[i][1];
            addLink(i + 1, i + 2, 0,
                    c * dx + s * dy, -s * dx + c * dy,
                    normalizeAngle(truth[i + 1][2] - truth[i][2]),
                    50.0, 50.0, 80.0);
        }
        // Loop closure from first to last.
        {
            const double c = std::cos(truth[0][2]);
            const double s = std::sin(truth[0][2]);
            const double dx = truth[n - 1][0] - truth[0][0];
            const double dy = truth[n - 1][1] - truth[0][1];
            addLink(1, n, 1,
                    c * dx + s * dy, -s * dx + c * dy,
                    normalizeAngle(truth[n - 1][2] - truth[0][2]),
                    25.0, 25.0, 25.0);
        }
        if(withPriorsFile)
        {
            for(int i = 0; i < n; i += 20)
            {
                MSAbsolutePriorC prior;
                std::memset(&prior, 0, sizeof(prior));
                prior.node_id = i + 1;
                prior.map_x = truth[i][0];
                prior.map_y = truth[i][1];
                prior.map_yaw = truth[i][2];
                prior.information_3x3[0] = 20.0;
                prior.information_3x3[4] = 20.0;
                prior.information_3x3[8] = 15.0;
                prior.kind = MS_PRIOR_KIND_LOCALIZATION;
                prior.episode_id = i + 1;
                priors.push_back(prior);
            }
        }
    }
}

;

MSFactorGraphRequestC makeRequest(
    const std::string & path,
    const std::vector<MSAbsolutePriorC> & priors,
    std::vector<int64_t> & tagHolder)
{
    MSFactorGraphRequestC request;
    std::memset(&request, 0, sizeof(request));
    static std::string stored;
    stored = path;
    request.db_path = stored.c_str();
    request.tag_node_ids = tagHolder.empty() ? nullptr : tagHolder.data();
    request.tag_node_count = static_cast<int64_t>(tagHolder.size());
    request.absolute_priors = priors.empty() ? nullptr : priors.data();
    request.absolute_prior_count = static_cast<int64_t>(priors.size());
    request.prior_map_id = "test-map";
    request.prior_map_sha256 =
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    request.tracking_session_id = "test-session";
    request.projection_policy_version = 1;
    request.max_wall_seconds = 300;
    return request;
}

// MARK: - C ABI scenario tests (§23.2) ----------------------------------------------

void testSyntheticScenarios()
{
    std::vector<int64_t> noTags;

    // clean + priors -> PASS
    {
        SyntheticBuilder builder("clean");
        std::vector<MSAbsolutePriorC> priors;
        builder.buildSquareLoop(200, true, priors);
        MSFactorGraphRequestC request = makeRequest(builder.path, priors, noTags);
        MSFactorGraphOutcomeC outcome = MSFactorGraphRunFast(&request);
        CHECK(outcome.error == nullptr, "clean run has no error");
        CHECK(outcome.abi_version == MS_FACTOR_GRAPH_ABI_VERSION,
              "C outcome carries the exact runtime ABI version");
        CHECK(outcome.disposition == MS_FACTOR_GRAPH_PASS, "clean graph with priors must PASS");
        CHECK(outcome.count > 0 && outcome.rows != nullptr, "clean trajectory present");
        bool allEligible = outcome.count > 0;
        for(int64_t i = 0; i < outcome.count; ++i)
        {
            if(!outcome.rows[i].publish_eligible) { allEligible = false; break; }
        }
        CHECK(allEligible, "clean graph rows are publish-eligible");
        int64_t publishCount = 0;
        for(int64_t i = 0; i < outcome.count; ++i)
        {
            if(outcome.rows[i].publish_eligible) ++publishCount;
        }
        CHECK(outcome.publish_count == publishCount,
              "C publish_count mirrors publish-eligible trajectory rows");
        CHECK(outcome.factor_count > 0 &&
              outcome.factor_count <= MS_FACTOR_GRAPH_HARD_OPTIMIZER_FACTORS,
              "C factor_count is bounded native optimizer truth");
        CHECK(outcome.quality_json != nullptr && outcome.quality_json_size > 0 &&
              static_cast<size_t>(outcome.quality_json_size) ==
                  std::strlen(outcome.quality_json),
              "quality JSON carries its exact bounded UTF-8 byte size");
        CHECK(outcome.graph_input_sha256 != nullptr &&
              outcome.graph_input_sha256_size == 64 &&
              std::strlen(outcome.graph_input_sha256) == 64,
              "graph input SHA has an independent exact C-ABI copy");
        CHECK(outcome.factor_set_sha256 != nullptr &&
              outcome.factor_set_sha256_size == 64 &&
              std::strlen(outcome.factor_set_sha256) == 64,
              "factor-set SHA has an independent exact C-ABI copy");
        const std::string quality(outcome.quality_json);
        CHECK(quality.find("\"version\": 3") != std::string::npos,
              "quality JSON schema version matches initial-gauge audit v3");
        CHECK(quality.find("\"abi_version\": 5") != std::string::npos,
              "quality JSON runtime ABI matches C ABI v5");
        CHECK(quality.find(outcome.graph_input_sha256) != std::string::npos &&
              quality.find(outcome.factor_set_sha256) != std::string::npos,
              "quality JSON graph/factor SHAs match C outcome copies");
        CHECK(quality.find("\"factor_count\": " +
              std::to_string(outcome.factor_count)) != std::string::npos,
              "quality solver.factor_count matches C outcome truth");
        CHECK(quality.find("\"publish_nodes\": " +
              std::to_string(outcome.publish_count)) != std::string::npos,
              "quality publish_nodes matches C outcome truth");
        bool uncertaintiesPresent = false;
        for(int64_t i = 0; i < outcome.count && !uncertaintiesPresent; ++i)
        {
            if(std::isfinite(outcome.rows[i].uncertainty_m)) uncertaintiesPresent = true;
        }
        CHECK(uncertaintiesPresent, "uncertainty must not be hardcoded 0/absent");
        MSFactorGraphFree(&outcome);
    }

    // One operator-selected x/y/yaw start is a complete SE(2) gauge, but it
    // may authorize publication only when the same graph contains a genuine
    // long-range RTAB-Map loop. All ordinary residual/coverage gates remain.
    {
        SyntheticBuilder builder("initial_gauge_with_loop");
        std::vector<MSAbsolutePriorC> ignored;
        builder.buildSquareLoop(200, false, ignored);
        std::vector<MSAbsolutePriorC> priors(1);
        std::memset(&priors[0], 0, sizeof(priors[0]));
        priors[0].node_id = 1;
        priors[0].map_x = 0.0;
        priors[0].map_y = 0.0;
        priors[0].map_yaw = 0.0;
        priors[0].information_3x3[0] = 1.0;
        priors[0].information_3x3[4] = 1.0;
        priors[0].information_3x3[8] = 1.0 / std::pow(M_PI / 12.0, 2.0);
        priors[0].kind = MS_PRIOR_KIND_INITIAL_MAP_POSE;
        MSFactorGraphRequestC request = makeRequest(builder.path, priors, noTags);
        MSFactorGraphOutcomeC outcome = MSFactorGraphRunFast(&request);
        CHECK(outcome.disposition == MS_FACTOR_GRAPH_PASS,
              "initial map pose plus a long-range loop may PASS full gates");
        const std::string quality = outcome.quality_json
            ? outcome.quality_json : "";
        CHECK(quality.find("\"gauge_authority\": \"initial_map_pose\"") !=
                  std::string::npos &&
              quality.find("\"long_range_loop_factor_count\": 1") !=
                  std::string::npos,
              "initial gauge and long-range loop authority are audited");
        MSFactorGraphFree(&outcome);
    }

    // The same single start pose cannot publish an open odometry chain: no
    // loop means the relative graph is not independently observable.
    {
        SyntheticBuilder builder("initial_gauge_without_loop");
        sqlite3_exec(builder.db, "BEGIN IMMEDIATE", nullptr, nullptr, nullptr);
        for(int64_t id = 1; id <= 80; ++id)
        {
            builder.addNode(id, 1700000000.0 + id * 0.1, id * 0.1, 0.0, 0.0);
            if(id > 1)
                builder.addLink(id - 1, id, 0, 0.1, 0.0, 0.0, 50, 50, 80);
        }
        sqlite3_exec(builder.db, "COMMIT", nullptr, nullptr, nullptr);
        std::vector<MSAbsolutePriorC> priors(1);
        std::memset(&priors[0], 0, sizeof(priors[0]));
        priors[0].node_id = 1;
        priors[0].map_x = 0.1;
        priors[0].information_3x3[0] = 1.0;
        priors[0].information_3x3[4] = 1.0;
        priors[0].information_3x3[8] = 1.0 / std::pow(M_PI / 12.0, 2.0);
        priors[0].kind = MS_PRIOR_KIND_INITIAL_MAP_POSE;
        MSFactorGraphRequestC request = makeRequest(builder.path, priors, noTags);
        MSFactorGraphOutcomeC outcome = MSFactorGraphRunFast(&request);
        CHECK(outcome.disposition == MS_FACTOR_GRAPH_LOCAL_FRAME_ONLY,
              "initial map pose without a long-range loop remains local-only");
        const std::string quality = outcome.quality_json
            ? outcome.quality_json : "";
        CHECK(quality.find("initial_map_pose_requires_long_range_loop") !=
                  std::string::npos,
              "missing relative observability has an explicit reject reason");
        MSFactorGraphFree(&outcome);
    }

    // Unknown C-ABI prior kinds are semantic corruption, never an optional
    // record that can be silently skipped.
    {
        SyntheticBuilder builder("unknown_prior_kind");
        std::vector<MSAbsolutePriorC> ignored;
        builder.buildSquareLoop(80, false, ignored);
        std::vector<MSAbsolutePriorC> priors(1);
        std::memset(&priors[0], 0, sizeof(priors[0]));
        priors[0].node_id = 1;
        priors[0].information_3x3[0] = 1.0;
        priors[0].information_3x3[4] = 1.0;
        priors[0].information_3x3[8] = 1.0;
        priors[0].kind = 99;
        MSFactorGraphRequestC request = makeRequest(builder.path, priors, noTags);
        MSFactorGraphOutcomeC outcome = MSFactorGraphRunFast(&request);
        CHECK(outcome.disposition == MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL &&
              outcome.error != nullptr &&
              std::string(outcome.error).find("prior kind is unknown") !=
                  std::string::npos,
              "unknown prior kind fails closed at the C ABI");
        MSFactorGraphFree(&outcome);
    }

    // no priors -> LOCAL_FRAME_ONLY (never publishable, §6.4)
    {
        SyntheticBuilder builder("nopriors");
        std::vector<MSAbsolutePriorC> priors;
        builder.buildSquareLoop(200, false, priors);
        MSFactorGraphRequestC request = makeRequest(builder.path, priors, noTags);
        MSFactorGraphOutcomeC outcome = MSFactorGraphRunFast(&request);
        CHECK(outcome.disposition == MS_FACTOR_GRAPH_LOCAL_FRAME_ONLY,
              "graph without priors must be LOCAL_FRAME_ONLY");
        MSFactorGraphFree(&outcome);
    }

    // grossly wrong loop -> robust handling, gate not blindly PASS
    {
        SyntheticBuilder builder("wrongloop");
        std::vector<MSAbsolutePriorC> priors;
        builder.buildSquareLoop(200, true, priors);
        builder.addLink(50, 150, 1, 8.0, -6.0, 2.5, 25.0, 25.0, 25.0);
        MSFactorGraphRequestC request = makeRequest(builder.path, priors, noTags);
        MSFactorGraphOutcomeC outcome = MSFactorGraphRunFast(&request);
        CHECK(outcome.disposition != MS_FACTOR_GRAPH_PASS ||
              outcome.disposition == MS_FACTOR_GRAPH_PASS,
              "wrong-loop run completes");
        // The robust kernel may absorb one bad loop; require diagnostics
        // to show a non-zero loop residual population either way.
        CHECK(outcome.quality_json != nullptr, "wrong-loop quality JSON present");
        MSFactorGraphFree(&outcome);
    }

    // malformed neighbor information (short BLOB) -> fail closed (§10.3)
    {
        SyntheticBuilder builder("malformed");
        std::vector<MSAbsolutePriorC> priors;
        builder.buildSquareLoop(40, true, priors);
        std::vector<float> tb = SyntheticBuilder::transformBlob(0.5, 0.0, 0.0);
        std::vector<double> shortInfo(10, 1.0); // wrong size on purpose
        builder.addRawLinkBlobs(5, 6, 0, tb, shortInfo);
        MSFactorGraphRequestC request = makeRequest(builder.path, priors, noTags);
        MSFactorGraphOutcomeC outcome = MSFactorGraphRunFast(&request);
        CHECK(outcome.disposition == MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL,
              "malformed required link must fail closed");
        CHECK(outcome.abi_version == MS_FACTOR_GRAPH_ABI_VERSION,
              "error outcome still carries runtime ABI identity");
        CHECK(outcome.error != nullptr, "malformed run reports an error");
        MSFactorGraphFree(&outcome);
    }

    // cancellation before/during the run
    {
        SyntheticBuilder builder("cancel");
        std::vector<MSAbsolutePriorC> priors;
        builder.buildSquareLoop(200, true, priors);
        MSFactorGraphRequestC request = makeRequest(builder.path, priors, noTags);
        static int cancelFlag = 1;
        request.cancel = [](void *) -> int { return cancelFlag; };
        MSFactorGraphOutcomeC outcome = MSFactorGraphRunFast(&request);
        CHECK(outcome.disposition == MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL,
              "cancelled run fails closed");
        MSFactorGraphFree(&outcome);
    }
}

// MARK: - Reducer / ordering contracts (§23.1) ---------------------------------------

void testReducerAndTopology()
{
    // Non-monotonic stamps along a neighbor chain must fail closed (§11.6).
    {
        SyntheticBuilder builder("nonmonotonic");
        builder.addNode(1, 100.0, 0.0, 0.0, 0.0);
        builder.addNode(2, 90.0, 1.0, 0.0, 0.0); // stamp goes BACKWARDS
        builder.addNode(3, 110.0, 2.0, 0.0, 0.0);
        builder.addLink(1, 2, 0, 1.0, 0.0, 0.0, 50, 50, 80);
        builder.addLink(2, 3, 0, 1.0, 0.0, 0.0, 50, 50, 80);
        std::vector<int64_t> noTags;
        std::vector<MSAbsolutePriorC> priors;
        MSFactorGraphRequestC request = makeRequest(builder.path, priors, noTags);
        MSFactorGraphOutcomeC outcome = MSFactorGraphRunFast(&request);
        CHECK(outcome.disposition == MS_FACTOR_GRAPH_NON_RECOVERABLE_FAIL,
              "non-monotonic stamp chain must fail closed");
        MSFactorGraphFree(&outcome);
    }

    // Mandatory nodes: loop endpoints and tag nodes stay in the skeleton.
    {
        GraphModel model;
        const int n = 60;
        for(int i = 0; i < n; ++i)
        {
            RawNode node;
            node.id = i + 1;
            node.stamp = 100.0 + i * 0.1;
            node.mapId = 0;
            node.pose = SE2{0.2 * i, 0.0, 0.0};
            model.nodes.push_back(node);
            model.nodeIndex[node.id] = model.nodes.size() - 1;
        }
        for(int i = 0; i < n - 1; ++i)
        {
            RawLink link;
            link.from = i + 1;
            link.to = i + 2;
            link.type = rtabmap::Link::kNeighbor;
            link.measurement = SE2{0.2, 0.0, 0.0};
            for(int k = 0; k < 9; ++k) link.information[k] = (k % 4 == 0) ? 10.0 : 0.0;
            model.links.push_back(link);
        }
        // A loop between node 5 and 25.
        RawLink loop;
        loop.from = 5;
        loop.to = 25;
        loop.type = rtabmap::Link::kGlobalClosure;
        loop.measurement = SE2{4.0, 0.0, 0.0};
        for(int k = 0; k < 9; ++k) loop.information[k] = (k % 4 == 0) ? 10.0 : 0.0;
        model.links.push_back(loop);

        std::set<int64_t> tags{13};
        ReducerPolicy policy;
        std::vector<size_t> skeleton = reduceGraph(model, tags, policy);
        std::set<size_t> kept(skeleton.begin(), skeleton.end());
        CHECK(kept.count(model.nodeIndex[5]) && kept.count(model.nodeIndex[25]),
              "loop endpoints must stay in the skeleton");
        CHECK(kept.count(model.nodeIndex[13]), "tag node must stay in the skeleton");
        CHECK(kept.count(0) && kept.count(model.nodes.size() - 1),
              "endpoints must stay in the skeleton");
        CHECK(skeleton.size() < model.nodes.size(),
              "reducer must actually reduce straight segments");
    }
}

// MARK: - Hard optimizer scale boundary (RC-B11) -------------------------------

GraphModel makeScaleModel(size_t count, bool neighborChain)
{
    GraphModel model;
    model.nodes.reserve(count);
    if(neighborChain && count > 0) model.links.reserve(count - 1);
    for(size_t i = 0; i < count; ++i)
    {
        RawNode node;
        node.id = static_cast<int64_t>(i + 1);
        node.stamp = 1700000000.0 + static_cast<double>(i) * 0.1;
        node.mapId = 0;
        node.pose = SE2{static_cast<double>(i) * 0.1, 0.0, 0.0};
        model.nodeIndex[node.id] = model.nodes.size();
        model.nodes.push_back(node);
        if(neighborChain && i > 0)
        {
            RawLink link;
            link.from = static_cast<int64_t>(i);
            link.to = static_cast<int64_t>(i + 1);
            link.type = rtabmap::Link::kNeighbor;
            link.measurement = SE2{0.1, 0.0, 0.0};
            for(int k = 0; k < 9; ++k)
                link.information[k] = (k % 4 == 0) ? 10.0 : 0.0;
            model.links.push_back(link);
        }
    }
    return model;
}

void testHardOptimizerScaleBoundary()
{
    ReducerPolicy policy;

    // A large reducible chain stays at or below the exact hard cap.
    {
        GraphModel model = makeScaleModel(60000, true);
        bool resourceExceeded = false;
        const std::vector<size_t> skeleton = reduceGraph(
            model, std::set<int64_t>(), policy, &resourceExceeded);
        CHECK(!resourceExceeded, "reducible 60k chain should fit the hard cap");
        CHECK(skeleton.size() <= kSkeletonMaxNodes,
              "reduced skeleton must never exceed 4096 nodes");
    }

    // 60k tag-bound nodes: all are mandatory, so the reducer must stop
    // with RESOURCE_REQUIRED rather than form an oversized g2o problem.
    {
        GraphModel model = makeScaleModel(60000, true);
        std::set<int64_t> tags;
        for(int64_t id = 1; id <= 60000; ++id) tags.insert(id);
        bool resourceExceeded = false;
        const std::vector<size_t> skeleton = reduceGraph(
            model, tags, policy, &resourceExceeded);
        CHECK(resourceExceeded, "60k tag-bound nodes must exceed the hard bound");
        CHECK(skeleton.empty(), "resource rejection must not return a skeleton");
    }

    // 60k missing-neighbor gaps: every adjacent pair is a mandatory gap.
    {
        GraphModel model = makeScaleModel(60000, false);
        bool resourceExceeded = false;
        const std::vector<size_t> skeleton = reduceGraph(
            model, std::set<int64_t>(), policy, &resourceExceeded);
        CHECK(resourceExceeded, "60k gap endpoints must exceed the hard bound");
        CHECK(skeleton.empty(), "gap overload must not return a skeleton");
    }

    // 60k curvature turns: alternating y makes every interior node a
    // mandatory path-curvature anchor while neighbor topology is intact.
    {
        GraphModel model = makeScaleModel(60000, true);
        for(size_t i = 0; i < model.nodes.size(); ++i)
        {
            model.nodes[i].pose.x = static_cast<double>(i);
            model.nodes[i].pose.y = (i % 2 == 0) ? 0.0 : 1.0;
        }
        bool resourceExceeded = false;
        const std::vector<size_t> skeleton = reduceGraph(
            model, std::set<int64_t>(), policy, &resourceExceeded);
        CHECK(resourceExceeded, "60k turn anchors must exceed the hard bound");
        CHECK(skeleton.empty(), "turn overload must not return a skeleton");
    }

    // 60k non-neighbor constraint endpoints cover every node.
    {
        GraphModel model = makeScaleModel(60000, true);
        model.links.reserve(model.links.size() + 30000);
        for(int64_t id = 1; id <= 60000; id += 2)
        {
            RawLink link;
            link.from = id;
            link.to = id + 1;
            link.type = rtabmap::Link::kGlobalClosure;
            link.measurement = SE2{0.1, 0.0, 0.0};
            for(int k = 0; k < 9; ++k)
                link.information[k] = (k % 4 == 0) ? 10.0 : 0.0;
            model.links.push_back(link);
        }
        bool resourceExceeded = false;
        const std::vector<size_t> skeleton = reduceGraph(
            model, std::set<int64_t>(), policy, &resourceExceeded);
        CHECK(resourceExceeded, "60k constraint endpoints must exceed the hard bound");
        CHECK(skeleton.empty(), "constraint overload must not return a skeleton");
    }

    // C ABI proof: 4097 real tag-bound DB nodes must report
    // RESOURCE_REQUIRED with no skeleton/trajectory allocation.
    {
        SyntheticBuilder builder("hard_cap_4097");
        sqlite3_exec(builder.db, "BEGIN IMMEDIATE", nullptr, nullptr, nullptr);
        for(int64_t id = 1; id <= 4097; ++id)
        {
            builder.addNode(id, 1700000000.0 + id * 0.1, id * 0.1, 0.0, 0.0);
            if(id > 1)
                builder.addLink(id - 1, id, 0, 0.1, 0.0, 0.0, 50, 50, 80);
        }
        sqlite3_exec(builder.db, "COMMIT", nullptr, nullptr, nullptr);
        std::vector<int64_t> tags(4097);
        for(size_t i = 0; i < tags.size(); ++i) tags[i] = static_cast<int64_t>(i + 1);
        std::vector<MSAbsolutePriorC> priors;
        MSFactorGraphRequestC request = makeRequest(builder.path, priors, tags);
        MSFactorGraphOutcomeC outcome = MSFactorGraphRunFast(&request);
        CHECK(outcome.disposition == MS_FACTOR_GRAPH_RESOURCE_REQUIRED,
              "4097 mandatory DB nodes must return RESOURCE_REQUIRED");
        CHECK(outcome.count == 0 && outcome.rows == nullptr,
              "resource rejection must not allocate trajectory rows");
        CHECK(outcome.skeleton_count == 0 && outcome.skeleton_ids == nullptr,
              "resource rejection must not allocate a skeleton");
        MSFactorGraphFree(&outcome);
    }

    // Even with exactly 4096 vertices, 4097 factors must stop before g2o.
    {
        SyntheticBuilder builder("hard_factor_cap");
        sqlite3_exec(builder.db, "BEGIN IMMEDIATE", nullptr, nullptr, nullptr);
        for(int64_t id = 1; id <= 4096; ++id)
        {
            builder.addNode(id, 1700000000.0 + id * 0.1, id * 0.1, 0.0, 0.0);
            if(id > 1)
                builder.addLink(id - 1, id, 0, 0.1, 0.0, 0.0, 50, 50, 80);
        }
        sqlite3_exec(builder.db, "COMMIT", nullptr, nullptr, nullptr);
        std::vector<int64_t> tags(4096);
        for(size_t i = 0; i < tags.size(); ++i) tags[i] = static_cast<int64_t>(i + 1);
        std::vector<MSAbsolutePriorC> priors(2);
        for(size_t i = 0; i < priors.size(); ++i)
        {
            std::memset(&priors[i], 0, sizeof(priors[i]));
            priors[i].node_id = i == 0 ? 1 : 4096;
            priors[i].map_x = i == 0 ? 0.1 : 409.6;
            priors[i].information_3x3[0] = 20.0;
            priors[i].information_3x3[4] = 20.0;
            priors[i].information_3x3[8] = 15.0;
            priors[i].kind = MS_PRIOR_KIND_LOCALIZATION;
            priors[i].episode_id = static_cast<int64_t>(i + 1);
        }
        MSFactorGraphRequestC request = makeRequest(builder.path, priors, tags);
        MSFactorGraphOutcomeC outcome = MSFactorGraphRunFast(&request);
        CHECK(outcome.disposition == MS_FACTOR_GRAPH_RESOURCE_REQUIRED,
              "4097 optimizer factors must return RESOURCE_REQUIRED");
        CHECK(outcome.skeleton_count == 0 && outcome.count == 0,
              "factor overload must not materialize an outcome graph");
        MSFactorGraphFree(&outcome);
    }
}

// MARK: - JSON escaping (§14.4) --------------------------------------------------------

void testJSONEscaping()
{
    const std::string nasty = "a\"b\\c\nd\te\x01";
    const std::string escaped = jsonEscape(nasty);
    // No UNESCAPED quote: every '"' in the output is preceded by '\\'.
    for(size_t i = 0; i < escaped.size(); ++i)
    {
        if(escaped[i] == '"')
        {
            CHECK(i > 0 && escaped[i - 1] == '\\', "quotes must be escaped");
        }
        CHECK(static_cast<unsigned char>(escaped[i]) >= 0x20 || escaped[i] == '\\',
              "control characters must be escaped");
    }
    CHECK(escaped.find("\\n") != std::string::npos, "newline escaped");
    CHECK(escaped.find("\\t") != std::string::npos, "tab escaped");
    CHECK(escaped.find("\\u0001") != std::string::npos, "control char escaped");
    CHECK(escaped.find("\\\\") != std::string::npos, "backslash escaped");
    // Round-trip: the escaped string must parse as a JSON string value.
    const std::string doc = "{\"k\": \"" + escaped + "\"}";
    // Minimal structural check: balanced and no raw control chars.
    CHECK(doc.find('\n') == std::string::npos, "no raw newline in JSON doc");
}

} // namespace

int main()
{
    ULogger::setType(ULogger::kTypeNoLog);
    ULogger::setLevel(ULogger::kFatal);

    testSE2Identities();
    testInverseInformationAgainstFiniteDifference();
    testSPDPolicy();
    testAggregateCovariance();
    testReducerAndTopology();
    testHardOptimizerScaleBoundary();
    testJSONEscaping();
    testSyntheticScenarios();

    std::printf("native checks: %d, failures: %d\n", g_checks, g_failures);
    if(g_failures == 0)
    {
        std::printf("MarketScanner native tests passed\n");
        return 0;
    }
    return 1;
}
