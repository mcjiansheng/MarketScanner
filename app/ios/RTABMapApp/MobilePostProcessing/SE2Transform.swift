import Foundation

/// Minimal SE(2) transform with explicit pose algebra used by the tag
/// position propagation: P_final = T_final_node * inverse(T_raw_node) *
/// P_raw.
struct SE2Transform: Equatable {
    var xM: Double
    var yM: Double
    var yawRad: Double

    static let identity = SE2Transform(xM: 0, yM: 0, yawRad: 0)

    var cosine: Double { cos(yawRad) }
    var sine: Double { sin(yawRad) }

    func applied(to x: Double, _ y: Double) -> (Double, Double) {
        return (xM + cosine * x - sine * y,
                yM + sine * x + cosine * y)
    }

    func appliedYaw(_ yaw: Double) -> Double {
        return SourceGeometry.normalizeAngle(yawRad + yaw)
    }

    func composed(with other: SE2Transform) -> SE2Transform {
        let (nx, ny) = applied(to: other.xM, other.yM)
        return SE2Transform(
            xM: nx, yM: ny, yawRad: appliedYaw(other.yawRad))
    }

    var inverse: SE2Transform {
        let cosNeg = cosine
        let sinNeg = -sine
        let ix = -(cosNeg * xM - sinNeg * yM)
        let iy = -(sinNeg * xM + cosNeg * yM)
        return SE2Transform(xM: ix, yM: iy, yawRad: -yawRad)
    }
}
