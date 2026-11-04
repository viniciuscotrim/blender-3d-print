import Foundation

public enum MeshFormat: String, CaseIterable {
    case threeMF = "3mf", stl = "stl", obj = "obj"
    public init?(url: URL) { self.init(rawValue: url.pathExtension.lowercased()) }
}

// MARK: - Byte helpers

@inline(__always) private func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

/// Parse a float at `p` (strtof stops on the first non-numeric byte).
@inline(__always) private func parseFloat(_ p: UnsafePointer<UInt8>) -> Float {
    p.withMemoryRebound(to: CChar.self, capacity: 1) { strtof($0, nil) }
}

// MARK: - Reading

public enum MeshReader {
    public static func read(url: URL) throws -> TriMesh {
        guard let f = MeshFormat(url: url) else { throw SolidFillError.unsupported("Formato não suportado: .\(url.pathExtension)") }
        switch f {
        case .threeMF: return try ThreeMFReader.read(url: url)
        case .stl: return try readSTL(url: url)
        case .obj: return try readOBJ(url: url)
        }
    }

    static func readSTL(url: URL) throws -> TriMesh {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var mesh = TriMesh()
        try data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            let n = b.count
            if n >= 84 {
                let tc = Int(b.loadUnaligned(fromByteOffset: 80, as: UInt32.self))
                if 84 + tc * 50 == n {
                    mesh.vertices = [Float](unsafeUninitializedCapacity: tc * 9) { buf, cnt in
                        for t in 0..<tc {
                            let o = 84 + t * 50 + 12
                            for k in 0..<9 { buf[t * 9 + k] = b.loadUnaligned(fromByteOffset: o + k * 4, as: Float.self) }
                        }
                        cnt = tc * 9
                    }
                    mesh.indices = (0..<Int32(tc * 3)).map { $0 }
                    return
                }
            }
            // ASCII STL
            let base = b.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let key: [UInt8] = Array("vertex".utf8)
            var verts = [Float]()
            var pos = 0
            while pos < n - 6 {
                guard let hit = key.withUnsafeBytes({ memmem(base + pos, n - pos, $0.baseAddress!, 6) }) else { break }
                var q = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) + 6
                let end = UnsafePointer<UInt8>(base) + n
                for _ in 0..<3 {
                    while q < end && isSpace(q.pointee) { q += 1 }
                    verts.append(parseFloat(q))
                    while q < end && !isSpace(q.pointee) { q += 1 }
                }
                pos = q - base
            }
            guard verts.count >= 9, verts.count % 9 == 0 else { throw SolidFillError.invalid("STL sem triângulos válidos") }
            mesh.vertices = verts
            mesh.indices = (0..<Int32(verts.count / 3)).map { $0 }
        }
        return mesh
    }

    static func readOBJ(url: URL) throws -> TriMesh {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var mesh = TriMesh()
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            let base = b.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let n = b.count
            var i = 0
            var face = [Int32]()
            while i < n {
                // line start
                while i < n && (base[i] == 32 || base[i] == 9) { i += 1 }
                if i + 1 < n && base[i] == 118 && base[i + 1] == 32 { // "v "
                    var q = UnsafePointer<UInt8>(base) + i + 2
                    let end = UnsafePointer<UInt8>(base) + n
                    for _ in 0..<3 {
                        while q < end && isSpace(q.pointee) && q.pointee != 10 { q += 1 }
                        mesh.vertices.append(parseFloat(q))
                        while q < end && !isSpace(q.pointee) { q += 1 }
                    }
                } else if i + 1 < n && base[i] == 102 && (base[i + 1] == 32 || base[i + 1] == 9) { // "f "
                    face.removeAll(keepingCapacity: true)
                    var q = i + 2
                    let vc = Int32(mesh.vertices.count / 3)
                    while q < n && base[q] != 10 && base[q] != 13 {
                        while q < n && (base[q] == 32 || base[q] == 9) { q += 1 }
                        if q >= n || base[q] == 10 || base[q] == 13 { break }
                        var neg = false
                        if base[q] == 45 { neg = true; q += 1 }
                        var v: Int32 = 0
                        while q < n, base[q] >= 48, base[q] <= 57 { v = v * 10 + Int32(base[q] - 48); q += 1 }
                        while q < n && !isSpace(base[q]) { q += 1 } // skip /vt/vn
                        face.append(neg ? vc - v : v - 1)
                    }
                    if face.count >= 3 {
                        for k in 1..<(face.count - 1) { mesh.indices.append(contentsOf: [face[0], face[k], face[k + 1]]) }
                    }
                }
                while i < n && base[i] != 10 { i += 1 }
                i += 1
            }
        }
        guard mesh.triangleCount > 0 else { throw SolidFillError.invalid("OBJ sem faces") }
        let vc = Int32(mesh.vertexCount)
        if mesh.indices.contains(where: { $0 < 0 || $0 >= vc }) { throw SolidFillError.invalid("OBJ com índices inválidos") }
        return mesh
    }
}

// MARK: - Writing

public enum MeshWriter {
    /// `template`: the file the mesh came from. When it is a Bambu Studio project (.3mf), its settings are carried over.
    public static func write(_ mesh: TriMesh, to url: URL, format: MeshFormat? = nil, template: URL? = nil) throws {
        switch format ?? MeshFormat(url: url) ?? .threeMF {
        case .stl: try writeSTL(mesh, to: url)
        case .obj: try writeOBJ(mesh, to: url)
        case .threeMF:
            if let t = template, t.pathExtension.lowercased() == "3mf", let z = try? ZipArchive(url: t),
               z.entries["Metadata/project_settings.config"] != nil {
                try writeBambu3MF(mesh, to: url, template: z)
            } else { try write3MF(mesh, to: url) }
        }
    }

    static func writeSTL(_ m: TriMesh, to url: URL) throws {
        let tc = m.triangleCount
        var d = Data(count: 84 + tc * 50)
        d.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
            let hdr = Array("SolidFill binary STL".utf8)
            for (i, c) in hdr.enumerated() { o[i] = c }
            o.storeBytes(of: UInt32(tc).littleEndian, toByteOffset: 80, as: UInt32.self)
            m.vertices.withUnsafeBufferPointer { v in m.indices.withUnsafeBufferPointer { t in
                for k in 0..<tc {
                    let a = Int(t[k * 3]) * 3, b = Int(t[k * 3 + 1]) * 3, c = Int(t[k * 3 + 2]) * 3
                    let u = SIMD3<Float>(v[b] - v[a], v[b + 1] - v[a + 1], v[b + 2] - v[a + 2])
                    let w = SIMD3<Float>(v[c] - v[a], v[c + 1] - v[a + 1], v[c + 2] - v[a + 2])
                    var n = SIMD3<Float>(u.y * w.z - u.z * w.y, u.z * w.x - u.x * w.z, u.x * w.y - u.y * w.x)
                    let l = (n * n).sum().squareRoot(); if l > 0 { n /= l }
                    let off = 84 + k * 50
                    let vals: [Float] = [n.x, n.y, n.z, v[a], v[a + 1], v[a + 2], v[b], v[b + 1], v[b + 2], v[c], v[c + 1], v[c + 2]]
                    for (j, f) in vals.enumerated() { o.storeBytes(of: f.bitPattern.littleEndian, toByteOffset: off + j * 4, as: UInt32.self) }
                    o.storeBytes(of: UInt16(0), toByteOffset: off + 48, as: UInt16.self)
                }
            } }
        }
        try d.write(to: url)
    }

    static func writeOBJ(_ m: TriMesh, to url: URL) throws {
        var s = "# SolidFill\n"
        s.reserveCapacity(m.vertexCount * 28 + m.triangleCount * 24)
        for i in 0..<m.vertexCount { s += "v \(m.vertices[i * 3]) \(m.vertices[i * 3 + 1]) \(m.vertices[i * 3 + 2])\n" }
        for i in 0..<m.triangleCount { s += "f \(m.indices[i * 3] + 1) \(m.indices[i * 3 + 1] + 1) \(m.indices[i * 3 + 2] + 1)\n" }
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `<mesh>` element body shared by the plain and Bambu writers.
    static func meshXML(_ m: TriMesh) -> String {
        var s = "   <mesh>\n    <vertices>\n"
        s.reserveCapacity(m.vertexCount * 60 + m.triangleCount * 50)
        for i in 0..<m.vertexCount { s += "     <vertex x=\"\(m.vertices[i * 3])\" y=\"\(m.vertices[i * 3 + 1])\" z=\"\(m.vertices[i * 3 + 2])\"/>\n" }
        s += "    </vertices>\n    <triangles>\n"
        for i in 0..<m.triangleCount { s += "     <triangle v1=\"\(m.indices[i * 3])\" v2=\"\(m.indices[i * 3 + 1])\" v3=\"\(m.indices[i * 3 + 2])\"/>\n" }
        s += "    </triangles>\n   </mesh>\n"
        return s
    }

    /// If the mesh lies outside the printer's plate (e.g. it came from an STL in some other coordinate system), move it to the
    /// plate centre and onto the bed. Meshes that are already on the plate are left untouched.
    static func placedOnPlate(_ m: TriMesh, projectSettings: Data) -> TriMesh {
        guard let b = m.bounds(),
              let json = try? JSONSerialization.jsonObject(with: projectSettings) as? [String: Any],
              let area = json["printable_area"] as? [String] else { return m }
        let pts = area.compactMap { a -> (Double, Double)? in
            let p = a.split(separator: "x").compactMap { Double($0) }
            return p.count == 2 ? (p[0], p[1]) : nil
        }
        guard !pts.isEmpty else { return m }
        let x0 = pts.map { $0.0 }.min()!, x1 = pts.map { $0.0 }.max()!, y0 = pts.map { $0.1 }.min()!, y1 = pts.map { $0.1 }.max()!
        if b.min.x >= x0 - 1, b.max.x <= x1 + 1, b.min.y >= y0 - 1, b.max.y <= y1 + 1 { return m }
        let d = SIMD3<Double>((x0 + x1) / 2 - (b.min.x + b.max.x) / 2, (y0 + y1) / 2 - (b.min.y + b.max.y) / 2, -b.min.z)
        var out = m
        var i = 0
        while i < out.vertices.count {
            out.vertices[i] += Float(d.x); out.vertices[i + 1] += Float(d.y); out.vertices[i + 2] += Float(d.z); i += 3
        }
        return out
    }

    /// Writes a Bambu Studio project: the template's `Metadata/` (print/filament/support settings, thumbnails) is kept,
    /// the geometry is replaced by `mesh` (already in plate coordinates, so all transforms are identity).
    static func writeBambu3MF(_ mesh: TriMesh, to url: URL, template t: ZipArchive) throws {
        let m = placedOnPlate(mesh, projectSettings: (try? t.read("Metadata/project_settings.config")) ?? Data())
        func text(_ name: String) -> String { (try? t.read(name)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        func first(_ pattern: String, in s: String) -> String? {
            guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
            return String(s[r])
        }
        func attr(_ s: String) -> String { s.components(separatedBy: "\"").dropFirst(3).first ?? "" }
        let oldMain = text("3D/3dmodel.model")
        let app = first(#"<metadata name="Application">[^<]*</metadata>"#, in: oldMain) ?? "<metadata name=\"Application\">BambuStudio-02.00.00.00</metadata>"
        let ver = first(#"<metadata name="BambuStudio:3mfVersion">[^<]*</metadata>"#, in: oldMain) ?? "<metadata name=\"BambuStudio:3mfVersion\">1</metadata>"
        let name = url.deletingPathExtension().lastPathComponent
        let header = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">

        """
        let uuid = { () -> String in UUID().uuidString.lowercased() }
        let objectModel = header + " " + ver + "\n <resources>\n  <object id=\"1\" p:UUID=\"\(uuid())\" type=\"model\">\n" + meshXML(m) + "  </object>\n </resources>\n <build/>\n</model>\n"
        let thumbs = ["Thumbnail_Middle": "/Metadata/plate_1.png", "Thumbnail_Small": "/Metadata/plate_1_small.png"].filter { t.entries[String($0.value.dropFirst())] != nil }
        var mainModel = header + " " + app + "\n " + ver + "\n <metadata name=\"CreationDate\">\(ISO8601DateFormatter().string(from: Date()).prefix(10))</metadata>\n"
        for (k, v) in thumbs.sorted(by: { $0.key < $1.key }) { mainModel += " <metadata name=\"\(k)\">\(v)</metadata>\n" }
        mainModel += """
         <resources>
          <object id="2" p:UUID="\(uuid())" type="model">
           <components>
            <component p:path="/3D/Objects/object_1.model" objectid="1" p:UUID="\(uuid())" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>
           </components>
          </object>
         </resources>
         <build p:UUID="\(uuid())">
          <item objectid="2" p:UUID="\(uuid())" transform="1 0 0 0 1 0 0 0 1 0 0 0" printable="1"/>
         </build>
        </model>

        """

        // model_settings.config: one object on plate 1; plate-level filament mapping is taken from the template.
        let oldSettings = text("Metadata/model_settings.config")
        let keep = oldSettings.components(separatedBy: "\n").filter {
            $0.contains("key=\"filament_") || $0.contains("key=\"plater_name\"") || $0.contains("key=\"locked\"")
        }.joined(separator: "\n")
        var plateFiles = ""
        for (k, f) in [("thumbnail_file", "plate_1.png"), ("thumbnail_no_light_file", "plate_no_light_1.png"), ("top_file", "top_1.png"), ("pick_file", "pick_1.png")]
        where t.entries["Metadata/" + f] != nil { plateFiles += "    <metadata key=\"\(k)\" value=\"Metadata/\(f)\"/>\n" }
        let esc = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        let settings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config>
          <object id="2">
            <metadata key="name" value="\(esc)"/>
            <metadata key="extruder" value="1"/>
            <metadata face_count="\(m.triangleCount)"/>
            <part id="1" subtype="normal_part" uuid="\(uuid())">
              <metadata key="name" value="\(esc)"/>
              <metadata key="matrix" value="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"/>
              <metadata key="source_file" value="\(esc)"/>
              <metadata key="source_object_id" value="0"/>
              <metadata key="source_volume_id" value="0"/>
              <metadata key="source_offset_x" value="0"/>
              <metadata key="source_offset_y" value="0"/>
              <metadata key="source_offset_z" value="0"/>
              <mesh_stat face_count="\(m.triangleCount)" edges_fixed="0" degenerate_facets="0" facets_removed="0" facets_reversed="0" backwards_edges="0"/>
            </part>
          </object>
          <plate>
            <metadata key="plater_id" value="1"/>
        \(keep.isEmpty ? "" : keep + "\n")\(plateFiles)    <model_instance>
              <metadata key="object_id" value="2"/>
              <metadata key="instance_id" value="0"/>
              <metadata key="identify_id" value="1"/>
            </model_instance>
          </plate>
          <assemble>
           <assemble_item object_id="2" instance_id="0" transform="1 0 0 0 1 0 0 0 1 0 0 0" offset="0 0 0" />
          </assemble>
        </config>

        """

        var rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>

        """
        if t.entries["Metadata/plate_1.png"] != nil {
            rels += " <Relationship Target=\"/Metadata/plate_1.png\" Id=\"rel-2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail\"/>\n"
            rels += " <Relationship Target=\"/Metadata/plate_1.png\" Id=\"rel-4\" Type=\"http://schemas.bambulab.com/package/2021/cover-thumbnail-middle\"/>\n"
        }
        if t.entries["Metadata/plate_1_small.png"] != nil {
            rels += " <Relationship Target=\"/Metadata/plate_1_small.png\" Id=\"rel-5\" Type=\"http://schemas.bambulab.com/package/2021/cover-thumbnail-small\"/>\n"
        }
        rels += "</Relationships>\n"

        let z = ZipWriter()
        z.add("[Content_Types].xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
         <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
         <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
         <Default Extension="png" ContentType="image/png"/>
         <Default Extension="gcode" ContentType="text/x.gcode"/>
        </Types>
        """.utf8))
        z.add("_rels/.rels", Data(rels.utf8))
        z.add("3D/3dmodel.model", Data(mainModel.utf8))
        z.add("3D/_rels/3dmodel.model.rels", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Target="/3D/Objects/object_1.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
        </Relationships>
        """.utf8))
        z.add("3D/Objects/object_1.model", Data(objectModel.utf8))
        z.add("Metadata/model_settings.config", Data(settings.utf8))
        for n in t.names.sorted() where n.hasPrefix("Metadata/") && n != "Metadata/model_settings.config" && !n.hasSuffix("/") {
            if let d = try? t.read(n) { z.add(n, d) }
        }
        try z.finish().write(to: url)
    }

    static func write3MF(_ m: TriMesh, to url: URL) throws {
        let s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <metadata name="Application">SolidFill</metadata>
         <resources>
          <object id="1" type="model">

        """ + meshXML(m) + "  </object>\n </resources>\n <build>\n  <item objectid=\"1\"/>\n </build>\n</model>\n"
        let z = ZipWriter()
        z.add("[Content_Types].xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>
        """.utf8))
        z.add("_rels/.rels", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
        """.utf8))
        z.add("3D/3dmodel.model", Data(s.utf8))
        try z.finish().write(to: url)
    }
}
