import Foundation

public enum SolidFillError: LocalizedError {
    case unsupported(String)
    case invalid(String)
    case tooBig(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let s), .invalid(let s), .tooBig(let s): return s
        }
    }
}

/// Indexed triangle mesh. Units are millimetres once loaded through `MeshIO`.
public struct TriMesh {
    public var vertices: [Float] = []   // x y z ...
    public var indices: [Int32] = []    // 3 per triangle
    public init() {}
    public init(vertices: [Float], indices: [Int32]) { self.vertices = vertices; self.indices = indices }
    public var vertexCount: Int { vertices.count / 3 }
    public var triangleCount: Int { indices.count / 3 }

    public func bounds() -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        guard vertices.count >= 3 else { return nil }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        vertices.withUnsafeBufferPointer { p in
            var i = 0
            while i < p.count {
                let v = SIMD3<Float>(p[i], p[i + 1], p[i + 2])
                lo = pointwiseMin(lo, v); hi = pointwiseMax(hi, v); i += 3
            }
        }
        return (SIMD3<Double>(lo), SIMD3<Double>(hi))
    }

    /// Signed volume (mm^3); positive when triangles are wound counter-clockwise seen from outside.
    public func signedVolume() -> Double {
        var vol = 0.0
        vertices.withUnsafeBufferPointer { v in
            indices.withUnsafeBufferPointer { t in
                var k = 0
                while k < t.count {
                    let a = Int(t[k]) * 3, b = Int(t[k + 1]) * 3, c = Int(t[k + 2]) * 3
                    let pa = SIMD3<Double>(Double(v[a]), Double(v[a + 1]), Double(v[a + 2]))
                    let pb = SIMD3<Double>(Double(v[b]), Double(v[b + 1]), Double(v[b + 2]))
                    let pc = SIMD3<Double>(Double(v[c]), Double(v[c + 1]), Double(v[c + 2]))
                    let cr = SIMD3<Double>(pb.y * pc.z - pb.z * pc.y, pb.z * pc.x - pb.x * pc.z, pb.x * pc.y - pb.y * pc.x)
                    vol += (pa.x * cr.x + pa.y * cr.y + pa.z * cr.z) / 6.0
                    k += 3
                }
            }
        }
        return vol
    }
}

/// 3MF-style affine transform (row-vector convention): p' = p * M + t.
public struct Affine {
    public var r0 = SIMD3<Double>(1, 0, 0), r1 = SIMD3<Double>(0, 1, 0), r2 = SIMD3<Double>(0, 0, 1)
    public var t = SIMD3<Double>(0, 0, 0)
    public init() {}
    public init(values m: [Double]) {
        guard m.count == 12 else { return }
        r0 = SIMD3(m[0], m[1], m[2]); r1 = SIMD3(m[3], m[4], m[5]); r2 = SIMD3(m[6], m[7], m[8]); t = SIMD3(m[9], m[10], m[11])
    }
    @inline(__always) public func apply(_ p: SIMD3<Double>) -> SIMD3<Double> { p.x * r0 + p.y * r1 + p.z * r2 + t }
    @inline(__always) func lin(_ p: SIMD3<Double>) -> SIMD3<Double> { p.x * r0 + p.y * r1 + p.z * r2 }
    /// Apply `self` first, then `outer`.
    public func then(_ outer: Affine) -> Affine {
        var o = Affine()
        o.r0 = outer.lin(r0); o.r1 = outer.lin(r1); o.r2 = outer.lin(r2); o.t = outer.apply(t)
        return o
    }
}
