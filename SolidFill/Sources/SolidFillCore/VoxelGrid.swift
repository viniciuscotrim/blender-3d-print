import Foundation

/// Voxel cell states.
public enum Cell {
    public static let empty: UInt8 = 0
    public static let surface: UInt8 = 1     // touched by the model's skin
    public static let exterior: UInt8 = 2    // reachable from outside
    public static let sentinel: UInt8 = 3    // outer shell of the grid (never solid)
    public static let band: UInt8 = 4        // temporary seal band (counts as solid unless eroded back)
    public static let void: UInt8 = 9        // internal cavity left empty (support mode)
    public static let support: UInt8 = 10    // support structure inside a cavity
    public static let hollow: UInt8 = 11     // small cavity left empty on purpose (bridgeable, no support)
}

public final class VoxelGrid {
    public let nx: Int, ny: Int, nz: Int
    public let origin: SIMD3<Double>
    public let h: Double
    public let data: UnsafeMutablePointer<UInt8>
    public var count: Int { nx * ny * nz }

    public init(nx: Int, ny: Int, nz: Int, origin: SIMD3<Double>, h: Double) {
        self.nx = nx; self.ny = ny; self.nz = nz; self.origin = origin; self.h = h
        data = UnsafeMutablePointer<UInt8>.allocate(capacity: nx * ny * nz)
        data.initialize(repeating: 0, count: nx * ny * nz)
    }
    deinit { data.deallocate() }

    @inline(__always) public func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * ny + y) * nx + x }
    @inline(__always) public static func isSolid(_ v: UInt8) -> Bool { v != Cell.exterior && v != Cell.sentinel && v != Cell.void && v != Cell.hollow }
}

// MARK: - Rasterization (triangle / voxel overlap, conservative)

enum Rasterizer {
    /// Triangle vs. unit-cube overlap (Akenine-Möller SAT); all points are relative to the cube centre, half-size 0.5.
    @inline(__always)
    static func triBox(_ v0: SIMD3<Double>, _ v1: SIMD3<Double>, _ v2: SIMD3<Double>) -> Bool {
        let hh = 0.5
        // bbox axes
        if min(v0.x, v1.x, v2.x) > hh || max(v0.x, v1.x, v2.x) < -hh { return false }
        if min(v0.y, v1.y, v2.y) > hh || max(v0.y, v1.y, v2.y) < -hh { return false }
        if min(v0.z, v1.z, v2.z) > hh || max(v0.z, v1.z, v2.z) < -hh { return false }
        let e0 = v1 - v0, e1 = v2 - v1, e2 = v0 - v2
        // plane
        let n = SIMD3<Double>(e0.y * e1.z - e0.z * e1.y, e0.z * e1.x - e0.x * e1.z, e0.x * e1.y - e0.y * e1.x)
        let d = n.x * v0.x + n.y * v0.y + n.z * v0.z
        if abs(d) > hh * (abs(n.x) + abs(n.y) + abs(n.z)) { return false }
        // 9 edge cross axes
        @inline(__always) func axis(_ a: SIMD3<Double>) -> Bool {
            let p0 = a.x * v0.x + a.y * v0.y + a.z * v0.z
            let p1 = a.x * v1.x + a.y * v1.y + a.z * v1.z
            let p2 = a.x * v2.x + a.y * v2.y + a.z * v2.z
            let r = hh * (abs(a.x) + abs(a.y) + abs(a.z))
            return !(min(p0, p1, p2) > r || max(p0, p1, p2) < -r)
        }
        for e in [e0, e1, e2] {
            if !axis(SIMD3(0, -e.z, e.y)) { return false }
            if !axis(SIMD3(e.z, 0, -e.x)) { return false }
            if !axis(SIMD3(-e.y, e.x, 0)) { return false }
        }
        return true
    }

    /// Mark all voxels overlapped by the triangle (coordinates already in grid space: voxel (i,j,k) spans [i,i+1)).
    static func rasterize(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
                          g: UnsafeMutablePointer<UInt8>, nx: Int, ny: Int, nz: Int, depth: Int = 0) {
        let lo = pointwiseMin(pointwiseMin(a, b), c), hi = pointwiseMax(pointwiseMax(a, b), c)
        let x0 = max(0, Int(lo.x.rounded(.down))), y0 = max(0, Int(lo.y.rounded(.down))), z0 = max(0, Int(lo.z.rounded(.down)))
        let x1 = min(nx - 1, Int(hi.x.rounded(.down))), y1 = min(ny - 1, Int(hi.y.rounded(.down))), z1 = min(nz - 1, Int(hi.z.rounded(.down)))
        if x1 < x0 || y1 < y0 || z1 < z0 { return }
        let cells = (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1)
        if cells == 1 { g[(z0 * ny + y0) * nx + x0] = Cell.surface; return }
        if cells > 512 && depth < 24 {
            let ab = (a + b) * 0.5, bc = (b + c) * 0.5, ca = (c + a) * 0.5
            rasterize(a, ab, ca, g: g, nx: nx, ny: ny, nz: nz, depth: depth + 1)
            rasterize(ab, b, bc, g: g, nx: nx, ny: ny, nz: nz, depth: depth + 1)
            rasterize(ca, bc, c, g: g, nx: nx, ny: ny, nz: nz, depth: depth + 1)
            rasterize(ab, bc, ca, g: g, nx: nx, ny: ny, nz: nz, depth: depth + 1)
            return
        }
        for z in z0...z1 { for y in y0...y1 {
            var id = (z * ny + y) * nx + x0
            for x in x0...x1 {
                if g[id] == 0 {
                    let cen = SIMD3<Double>(Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5)
                    if triBox(a - cen, b - cen, c - cen) { g[id] = Cell.surface }
                }
                id += 1
            }
        } }
    }
}
