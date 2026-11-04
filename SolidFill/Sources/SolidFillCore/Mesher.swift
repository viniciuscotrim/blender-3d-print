import Foundation

/// Greedy voxel meshing with T-junction repair and vertex welding, so the output is a watertight indexed mesh.
enum Mesher {
    static func mesh(grid: VoxelGrid) throws -> TriMesh {
        let dim = [grid.nx, grid.ny, grid.nz]
        let stride = [1, grid.nx, grid.nx * grid.ny]
        let g = grid.data
        var axisQuads = [[Int32]](repeating: [], count: 3)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 3) { d in
            let u = (d + 1) % 3, w = (d + 2) % 3
            let du = dim[u], dw = dim[w]
            var mask = [Int8](repeating: 0, count: du * dw)
            var quads = [Int32]()
            for s in 0...dim[d] {
                var any = false
                for j in 0..<dw {
                    for i in 0..<du {
                        let idx = i * stride[u] + j * stride[w] + s * stride[d]
                        let a = s > 0 && VoxelGrid.isSolid(g[idx - stride[d]])
                        let b = s < dim[d] && VoxelGrid.isSolid(g[idx])
                        let m: Int8 = a == b ? 0 : (a ? 1 : -1)
                        mask[j * du + i] = m; if m != 0 { any = true }
                    }
                }
                if !any { continue }
                for j in 0..<dw {
                    var i = 0
                    while i < du {
                        let m = mask[j * du + i]
                        if m == 0 { i += 1; continue }
                        var wd = 1
                        while i + wd < du && mask[j * du + i + wd] == m { wd += 1 }
                        var ht = 1
                        outer: while j + ht < dw {
                            for k in 0..<wd where mask[(j + ht) * du + i + k] != m { break outer }
                            ht += 1
                        }
                        for jj in 0..<ht { for k in 0..<wd { mask[(j + jj) * du + i + k] = 0 } }
                        let cc = [(0, 0), (wd, 0), (wd, ht), (0, ht)]
                        for k in 0..<4 {
                            let (du_, dw_) = cc[m > 0 ? k : 3 - k]
                            var c = [0, 0, 0]; c[d] = s; c[u] = i + du_; c[w] = j + dw_
                            quads.append(Int32(c[0])); quads.append(Int32(c[1])); quads.append(Int32(c[2]))
                        }
                        i += wd
                    }
                }
            }
            lock.lock(); axisQuads[d] = quads; lock.unlock()
        }
        let Q = axisQuads[0] + axisQuads[1] + axisQuads[2]
        let nq = Q.count / 12
        guard nq > 0 else { throw SolidFillError.invalid("Nenhum volume sólido gerado") }

        // Weld corners
        @inline(__always) func key(_ x: Int32, _ y: Int32, _ z: Int32) -> UInt64 { (UInt64(x) << 42) | (UInt64(y) << 21) | UInt64(z) }
        var ids = [UInt64: Int32](minimumCapacity: nq * 3)
        var verts = [Float](); verts.reserveCapacity(nq * 12)
        let o = grid.origin, h = grid.h
        for q in 0..<(nq * 4) {
            let x = Q[q * 3], y = Q[q * 3 + 1], z = Q[q * 3 + 2]
            let k = key(x, y, z)
            if ids[k] == nil {
                ids[k] = Int32(verts.count / 3)
                verts.append(Float(o.x + Double(x) * h)); verts.append(Float(o.y + Double(y) * h)); verts.append(Float(o.z + Double(z) * h))
            }
        }
        // Triangulate each quad, inserting lattice vertices that neighbouring quads put on its edges (T-junctions)
        var tris = [Int32](); tris.reserveCapacity(nq * 8)
        var bx = [Int32](), by = [Int32](), bz = [Int32]()
        for q in 0..<nq {
            let base = q * 12
            bx.removeAll(keepingCapacity: true); by.removeAll(keepingCapacity: true); bz.removeAll(keepingCapacity: true)
            for e in 0..<4 {
                let a = base + e * 3, b = base + ((e + 1) & 3) * 3
                let dx = Int32((Q[b] > Q[a] ? 1 : 0) - (Q[b] < Q[a] ? 1 : 0))
                let dy = Int32((Q[b + 1] > Q[a + 1] ? 1 : 0) - (Q[b + 1] < Q[a + 1] ? 1 : 0))
                let dz = Int32((Q[b + 2] > Q[a + 2] ? 1 : 0) - (Q[b + 2] < Q[a + 2] ? 1 : 0))
                let len = max(abs(Q[b] - Q[a]), abs(Q[b + 1] - Q[a + 1]), abs(Q[b + 2] - Q[a + 2]))
                bx.append(Q[a]); by.append(Q[a + 1]); bz.append(Q[a + 2])
                if len > 1 {
                    for t in 1..<len {
                        let x = Q[a] + dx * t, y = Q[a + 1] + dy * t, z = Q[a + 2] + dz * t
                        if ids[key(x, y, z)] != nil { bx.append(x); by.append(y); bz.append(z) }
                    }
                }
            }
            let nb = bx.count
            if nb == 4 {
                let i0 = ids[key(bx[0], by[0], bz[0])]!, i1 = ids[key(bx[1], by[1], bz[1])]!
                let i2 = ids[key(bx[2], by[2], bz[2])]!, i3 = ids[key(bx[3], by[3], bz[3])]!
                tris.append(contentsOf: [i0, i1, i2, i0, i2, i3])
            } else {
                var cx = 0.0, cy = 0.0, cz = 0.0
                for k in 0..<4 { cx += Double(Q[base + k * 3]); cy += Double(Q[base + k * 3 + 1]); cz += Double(Q[base + k * 3 + 2]) }
                let c = Int32(verts.count / 3)
                verts.append(Float(o.x + cx / 4 * h)); verts.append(Float(o.y + cy / 4 * h)); verts.append(Float(o.z + cz / 4 * h))
                for k in 0..<nb {
                    let i0 = ids[key(bx[k], by[k], bz[k])]!, i1 = ids[key(bx[(k + 1) % nb], by[(k + 1) % nb], bz[(k + 1) % nb])]!
                    tris.append(contentsOf: [c, i0, i1])
                }
            }
        }
        return TriMesh(vertices: verts, indices: tris)
    }
}
