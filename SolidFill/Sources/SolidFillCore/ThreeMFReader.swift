import Foundation

/// Reads 3MF packages (core spec + production extension `p:path`, as written by Bambu/Orca/Prusa slicers),
/// resolving components and build transforms into a single mesh in millimetres.
enum ThreeMFReader {
    struct Component { var path: String?; var id: Int; var xf: Affine }
    struct Object { var verts: [Float] = []; var tris: [Int32] = []; var comps: [Component] = []; var isModel = true }
    struct Item { var id: Int; var xf: Affine }
    struct Model { var unit = 1.0; var objects: [Int: Object] = [:]; var items: [Item] = []; var order: [Int] = [] }

    static func unitScale(_ s: String) -> Double {
        switch s { case "micron": return 0.001; case "centimeter": return 10; case "meter": return 1000
        case "inch": return 25.4; case "foot": return 304.8; default: return 1 }
    }

    static func read(url: URL) throws -> TriMesh {
        let zip = try ZipArchive(url: url)
        var rootPath = "3D/3dmodel.model"
        if let rels = try? zip.read("_rels/.rels"), let s = String(data: rels, encoding: .utf8),
           let r = s.range(of: "Target=\""), let e = s[r.upperBound...].firstIndex(of: "\"") {
            // take the relationship whose type ends with 3dmodel
            for part in s.components(separatedBy: "<Relationship ") where part.contains("3dmodel") && !part.contains("thumbnail") {
                if let a = part.range(of: "Target=\""), let b = part[a.upperBound...].firstIndex(of: "\"") {
                    rootPath = String(part[a.upperBound..<b]); break
                }
            }
            _ = e
        }
        if rootPath.hasPrefix("/") { rootPath.removeFirst() }
        if zip.entries[rootPath] == nil, let alt = zip.names.first(where: { $0.lowercased().hasSuffix(".model") }) { rootPath = alt }

        var cache: [String: Model] = [:]
        func loadModel(_ path: String) throws -> Model {
            var p = path; if p.hasPrefix("/") { p.removeFirst() }
            if let m = cache[p] { return m }
            let m = parse(try zip.read(p)); cache[p] = m; return m
        }
        let root = try loadModel(rootPath)
        var out = TriMesh()
        let scale = root.unit

        func emit(_ model: Model, path: String, id: Int, xf: Affine, depth: Int) throws {
            guard depth < 16, let o = model.objects[id], o.isModel else { return }
            if !o.verts.isEmpty {
                let base = Int32(out.vertexCount)
                out.vertices.reserveCapacity(out.vertices.count + o.verts.count)
                var i = 0
                while i < o.verts.count {
                    let p = xf.apply(SIMD3(Double(o.verts[i]), Double(o.verts[i + 1]), Double(o.verts[i + 2]))) * scale
                    out.vertices.append(Float(p.x)); out.vertices.append(Float(p.y)); out.vertices.append(Float(p.z))
                    i += 3
                }
                out.indices.reserveCapacity(out.indices.count + o.tris.count)
                for t in o.tris { out.indices.append(t + base) }
            }
            for c in o.comps {
                let childModel = c.path != nil ? try loadModel(c.path!) : model
                try emit(childModel, path: c.path ?? path, id: c.id, xf: c.xf.then(xf), depth: depth + 1)
            }
        }

        if !root.items.isEmpty {
            for it in root.items { try emit(root, path: rootPath, id: it.id, xf: it.xf, depth: 0) }
        } else {
            var referenced = Set<Int>()
            for o in root.objects.values { for c in o.comps where c.path == nil { referenced.insert(c.id) } }
            for id in root.order where !referenced.contains(id) { try emit(root, path: rootPath, id: id, xf: Affine(), depth: 0) }
        }
        guard out.triangleCount > 0 else { throw SolidFillError.invalid("Nenhuma malha encontrada no 3MF") }
        return out
    }

    // MARK: - Tiny streaming XML scanner

    static func parse(_ data: Data) -> Model {
        var model = Model()
        var cur: Int? = nil
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let n = raw.count

            @inline(__always) func attr(_ s: Int, _ e: Int, _ key: StaticString) -> (Int, Int)? {
                var i = s
                let kp = key.utf8Start, kl = key.utf8CodeUnitCount
                while i < e {
                    while i < e && (b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13 || b[i] == 47) { i += 1 }
                    let ks = i
                    while i < e && b[i] != 61 && b[i] != 32 { i += 1 }
                    let kn = i - ks
                    while i < e && (b[i] == 61 || b[i] == 32) { i += 1 }
                    guard i < e else { return nil }
                    let q = b[i]; i += 1
                    let vs = i
                    while i < e && b[i] != q { i += 1 }
                    if kn == kl && memcmp(b + ks, kp, kl) == 0 { return (vs, i) }
                    i += 1
                }
                return nil
            }
            @inline(__always) func num(_ r: (Int, Int)?) -> Float { r == nil ? 0 : (b + r!.0).withMemoryRebound(to: CChar.self, capacity: 1) { strtof($0, nil) } }
            @inline(__always) func int(_ r: (Int, Int)?) -> Int {
                guard let r = r else { return 0 }
                var v = 0, i = r.0; while i < r.1, b[i] >= 48, b[i] <= 57 { v = v * 10 + Int(b[i] - 48); i += 1 }; return v
            }
            func str(_ r: (Int, Int)?) -> String? { r == nil ? nil : String(decoding: UnsafeBufferPointer(start: b + r!.0, count: r!.1 - r!.0), as: UTF8.self) }
            func xform(_ r: (Int, Int)?) -> Affine {
                guard let s = str(r) else { return Affine() }
                let v = s.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                return Affine(values: v)
            }
            @inline(__always) func isName(_ s: Int, _ l: Int, _ k: StaticString) -> Bool { l == k.utf8CodeUnitCount && memcmp(b + s, k.utf8Start, l) == 0 }

            var i = 0
            while i < n {
                guard let lt = memchr(b + i, 60, n - i) else { break }
                i = b.distance(to: lt.assumingMemoryBound(to: UInt8.self)) + 1
                guard i < n else { break }
                if b[i] == 33 || b[i] == 63 { // <! or <?
                    guard let gt = memchr(b + i, 62, n - i) else { break }
                    i = b.distance(to: gt.assumingMemoryBound(to: UInt8.self)) + 1; continue
                }
                let closing = b[i] == 47
                if closing { i += 1 }
                let ns = i
                while i < n && b[i] != 32 && b[i] != 62 && b[i] != 47 && b[i] != 10 && b[i] != 13 && b[i] != 9 { i += 1 }
                let nl = i - ns
                guard let gt = memchr(b + i, 62, n - i) else { break }
                let te = b.distance(to: gt.assumingMemoryBound(to: UInt8.self))
                if closing {
                    if isName(ns, nl, "object") { cur = nil }
                } else if isName(ns, nl, "vertex") {
                    if let c = cur {
                        model.objects[c]!.verts.append(num(attr(i, te, "x")))
                        model.objects[c]!.verts.append(num(attr(i, te, "y")))
                        model.objects[c]!.verts.append(num(attr(i, te, "z")))
                    }
                } else if isName(ns, nl, "triangle") {
                    if let c = cur {
                        model.objects[c]!.tris.append(Int32(int(attr(i, te, "v1"))))
                        model.objects[c]!.tris.append(Int32(int(attr(i, te, "v2"))))
                        model.objects[c]!.tris.append(Int32(int(attr(i, te, "v3"))))
                    }
                } else if isName(ns, nl, "object") {
                    let id = int(attr(i, te, "id"))
                    var o = Object()
                    let t = str(attr(i, te, "type")) ?? "model"
                    o.isModel = (t == "model")
                    model.objects[id] = o; model.order.append(id)
                    let selfClose = b[te - 1] == 47
                    cur = selfClose ? nil : id
                } else if isName(ns, nl, "component") {
                    if let c = cur {
                        model.objects[c]!.comps.append(Component(path: str(attr(i, te, "p:path")), id: int(attr(i, te, "objectid")), xf: xform(attr(i, te, "transform"))))
                    }
                } else if isName(ns, nl, "item") {
                    model.items.append(Item(id: int(attr(i, te, "objectid")), xf: xform(attr(i, te, "transform"))))
                } else if isName(ns, nl, "model") {
                    if let u = str(attr(i, te, "unit")) { model.unit = unitScale(u) }
                }
                i = te + 1
            }
        }
        return model
    }
}
