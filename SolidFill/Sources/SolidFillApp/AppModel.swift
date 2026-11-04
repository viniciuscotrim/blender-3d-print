import SwiftUI
import SceneKit
import UniformTypeIdentifiers
import SolidFillCore

@MainActor
final class AppModel: ObservableObject {
    @Published var inputURL: URL?
    @Published var inputInfo = ""
    @Published var inputGeometry: SCNGeometry?
    @Published var outputGeometry: SCNGeometry?
    @Published var result: FillResult?
    @Published var resultInfo = ""

    @Published var voxelSize = 0.15
    @Published var sealMM = 0.0
    @Published var interiorOnly = false { didSet { if interiorOnly && sealMM == 0 { sealMM = 8 } } }
    @Published var visibilityPct = 2.0
    @Published var supportOn = false
    @Published var sup = SupportSettings()
    @Published var hasSupports = false
    @Published var format: MeshFormat = .threeMF

    @Published var status = "Arraste um arquivo 3MF, STL ou OBJ para começar."
    @Published var progress = 0.0
    @Published var busy = false
    @Published var errorText: String?

    @Published var showOutput = true
    @Published var sliceAxis = 2 { didSet { sliceIndex = 0.5; refreshSlice() } }
    @Published var sliceIndex = 0.5 { didSet { refreshSlice() } }   // 0...1
    @Published var sliceImage: CGImage?
    @Published var modelID = 0
    /// A Bambu Studio project whose settings are reused when exporting 3MF from a non-Bambu input (STL/OBJ).
    @Published var profileURL: URL? = UserDefaults.standard.string(forKey: "bambuProfilePath").map { URL(fileURLWithPath: $0) }

    func chooseProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = UTType(filenameExtension: "3mf").map { [$0] } ?? []
        panel.message = "Escolha um projeto .3mf salvo no Bambu Studio (impressora, filamento e suportes)."
        guard panel.runModal() == .OK, let u = panel.url else { return }
        profileURL = u; UserDefaults.standard.set(u.path, forKey: "bambuProfilePath")
    }
    func clearProfile() { profileURL = nil; UserDefaults.standard.removeObject(forKey: "bambuProfilePath") }
    @Published var simplifyPreview = true { didSet { if oldValue != simplifyPreview { rebuildPreviews() } } }
    @Published var inputTriangles = 0
    @Published var outputTriangles = 0
    @Published var inputPreviewTriangles = 0
    @Published var outputPreviewTriangles = 0
    @Published var colorLayers = true { didSet { refreshSlice() } }
    @Published var capImage: CGImage?
    @Published var zoomRequest = ZoomRequest(id: 0, factor: 1)

    func zoom3D(_ factor: Double) { zoomRequest = ZoomRequest(id: zoomRequest.id + 1, factor: factor) }

    /// Clip plane + cap description for the 3D view (nil = whole model).
    var clip: ClipInfo? {
        guard showOutput, let g = result?.grid else { return nil }
        let depth = SliceRenderer.size(grid: g, axis: sliceAxis).depth
        let k = Int(sliceIndex * Double(depth - 1))
        if k >= depth - 1 { return nil }
        let center = SIMD3<Double>(g.origin.x + Double(g.nx) * g.h / 2, g.origin.y + Double(g.ny) * g.h / 2, g.origin.z + Double(g.nz) * g.h / 2)
        return ClipInfo(axis: sliceAxis, coord: g.origin[sliceAxis] + Double(k + 1) * g.h, center: center,
                        size: SIMD3(Double(g.nx) * g.h, Double(g.ny) * g.h, Double(g.nz) * g.h), image: capImage)
    }

    private var inputMesh: TriMesh?

    static let supported: [UTType] = ["3mf", "stl", "obj"].compactMap { UTType(filenameExtension: $0) }

    func load(url: URL) {
        guard MeshFormat(url: url) != nil else { errorText = "Formato não suportado: .\(url.pathExtension)"; return }
        busy = true; progress = 0; errorText = nil; result = nil; outputGeometry = nil; sliceImage = nil; capImage = nil; resultInfo = ""
        status = "Lendo \(url.lastPathComponent)…"
        inputURL = url; modelID += 1
        let simplify = simplifyPreview
        Task.detached(priority: .userInitiated) {
            do {
                let mesh = try MeshReader.read(url: url)
                let geo = MeshPreview.geometry(mesh, maxTriangles: 1_500_000, simplify: simplify)
                let e = mesh.bounds().map { $0.max - $0.min } ?? .zero
                let info = String(format: "%d triângulos · %.1f × %.1f × %.1f mm", mesh.triangleCount, e.x, e.y, e.z)
                await MainActor.run {
                    self.inputMesh = mesh; self.inputGeometry = geo; self.inputInfo = info
                    self.inputTriangles = mesh.triangleCount; self.inputPreviewTriangles = geo.elements.first?.primitiveCount ?? 0
                    self.outputTriangles = 0; self.outputPreviewTriangles = 0
                    self.showOutput = false; self.busy = false; self.status = "Pronto para preencher."
                }
            } catch {
                await MainActor.run { self.busy = false; self.errorText = error.localizedDescription; self.status = "Falha ao ler o arquivo." }
            }
        }
    }

    func process() {
        guard let mesh = inputMesh, !busy else { return }
        var s = FillSettings(); s.voxelSize = voxelSize; s.sealOpenings = sealMM
        s.support = supportOn ? sup : nil
        s.interiorOnly = interiorOnly; s.visibilityThreshold = visibilityPct / 100
        busy = true; progress = 0; errorText = nil; status = "Processando…"
        let simplify = simplifyPreview
        Task.detached(priority: .userInitiated) {
            do {
                let r = try SolidFiller.run(mesh: mesh, settings: s) { stage, f in
                    Task { @MainActor in self.status = stage; self.progress = f }
                }
                let geo = MeshPreview.geometry(r.mesh, maxTriangles: 4_000_000, simplify: simplify)
                let st = r.stats
                let vox = st.voxelSize * st.voxelSize * st.voxelSize / 1000
                let info = String(format: "voxel %.3f mm%@ · %.1f cm³ sólido · %d triângulos", st.voxelSize,
                                  st.coarsened ? " (ajustado)" : "", st.solidVolumeMM3 / 1000, st.triangles)
                var info2 = info
                if s.support != nil {
                    info2 += st.supportedCavities + st.bridgedCavities == 0 ? "\nNenhuma cavidade vazia encontrada (aumente \"Selar aberturas\" se há furos)."
                        : String(format: "\n%d com suporte · %d em ponte · vazio %.1f cm³ · suporte %.2f cm³", st.supportedCavities, st.bridgedCavities, Double(st.voidVoxels) * vox, Double(st.supportVoxels) * vox)
                }
                await MainActor.run {
                    self.outputTriangles = r.mesh.triangleCount; self.outputPreviewTriangles = geo.elements.first?.primitiveCount ?? 0
                    self.sliceIndex = 1.0; self.result = r; self.outputGeometry = geo; self.resultInfo = info2; self.hasSupports = st.supportVoxels > 0
                    self.showOutput = true; self.busy = false; self.progress = 1
                    self.status = "Concluído. Confira o corte e exporte."
                    self.refreshSlice()
                }
            } catch {
                await MainActor.run { self.busy = false; self.errorText = error.localizedDescription; self.status = "Falha no processamento." }
            }
        }
    }

    /// Regenerates both preview geometries after the simplification toggle changes.
    private func rebuildPreviews() {
        let simplify = simplifyPreview
        let inMesh = inputMesh, outMesh = result?.mesh
        guard inMesh != nil || outMesh != nil else { return }
        Task.detached(priority: .userInitiated) {
            let gi = inMesh.map { MeshPreview.geometry($0, maxTriangles: 1_500_000, simplify: simplify) }
            let go = outMesh.map { MeshPreview.geometry($0, maxTriangles: 4_000_000, simplify: simplify) }
            await MainActor.run {
                if let gi { self.inputGeometry = gi; self.inputPreviewTriangles = gi.elements.first?.primitiveCount ?? 0 }
                if let go { self.outputGeometry = go; self.outputPreviewTriangles = go.elements.first?.primitiveCount ?? 0 }
            }
        }
    }

    func refreshSlice() {
        guard let g = result?.grid else { return }
        let depth = SliceRenderer.size(grid: g, axis: sliceAxis).depth
        let k = Int(sliceIndex * Double(depth - 1))
        sliceImage = SliceRenderer.image(grid: g, axis: sliceAxis, index: k)
        capImage = SliceRenderer.image(grid: g, axis: sliceAxis, index: k, colored: colorLayers, transparentOutside: true)
    }

    func export() {
        guard let r = result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = UTType(filenameExtension: format.rawValue).map { [$0] } ?? []
        let base = inputURL?.deletingPathExtension().lastPathComponent ?? "modelo"
        panel.nameFieldStringValue = "\(base)_solido.\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; status = "Gravando \(url.lastPathComponent)…"
        let fmt = format
        let tmpl = inputURL.flatMap { $0.pathExtension.lowercased() == "3mf" ? $0 : profileURL }
        Task.detached {
            do {
                try MeshWriter.write(r.mesh, to: url, format: fmt, template: tmpl)
                await MainActor.run { self.busy = false; self.status = "Salvo: \(url.path)"; NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } catch {
                await MainActor.run { self.busy = false; self.errorText = error.localizedDescription }
            }
        }
    }
}

struct ZoomRequest: Equatable { var id: Int; var factor: Double }

struct ClipInfo {
    var axis: Int
    var coord: Double
    var center: SIMD3<Double>
    var size: SIMD3<Double>
    var image: CGImage?
}

enum MeshPreview {
    /// Merges all vertices that fall in the same cell of a regular grid; degenerate triangles are dropped.
    static func cluster(_ mesh: TriMesh, budget: Int) -> TriMesh {
        guard let b = mesh.bounds() else { return mesh }
        let ext = b.max - b.min
        let longest = max(ext.x, ext.y, ext.z, 1e-9)
        func pass(_ n: Double) -> TriMesh {
            let cell = longest / n
            let lo = SIMD3<Float>(b.min)
            let inv = Float(1 / cell)
            var ids = [UInt64: Int32](minimumCapacity: 1 << 16)
            var remap = [Int32](repeating: 0, count: mesh.vertexCount)
            var sum = [SIMD3<Float>](), cnt = [Float]()
            mesh.vertices.withUnsafeBufferPointer { v in
                for i in 0..<mesh.vertexCount {
                    let p = (SIMD3<Float>(v[i * 3], v[i * 3 + 1], v[i * 3 + 2]) - lo) * inv
                    let key = (UInt64(max(0, p.x)) << 42) | (UInt64(max(0, p.y)) << 21) | UInt64(max(0, p.z))
                    let q = SIMD3<Float>(v[i * 3], v[i * 3 + 1], v[i * 3 + 2])
                    if let id = ids[key] { remap[i] = id; sum[Int(id)] += q; cnt[Int(id)] += 1 }
                    else { let id = Int32(sum.count); ids[key] = id; remap[i] = id; sum.append(q); cnt.append(1) }
                }
            }
            var out = TriMesh()
            out.vertices.reserveCapacity(sum.count * 3)
            for i in 0..<sum.count { let p = sum[i] / cnt[i]; out.vertices += [p.x, p.y, p.z] }
            out.indices.reserveCapacity(min(mesh.indices.count, budget * 6))
            var k = 0
            while k < mesh.indices.count {
                let a = remap[Int(mesh.indices[k])], c1 = remap[Int(mesh.indices[k + 1])], c2 = remap[Int(mesh.indices[k + 2])]
                if a != c1 && c1 != c2 && a != c2 { out.indices += [a, c1, c2] }
                k += 3
            }
            return out
        }
        var n = max(16, (Double(budget) / 2).squareRoot() * 1.5)
        var best = pass(n)
        for _ in 0..<4 where best.triangleCount > budget {
            n *= max(0.3, min(0.95, (Double(budget) / Double(best.triangleCount)).squareRoot() * 0.95))
            best = pass(n)
        }
        return best.triangleCount > 0 ? best : mesh
    }

    static let clipShader = """
    #pragma arguments
    float3 clipAxis;
    float clipPos;
    #pragma body
    float4 mp = scn_node.inverseModelViewTransform * float4(_surface.position, 1.0);
    if (dot(mp.xyz, clipAxis) > clipPos) { discard_fragment(); }
    """

    /// Builds a smooth-shaded SceneKit geometry. Very large meshes are sampled for preview only.
    /// With `simplify`, meshes above `maxTriangles` are reduced by vertex clustering (closed silhouette, no holes).
    /// Without it the full mesh is shown, whatever its size.
    static func geometry(_ input: TriMesh, maxTriangles: Int, simplify: Bool) -> SCNGeometry {
        let mesh = simplify && input.triangleCount > maxTriangles ? cluster(input, budget: maxTriangles) : input
        let idx = mesh.indices
        var normals = [Float](repeating: 0, count: mesh.vertices.count)
        mesh.vertices.withUnsafeBufferPointer { v in
            var k = 0
            while k < idx.count {
                let a = Int(idx[k]) * 3, b = Int(idx[k + 1]) * 3, c = Int(idx[k + 2]) * 3
                let u = SIMD3<Float>(v[b] - v[a], v[b + 1] - v[a + 1], v[b + 2] - v[a + 2])
                let w = SIMD3<Float>(v[c] - v[a], v[c + 1] - v[a + 1], v[c + 2] - v[a + 2])
                let n = SIMD3<Float>(u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x)
                for i in [a, b, c] { normals[i] += n.x; normals[i + 1] += n.y; normals[i + 2] += n.z }
                k += 3
            }
        }
        var i = 0
        while i < normals.count {
            let l = (normals[i] * normals[i] + normals[i + 1] * normals[i + 1] + normals[i + 2] * normals[i + 2]).squareRoot()
            if l > 0 { normals[i] /= l; normals[i + 1] /= l; normals[i + 2] /= l }
            i += 3
        }
        let vc = mesh.vertexCount
        let vsrc = SCNGeometrySource(data: Data(bytes: mesh.vertices, count: mesh.vertices.count * 4), semantic: .vertex,
                                     vectorCount: vc, usesFloatComponents: true, componentsPerVector: 3,
                                     bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let nsrc = SCNGeometrySource(data: Data(bytes: normals, count: normals.count * 4), semantic: .normal,
                                     vectorCount: vc, usesFloatComponents: true, componentsPerVector: 3,
                                     bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        let el = SCNGeometryElement(data: Data(bytes: idx, count: idx.count * 4), primitiveType: .triangles,
                                    primitiveCount: idx.count / 3, bytesPerIndex: 4)
        let geo = SCNGeometry(sources: [vsrc, nsrc], elements: [el])
        let m = SCNMaterial()
        m.diffuse.contents = NSColor(white: 0.82, alpha: 1); m.isDoubleSided = true; m.lightingModel = .blinn
        m.shaderModifiers = [.fragment: clipShader]
        m.setValue(SCNVector3(0, 0, 1), forKey: "clipAxis"); m.setValue(NSNumber(value: 1e9), forKey: "clipPos")
        geo.materials = [m]
        return geo
    }
}
