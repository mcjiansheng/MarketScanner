#!/usr/bin/env python3
"""Synthetic RTAB-Map graph fixture generator (V1R3 §23.2/§23.3).

Builds a clean, publishable graph with absolute prior-map constraints:
a square loop route with neighbor odometry, loop closures and periodic
priors in the prior-map frame. The produced SQLite database mimics the
RTAB-Map Node/Link schema subset the shared factor-graph core reads, so
the PC oracle and iOS share the exact same input contract.

Usage:
    python3 make_synthetic_graph.py --out-dir <dir> [--nodes 200]
      [--loop-noise 0.02] [--prior-every 20] [--scenario clean|wrong_loops|no_priors]

Scenarios:
    clean          -> expected PASS
    wrong_loops    -> 10% of loops grossly wrong -> robust kernel must
                      downweight them; still PASS when priors dominate
    no_priors      -> expected LOCAL_FRAME_ONLY
    offset_map     -> V1R4 §6.6 golden: the raw graph lives in a local
                      frame that is the map frame transformed by a
                      NON-identity rigid transform (+20 m / +25 m /
                      +90 deg); priors are given in the map frame; the
                      optimizer must rigidly align the whole component,
                      expected PASS with truth-level control error
    conflict_priors-> one node carries two contradicting priors ->
                      expected RECOVERABLE_FAIL (never first-wins)
    partial_priors -> 3 input priors but only 1 is in-graph/valid ->
                      the applied-count gate must refuse PASS
                      (expected LOCAL_FRAME_ONLY)
"""

import argparse
import math
import os
import random
import sqlite3
import struct


def build_route(node_count: int):
    """Square loop, counter-clockwise, side 25 m."""
    side = 25.0
    perimeter = 4.0 * side
    step = perimeter / node_count
    poses = []
    for i in range(node_count):
        d = i * step
        if d < side:
            x, y = d, 0.0
            yaw = 0.0
        elif d < 2 * side:
            x, y = side, d - side
            yaw = math.pi / 2
        elif d < 3 * side:
            x, y = side - (d - 2 * side), side
            yaw = math.pi
        else:
            x, y = 0.0, side - (d - 3 * side)
            yaw = -math.pi / 2
        poses.append((x, y, yaw))
    return poses


def transform_blob(x, y, yaw):
    c, s = math.cos(yaw), math.sin(yaw)
    # row-major 3x4 (R|t)
    m = (c, -s, 0.0, x,
         s, c, 0.0, y,
         0.0, 0.0, 1.0, 0.0)
    return struct.pack("<12f", *m)


def info_blob(xx, yy, yawyaw):
    v = [0.0] * 36
    v[0] = xx
    v[7] = yy
    v[35] = yawyaw
    return struct.pack("<36d", *v)


def relative(x1, y1, yaw1, x2, y2, yaw2):
    c, s = math.cos(yaw1), math.sin(yaw1)
    dx, dy = x2 - x1, y2 - y1
    rx = c * dx + s * dy
    ry = -s * dx + c * dy
    ryaw = yaw2 - yaw1
    while ryaw > math.pi:
        ryaw -= 2 * math.pi
    while ryaw < -math.pi:
        ryaw += 2 * math.pi
    return rx, ry, ryaw


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--nodes", type=int, default=200)
    parser.add_argument("--loop-noise", type=float, default=0.02)
    parser.add_argument("--prior-every", type=int, default=20)
    parser.add_argument("--scenario", default="clean",
                        choices=["clean", "wrong_loops", "no_priors",
                                 "offset_map", "conflict_priors", "partial_priors"])
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()

    random.seed(args.seed)
    os.makedirs(args.out_dir, exist_ok=True)
    db_path = os.path.join(args.out_dir, "synthetic.db")
    priors_path = os.path.join(args.out_dir, "priors.json")
    truth_path = os.path.join(args.out_dir, "truth_map.json")
    if os.path.exists(db_path):
        os.remove(db_path)

    poses = build_route(args.nodes)

    # §6.6: the non-identity map-from-local rigid transform. Raw node
    # poses are stored in the LOCAL frame; priors are in the MAP frame.
    if args.scenario == "offset_map":
        tx, ty, tyaw = 20.0, 25.0, math.pi / 2
    else:
        tx, ty, tyaw = 0.0, 0.0, 0.0
    c0, s0 = math.cos(tyaw), math.sin(tyaw)

    def local_from_map(x, y, yaw):
        # inv(T_map_local): map -> local
        dx, dy = x - tx, y - ty
        return (c0 * dx + s0 * dy, -s0 * dx + c0 * dy, yaw - tyaw)

    # Raw node poses = truth mapped into the local frame + small drift
    # (what an online scanner would have stored before optimization).
    drift = 0.0
    raw = []
    for i, (x, y, yaw) in enumerate(poses):
        drift += random.gauss(0.0, 0.004)
        lx, ly, lyaw = local_from_map(x, y, yaw)
        raw.append((lx + random.gauss(0.0, 0.01) + drift,
                    ly + random.gauss(0.0, 0.01),
                    lyaw + random.gauss(0.0, 0.005)))

    db = sqlite3.connect(db_path)
    db.execute("CREATE TABLE Node (id INTEGER PRIMARY KEY, map_id INTEGER,"
               " weight INTEGER, stamp REAL, pose BLOB)")
    db.execute("CREATE TABLE Link (from_id INTEGER, to_id INTEGER,"
               " type INTEGER, transform BLOB, information_matrix BLOB)")
    t0 = 1700000000.0
    for i in range(args.nodes):
        x, y, yaw = raw[i]
        db.execute("INSERT INTO Node VALUES (?,?,?,?,?)",
                   (i + 1, 0, 1, t0 + i * 0.5, transform_blob(x, y, yaw)))

    # Neighbor links from RAW poses (as RTAB-Map stores them: measured
    # relatives with information).
    for i in range(args.nodes - 1):
        x1, y1, yaw1 = raw[i]
        x2, y2, yaw2 = raw[i + 1]
        rx, ry, ryaw = relative(x1, y1, yaw1, x2, y2, yaw2)
        db.execute("INSERT INTO Link VALUES (?,?,?,?,?)",
                   (i + 1, i + 2, 0, transform_blob(rx, ry, ryaw),
                    info_blob(50.0, 50.0, 80.0)))

    # Loop closures: link the first node to the last, and a mid cross
    # link; RELATIVE measurements are frame-invariant, so truth-local
    # relatives are identical in any rigid frame.
    loop_pairs = [(0, args.nodes - 1), (args.nodes // 4, args.nodes - 1 - args.nodes // 4)]
    for k, (a, b) in enumerate(loop_pairs):
        x1, y1, yaw1 = raw[a]
        x2, y2, yaw2 = raw[b]
        rx, ry, ryaw = relative(x1, y1, yaw1, x2, y2, yaw2)
        noise = 4.0 if (args.scenario == "wrong_loops" and k == 1) else args.loop_noise
        rx += random.gauss(0.0, noise)
        ry += random.gauss(0.0, noise)
        db.execute("INSERT INTO Link VALUES (?,?,?,?,?)",
                   (a + 1, b + 1, 1, transform_blob(rx, ry, ryaw),
                    info_blob(25.0, 25.0, 25.0)))

    db.commit()
    db.close()

    # Absolute priors in the prior-map frame (map frame = truth frame).
    priors = []
    if args.scenario not in ("no_priors",):
        for i in range(0, args.nodes, args.prior_every):
            x, y, yaw = poses[i]
            priors.append({
                "node_id": i + 1,
                "map_x": x + random.gauss(0.0, 0.02),
                "map_y": y + random.gauss(0.0, 0.02),
                "map_yaw": yaw + random.gauss(0.0, 0.01),
                "information_3x3": [20.0, 0.0, 0.0,
                                     0.0, 20.0, 0.0,
                                     0.0, 0.0, 15.0],
                "kind": 0,
                "episode_id": i + 1,
            })
    if args.scenario == "conflict_priors":
        # A second prior on node 1, 5 m away: contradicting cluster.
        priors.append({
            "node_id": 1,
            "map_x": poses[0][0] + 5.0,
            "map_y": poses[0][1] + 5.0,
            "map_yaw": poses[0][2],
            "information_3x3": [20.0, 0.0, 0.0,
                                 0.0, 20.0, 0.0,
                                 0.0, 0.0, 15.0],
            "kind": 0,
            "episode_id": 90001,
        })
    if args.scenario == "partial_priors":
        # Keep exactly ONE in-graph prior; the other two reference nodes
        # that do not exist -> applied count must stay below the gate.
        priors = [priors[0],
                  dict(priors[1], node_id=999901),
                  dict(priors[2], node_id=999902)]
    with open(priors_path, "w", encoding="utf-8") as f:
        f.write("{\"priors\": " + repr(priors).replace("'", "\"").replace("True", "true").replace("False", "false") + "}")

    # Map-frame truth for control-point golden assertions (§6.6).
    truth = {"t_map_local": {"x": tx, "y": ty, "yaw": tyaw},
             "nodes": [{"id": i + 1, "map_x": x, "map_y": y, "map_yaw": yaw}
                       for i, (x, y, yaw) in enumerate(poses)]}
    with open(truth_path, "w", encoding="utf-8") as f:
        import json as _json
        f.write(_json.dumps(truth))
    print(db_path)
    print(priors_path)


if __name__ == "__main__":
    main()
