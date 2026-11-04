import Foundation

public struct FillSettings {
    /// Voxel edge in mm. Smaller = finer surface, more memory/time.
    public var voxelSize: Double = 0.15
    /// Openings up to this width (mm) are treated as closed, so large cavities reachable only through
    /// small holes/slits get filled. 0 disables sealing.
    public var sealOpenings: Double = 0
    /// "Interior only" mode: after sealing, every sealed-off region is classified as an internal cavity or as an
    /// external gap/groove by how visible it is from outside. Cavities are filled; external regions are restored untouched.
    /// Needs `sealOpenings` > 0 (the seal width is the largest hole that may connect a cavity to the outside).
    public var interiorOnly = false
    /// Interior-only: regions whose average line-of-sight escape fraction is below this (0...1) count as internal cavities.
    public var visibilityThreshold: Double = 0.02
    /// When set, internal cavities are not filled: they stay empty and receive support structure instead.
    /// Uses the same internal/external classification as `interiorOnly`, plus a parity test to tell cavities from material.
    public var support: SupportSettings?
    /// Memory budget: voxelSize is enlarged automatically if the grid would exceed this many voxels.
    public var maxVoxels: Int = 1_600_000_000
    public init() {}
}

public struct FillStats {
    public var voxelSize = 0.0
    public var grid = (0, 0, 0)
    public var sealVoxels = 0
    public var restoredExternalVoxels = 0
    public var cavities = 0
    public var voidVoxels = 0
    public var bridgedCavities = 0
    public var supportedCavities = 0
    public var supportVoxels = 0
    public var solidVolumeMM3 = 0.0
    public var triangles = 0
    public var vertices = 0
    public var coarsened = false
}

public struct FillResult {
    public var mesh: TriMesh
    public var grid: VoxelGrid
    public var stats: FillStats
}

public typealias Progress = (_ stage: String, _ fraction: Double) -> Void

public enum SolidFiller {
    public static func run(mesh: TriMesh, settings: FillSettings, progress: Progress? = nil) throws -> FillResult {
        guard let bb = mesh.bounds(), mesh.triangleCount > 0 else { throw SolidFillError.invalid("Malha vazia") }
        var stats = FillStats()
        var h = max(settings.voxelSize, 0.005)
        var seal = settings.sealOpenings > 0 ? Int((settings.sealOpenings / h / 2).rounded(.up)) : 0
        let ext = bb.max - bb.min

        func dims(_ h: Double, _ pad: Int) -> (Int, Int, Int) {
            (Int((ext.x / h).rounded(.up)) + 2 * pad + 1, Int((ext.y / h).rounded(.up)) + 2 * pad + 1, Int((ext.z / h).rounded(.up)) + 2 * pad + 1)
        }
        var pad = seal + 3
        var d = dims(h, pad)
        while d.0 * d.1 * d.2 > settings.maxVoxels {
            h *= 1.05; stats.coarsened = true
            seal = settings.sealOpenings > 0 ? Int((settings.sealOpenings / h / 2).rounded(.up)) : 0
            pad = seal + 3; d = dims(h, pad)
        }
        guard d.0 * d.1 * d.2 < Int(UInt32.max) else { throw SolidFillError.tooBig("Grade grande demais") }
        let origin = bb.min - SIMD3<Double>(repeating: Double(pad) * h)
        let grid = VoxelGrid(nx: d.0, ny: d.1, nz: d.2, origin: origin, h: h)
        stats.voxelSize = h; stats.grid = d

        // 1. Rasterize the skin ------------------------------------------------------------------
        progress?("Voxelizando superfície", 0.02)
        let tc = mesh.triangleCount
        let g = grid.data, nx = grid.nx, ny = grid.ny, nz = grid.nz
        let chunks = 512
        let done = NSLock(); var finished = 0
        mesh.vertices.withUnsafeBufferPointer { v in mesh.indices.withUnsafeBufferPointer { t in
            DispatchQueue.concurrentPerform(iterations: chunks) { ch in
                let s = tc * ch / chunks, e = tc * (ch + 1) / chunks
                var k = s
                while k < e {
                    @inline(__always) func P(_ i: Int32) -> SIMD3<Double> {
                        let j = Int(i) * 3
                        return (SIMD3<Double>(Double(v[j]), Double(v[j + 1]), Double(v[j + 2])) - origin) / h
                    }
                    Rasterizer.rasterize(P(t[k * 3]), P(t[k * 3 + 1]), P(t[k * 3 + 2]), g: g, nx: nx, ny: ny, nz: nz)
                    k += 1
                }
                done.lock(); finished += 1; let f = Double(finished) / Double(chunks); done.unlock()
                if ch % 16 == 0 { progress?("Voxelizando superfície", 0.02 + 0.28 * f) }
            }
        } }

        // 2. Shell sentinel ---------------------------------------------------------------------
        let sy = nx, sz = nx * ny
        for z in 0..<nz { for y in 0..<ny { for x in 0..<nx where x == 0 || y == 0 || z == 0 || x == nx - 1 || y == ny - 1 || z == nz - 1 {
            g[z * sz + y * sy + x] = Cell.sentinel
        } } }

        // 3. Optional sealing: dilate the skin so small openings close ---------------------------
        var bandList = [UInt32]()
        if seal > 0 {
            progress?("Selando aberturas", 0.32)
            var front = [UInt32](); front.reserveCapacity(1 << 20)
            for i in 0..<grid.count where g[i] == Cell.surface { front.append(UInt32(i)) }
            let offs = [1, -1, sy, -sy, sz, -sz]
            for _ in 0..<seal {
                var next = [UInt32](); next.reserveCapacity(front.count)
                for f in front {
                    let i = Int(f)
                    for o in offs where g[i + o] == Cell.empty { g[i + o] = Cell.band; next.append(UInt32(i + o)) }
                }
                bandList.append(contentsOf: next); front = next
            }
            stats.sealVoxels = bandList.count
        }

        // 4. Flood the exterior ---------------------------------------------------------------------
        progress?("Identificando o exterior", 0.45)
        var cap = 1 << 22, sp = 0
        var stack = UnsafeMutablePointer<UInt32>.allocate(capacity: cap)
        defer { stack.deallocate() }
        let start = grid.index(1, 1, 1)
        g[start] = Cell.exterior; stack[sp] = UInt32(start); sp += 1
        while sp > 0 {
            sp -= 1
            let i = Int(stack[sp])
            for o in [1, -1, sy, -sy, sz, -sz] {
                let j = i + o
                if g[j] == Cell.empty {
                    g[j] = Cell.exterior
                    if sp == cap {
                        let ns = UnsafeMutablePointer<UInt32>.allocate(capacity: cap * 2)
                        ns.update(from: stack, count: cap); stack.deallocate(); stack = ns; cap *= 2
                    }
                    stack[sp] = UInt32(j); sp += 1
                }
            }
        }

        // 5. Erode the seal band back from the exterior side -----------------------------------------
        if seal > 0 {
            progress?("Restaurando superfície", 0.7)
            var remaining = bandList
            let offs = [1, -1, sy, -sy, sz, -sz]
            for _ in 0..<(seal + 1) {
                var flip = [UInt32](), keep = [UInt32]()
                for f in remaining {
                    let i = Int(f)
                    if offs.contains(where: { g[i + $0] == Cell.exterior }) { flip.append(f) } else { keep.append(f) }
                }
                if flip.isEmpty { break }
                for f in flip { g[Int(f)] = Cell.exterior }
                remaining = keep
            }
        }

        // 5b. Interior-only: restore external gaps that sealing swallowed -------------------------------
        if (settings.interiorOnly && seal > 0) || settings.support != nil {
            classifyPockets(grid: grid, threshold: settings.visibilityThreshold, support: settings.support,
                            stats: &stats, progress: progress)
        }
        if let sp = settings.support, stats.supportedCavities > 0 {
            stats.supportVoxels = SupportGenerator.generate(grid: grid, settings: sp, progress: progress)
        }

        // 6. Mesh the solid ------------------------------------------------------------------------
        progress?("Gerando malha sólida", 0.78)
        var out = try Mesher.mesh(grid: grid)
        if out.signedVolume() < 0 { // make sure triangles face outward
            for i in 0..<out.triangleCount { out.indices.swapAt(i * 3 + 1, i * 3 + 2) }
        }
        var solid = 0
        for i in 0..<grid.count where VoxelGrid.isSolid(g[i]) { solid += 1 }
        stats.solidVolumeMM3 = Double(solid) * h * h * h
        stats.triangles = out.triangleCount; stats.vertices = out.vertexCount
        progress?("Concluído", 1)
        return FillResult(mesh: out, grid: grid, stats: stats)
    }

    // MARK: - Interior / exterior classification

    /// Unit directions spread evenly over the sphere (Fibonacci lattice).
    private static func sphereDirections(_ n: Int) -> [SIMD3<Float>] {
        let ga = Float.pi * (3 - Float(5).squareRoot())
        return (0..<n).map { i in
            let y = 1 - 2 * (Float(i) + 0.5) / Float(n), r = (1 - y * y).squareRoot(), a = ga * Float(i)
            return SIMD3(r * cos(a), y, r * sin(a))
        }
    }

    /// Mean fraction of directions that escape to the outside from the sampled cells (surface voxels block, exterior/sentinel escape).
    private static func escapeFraction(g: UnsafeMutablePointer<UInt8>, nx: Int, ny: Int, cells: [UInt32],
                                       dirs: [SIMD3<Float>], maxSamples: Int) -> Double {
        let stride = max(1, cells.count / maxSamples)
        let samples = Array(Swift.stride(from: 0, to: cells.count, by: stride)).map { cells[$0] }
        let lock = NSLock(); var total = 0.0
        let chunks = samples.count > 16 ? min(samples.count, 32) : 1
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            var escaped = 0
            var k = c
            while k < samples.count {
                let i = Int(samples[k])
                let start = SIMD3<Float>(Float(i % nx) + 0.5, Float((i / nx) % ny) + 0.5, Float(i / (nx * ny)) + 0.5)
                for d in dirs {
                    var p = start; let step = d * 0.6
                    while true {
                        p += step
                        let v = g[(Int(p.z) * ny + Int(p.y)) * nx + Int(p.x)]
                        if v == Cell.surface { break }
                        if v == Cell.exterior || v == Cell.sentinel { escaped += 1; break }
                    }
                }
                k += chunks
            }
            lock.lock(); total += Double(escaped); lock.unlock()
        }
        return total / Double(samples.count * dirs.count)
    }

    /// Ray parity test on the skin: a region inside the part's material is crossed an odd number of times going
    /// outward, an empty cavity (bounded by inner surfaces) an even number. Majority vote over several cells and 6 directions.
    private static func isHollow(g: UnsafeMutablePointer<UInt8>, nx: Int, ny: Int, nz: Int, cells: [UInt32]) -> Bool {
        let n = cells.count
        let picks = Set([0, n / 3, 2 * n / 3, n - 1]).map { Int(cells[$0]) }
        var odd = 0, total = 0
        let steps = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
        for c in picks {
            let x0 = c % nx, y0 = (c / nx) % ny, z0 = c / (nx * ny)
            for (dx, dy, dz) in steps {
                var x = x0, y = y0, z = z0, runs = 0, prev = false
                while x >= 0, x < nx, y >= 0, y < ny, z >= 0, z < nz {
                    let isSurf = g[(z * ny + y) * nx + x] == Cell.surface
                    if isSurf && !prev { runs += 1 }
                    prev = isSurf
                    x += dx; y += dy; z += dz
                }
                if runs & 1 == 1 { odd += 1 }
                total += 1
            }
        }
        return odd * 2 < total       // ties count as material, so nothing is hollowed by accident
    }

    /// Widest unsupported ceiling of a cavity, in voxels: for a sample of unsupported ceiling cells, the shorter of the
    /// unsupported runs along x and y (a bridge spans the shorter way); the maximum over the sample.
    private static func bridgeSpan(g: UnsafeMutablePointer<UInt8>, nx: Int, ny: Int, nz: Int, cells: [UInt32],
                                   offsets: [(Int, Int)]) -> Int {
        let sz = nx * ny
        @inline(__always) func inCavity(_ v: UInt8) -> Bool { v == 5 || v == 6 }
        @inline(__always) func isModel(_ v: UInt8) -> Bool { !(inCavity(v) || v == Cell.void || v == Cell.support || v == Cell.hollow) }
        func unsupportedCeiling(_ x: Int, _ y: Int, _ z: Int) -> Bool {
            guard x > 0, x < nx - 1, y > 0, y < ny - 1, z >= 0, z < nz - 1 else { return false }
            let i = z * sz + y * nx + x
            guard inCavity(g[i]), isModel(g[i + sz]) else { return false }
            for (dx, dy) in offsets where dx != 0 || dy != 0 {
                let xx = x + dx, yy = y + dy
                if xx >= 0, xx < nx, yy >= 0, yy < ny, isModel(g[z * sz + yy * nx + xx]) { return false }
            }
            return true
        }
        func run(_ x: Int, _ y: Int, _ z: Int, _ dx: Int, _ dy: Int) -> Int {
            var n = 1, a = 1
            while n < 4000, unsupportedCeiling(x + dx * a, y + dy * a, z) { n += 1; a += 1 }
            a = 1
            while n < 4000, unsupportedCeiling(x - dx * a, y - dy * a, z) { n += 1; a += 1 }
            return n
        }
        let stride = max(1, cells.count / 200_000)
        var ceil = [Int]()
        var k = 0
        while k < cells.count {
            let i = Int(cells[k]); k += stride
            if unsupportedCeiling(i % nx, (i / nx) % ny, i / sz) { ceil.append(i) }
        }
        let step = max(1, ceil.count / 2000)
        var best = 0
        var j = 0
        while j < ceil.count {
            let i = ceil[j]; j += step
            let x = i % nx, y = (i / nx) % ny, z = i / sz
            best = max(best, min(run(x, y, z, 1, 0), run(x, y, z, 0, 1)))
        }
        return best
    }

    /// Splits the still-solid free space (band + enclosed empty cells) into connected regions, then keeps the
    /// poorly visible ones (internal cavities) filled and turns the visible ones (external gaps/grooves) back to exterior.
    private static func classifyPockets(grid: VoxelGrid, threshold: Double, support: SupportSettings?, stats: inout FillStats, progress: Progress?) {
        let g = grid.data, nx = grid.nx, ny = grid.ny
        let offs = [1, -1, nx, -nx, nx * ny, -nx * ny]
        let dirs = sphereDirections(64)
        let markBand: UInt8 = 5, markEmpty: UInt8 = 6, keepBand: UInt8 = 7, keepEmpty: UInt8 = 8
        @inline(__always) func isFree(_ v: UInt8) -> Bool { v == Cell.band || v == Cell.empty }
        let total = grid.count
        var comp = [UInt32](), stack = [UInt32]()
        var restored = 0, cavities = 0, voids = 0, bridged = 0, supported = 0
        let offsets = SupportGenerator.reachOffsets(angle: support?.thresholdAngle ?? 30)
        var s = 0
        while s < total {
            if !isFree(g[s]) { s += 1; continue }
            if s & 0xFFFFF == 0 { progress?("Separando interior e exterior", 0.85 + 0.1 * Double(s) / Double(total)) }
            comp.removeAll(keepingCapacity: true)
            g[s] = g[s] == Cell.band ? markBand : markEmpty; stack.append(UInt32(s))
            while let i32 = stack.popLast() {
                let i = Int(i32); comp.append(i32)
                for o in offs {
                    let j = i + o, v = g[j]
                    if isFree(v) { g[j] = v == Cell.band ? markBand : markEmpty; stack.append(UInt32(j)) }
                }
            }
            let frac = escapeFraction(g: g, nx: nx, ny: ny, cells: comp, dirs: dirs, maxSamples: 96)
            if frac < threshold {
                cavities += 1
                if let sp = support, isHollow(g: g, nx: nx, ny: ny, nz: grid.nz, cells: comp) {
                    let span = Double(bridgeSpan(g: g, nx: nx, ny: ny, nz: grid.nz, cells: comp, offsets: offsets)) * grid.h
                    if sp.bridgeSpan > 0 && span <= sp.bridgeSpan {            // bridgeable: no support needed
                        bridged += 1
                        if sp.fillBridgeable { for c in comp { g[Int(c)] = g[Int(c)] == markBand ? keepBand : keepEmpty } }
                        else { voids += comp.count; for c in comp { g[Int(c)] = Cell.hollow } }
                    } else {
                        supported += 1; voids += comp.count
                        for c in comp { g[Int(c)] = Cell.void }
                    }
                } else {
                    for c in comp { g[Int(c)] = g[Int(c)] == markBand ? keepBand : keepEmpty }
                }
            } else {
                restored += comp.count
                for c in comp { g[Int(c)] = Cell.exterior }
            }
            s += 1
        }
        for i in 0..<total { if g[i] == keepBand { g[i] = Cell.band } else if g[i] == keepEmpty { g[i] = Cell.empty } }
        stats.restoredExternalVoxels = restored; stats.cavities = cavities; stats.voidVoxels = voids; stats.bridgedCavities = bridged; stats.supportedCavities = supported
    }
}
