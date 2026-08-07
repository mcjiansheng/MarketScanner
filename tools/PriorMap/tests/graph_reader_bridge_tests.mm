/* Executable RC-B10 contract tests for MSRTABMapGraphReaderBridge. */

#include "../../../app/ios/RTABMapApp/MSRTABMapGraphReaderBridge.h"

#include <sqlite3.h>

#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <string>
#include <unistd.h>
#include <vector>

namespace {

int failures = 0;

#define CHECK(condition, message)                                      \
    do {                                                               \
        if(!(condition)) {                                             \
            ++failures;                                                \
            std::fprintf(stderr, "FAIL: %s\n", message);              \
        }                                                              \
    } while(0)

std::array<float, 12> identityPose()
{
    return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0};
}

std::array<double, 36> information()
{
    std::array<double, 36> values{};
    values[0] = 10.0;
    values[7] = 10.0;
    values[35] = 10.0;
    return values;
}

sqlite3 * createDatabase(const std::string & path)
{
    std::remove(path.c_str());
    sqlite3 * db = nullptr;
    if(sqlite3_open(path.c_str(), &db) != SQLITE_OK) return nullptr;
    const char * schema =
        "CREATE TABLE Node (id INTEGER PRIMARY KEY, map_id INTEGER, "
        "weight INTEGER, stamp REAL, pose BLOB);"
        "CREATE TABLE Link (from_id INTEGER, to_id INTEGER, type INTEGER, "
        "transform BLOB, information_matrix BLOB);";
    if(sqlite3_exec(db, schema, nullptr, nullptr, nullptr) != SQLITE_OK)
    {
        sqlite3_close(db);
        return nullptr;
    }
    return db;
}

void insertNode(
    sqlite3 * db,
    int64_t id,
    const void * pose,
    int poseBytes,
    double stamp = 1.0)
{
    sqlite3_stmt * statement = nullptr;
    sqlite3_prepare_v2(
        db, "INSERT INTO Node VALUES (?,?,?,?,?)", -1, &statement, nullptr);
    sqlite3_bind_int64(statement, 1, id);
    sqlite3_bind_int(statement, 2, 0);
    sqlite3_bind_int(statement, 3, 1);
    sqlite3_bind_double(statement, 4, stamp);
    if(pose == nullptr)
        sqlite3_bind_null(statement, 5);
    else
        sqlite3_bind_blob(statement, 5, pose, poseBytes, SQLITE_TRANSIENT);
    sqlite3_step(statement);
    sqlite3_finalize(statement);
}

void insertLink(
    sqlite3 * db,
    const void * transform,
    int transformBytes,
    const void * info,
    int infoBytes)
{
    sqlite3_stmt * statement = nullptr;
    sqlite3_prepare_v2(
        db, "INSERT INTO Link VALUES (?,?,?,?,?)", -1, &statement, nullptr);
    sqlite3_bind_int64(statement, 1, 1);
    sqlite3_bind_int64(statement, 2, 2);
    sqlite3_bind_int(statement, 3, 0);
    if(transform == nullptr)
        sqlite3_bind_null(statement, 4);
    else
        sqlite3_bind_blob(statement, 4, transform, transformBytes, SQLITE_TRANSIENT);
    if(info == nullptr)
        sqlite3_bind_null(statement, 5);
    else
        sqlite3_bind_blob(statement, 5, info, infoBytes, SQLITE_TRANSIENT);
    sqlite3_step(statement);
    sqlite3_finalize(statement);
}

bool readFails(const std::string & path)
{
    MSMobileGraphReadResult result = MSMobileGraphReaderRead(path.c_str());
    const bool failed = result.error != nullptr && result.nodes == nullptr &&
        result.links == nullptr;
    MSMobileGraphReaderFree(&result);
    return failed;
}

void testSuccessAndEncodedURI(const std::string & directory)
{
    const std::string path = directory + "/graph %?# valid.sqlite";
    sqlite3 * db = createDatabase(path);
    CHECK(db != nullptr, "create encoded-path database");
    if(!db) return;
    const auto pose = identityPose();
    const auto info = information();
    insertNode(db, 1, pose.data(), sizeof(pose));
    insertNode(db, 2, pose.data(), sizeof(pose), 2.0);
    insertLink(db, pose.data(), sizeof(pose), info.data(), sizeof(info));
    sqlite3_close(db);

    MSMobileGraphReadResult result = MSMobileGraphReaderRead(path.c_str());
    CHECK(result.error == nullptr, "encoded URI path must open");
    CHECK(result.node_count == 2 && result.nodes != nullptr,
          "valid nodes must be returned");
    CHECK(result.link_count == 1 && result.links != nullptr,
          "valid link must be returned");
    CHECK(result.projection_policy_version ==
          MS_MOBILE_GRAPH_PROJECTION_POLICY_VERSION,
          "projection policy version must be exact");
    MSMobileGraphReaderFree(&result);
    std::remove(path.c_str());

    const std::string emptyPath = directory + "/empty.sqlite";
    db = createDatabase(emptyPath);
    sqlite3_close(db);
    result = MSMobileGraphReaderRead(emptyPath.c_str());
    CHECK(result.error == nullptr, "empty valid graph must read");
    CHECK(result.node_count == 0 && result.nodes == nullptr,
          "zero nodes require NULL pointer");
    CHECK(result.link_count == 0 && result.links == nullptr,
          "zero links require NULL pointer");
    MSMobileGraphReaderFree(&result);
    std::remove(emptyPath.c_str());
}

void testInvalidPoseBlobs(const std::string & directory)
{
    std::vector<std::vector<float>> invalid = {
        std::vector<float>(11, 0.0f),
        std::vector<float>(13, 0.0f),
        std::vector<float>(12, 0.0f),
        std::vector<float>(12, 0.0f),
    };
    invalid[2][0] = std::numeric_limits<float>::quiet_NaN();
    invalid[3][0] = std::numeric_limits<float>::infinity();
    for(size_t index = 0; index < invalid.size(); ++index)
    {
        const std::string path = directory + "/bad-pose-" +
            std::to_string(index) + ".sqlite";
        sqlite3 * db = createDatabase(path);
        insertNode(
            db, 1, invalid[index].data(),
            static_cast<int>(invalid[index].size() * sizeof(float)));
        sqlite3_close(db);
        CHECK(readFails(path), "short/long/non-finite pose must fail");
        std::remove(path.c_str());
    }
    const std::string nullPath = directory + "/null-pose.sqlite";
    sqlite3 * db = createDatabase(nullPath);
    insertNode(db, 1, nullptr, 0);
    sqlite3_close(db);
    CHECK(readFails(nullPath), "NULL pose must fail");
    std::remove(nullPath.c_str());
}

void testInvalidLinkBlobs(const std::string & directory)
{
    const auto pose = identityPose();
    const auto info = information();
    for(int variant = 0; variant < 7; ++variant)
    {
        const std::string path = directory + "/bad-link-" +
            std::to_string(variant) + ".sqlite";
        sqlite3 * db = createDatabase(path);
        insertNode(db, 1, pose.data(), sizeof(pose));
        insertNode(db, 2, pose.data(), sizeof(pose), 2.0);
        std::vector<float> transform(pose.begin(), pose.end());
        std::vector<double> matrix(info.begin(), info.end());
        const void * transformPtr = transform.data();
        const void * infoPtr = matrix.data();
        int transformBytes = static_cast<int>(transform.size() * sizeof(float));
        int infoBytes = static_cast<int>(matrix.size() * sizeof(double));
        if(variant == 0) transformPtr = nullptr;
        if(variant == 1) transformBytes -= sizeof(float);
        if(variant == 2) transformBytes += sizeof(float);
        if(variant == 3) transform[0] = std::numeric_limits<float>::quiet_NaN();
        if(variant == 4) infoPtr = nullptr;
        if(variant == 5) infoBytes -= sizeof(double);
        if(variant == 6) matrix[0] = std::numeric_limits<double>::infinity();
        insertLink(db, transformPtr, transformBytes, infoPtr, infoBytes);
        sqlite3_close(db);
        CHECK(readFails(path), "malformed transform/information must fail");
        std::remove(path.c_str());
    }
}

} // namespace

int main()
{
    char templatePath[] = "/tmp/ms-graph-reader-XXXXXX";
    char * directory = mkdtemp(templatePath);
    if(directory == nullptr) return 2;
    testSuccessAndEncodedURI(directory);
    testInvalidPoseBlobs(directory);
    testInvalidLinkBlobs(directory);
    rmdir(directory);
    if(failures == 0)
    {
        std::puts("graph reader bridge tests passed");
        return 0;
    }
    return 1;
}
