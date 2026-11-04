import Foundation
import SolidFillCore

func usage() -> Never {
    print("""
    solidfill — preenche o interior de modelos 3D (3MF / STL / OBJ) para impressão sem suporte interno.

    Uso: solidfill <entrada> [saída] [opções]
      --voxel <mm>   tamanho do voxel (padrão 0.15). Menor = mais detalhe, mais memória.
      --seal <mm>    sela aberturas de até <mm> de largura antes de preencher (padrão 0).
      --interior     só preenche cavidades internas; fendas externas (mesmo estreitas) são preservadas. Use com --seal.
      --visibility <%> em --interior: cavidade = região vista de fora em menos de <%> das direções (padrão 2)
      --support      não preenche cavidades internas: gera suportes dentro delas (exterior intocado). Opções, como no Bambu Studio:
                     --support-angle <°> (30)  --pattern rectilinear|grid|honeycomb  --spacing <mm> (2.5)  --pattern-angle <°>
                     --line-width <mm> (0.42)  --top-z <mm> (0.2)  --bottom-z <mm> (0.2)  --xy <mm> (0.35)
                     --bridge <mm> (6): cavidades com vão de teto até <mm> não recebem suporte (0 = sempre suportar); --bridge-empty deixa-as vazias em vez de sólidas
                     --interface-layers <n> (2)  --interface-spacing <mm> (0.5)  --layer-height <mm> (0.2)
      --profile <arq.3mf> projeto do Bambu Studio cujas configurações são usadas ao gravar 3MF a partir de STL/OBJ (a peça é centralizada na mesa)
      --format <f>   3mf | stl | obj (padrão: extensão da saída; sem saída => <nome>_solid.3mf)
    """)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
var s = FillSettings()
var positional = [String](), format: MeshFormat?, profile: URL?
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--voxel": guard let v = args.first.flatMap(Double.init) else { usage() }; s.voxelSize = v; args.removeFirst()
    case "--seal": guard let v = args.first.flatMap(Double.init) else { usage() }; s.sealOpenings = v; args.removeFirst()
    case "--profile": guard let v = args.first else { usage() }; profile = URL(fileURLWithPath: v); args.removeFirst()
    case "--interior": s.interiorOnly = true
    case "--visibility": guard let v = args.first.flatMap(Double.init) else { usage() }; s.visibilityThreshold = v / 100; args.removeFirst()
    case "--support": s.support = s.support ?? SupportSettings()
    case "--bridge-empty": var sp = s.support ?? SupportSettings(); sp.fillBridgeable = false; s.support = sp
    case "--bridge": guard let d = args.first.flatMap(Double.init) else { usage() }; args.removeFirst(); var sp = s.support ?? SupportSettings(); sp.bridgeSpan = d; s.support = sp
    case "--support-angle", "--pattern", "--spacing", "--line-width", "--pattern-angle", "--top-z", "--bottom-z", "--xy", "--interface-layers", "--interface-spacing", "--layer-height":
        guard let v = args.first else { usage() }; args.removeFirst()
        var sp = s.support ?? SupportSettings()
        switch a {
        case "--pattern": guard let pt = SupportPattern(rawValue: v) else { usage() }; sp.pattern = pt
        default:
            guard let d = Double(v) else { usage() }
            switch a {
            case "--support-angle": sp.thresholdAngle = d
            case "--spacing": sp.patternSpacing = d
            case "--line-width": sp.lineWidth = d
            case "--pattern-angle": sp.patternAngle = d
            case "--top-z": sp.topZDistance = d
            case "--bottom-z": sp.bottomZDistance = d
            case "--xy": sp.xyDistance = d
            case "--interface-layers": sp.interfaceLayers = Int(d)
            case "--interface-spacing": sp.interfaceSpacing = d
            default: sp.layerHeight = d
            }
        }
        s.support = sp
    case "--format": guard let v = args.first.flatMap(MeshFormat.init(rawValue:)) else { usage() }; format = v; args.removeFirst()
    case "-h", "--help": usage()
    default: positional.append(a)
    }
}
guard let inPath = positional.first else { usage() }
let inURL = URL(fileURLWithPath: inPath)
let outURL: URL = positional.count > 1 ? URL(fileURLWithPath: positional[1]) :
    inURL.deletingLastPathComponent().appendingPathComponent(inURL.deletingPathExtension().lastPathComponent + "_solid." + (format ?? .threeMF).rawValue)

do {
    let t0 = Date()
    print("Lendo \(inURL.lastPathComponent)…")
    let mesh = try MeshReader.read(url: inURL)
    if let b = mesh.bounds() {
        let e = b.max - b.min
        print(String(format: "  %d triângulos, %.1f × %.1f × %.1f mm", mesh.triangleCount, e.x, e.y, e.z))
    }
    var last = ""
    let r = try SolidFiller.run(mesh: mesh, settings: s) { stage, f in
        if stage != last { print(String(format: "  [%3.0f%%] %@", f * 100, stage)); last = stage }
    }
    let st = r.stats
    print(String(format: "  voxel %.3f mm%@, grade %d×%d×%d, volume sólido %.1f cm³, %d triângulos",
                 st.voxelSize, st.coarsened ? " (ajustado ao limite de memória)" : "", st.grid.0, st.grid.1, st.grid.2,
                 st.solidVolumeMM3 / 1000, st.triangles))
    if s.support != nil { print(String(format: "  cavidades com suporte: %d, em ponte: %d, vazias: %.1f cm³, suporte: %.2f cm³", st.supportedCavities, st.bridgedCavities, Double(st.voidVoxels) * pow(st.voxelSize, 3) / 1000, Double(st.supportVoxels) * pow(st.voxelSize, 3) / 1000)) }
    if s.interiorOnly { print("  cavidades: \(st.cavities), voxels externos restaurados: \(st.restoredExternalVoxels)") }
    try MeshWriter.write(r.mesh, to: outURL, format: format, template: inURL.pathExtension.lowercased() == "3mf" ? inURL : profile)
    print(String(format: "Salvo em %@ (%.1fs)", outURL.path, Date().timeIntervalSince(t0)))
} catch {
    FileHandle.standardError.write(Data("Erro: \(error.localizedDescription)\n".utf8)); exit(2)
}
