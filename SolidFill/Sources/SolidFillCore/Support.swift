import Foundation

public enum SupportPattern: String, CaseIterable, Sendable {
    case rectilinear, grid, honeycomb
}

/// Support parameters, named after the Bambu Studio ones. Lengths in mm, angles in degrees.
public struct SupportSettings: Sendable {
    /// Overhangs whose slope (measured from horizontal, 90 = vertical wall) is below this need support.
    public var thresholdAngle = 30.0
    public var pattern: SupportPattern = .rectilinear
    /// Distance between pattern lines (hexagon centre distance for honeycomb).
    public var patternSpacing = 2.5
    public var patternAngle = 0.0
    /// Width of the pattern walls; keep it >= the nozzle width or the slicer drops the lines.
    public var lineWidth = 0.42
    public var topZDistance = 0.2
    public var bottomZDistance = 0.2
    /// Horizontal gap between support and the part's walls.
    public var xyDistance = 0.35
    public var interfaceLayers = 2
    public var interfaceSpacing = 0.5
    /// Print layer height; sets the layer thickness of the interface and the layer-to-layer alternation of the lines.
    public var layerHeight = 0.2
    /// Cavities whose widest unsupported ceiling is at most this wide (mm) are bridgeable and get no support.
    /// 0 = always support.
    public var bridgeSpan = 6.0
    /// What to do with bridgeable cavities: fill them solid (true) or leave them empty (false).
    public var fillBridgeable = true
    public init() {}
}

enum SupportGenerator {
    /// Fills the cavity cells (`Cell.void`) with support structure (`Cell.support`) under unsupported ceilings.
    /// Returns the number of support voxels.
    static func generate(grid: VoxelGrid, settings s: SupportSettings, progress: Progress?) -> Int {
        let nx = grid.nx, ny = grid.ny, nz = grid.nz, g = grid.data, h = grid.h
        let sz = nx * ny

        // Columns that contain cavity cells (linear scan, cache friendly).
        progress?("Procurando cavidades", 0.9)
        var hasVoid = [Bool](repeating: false, count: sz)
        for z in 0..<nz {
            let base = z * sz
            for c in 0..<sz where g[base + c] == Cell.void { hasVoid[c] = true }
        }
        let columns = (0..<sz).filter { hasVoid[$0] }
        if columns.isEmpty { return 0 }

        // Allowed horizontal offset per layer for a given overhang slope: cot(angle), in voxels.
        let offsets = reachOffsets(angle: s.thresholdAngle)
        let gapR = Int((s.xyDistance / h).rounded())
        var gapOffsets = [Int]()
        for dy in -gapR...gapR { for dx in -gapR...gapR where gapR > 0 && dx * dx + dy * dy <= gapR * gapR { gapOffsets.append(dy * nx + dx) } }
        let topGap = Int((s.topZDistance / h).rounded()), botGap = Int((s.bottomZDistance / h).rounded())
        let ifaceCells = max(0, Int((Double(s.interfaceLayers) * s.layerHeight / h).rounded()))
        let layerCells = max(1, Int((s.layerHeight / h).rounded()))
        let ang = s.patternAngle * .pi / 180

        @inline(__always) func isModel(_ v: UInt8) -> Bool { v != Cell.void && v != Cell.support && v != Cell.hollow }
        let lock = NSLock(); var total = 0, doneCols = 0
        let chunks = min(columns.count, 256)
        DispatchQueue.concurrentPerform(iterations: chunks) { ch in
            var count = 0
            var k = ch
            while k < columns.count {
                let col = columns[k]; k += chunks
                let x = col % nx, y = col / nx
                let X = (Double(x) + 0.5) * h, Y = (Double(y) + 0.5) * h
                let wallA = wall(s.pattern, X, Y, s.patternSpacing, s.lineWidth, ang, false)
                let wallB = s.pattern == .honeycomb ? wallA : wall(s.pattern, X, Y, s.patternSpacing, s.lineWidth, ang, true)
                let ifA = wall(.rectilinear, X, Y, s.interfaceSpacing, s.lineWidth, ang, false)
                let ifB = wall(.rectilinear, X, Y, s.interfaceSpacing, s.lineWidth, ang, true)
                var z = 0
                while z < nz {
                    if g[z * sz + col] != Cell.void { z += 1; continue }
                    let z0 = z
                    while z < nz && g[z * sz + col] == Cell.void { z += 1 }
                    let z1 = z - 1                                   // ceiling cell is at z (non-void, sentinel at worst)
                    guard z < nz else { break }
                    // Supported if the layer under the ceiling has part material within the allowed offset.
                    var supported = false
                    for (dx, dy) in offsets where (dx != 0 || dy != 0) {
                        let xx = x + dx, yy = y + dy
                        if xx >= 0, xx < nx, yy >= 0, yy < ny, isModel(g[z1 * sz + yy * nx + xx]) { supported = true; break }
                    }
                    if supported { continue }
                    let top = z1 - topGap, bottom = z0 + botGap
                    if top < bottom { continue }
                    for zz in bottom...top {
                        let alt = (zz / layerCells) & 1 == 1
                        let inIface = ifaceCells > 0 && zz > top - ifaceCells
                        let on: Bool
                        switch s.pattern {
                        case .grid: on = inIface ? (ifA || ifB) : (wallA || wallB)
                        case .rectilinear: on = inIface ? (alt ? ifB : ifA) : (alt ? wallB : wallA)
                        case .honeycomb: on = inIface ? (alt ? ifB : ifA) : wallA
                        }
                        if !on { continue }
                        let idx = zz * sz + col
                        var blocked = false
                        for o in gapOffsets {
                            let j = idx + o
                            if j >= 0, j < grid.count, isModel(g[j]) { blocked = true; break }
                        }
                        if !blocked { g[idx] = Cell.support; count += 1 }
                    }
                }
            }
            lock.lock(); total += count; doneCols += 1; let f = Double(doneCols) / Double(chunks); lock.unlock()
            if ch % 8 == 0 { progress?("Gerando suportes", 0.9 + 0.08 * f) }
        }
        return total
    }

    /// Horizontal neighbour offsets (voxels) within which part material under a cell counts as support for it.
    static func reachOffsets(angle: Double) -> [(Int, Int)] {
        let reach = 1 / tan(max(1, min(89, angle)) * .pi / 180)
        let rr = Int(reach.rounded(.up))
        var offsets = [(Int, Int)]()
        for dy in -rr...rr { for dx in -rr...rr where Double(dx * dx + dy * dy) <= reach * reach + 1e-9 { offsets.append((dx, dy)) } }
        return offsets
    }

    /// Is the point (x, y) on a wall of the pattern? `second` selects the perpendicular line family.
    static func wall(_ p: SupportPattern, _ x: Double, _ y: Double, _ spacing: Double, _ width: Double,
                     _ angle: Double, _ second: Bool) -> Bool {
        let sp = max(spacing, 0.01)
        if width >= sp { return true }
        if p == .honeycomb {
            let rowH = sp * 0.8660254037844386
            let j0 = Int((y / rowH).rounded())
            let i0 = Int(((x - Double(j0) * sp / 2) / sp).rounded())
            var d1 = Double.infinity, d2 = Double.infinity
            var c1 = SIMD2<Double>(0, 0), c2 = SIMD2<Double>(0, 0)
            for j in (j0 - 1)...(j0 + 1) { for i in (i0 - 1)...(i0 + 1) {
                let c = SIMD2<Double>(Double(i) * sp + Double(j) * sp / 2, Double(j) * rowH)
                let d = ((x - c.x) * (x - c.x) + (y - c.y) * (y - c.y)).squareRoot()
                if d < d1 { d2 = d1; c2 = c1; d1 = d; c1 = c } else if d < d2 { d2 = d; c2 = c }
            } }
            let gap = ((c1.x - c2.x) * (c1.x - c2.x) + (c1.y - c2.y) * (c1.y - c2.y)).squareRoot()
            return (d2 * d2 - d1 * d1) / (2 * max(gap, 1e-9)) < width / 2
        }
        let a = angle + (second ? Double.pi / 2 : 0)
        let u = -x * sin(a) + y * cos(a)
        return u - (u / sp).rounded(.down) * sp < width
    }
}
