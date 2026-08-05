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
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

/// Projection policy version: the reader preserves the raw 3D pose; the
/// business layer projects to SE(2) with this recorded policy version.
static const int32_t kMSProjectionPolicyVersion = 1;

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

/// Copies a 3x4 float BLOB (12 floats) into a double array.
static void msCopyFloat12(const void *blob, int blobBytes, double out[12]) {
    for (int index = 0; index < 12; ++index) {
        out[index] = 0.0;
    }
    if (blob == NULL) {
        return;
    }
    int count = blobBytes / (int)sizeof(float);
    if (count > 12) {
        count = 12;
    }
    const float *values = (const float *)blob;
    for (int index = 0; index < count; ++index) {
        out[index] = (double)values[index];
    }
}

/// Copies a 6x6 double BLOB (36 doubles) into a double array.
static void msCopyDouble36(const void *blob, int blobBytes, double out[36]) {
    for (int index = 0; index < 36; ++index) {
        out[index] = 0.0;
    }
    if (blob == NULL) {
        return;
    }
    int count = blobBytes / (int)sizeof(double);
    if (count > 36) {
        count = 36;
    }
    const double *values = (const double *)blob;
    for (int index = 0; index < count; ++index) {
        out[index] = values[index];
    }
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
    char uri[4096];
    snprintf(uri, sizeof(uri), "file:%s?mode=ro&immutable=1", dbPath);
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL);
    if (rc != SQLITE_OK) {
        result.error = msCopyError(sqlite3_errmsg(db));
        if (db != NULL) {
            sqlite3_close(db);
        }
        return result;
    }

    // Quick integrity check of the snapshot copy.
    sqlite3_stmt *check = NULL;
    rc = sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &check, NULL);
    if (rc == SQLITE_OK && check != NULL) {
        if (sqlite3_step(check) == SQLITE_ROW) {
            const unsigned char *text = sqlite3_column_text(check, 0);
            if (text == NULL || strncmp((const char *)text, "ok", 2) != 0) {
                sqlite3_finalize(check);
                result.error = msCopyError("PRAGMA quick_check failed");
                sqlite3_close(db);
                return result;
            }
        }
        sqlite3_finalize(check);
    }

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
    int64_t nodeCapacity = 1024;
    int64_t nodeCount = 0;
    MSMobileGraphNodeC *nodes =
        (MSMobileGraphNodeC *)malloc((size_t)nodeCapacity * sizeof(MSMobileGraphNodeC));
    if (nodes == NULL) {
        sqlite3_finalize(nodeStmt);
        sqlite3_close(db);
        result.error = msCopyError("out of memory for nodes");
        return result;
    }
    while (sqlite3_step(nodeStmt) == SQLITE_ROW) {
        if (nodeCount == nodeCapacity) {
            nodeCapacity *= 2;
            MSMobileGraphNodeC *grown = (MSMobileGraphNodeC *)realloc(
                nodes, (size_t)nodeCapacity * sizeof(MSMobileGraphNodeC));
            if (grown == NULL) {
                free(nodes);
                sqlite3_finalize(nodeStmt);
                sqlite3_close(db);
                result.error = msCopyError("out of memory growing nodes");
                return result;
            }
            nodes = grown;
        }
        MSMobileGraphNodeC *node = &nodes[nodeCount];
        memset(node, 0, sizeof(*node));
        node->id = (int64_t)sqlite3_column_int64(nodeStmt, 0);
        node->map_id = sqlite3_column_int(nodeStmt, 1);
        node->stamp = sqlite3_column_double(nodeStmt, 2);
        msCopyFloat12(
            sqlite3_column_blob(nodeStmt, 3),
            sqlite3_column_bytes(nodeStmt, 3),
            node->pose);
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
    int64_t linkCapacity = 1024;
    int64_t linkCount = 0;
    MSMobileGraphLinkC *links =
        (MSMobileGraphLinkC *)malloc((size_t)linkCapacity * sizeof(MSMobileGraphLinkC));
    if (links == NULL) {
        free(nodes);
        sqlite3_finalize(linkStmt);
        sqlite3_close(db);
        result.error = msCopyError("out of memory for links");
        return result;
    }
    while (sqlite3_step(linkStmt) == SQLITE_ROW) {
        if (linkCount == linkCapacity) {
            linkCapacity *= 2;
            MSMobileGraphLinkC *grown = (MSMobileGraphLinkC *)realloc(
                links, (size_t)linkCapacity * sizeof(MSMobileGraphLinkC));
            if (grown == NULL) {
                free(nodes);
                free(links);
                sqlite3_finalize(linkStmt);
                sqlite3_close(db);
                result.error = msCopyError("out of memory growing links");
                return result;
            }
            links = grown;
        }
        MSMobileGraphLinkC *link = &links[linkCount];
        memset(link, 0, sizeof(*link));
        link->from = (int64_t)sqlite3_column_int64(linkStmt, 0);
        link->to = (int64_t)sqlite3_column_int64(linkStmt, 1);
        link->type = sqlite3_column_int(linkStmt, 2);
        msCopyFloat12(
            sqlite3_column_blob(linkStmt, 3),
            sqlite3_column_bytes(linkStmt, 3),
            link->transform);
        msCopyDouble36(
            sqlite3_column_blob(linkStmt, 4),
            sqlite3_column_bytes(linkStmt, 4),
            link->information);
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
