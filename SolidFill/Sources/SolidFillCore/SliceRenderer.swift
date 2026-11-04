import Foundation
import CoreGraphics

/// Renders a 2-D cross-section of the voxel grid so the user can check what was filled.
public enum SliceRenderer {
    public static func size(grid: VoxelGrid, axis: Int) -> (w: Int, h: Int, depth: Int) {
        switch axis {
        case 0: return (grid.ny, grid.nz, grid.nx)
        case 1: return (grid.nx, grid.nz, grid.ny)
        default: return (grid.nx, grid.ny, grid.nz)
        }
    }

    /// `colored` distinguishes filled interior from the original skin; `transparentOutside` makes the exterior see-through
    /// (used as a cap texture in the 3D view).
    public static func image(grid: VoxelGrid, axis: Int, index: Int, colored: Bool = true, transparentOutside: Bool = false) -> CGImage? {
        let (w, h, depth) = size(grid: grid, axis: axis)
        let k = max(0, min(depth - 1, index))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let g = grid.data
        for r in 0..<h {
            for c in 0..<w {
                let (x, y, z): (Int, Int, Int)
                switch axis {
                case 0: (x, y, z) = (k, c, h - 1 - r)
                case 1: (x, y, z) = (c, k, h - 1 - r)
                default: (x, y, z) = (c, h - 1 - r, k)
                }
                let v = g[grid.index(x, y, z)]
                let (R, G, B, A): (UInt8, UInt8, UInt8, UInt8)
                switch v {
                case Cell.surface: (R, G, B, A) = colored ? (215, 215, 215, 255) : (200, 200, 205, 255)
                case Cell.empty, Cell.band: (R, G, B, A) = colored ? (60, 140, 240, 255) : (200, 200, 205, 255)   // interior that was filled
                case Cell.void, Cell.hollow: (R, G, B, A) = transparentOutside ? (0, 0, 0, 0) : (52, 52, 76, 255)          // empty cavity
                case Cell.support: (R, G, B, A) = colored ? (245, 160, 40, 255) : (200, 200, 205, 255)
                default: (R, G, B, A) = transparentOutside ? (0, 0, 0, 0) : (28, 28, 32, 255)                  // outside
                }
                let o = (r * w + c) * 4
                px[o] = R; px[o + 1] = G; px[o + 2] = B; px[o + 3] = A
            }
        }
        return px.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}
