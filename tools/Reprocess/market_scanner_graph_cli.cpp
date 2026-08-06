/*
 * rtabmap-market-scanner-graph — PC diagnostic oracle (V1R2 Gate G,
 * V1R3 §6.5 parity).
 *
 * Calls the SAME shared MarketScanner factor-graph core the iOS app
 * links, so PC replays and on-device runs produce identical native
 * math. Absolute priors may be supplied from a JSON sidecar to exercise
 * the global-frame gate. Read-only: the input database is never
 * written.
 */

#include "market_scanner_factor_graph.h"

#include <rtabmap/core/Version.h>
#include <rtabmap/utilite/ULogger.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct Options
{
    std::string database;
    std::string mode = "fast";
    std::string priorsJson;
    std::string rowsOut;
    std::vector<int64_t> tagNodes;
    int64_t maxNodes = 0;
    double maxWallSeconds = 0.0;
};

void usage()
{
    std::cerr <<
        "Usage: rtabmap-market-scanner-graph --db <database.db> [--mode fast|full]\n"
        "       [--priors <priors.json>] [--tag-node <id>...]\n"
        "       [--max-nodes N] [--max-wall-seconds S]\n";
}

Options parseOptions(int argc, char ** argv)
{
    Options options;
    for(int i = 1; i < argc; ++i)
    {
        const std::string arg = argv[i];
        if(arg == "--version")
        {
#ifdef MARKETSCANNER_GIT_SHA
            std::cout << "rtabmap-market-scanner-graph " << RTABMAP_VERSION
                      << " marketscanner_git_sha=" << MARKETSCANNER_GIT_SHA
                      << " abi=" << MS_FACTOR_GRAPH_ABI_VERSION << std::endl;
#else
            std::cout << "rtabmap-market-scanner-graph " << RTABMAP_VERSION
                      << " marketscanner_git_sha=untracked-build"
                      << " abi=" << MS_FACTOR_GRAPH_ABI_VERSION << std::endl;
#endif
            std::exit(0);
        }
        else if(arg == "--db" && i + 1 < argc) options.database = argv[++i];
        else if(arg == "--mode" && i + 1 < argc) options.mode = argv[++i];
        else if(arg == "--priors" && i + 1 < argc) options.priorsJson = argv[++i];
        else if(arg == "--rows-out" && i + 1 < argc) options.rowsOut = argv[++i];
        else if(arg == "--tag-node" && i + 1 < argc) options.tagNodes.push_back(std::atoll(argv[++i]));
        else if(arg == "--max-nodes" && i + 1 < argc) options.maxNodes = std::atoll(argv[++i]);
        else if(arg == "--max-wall-seconds" && i + 1 < argc) options.maxWallSeconds = std::atof(argv[++i]);
        else { usage(); std::exit(2); }
    }
    if(options.database.empty()) { usage(); std::exit(2); }
    if(options.mode != "fast" && options.mode != "full") { usage(); std::exit(2); }
    return options;
}

/// Minimal strict-ish parser for the oracle's prior sidecar:
/// {"priors":[{"node_id":..,"map_x":..,"map_y":..,"map_yaw":..,
///   "information_3x3":[9 numbers],"kind":0,"episode_id":..}, ...]}
/// The production parser lives in the pipeline evidence layer; this
/// oracle only needs deterministic parity inputs.
bool parsePriors(const std::string & path, std::vector<MSAbsolutePriorC> & out, std::string & error)
{
    std::ifstream in(path.c_str());
    if(!in.good())
    {
        error = "cannot open priors file";
        return false;
    }
    std::stringstream buffer;
    buffer << in.rdbuf();
    const std::string text = buffer.str();
    // Extract each object inside "priors":[ ... ].
    const size_t start = text.find("\"priors\"");
    if(start == std::string::npos)
    {
        error = "priors array missing";
        return false;
    }
    const size_t arrayStart = text.find('[', start);
    if(arrayStart == std::string::npos)
    {
        error = "priors array malformed";
        return false;
    }
    size_t cursor = arrayStart;
    while(true)
    {
        const size_t objStart = text.find('{', cursor);
        const size_t arrayEnd = text.find(']', cursor);
        if(objStart == std::string::npos ||
           (arrayEnd != std::string::npos && arrayEnd < objStart))
        {
            break;
        }
        const size_t objEnd = text.find('}', objStart);
        if(objEnd == std::string::npos)
        {
            error = "unterminated prior object";
            return false;
        }
        const std::string obj = text.substr(objStart, objEnd - objStart + 1);
        cursor = objEnd + 1;
        MSAbsolutePriorC prior;
        std::memset(&prior, 0, sizeof(prior));
        auto numberField = [&](const std::string & name, double & value) -> bool {
            const size_t at = obj.find("\"" + name + "\"");
            if(at == std::string::npos) return false;
            const size_t colon = obj.find(':', at);
            if(colon == std::string::npos) return false;
            value = std::strtod(obj.c_str() + colon + 1, 0);
            return true;
        };
        double nodeId = 0, x = 0, y = 0, yaw = 0, kind = 0, episode = 0;
        if(!numberField("node_id", nodeId) || !numberField("map_x", x) ||
           !numberField("map_y", y) || !numberField("map_yaw", yaw))
        {
            error = "prior object missing required fields";
            return false;
        }
        numberField("kind", kind);
        numberField("episode_id", episode);
        prior.node_id = static_cast<int64_t>(nodeId);
        prior.map_x = x;
        prior.map_y = y;
        prior.map_yaw = yaw;
        prior.kind = static_cast<int32_t>(kind);
        prior.episode_id = static_cast<int64_t>(episode);
        // information_3x3 array.
        const size_t infoAt = obj.find("\"information_3x3\"");
        if(infoAt != std::string::npos)
        {
            const size_t infoStart = obj.find('[', infoAt);
            if(infoStart != std::string::npos)
            {
                size_t p = infoStart + 1;
                for(int k = 0; k < 9; ++k)
                {
                    char * end = 0;
                    const double v = std::strtod(obj.c_str() + p, &end);
                    if(end == obj.c_str() + p) break;
                    prior.information_3x3[k] = v;
                    p = static_cast<size_t>(end - obj.c_str());
                }
            }
        }
        else
        {
            prior.information_3x3[0] = prior.information_3x3[4] = prior.information_3x3[8] = 100.0;
        }
        out.push_back(prior);
    }
    return true;
}

void onProgress(double fraction, void *)
{
    std::fprintf(stderr, "[progress] %.2f\n", fraction);
}

} // namespace

int main(int argc, char ** argv)
{
    ULogger::setType(ULogger::kTypeNoLog);
    ULogger::setLevel(ULogger::kError);
    const Options options = parseOptions(argc, argv);
    std::vector<MSAbsolutePriorC> priors;
    if(!options.priorsJson.empty())
    {
        std::string error;
        if(!parsePriors(options.priorsJson, priors, error))
        {
            std::cerr << "PRIORS_ERROR: " << error << std::endl;
            return 2;
        }
    }

    MSFactorGraphRequestC request;
    std::memset(&request, 0, sizeof(request));
    request.db_path = options.database.c_str();
    request.tag_node_ids = options.tagNodes.empty() ? 0 : options.tagNodes.data();
    request.tag_node_count = static_cast<int64_t>(options.tagNodes.size());
    request.absolute_priors = priors.empty() ? 0 : priors.data();
    request.absolute_prior_count = static_cast<int64_t>(priors.size());
    request.prior_map_id = "oracle";
    request.prior_map_sha256 = "oracle";
    request.tracking_session_id = "oracle";
    request.projection_policy_version = 1;
    request.max_nodes = options.maxNodes;
    request.max_wall_seconds = options.maxWallSeconds;
    request.progress = onProgress;

    MSFactorGraphOutcomeC outcome = options.mode == "full"
        ? MSFactorGraphRunFullGraph(&request)
        : MSFactorGraphRunFast(&request);

    if(outcome.error)
    {
        std::cerr << "FACTOR_GRAPH_ERROR: " << outcome.error << std::endl;
    }
    if(outcome.quality_json)
    {
        std::cout << outcome.quality_json << std::endl;
    }
    if(!options.rowsOut.empty())
    {
        // Golden assertions (§6.6) need the reconstructed map-frame rows.
        std::ofstream out(options.rowsOut.c_str());
        out.precision(12);
        for(int64_t i = 0; i < outcome.count; ++i)
        {
            const MSTrajectoryRowC & r = outcome.rows[i];
            out << "{\"id\": " << r.id
                << ", \"x\": " << r.x << ", \"y\": " << r.y
                << ", \"yaw\": " << r.yaw
                << ", \"publish\": " << (int)r.publish_eligible
                << ", \"component\": " << r.component_id << "}\n";
        }
    }
    std::fprintf(stderr, "[summary] trajectory_rows=%lld skeleton_nodes=%lld disposition=%d\n",
                 (long long)outcome.count, (long long)outcome.skeleton_count, outcome.disposition);

    const int exitCode = outcome.error ? 2
        : (outcome.disposition == MS_FACTOR_GRAPH_PASS ? 0 : 3);
    MSFactorGraphFree(&outcome);
    return exitCode;
}
