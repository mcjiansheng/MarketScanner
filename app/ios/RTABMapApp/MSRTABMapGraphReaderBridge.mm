//
//  MSRTABMapGraphReaderBridge.mm
//  RTABMapApp
//
//  SQLite-backed implementation of the raw RTAB-Map graph reader
//  (Mobile-Only V1R1 Gate E, section 9.4). The schema follows the
//  RTAB-Map DatabaseSchema: `Node` (id, map_id, weight, stamp, pose
//  3x4 float BLOB) and `Link` (from_id, to_id, type, transform 3x4
//  float BLOB, information_matrix 6x6 double BLOB).
//

#import "MSRTABMapGraphReaderBridge.h"

#import <sqlite3.h>
#import <cmath>
#import <limits.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

/// Projection policy version: the reader preserves the raw 3D pose; the
/// business layer projects to SE(2) with this recorded policy version.
static const int32_t kMSProjectionPolicyVersion =
    MS_MOBILE_GRAPH_PROJECTION_POLICY_VERSION;

static char *msCopyError(const char *message) {
    if (message == NULL) {
        return NULL;
    }
    size_t length = strlen(message);
    char *copy = (char *)malloc(length + 1);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, message, length + 1);
    return copy;
}

/// Copies an EXACT 3x4 float BLOB into a double array. NULL, short/long
/// and non-finite payloads are rejected; malformed poses are never padded.
static bool msCopyFloat12(const void *blob, int blobBytes, double out[12]) {
    if (blob == NULL || blobBytes != 12 * (int)sizeof(float)) {
        return false;
    }
    float values[12];
    memcpy(values, blob, sizeof(values));
    for (int index = 0; index < 12; ++index) {
        if (!std::isfinite(values[index])) {
            return false;
        }
        out[index] = (double)values[index];
    }
    return true;
}

/// Copies an EXACT 6x6 double BLOB. NULL, size mismatches and non-finite
/// information values are rejected.
static bool msCopyDouble36(const void *blob, int blobBytes, double out[36]) {
    if (blob == NULL || blobBytes != 36 * (int)sizeof(double)) {
        return false;
    }
    memcpy(out, blob, 36 * sizeof(double));
    for (int index = 0; index < 36; ++index) {
        if (!std::isfinite(out[index])) {
            return false;
        }
    }
    return true;
}

static bool msURISafeByte(unsigned char value) {
    return (value >= 'a' && value <= 'z') ||
        (value >= 'A' && value <= 'Z') ||
        (value >= '0' && value <= '9') ||
        value == '-' || value == '.' || value == '_' || value == '~' ||
        value == '/';
}

/// Builds a percent-encoded SQLite URI without a fixed-size path buffer.
/// In particular, '%', '?', and '#' in a filename cannot inject URI syntax.
static char *msReadOnlyImmutableURI(const char *path) {
    if (path == NULL || path[0] == '\0') {
        return NULL;
    }
    static const char prefix[] = "file:";
    static const char suffix[] = "?mode=ro&immutable=1";
    const size_t pathLength = strlen(path);
    const size_t fixedBytes = sizeof(prefix) - 1 + sizeof(suffix);
    if (pathLength > (SIZE_MAX - fixedBytes) / 3) {
        return NULL;
    }
    const size_t capacity = fixedBytes + pathLength * 3;
    char *uri = (char *)malloc(capacity);
    if (uri == NULL) {
        return NULL;
    }
    char *cursor = uri;
    memcpy(cursor, prefix, sizeof(prefix) - 1);
    cursor += sizeof(prefix) - 1;
    static const char hex[] = "0123456789ABCDEF";
    for (const unsigned char *byte = (const unsigned char *)path; *byte; ++byte) {
        if (msURISafeByte(*byte)) {
            *cursor++ = (char)*byte;
        } else {
            *cursor++ = '%';
            *cursor++ = hex[*byte >> 4];
            *cursor++ = hex[*byte & 0x0f];
        }
    }
    memcpy(cursor, suffix, sizeof(suffix));
    return uri;
}

/// Grows an output array with checked count/capacity/size arithmetic.
static bool msEnsureCapacity(
    void **buffer,
    int64_t *capacity,
    int64_t count,
    int64_t hardMaximum,
    size_t elementSize) {
    if (buffer == NULL || capacity == NULL || count < 0 ||
        hardMaximum <= 0 || count >= hardMaximum) {
        return false;
    }
    if (count < *capacity) {
        return true;
    }
    int64_t grown = *capacity == 0 ? 1024 : *capacity;
    if (grown > hardMaximum) {
        return false;
    }
    if (*capacity != 0) {
        grown = grown > hardMaximum / 2 ? hardMaximum : grown * 2;
    }
    if (grown <= count || (uint64_t)grown > SIZE_MAX / elementSize) {
        return false;
    }
    void *next = realloc(*buffer, (size_t)grown * elementSize);
    if (next == NULL) {
        return false;
    }
    *buffer = next;
    *capacity = grown;
    return true;
}

MSMobileGraphReadResult MSMobileGraphReaderRead(const char *dbPath) {
    MSMobileGraphReadResult result;
    memset(&result, 0, sizeof(result));
    result.projection_policy_version = kMSProjectionPolicyVersion;

    if (dbPath == NULL) {
        result.error = msCopyError("database path is NULL");
        return result;
    }

    // Read-only with immutable=1: the source DB is never written and no
    // journal/wal side effects are produced (V1R1 section 9.3).
    char *uri = msReadOnlyImmutableURI(dbPath);
    if (uri == NULL) {
        result.error = msCopyError("cannot build encoded database URI");
        return result;
    }
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL);
    free(uri);
    if (rc != SQLITE_OK) {
        result.error = msCopyError(
            db != NULL ? sqlite3_errmsg(db) : "cannot allocate SQLite handle");
        if (db != NULL) {
            sqlite3_close(db);
        }
        return result;
    }

    // Quick integrity check of the snapshot copy.
    sqlite3_stmt *check = NULL;
    rc = sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &check, NULL);
    if (rc != SQLITE_OK || check == NULL) {
        result.error = msCopyError("cannot prepare PRAGMA quick_check");
        if (check != NULL) sqlite3_finalize(check);
        sqlite3_close(db);
        return result;
    }
    rc = sqlite3_step(check);
    const unsigned char *checkText = rc == SQLITE_ROW
        ? sqlite3_column_text(check, 0) : NULL;
    const int checkBytes = rc == SQLITE_ROW
        ? sqlite3_column_bytes(check, 0) : -1;
    if (rc != SQLITE_ROW || sqlite3_column_count(check) != 1 ||
        checkText == NULL || checkBytes != 2 ||
        memcmp(checkText, "ok", 2) != 0) {
        sqlite3_finalize(check);
        result.error = msCopyError("PRAGMA quick_check failed");
        sqlite3_close(db);
        return result;
    }
    rc = sqlite3_step(check);
    if (rc != SQLITE_DONE) {
        sqlite3_finalize(check);
        result.error = msCopyError(
            rc == SQLITE_ROW ? "PRAGMA quick_check returned multiple rows"
                             : "PRAGMA quick_check step failed");
        sqlite3_close(db);
        return result;
    }
    sqlite3_finalize(check);

    // Node table: id, map_id, stamp, pose.
    sqlite3_stmt *nodeStmt = NULL;
    rc = sqlite3_prepare_v2(
        db,
        "SELECT id, map_id, stamp, pose FROM Node ORDER BY id;",
        -1, &nodeStmt, NULL);
    if (rc != SQLITE_OK) {
        result.error = msCopyError(sqlite3_errmsg(db));
        sqlite3_close(db);
        return result;
    }
    int64_t nodeCapacity = 0;
    int64_t nodeCount = 0;
    MSMobileGraphNodeC *nodes = NULL;
    while (true) {
        rc = sqlite3_step(nodeStmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) {
            free(nodes);
            sqlite3_finalize(nodeStmt);
            sqlite3_close(db);
            result.error = msCopyError("Node query step failed");
            return result;
        }
        if (!msEnsureCapacity(
                (void **)&nodes, &nodeCapacity, nodeCount,
                MS_MOBILE_GRAPH_MAX_NODES, sizeof(MSMobileGraphNodeC))) {
            free(nodes);
            sqlite3_finalize(nodeStmt);
            sqlite3_close(db);
            result.error = msCopyError(
                nodeCount >= MS_MOBILE_GRAPH_MAX_NODES
                    ? "Node count exceeds product hard maximum"
                    : "out of memory growing nodes");
            return result;
        }
        MSMobileGraphNodeC *node = &nodes[nodeCount];
        memset(node, 0, sizeof(*node));
        node->id = (int64_t)sqlite3_column_int64(nodeStmt, 0);
        node->map_id = sqlite3_column_int(nodeStmt, 1);
        node->stamp = sqlite3_column_double(nodeStmt, 2);
        if (!std::isfinite(node->stamp) ||
            sqlite3_column_type(nodeStmt, 3) != SQLITE_BLOB ||
            !msCopyFloat12(
                sqlite3_column_blob(nodeStmt, 3),
                sqlite3_column_bytes(nodeStmt, 3),
                node->pose)) {
            free(nodes);
            sqlite3_finalize(nodeStmt);
            sqlite3_close(db);
            result.error = msCopyError("Node row has invalid stamp or exact pose BLOB");
            return result;
        }
        nodeCount += 1;
    }
    sqlite3_finalize(nodeStmt);

    // Link table: from_id, to_id, type, transform, information_matrix.
    sqlite3_stmt *linkStmt = NULL;
    rc = sqlite3_prepare_v2(
        db,
        "SELECT from_id, to_id, type, transform, information_matrix "
        "FROM Link ORDER BY from_id, to_id;",
        -1, &linkStmt, NULL);
    if (rc != SQLITE_OK) {
        free(nodes);
        result.error = msCopyError(sqlite3_errmsg(db));
        sqlite3_close(db);
        return result;
    }
    int64_t linkCapacity = 0;
    int64_t linkCount = 0;
    MSMobileGraphLinkC *links = NULL;
    while (true) {
        rc = sqlite3_step(linkStmt);
        if (rc == SQLITE_DONE) break;
        if (rc != SQLITE_ROW) {
            free(nodes);
            free(links);
            sqlite3_finalize(linkStmt);
            sqlite3_close(db);
            result.error = msCopyError("Link query step failed");
            return result;
        }
        if (!msEnsureCapacity(
                (void **)&links, &linkCapacity, linkCount,
                MS_MOBILE_GRAPH_MAX_LINKS, sizeof(MSMobileGraphLinkC))) {
            free(nodes);
            free(links);
            sqlite3_finalize(linkStmt);
            sqlite3_close(db);
            result.error = msCopyError(
                linkCount >= MS_MOBILE_GRAPH_MAX_LINKS
                    ? "Link count exceeds product hard maximum"
                    : "out of memory growing links");
            return result;
        }
        MSMobileGraphLinkC *link = &links[linkCount];
        memset(link, 0, sizeof(*link));
        link->from = (int64_t)sqlite3_column_int64(linkStmt, 0);
        link->to = (int64_t)sqlite3_column_int64(linkStmt, 1);
        link->type = sqlite3_column_int(linkStmt, 2);
        if (sqlite3_column_type(linkStmt, 3) != SQLITE_BLOB ||
            sqlite3_column_type(linkStmt, 4) != SQLITE_BLOB ||
            !msCopyFloat12(
                sqlite3_column_blob(linkStmt, 3),
                sqlite3_column_bytes(linkStmt, 3),
                link->transform) ||
            !msCopyDouble36(
                sqlite3_column_blob(linkStmt, 4),
                sqlite3_column_bytes(linkStmt, 4),
                link->information)) {
            free(nodes);
            free(links);
            sqlite3_finalize(linkStmt);
            sqlite3_close(db);
            result.error = msCopyError(
                "Link row has invalid exact transform/information BLOB");
            return result;
        }
        linkCount += 1;
    }
    sqlite3_finalize(linkStmt);

    sqlite3_close(db);

    result.nodes = nodes;
    result.node_count = nodeCount;
    result.links = links;
    result.link_count = linkCount;
    return result;
}

void MSMobileGraphReaderFree(MSMobileGraphReadResult *result) {
    if (result == NULL) {
        return;
    }
    if (result->nodes != NULL) {
        free(result->nodes);
        result->nodes = NULL;
    }
    if (result->links != NULL) {
        free(result->links);
        result->links = NULL;
    }
    if (result->error != NULL) {
        free(result->error);
        result->error = NULL;
    }
    result->node_count = 0;
    result->link_count = 0;
}
