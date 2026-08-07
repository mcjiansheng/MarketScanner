import Foundation

/// Swift-facing wrapper over the in-process RTAB-Map graph reader
/// (Mobile-Only V1R1 Gate E, section 9.4).
///
/// The reader opens the snapshot database read-only (`mode=ro&immutable=1`),
/// preserves the raw 3D node poses and link measurements, and lets the
/// business layer project to SE(2) under a recorded projection policy
/// version.
struct MobileGraphNode {
    var id: Int64
    var stamp: Double
    var mapID: Int32
    /// Raw 3D pose, row-major 3x4 (R | t). Never projected here.
    var poseRowMajor3x4: [Double]
}

struct MobileGraphLink {
    var from: Int64
    var to: Int64
    var type: Int32
    /// Raw SE(3) measurement, row-major 3x4.
    var transformRowMajor3x4: [Double]
    /// 6x6 information matrix (inverse covariance), row-major, 36 values.
    var information6x6: [Double]
}

struct MobileGraphReadout {
    var nodes: [MobileGraphNode]
    var links: [MobileGraphLink]
    /// Recorded projection policy version (business layer projects the
    /// raw 3D poses to SE(2) with this policy).
    var projectionPolicyVersion: Int
}

enum MobileGraphReaderError: Error, LocalizedError {
    case readFailed(String)
    case integrityFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let detail): return "数据库图读取失败：\(detail)"
        case .integrityFailed(let detail): return "数据库完整性校验失败：\(detail)"
        }
    }
}

enum MobileGraphReader {

    static let maximumNodeCount: Int64 = 200_000
    static let maximumLinkCount: Int64 = 400_000
    static let expectedProjectionPolicyVersion: Int32 = 1

    /// Reads the raw graph of the (immutable snapshot) database.
    static func readGraph(databaseURL: URL) throws -> MobileGraphReadout {
        var result = MSMobileGraphReaderRead(databaseURL.path)
        defer { MSMobileGraphReaderFree(&result) }

        if let error = result.error {
            let message = String(cString: error)
            if message.contains("quick_check") {
                throw MobileGraphReaderError.integrityFailed(message)
            }
            throw MobileGraphReaderError.readFailed(message)
        }

        guard result.node_count >= 0,
              result.node_count <= maximumNodeCount else {
            throw MobileGraphReaderError.readFailed(
                "node count out of bounds: \(result.node_count)")
        }
        guard result.link_count >= 0,
              result.link_count <= maximumLinkCount else {
            throw MobileGraphReaderError.readFailed(
                "link count out of bounds: \(result.link_count)")
        }
        guard (result.node_count == 0) == (result.nodes == nil) else {
            throw MobileGraphReaderError.readFailed(
                "node pointer/count mismatch")
        }
        guard (result.link_count == 0) == (result.links == nil) else {
            throw MobileGraphReaderError.readFailed(
                "link pointer/count mismatch")
        }
        guard result.projection_policy_version == expectedProjectionPolicyVersion else {
            throw MobileGraphReaderError.readFailed(
                "projection policy version mismatch: "
                + "\(result.projection_policy_version) != "
                + "\(expectedProjectionPolicyVersion)")
        }

        var nodes: [MobileGraphNode] = []
        nodes.reserveCapacity(Int(result.node_count))
        var nodeIDs = Set<Int64>()
        if let buffer = result.nodes {
            for index in 0..<result.node_count {
                let raw = buffer[Int(index)]
                let pose = tupleToArray(raw.pose)
                guard raw.id > 0, nodeIDs.insert(raw.id).inserted else {
                    throw MobileGraphReaderError.readFailed(
                        "node id must be positive and unique: \(raw.id)")
                }
                guard raw.stamp.isFinite, pose.count == 12,
                      pose.allSatisfy({ $0.isFinite }) else {
                    throw MobileGraphReaderError.readFailed(
                        "node \(raw.id) contains non-finite or malformed data")
                }
                nodes.append(MobileGraphNode(
                    id: raw.id,
                    stamp: raw.stamp,
                    mapID: raw.map_id,
                    poseRowMajor3x4: pose))
            }
        }

        var links: [MobileGraphLink] = []
        links.reserveCapacity(Int(result.link_count))
        if let buffer = result.links {
            for index in 0..<result.link_count {
                let raw = buffer[Int(index)]
                let transform = tupleToArray(raw.transform)
                let information = tupleToArray(raw.information)
                guard nodeIDs.contains(raw.from), nodeIDs.contains(raw.to) else {
                    throw MobileGraphReaderError.readFailed(
                        "link endpoint missing from node inventory: "
                        + "\(raw.from)->\(raw.to)")
                }
                guard transform.count == 12,
                      information.count == 36,
                      transform.allSatisfy({ $0.isFinite }),
                      information.allSatisfy({ $0.isFinite }) else {
                    throw MobileGraphReaderError.readFailed(
                        "link \(raw.from)->\(raw.to) contains non-finite or malformed data")
                }
                links.append(MobileGraphLink(
                    from: raw.from,
                    to: raw.to,
                    type: raw.type,
                    transformRowMajor3x4: transform,
                    information6x6: information))
            }
        }
        return MobileGraphReadout(
            nodes: nodes,
            links: links,
            projectionPolicyVersion: Int(result.projection_policy_version))
    }

    /// Converts a C fixed-size array (imported into Swift as a tuple) to
    /// a `[Double]`. The C layout is a contiguous run of doubles.
    private static func tupleToArray<T>(_ tuple: T) -> [Double] {
        return withUnsafeBytes(of: tuple) { buffer in
            Array(buffer.bindMemory(to: Double.self))
        }
    }

    /// Projects a raw 3x4 pose to SE(2): keeps the x/y translation and
    /// the yaw from the rotation block. The projection policy version is
    /// recorded so trajectory/tag code can audit which convention it ran
    /// under.
    static func projectToSE2(
        poseRowMajor3x4: [Double]
    ) throws -> SE2Transform {
        guard poseRowMajor3x4.count == 12,
              poseRowMajor3x4.allSatisfy({ $0.isFinite }) else {
            throw MobileGraphReaderError.readFailed(
                "SE(2) projection requires exactly 12 finite pose values")
        }
        let x = poseRowMajor3x4[3]
        let y = poseRowMajor3x4[7]
        // Rotation block r11/r21 (column 0 of the 3x3 rotation).
        let r11 = poseRowMajor3x4[0]
        let r21 = poseRowMajor3x4[4]
        guard hypot(r11, r21) > Double.ulpOfOne else {
            throw MobileGraphReaderError.readFailed(
                "SE(2) projection has a degenerate horizontal rotation")
        }
        let yaw = atan2(r21, r11)
        guard yaw.isFinite else {
            throw MobileGraphReaderError.readFailed(
                "SE(2) projection produced non-finite yaw")
        }
        return SE2Transform(xM: x, yM: y, yawRad: yaw)
    }
}
