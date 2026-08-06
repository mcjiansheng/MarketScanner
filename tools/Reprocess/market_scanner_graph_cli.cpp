/*
 * rtabmap-market-scanner-graph — PC diagnostic oracle (V1R2 Gate G §11.1).
 *
 * Calls the SAME shared MarketScanner factor-graph core the iOS app
 * links, so PC replays and on-device runs produce identical native math.
 * Read-only: the input database is never written.
 */

#include "market_scanner_factor_graph.h"

#include <rtabmap/core/Version.h>

#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace {

struct Options
{
    std::string database;
    std::string mode = "fast";
    std::vector<int64_t> tagNodes;
    int64_t maxNodes = 0;
    double maxWallSeconds = 0.0;
};

void usage()
{
    std::cerr <<
        "Usage: rtabmap-market-scanner-graph --db <database.db> [--mode fast|deep]\n"
        "       [--tag-node <id>...] [--max-nodes N] [--max-wall-seconds S]\n";
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
                      << " marketscanner_git_sha=" << MARKETSCANNER_GIT_SHA << std::endl;
#else
            std::cout << "rtabmap-market-scanner-graph " << RTABMAP_VERSION
                      << " marketscanner_git_sha=untracked-build" << std::endl;
#endif
            std::exit(0);
        }
        else if(arg == "--db" && i + 1 < argc) options.database = argv[++i];
        else if(arg == "--mode" && i + 1 < argc) options.mode = argv[++i];
        else if(arg == "--tag-node" && i + 1 < argc) options.tagNodes.push_back(std::atoll(argv[++i]));
        else if(arg == "--max-nodes" && i + 1 < argc) options.maxNodes = std::atoll(argv[++i]);
        else if(arg == "--max-wall-seconds" && i + 1 < argc) options.maxWallSeconds = std::atof(argv[++i]);
        else { usage(); std::exit(2); }
    }
    if(options.database.empty()) { usage(); std::exit(2); }
    if(options.mode != "fast" && options.mode != "deep") { usage(); std::exit(2); }
    return options;
}

void onProgress(double fraction, void *)
{
    std::fprintf(stderr, "[progress] %.2f\n", fraction);
}

} // namespace

int main(int argc, char ** argv)
{
    const Options options = parseOptions(argc, argv);
    MSFactorGraphRequestC request;
    std::memset(&request, 0, sizeof(request));
    request.db_path = options.database.c_str();
    request.tag_node_ids = options.tagNodes.empty() ? 0 : options.tagNodes.data();
    request.tag_node_count = static_cast<int64_t>(options.tagNodes.size());
    request.max_nodes = options.maxNodes;
    request.max_wall_seconds = options.maxWallSeconds;
    request.progress = onProgress;

    MSFactorGraphOutcomeC outcome = options.mode == "deep"
        ? MSFactorGraphRunDeep(&request)
        : MSFactorGraphRunFast(&request);

    if(outcome.error)
    {
        std::cerr << "FACTOR_GRAPH_ERROR: " << outcome.error << std::endl;
    }
    if(outcome.quality_json)
    {
        std::cout << outcome.quality_json << std::endl;
    }
    std::fprintf(stderr, "[summary] trajectory_rows=%lld skeleton_nodes=%lld disposition=%d\n",
                 (long long)outcome.count, (long long)outcome.skeleton_count, outcome.disposition);

    const int exitCode = outcome.error ? 2 : (outcome.disposition == MS_FACTOR_GRAPH_PASS ? 0 : 3);
    MSFactorGraphFree(&outcome);
    return exitCode;
}
