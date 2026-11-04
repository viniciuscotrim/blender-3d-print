import Foundation
import Compression

/// Minimal ZIP reader/writer (stored + deflate) built on the Compression framework.
public final class ZipArchive {
    public struct Entry { public let name: String; let method: UInt16; let csize: Int; let usize: Int; let offset: Int }
    let data: Data
    public private(set) var entries: [String: Entry] = [:]
    public var names: [String] { Array(entries.keys) }

    public init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        try data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            let n = b.count
            guard n >= 22 else { throw SolidFillError.invalid("Arquivo ZIP/3MF inválido") }
            var eocd = -1
            var i = n - 22
            let lo = max(0, n - 22 - 65535)
            while i >= lo {
                if b.loadUnaligned(fromByteOffset: i, as: UInt32.self) == 0x06054b50 { eocd = i; break }
                i -= 1
            }
            guard eocd >= 0 else { throw SolidFillError.invalid("Diretório central do ZIP não encontrado") }
            let count = Int(b.loadUnaligned(fromByteOffset: eocd + 10, as: UInt16.self))
            var p = Int(b.loadUnaligned(fromByteOffset: eocd + 16, as: UInt32.self))
            for _ in 0..<count {
                guard p + 46 <= n, b.loadUnaligned(fromByteOffset: p, as: UInt32.self) == 0x02014b50 else { break }
                let method = b.loadUnaligned(fromByteOffset: p + 10, as: UInt16.self)
                let cs = Int(b.loadUnaligned(fromByteOffset: p + 20, as: UInt32.self))
                let us = Int(b.loadUnaligned(fromByteOffset: p + 24, as: UInt32.self))
                let nl = Int(b.loadUnaligned(fromByteOffset: p + 28, as: UInt16.self))
                let el = Int(b.loadUnaligned(fromByteOffset: p + 30, as: UInt16.self))
                let cl = Int(b.loadUnaligned(fromByteOffset: p + 32, as: UInt16.self))
                let off = Int(b.loadUnaligned(fromByteOffset: p + 42, as: UInt32.self))
                let name = String(decoding: UnsafeRawBufferPointer(rebasing: b[(p + 46)..<(p + 46 + nl)]), as: UTF8.self)
                entries[name] = Entry(name: name, method: method, csize: cs, usize: us, offset: off)
                p += 46 + nl + el + cl
            }
        }
    }

    public func read(_ name: String) throws -> Data {
        var key = name
        if key.hasPrefix("/") { key.removeFirst() }
        guard let e = entries[key] else { throw SolidFillError.invalid("Entrada ausente no pacote: \(name)") }
        return try data.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Data in
            guard e.offset + 30 <= b.count, b.loadUnaligned(fromByteOffset: e.offset, as: UInt32.self) == 0x04034b50 else {
                throw SolidFillError.invalid("Cabeçalho local ZIP inválido")
            }
            let nl = Int(b.loadUnaligned(fromByteOffset: e.offset + 26, as: UInt16.self))
            let el = Int(b.loadUnaligned(fromByteOffset: e.offset + 28, as: UInt16.self))
            let start = e.offset + 30 + nl + el
            guard start + e.csize <= b.count else { throw SolidFillError.invalid("ZIP truncado") }
            if e.method == 0 { return Data(b[start..<(start + e.csize)]) }
            guard e.method == 8 else { throw SolidFillError.unsupported("Compressão ZIP não suportada (\(e.method))") }
            var out = Data(count: e.usize)
            let written = out.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
                guard e.usize > 0 else { return 0 }
                return compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, e.usize,
                                                 b.baseAddress!.assumingMemoryBound(to: UInt8.self) + start, e.csize,
                                                 nil, COMPRESSION_ZLIB)
            }
            guard written == e.usize else { throw SolidFillError.invalid("Falha ao descomprimir \(name)") }
            return out
        }
    }
}

public final class ZipWriter {
    private var out = Data()
    private var central = Data()
    private var count = 0
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i); for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }; return c
    }
    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            table.withUnsafeBufferPointer { t in for x in b { c = t[Int((c ^ UInt32(x)) & 0xFF)] ^ (c >> 8) } }
        }
        return c ^ 0xFFFFFFFF
    }
    private func put<T: FixedWidthInteger>(_ d: inout Data, _ v: T) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

    public init() {}
    public func add(_ name: String, _ content: Data) {
        var method: UInt16 = 0
        var payload = content
        if content.count > 64 {
            var comp = Data(count: content.count + content.count / 50 + 1024)
            let n = comp.withUnsafeMutableBytes { d in content.withUnsafeBytes { s in
                compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, d.count,
                                          s.bindMemory(to: UInt8.self).baseAddress!, s.count, nil, COMPRESSION_ZLIB) } }
            if n > 0 && n < content.count { comp.count = n; payload = comp; method = 8 }
        }
        let crc = ZipWriter.crc32(content)
        let nameData = Data(name.utf8)
        let offset = out.count
        put(&out, UInt32(0x04034b50)); put(&out, UInt16(20)); put(&out, UInt16(0x0800)); put(&out, method)
        put(&out, UInt16(0)); put(&out, UInt16(0x21)); put(&out, crc)
        put(&out, UInt32(payload.count)); put(&out, UInt32(content.count))
        put(&out, UInt16(nameData.count)); put(&out, UInt16(0)); out.append(nameData); out.append(payload)
        put(&central, UInt32(0x02014b50)); put(&central, UInt16(20)); put(&central, UInt16(20)); put(&central, UInt16(0x0800))
        put(&central, method); put(&central, UInt16(0)); put(&central, UInt16(0x21)); put(&central, crc)
        put(&central, UInt32(payload.count)); put(&central, UInt32(content.count))
        put(&central, UInt16(nameData.count)); put(&central, UInt16(0)); put(&central, UInt16(0))
        put(&central, UInt16(0)); put(&central, UInt16(0)); put(&central, UInt32(0)); put(&central, UInt32(offset))
        central.append(nameData); count += 1
    }
    public func finish() -> Data {
        let cdOffset = out.count
        out.append(central)
        put(&out, UInt32(0x06054b50)); put(&out, UInt16(0)); put(&out, UInt16(0))
        put(&out, UInt16(count)); put(&out, UInt16(count)); put(&out, UInt32(central.count)); put(&out, UInt32(cdOffset))
        put(&out, UInt16(0))
        return out
    }
}
