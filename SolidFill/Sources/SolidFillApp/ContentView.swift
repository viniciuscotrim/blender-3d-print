import SwiftUI
import SceneKit
import UniformTypeIdentifiers
import SolidFillCore

struct ContentView: View {
    @EnvironmentObject var m: AppModel
    @State private var targeted = false
    @State private var picking = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 320).background(.background.secondary)
            Divider()
            preview
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: AppModel.supported) { r in
            if case .success(let u) = r { m.load(url: u) }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in m.load(url: url) } } }
            return true
        }
        .overlay { if targeted { RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 4).padding(6).allowsHitTesting(false) } }
    }

    var sidebar: some View {
        ScrollView { sidebarContent }
    }

    var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SolidFill").font(.title2.bold())
            Text("Preenche com sólido tudo que não é visível por fora, para imprimir sem suporte interno.")
                .font(.callout).foregroundStyle(.secondary)

            Button { picking = true } label: {
                VStack(spacing: 6) {
                    Image(systemName: "cube.transparent").font(.system(size: 28))
                    Text(m.inputURL?.lastPathComponent ?? "Solte aqui um .3mf, .stl ou .obj").font(.callout).multilineTextAlignment(.center)
                    if !m.inputInfo.isEmpty { Text(m.inputInfo).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity).padding(14)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.secondary))
            }.buttonStyle(.plain)

            GroupBox("Parâmetros") {
                VStack(alignment: .leading, spacing: 10) {
                    param("Voxel (mm)", value: $m.voxelSize, range: 0.05...0.5, step: 0.01,
                          help: "Resolução da superfície. Menor = mais detalhe, mais memória e tempo.")
                    param("Selar aberturas (mm)", value: $m.sealMM, range: 0...20, step: 0.5,
                          help: "Fecha frestas e furos até essa largura, preenchendo vãos internos que só se ligam ao exterior por elas. 0 = desligado.")
                    Toggle("Somente interior (preservar exterior)", isOn: $m.interiorOnly)
                    Text("Preenche só cavidades internas. Depois de selar, regiões visíveis de fora (fendas, ranhuras) são devolvidas intactas. Com isso pode usar uma abertura grande sem estragar o exterior. Mais lento.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if m.interiorOnly {
                        param("Visibilidade máx. (%)", value: $m.visibilityPct, range: 0.5...20, step: 0.5,
                              help: "Região vista de fora em menos que isso das direções é tratada como cavidade interna. Aumente se cavidades ficaram vazias; diminua se fendas externas foram preenchidas.")
                    }
                    Picker("Saída", selection: $m.format) {
                        ForEach(MeshFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }.pickerStyle(.segmented)
                    if m.format == .threeMF {
                        HStack {
                            Button("Perfil Bambu…") { m.chooseProfile() }
                            Text(m.profileURL?.lastPathComponent ?? "nenhum").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if m.profileURL != nil { Button { m.clearProfile() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                        }
                        Text("Com entrada .3mf do Bambu Studio as configurações vêm do próprio arquivo. Com STL/OBJ, escolha um projeto do Bambu como perfil, senão o Studio carrega só a geometria.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.top, 4)
            }

            GroupBox("Suportes internos") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Gerar suportes em vez de preencher", isOn: $m.supportOn)
                    Text("As cavidades internas ficam vazias e recebem suporte só onde há overhang. O exterior não é tocado. Cavidades com furo maior que \"Selar aberturas\" não são detectadas.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if m.supportOn {
                        Picker("Padrão", selection: $m.sup.pattern) {
                            Text("Retilíneo").tag(SupportPattern.rectilinear); Text("Grade").tag(SupportPattern.grid); Text("Favo").tag(SupportPattern.honeycomb)
                        }.pickerStyle(.segmented)
                        param("Vão máx. de ponte (mm)", value: $m.sup.bridgeSpan, range: 0...30, step: 0.5,
                              help: "Cavidades cujo teto sem apoio é mais estreito que isso não recebem suporte (a impressora faz ponte). 0 = sempre suportar.")
                        Toggle("Preencher cavidades em ponte (senão ficam vazias)", isOn: $m.sup.fillBridgeable)
                        param("Ângulo limite (°)", value: $m.sup.thresholdAngle, range: 1...89, step: 1, help: "Overhangs com inclinação (desde a horizontal) abaixo disso recebem suporte.")
                        param("Espaçamento do padrão (mm)", value: $m.sup.patternSpacing, range: 0.5...10, step: 0.1, help: "Distância entre as linhas do padrão.")
                        param("Ângulo do padrão (°)", value: $m.sup.patternAngle, range: 0...180, step: 5, help: "")
                        param("Largura da linha (mm)", value: $m.sup.lineWidth, range: 0.2...1.2, step: 0.02, help: "Use pelo menos a largura do bico, senão o fatiador descarta as linhas.")
                        param("Distância Z superior (mm)", value: $m.sup.topZDistance, range: 0...1, step: 0.05, help: "Vão entre o topo do suporte e o overhang.")
                        param("Distância Z inferior (mm)", value: $m.sup.bottomZDistance, range: 0...1, step: 0.05, help: "Vão entre a base do suporte e o piso da cavidade.")
                        param("Distância XY (mm)", value: $m.sup.xyDistance, range: 0...2, step: 0.05, help: "Folga lateral entre suporte e paredes.")
                        Stepper("Camadas de interface: \(m.sup.interfaceLayers)", value: $m.sup.interfaceLayers, in: 0...6)
                        param("Espaçamento da interface (mm)", value: $m.sup.interfaceSpacing, range: 0.2...3, step: 0.05, help: "Padrão denso sob o overhang.")
                        param("Altura da camada (mm)", value: $m.sup.layerHeight, range: 0.05...0.5, step: 0.01, help: "Define a espessura da interface e a alternância das linhas.")
                    }
                }.padding(.top, 4)
            }

            Button { m.process() } label: { Label("Preencher interior", systemImage: "cube.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(m.inputURL == nil || m.busy || m.inputGeometry == nil)
            Button { m.export() } label: { Label("Exportar…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                .controlSize(.large).disabled(m.result == nil || m.busy)

            if m.busy { ProgressView(value: m.progress) }
            Text(m.status).font(.caption).foregroundStyle(.secondary)
            if !m.resultInfo.isEmpty { Text(m.resultInfo).font(.caption) }
            if let e = m.errorText { Text(e).font(.caption).foregroundStyle(.red) }
        }.padding(16)
    }

    func param(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step)
            Text(help).font(.caption2).foregroundStyle(.secondary)
        }
    }

    var preview: some View {
        VStack(spacing: 0) {
            if m.inputGeometry == nil {
                ContentUnavailableView("Nenhum modelo", systemImage: "cube", description: Text("Arraste um arquivo para a janela."))
            } else {
                TabView {
                    VStack(spacing: 0) {
                        HStack(spacing: 16) {
                            Picker("", selection: $m.showOutput) {
                                Text("Original").tag(false)
                                Text("Resultado").tag(true).disabled(m.outputGeometry == nil)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                            Spacer(minLength: 0)
                            Toggle("Preview simplificado", isOn: $m.simplifyPreview).toggleStyle(.switch).controlSize(.small)
                                .help("Ligado: modelos muito grandes são reduzidos só na visualização, sem criar furos. Desligado: mostra todos os triângulos (pode ficar lento).")
                        }.padding(8)
                        ModelSceneView(geometry: m.showOutput ? m.outputGeometry : m.inputGeometry,
                                       clip: m.clip, zoom: m.zoomRequest, sceneID: m.modelID)
                            .overlay(alignment: .topLeading) { triangleCounter.padding(10) }
                            .overlay(alignment: .bottomTrailing) {
                                zoomButtons(in: { m.zoom3D(1.25) }, out: { m.zoom3D(0.8) }, reset: { m.zoom3D(0) }).padding(10)
                            }
                        if m.showOutput && m.result != nil { layerBar }
                    }.tabItem { Label("3D", systemImage: "cube") }
                    sliceView.tabItem { Label("Corte", systemImage: "square.split.1x2") }
                }
            }
        }
    }

    var triangleCounter: some View {
        let showingOut = m.showOutput && m.outputGeometry != nil
        let total = showingOut ? m.outputTriangles : m.inputTriangles
        let shown = showingOut ? m.outputPreviewTriangles : m.inputPreviewTriangles
        let fmt = { (n: Int) in n.formatted(.number.grouping(.automatic)) }
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(fmt(total)) triângulos").monospacedDigit()
            if shown < total { Text("preview simplificado: \(fmt(shown))").foregroundStyle(.secondary) }
        }.font(.caption).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    var layerBar: some View {
        HStack {
            Picker("Eixo", selection: $m.sliceAxis) { Text("X").tag(0); Text("Y").tag(1); Text("Z").tag(2) }
                .pickerStyle(.segmented).frame(width: 140)
            Text("Camadas").font(.caption).foregroundStyle(.secondary)
            Slider(value: $m.sliceIndex, in: 0...1)
            Toggle("Cores", isOn: $m.colorLayers).toggleStyle(.switch).controlSize(.small)
                .help("Mostra no corte o preenchido (azul) e a superfície original (cinza).")
        }.padding(.horizontal).padding(.bottom, 8)
    }

    func zoomButtons(in zin: @escaping () -> Void, out zout: @escaping () -> Void, reset: (() -> Void)?) -> some View {
        HStack(spacing: 0) {
            Button(action: zout) { Image(systemName: "minus.magnifyingglass").frame(width: 28, height: 24) }
            if let reset { Button(action: reset) { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass").frame(width: 28, height: 24) } }
            Button(action: zin) { Image(systemName: "plus.magnifyingglass").frame(width: 28, height: 24) }
        }.buttonStyle(.bordered).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    var sliceView: some View {
        VStack(spacing: 8) {
            if let img = m.sliceImage {
                ZoomableImage(image: img)
                HStack {
                    Picker("Eixo", selection: $m.sliceAxis) { Text("X").tag(0); Text("Y").tag(1); Text("Z").tag(2) }
                        .pickerStyle(.segmented).frame(width: 140)
                    Slider(value: $m.sliceIndex, in: 0...1)
                }.padding(.horizontal)
                HStack(spacing: 14) {
                    legend(Color(red: 0.235, green: 0.55, blue: 0.94), "preenchido")
                    legend(Color(white: 0.84), "superfície original")
                    legend(Color(white: 0.11), "exterior")
                    if m.hasSupports { legend(Color(red: 0.96, green: 0.63, blue: 0.16), "suporte"); legend(Color(red: 0.2, green: 0.2, blue: 0.3), "cavidade") }
                }.font(.caption).padding(.bottom, 8)
            } else {
                ContentUnavailableView("Sem resultado", systemImage: "square.split.1x2", description: Text("Processe o modelo para ver cortes."))
            }
        }
    }
    func legend(_ c: Color, _ t: String) -> some View { HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 12, height: 12); Text(t) } }
}

/// Image with scroll-wheel / pinch zoom, drag to pan and on-screen zoom buttons.
struct ZoomableImage: View {
    var image: CGImage
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @State private var dragStart = CGSize.zero
    @State private var pinchStart: Double?

    var body: some View {
        Image(decorative: image, scale: 1).resizable().interpolation(.none).scaledToFit()
            .scaleEffect(zoom).offset(offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            .background(Color.black.opacity(0.4))
            .background(ScrollMonitor { dy in setZoom(zoom * exp(dy)) })
            .gesture(DragGesture().onChanged { offset = CGSize(width: dragStart.width + $0.translation.width, height: dragStart.height + $0.translation.height) }
                .onEnded { _ in dragStart = offset })
            .gesture(MagnifyGesture().onChanged { v in
                if pinchStart == nil { pinchStart = zoom }
                setZoom(pinchStart! * v.magnification)
            }.onEnded { _ in pinchStart = nil })
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 0) {
                    Button { setZoom(zoom * 0.8) } label: { Image(systemName: "minus.magnifyingglass").frame(width: 28, height: 24) }
                    Button { zoom = 1; offset = .zero; dragStart = .zero } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass").frame(width: 28, height: 24) }
                    Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass").frame(width: 28, height: 24) }
                }.buttonStyle(.bordered).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(10)
            }
    }
    private func setZoom(_ z: Double) { zoom = min(40, max(0.2, z)) }
}

/// Reports scroll-wheel movement (positive = zoom in) while the pointer is over the view, without blocking other gestures.
struct ScrollMonitor: NSViewRepresentable {
    var onScroll: (Double) -> Void
    final class Coordinator { var monitor: Any?; var handler: (Double) -> Void = { _ in }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } } }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let c = context.coordinator
        c.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak v] e in
            guard let v, let w = v.window, e.window === w else { return e }
            let p = v.convert(e.locationInWindow, from: nil)
            guard v.bounds.contains(p) else { return e }
            c.handler(Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.005 : 0.05))
            return nil
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { context.coordinator.handler = onScroll }
}

/// Navigation: left-drag pans, right-drag (or ctrl+click) orbits, scroll / pinch zooms toward the pointer.
final class ZoomSCNView: SCNView {
    var onScrollZoom: ((Double, CGPoint) -> Void)?
    var onNavigate: (() -> Void)?

    private func local(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func scrollWheel(with event: NSEvent) {
        let d = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.005 : 0.05)
        onScrollZoom?(d, local(event))
    }
    override func magnify(with event: NSEvent) { onScrollZoom?(Double(event.magnification) * 2, local(event)) }

    // Pan: the scene follows the pointer; the orbit pivot moves with it.
    private func pan(_ e: NSEvent) {
        guard let pov = pointOfView, bounds.height > 0 else { return }
        onNavigate?()
        let ctl = defaultCameraController
        let t = ctl.target
        let c = pov.simdWorldPosition
        let dist = Double(simd_length(c - SIMD3<Float>(Float(t.x), Float(t.y), Float(t.z))))
        let fov = (pov.camera?.fieldOfView ?? 60) * .pi / 180
        let k = 2 * dist * tan(fov / 2) / Double(bounds.height)
        let lx = Float(-Double(e.deltaX) * k), ly = Float(Double(e.deltaY) * k)
        ctl.translateInCameraSpaceBy(x: lx, y: ly, z: 0)
        let w = pov.simdWorldTransform
        let d = w.columns.0 * lx + w.columns.1 * ly
        ctl.target = SCNVector3(CGFloat(Float(t.x) + d.x), CGFloat(Float(t.y) + d.y), CGFloat(Float(t.z) + d.z))
    }
    override func mouseDown(with event: NSEvent) { onNavigate?() }
    override func mouseDragged(with event: NSEvent) { pan(event) }
    override func otherMouseDragged(with event: NSEvent) { pan(event) }

    override func rightMouseDown(with event: NSEvent) {
        onNavigate?()
        defaultCameraController.beginInteraction(local(event), withViewport: bounds.size)
    }
    override func rightMouseDragged(with event: NSEvent) {
        defaultCameraController.continueInteraction(local(event), withViewport: bounds.size, sensitivity: 1)
    }
    override func rightMouseUp(with event: NSEvent) {
        defaultCameraController.endInteraction(local(event), withViewport: bounds.size, velocity: .zero)
    }
}

struct ModelSceneView: NSViewRepresentable {
    var geometry: SCNGeometry?
    var clip: ClipInfo?
    var zoom: ZoomRequest
    /// Changes only when a new file is loaded; switching Original/Resultado keeps the camera.
    var sceneID: Int

    final class Coordinator {
        var current: SCNGeometry?
        var sceneID = -1
        var capNode: SCNNode?
        var modelNode: SCNNode?
        var capImage: CGImage?
        var capAxis = -1
        var zoomID = 0
        var pivot: (screen: CGPoint, world: SIMD3<Float>, time: Double)?
        var initialPos = SCNVector3Zero
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Zooms about the surface point under `point` (view centre when nil): that point stays fixed on screen,
    /// and it also becomes the orbit pivot so detail areas can be inspected by rotating around them.
    static func zoomCamera(_ v: SCNView, by f: Double, at point: CGPoint?, co: Coordinator) {
        guard let pov = v.pointOfView, f > 0 else { return }
        let pt = point ?? CGPoint(x: v.bounds.midX, y: v.bounds.midY)
        let ctl = v.defaultCameraController
        let C = pov.simdWorldPosition
        let tg = ctl.target
        let T = SIMD3<Float>(Float(tg.x), Float(tg.y), Float(tg.z))
        func vec(_ p: SCNVector3) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.y), Float(p.z)) }

        // Surface point under the cursor (cached while the cursor stays put, hit-testing millions of triangles is slow).
        let now = CACurrentMediaTime()
        let P: SIMD3<Float>
        if let c = co.pivot, hypot(pt.x - c.screen.x, pt.y - c.screen.y) < 3, now - c.time < 1.5 {
            P = c.world
        } else {
            if let h = v.hitTest(pt, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.closest.rawValue)]).first {
                P = vec(h.worldCoordinates)
            } else {
                let n = vec(v.unprojectPoint(SCNVector3(pt.x, pt.y, 0))), fa = vec(v.unprojectPoint(SCNVector3(pt.x, pt.y, 1)))
                P = C + simd_normalize(fa - n) * simd_length(T - C)
            }
            co.pivot = (pt, P, now)
        }
        let k = Float(1 / f)
        let C2 = P + (C - P) * k, T2 = P + (T - P) * k
        let w = pov.simdWorldTransform
        let rot = simd_float3x3(SIMD3(w.columns.0.x, w.columns.0.y, w.columns.0.z),
                                SIMD3(w.columns.1.x, w.columns.1.y, w.columns.1.z),
                                SIMD3(w.columns.2.x, w.columns.2.y, w.columns.2.z))
        let l = rot.transpose * (C2 - C)
        ctl.translateInCameraSpaceBy(x: l.x, y: l.y, z: l.z)
        ctl.target = SCNVector3(CGFloat(T2.x), CGFloat(T2.y), CGFloat(T2.z))
        // Keep the near plane close enough to inspect fine detail without clipping it.
        if let cam = pov.camera {
            let r = cam.zFar / 20
            cam.zNear = min(r * 0.01, max(Double(simd_length(C2 - P)) * 0.05, r * 1e-5))
        }
    }

    func makeNSView(context: Context) -> SCNView {
        let v = ZoomSCNView()
        v.allowsCameraControl = true; v.autoenablesDefaultLighting = true
        v.backgroundColor = NSColor(white: 0.13, alpha: 1); v.antialiasingMode = .multisampling4X
        let co = context.coordinator
        v.onNavigate = { [weak co] in co?.pivot = nil }
        v.onScrollZoom = { [weak v] d, p in if let v { Self.zoomCamera(v, by: exp(d), at: p, co: co) } }
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        let co = context.coordinator
        if co.current !== geometry, co.sceneID == sceneID, let node = co.modelNode, let g = geometry {
            // Same model, other view: swap the geometry in place so zoom, pan and orientation are kept.
            co.current = g; node.geometry = g
        } else if co.current !== geometry {
            co.current = geometry; co.sceneID = sceneID; co.pivot = nil; co.capNode = nil; co.modelNode = nil; co.capImage = nil
            let scene = SCNScene()
            if let g = geometry {
                let node = SCNNode(geometry: g)
                let (mn, mx) = g.boundingBox
                node.pivot = SCNMatrix4MakeTranslation((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
                node.eulerAngles.x = -.pi / 2           // models are Z-up
                scene.rootNode.addChildNode(node); co.modelNode = node
                let r = max(mx.x - mn.x, mx.y - mn.y, mx.z - mn.z)
                let cam = SCNNode(); cam.camera = SCNCamera(); cam.camera!.zNear = Double(r) * 0.01; cam.camera!.zFar = Double(r) * 20
                cam.position = SCNVector3(Double(r) * 0.9, Double(r) * 0.6, Double(r) * 1.7)
                cam.look(at: SCNVector3(0, 0, 0))
                scene.rootNode.addChildNode(cam); v.pointOfView = cam
                co.initialPos = cam.position
                v.defaultCameraController.target = SCNVector3Zero
            }
            v.scene = scene
        }
        applyClip(co)
        if zoom.id != co.zoomID {
            co.zoomID = zoom.id
            if zoom.factor == 0, let pov = v.pointOfView {          // reset view
                pov.position = co.initialPos; pov.look(at: SCNVector3Zero)
                v.defaultCameraController.target = SCNVector3Zero
                pov.camera?.zNear = (pov.camera?.zFar ?? 0) / 20 * 0.01
            } else { Self.zoomCamera(v, by: zoom.factor, at: nil, co: co) }
        }
    }

    private func applyClip(_ co: Coordinator) {
        guard let g = geometry, let mat = g.firstMaterial, let node = co.modelNode else { return }
        guard let c = clip, let img = c.image else {
            mat.setValue(NSNumber(value: 1e9), forKey: "clipPos")
            co.capNode?.isHidden = true
            return
        }
        var ax = SCNVector3(0, 0, 0)
        switch c.axis { case 0: ax.x = 1; case 1: ax.y = 1; default: ax.z = 1 }
        mat.setValue(ax, forKey: "clipAxis"); mat.setValue(NSNumber(value: c.coord), forKey: "clipPos")

        let cap: SCNNode
        if let n = co.capNode { cap = n } else {
            cap = SCNNode(geometry: SCNPlane(width: 1, height: 1))
            let m = SCNMaterial(); m.lightingModel = .constant; m.isDoubleSided = true
            m.diffuse.magnificationFilter = .nearest; m.diffuse.minificationFilter = .nearest
            cap.geometry!.materials = [m]
            node.addChildNode(cap); co.capNode = cap
        }
        cap.isHidden = false
        if co.capImage !== img { cap.geometry?.firstMaterial?.diffuse.contents = img; co.capImage = img }
        let plane = cap.geometry as! SCNPlane
        let nudge = 1e-5 * max(c.size.x, c.size.y, c.size.z)   // keep the cap just in front of coplanar mesh faces
        let t = c.coord + nudge
        let ctr = c.center, sz = c.size
        var cols: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>), pos: SIMD3<Float>
        switch c.axis {
        case 0:
            plane.width = sz.y; plane.height = sz.z
            cols = ([0, 1, 0], [0, 0, 1], [1, 0, 0]); pos = SIMD3(Float(t), Float(ctr.y), Float(ctr.z))
        case 1:
            plane.width = sz.x; plane.height = sz.z
            cols = ([1, 0, 0], [0, 0, 1], [0, -1, 0]); pos = SIMD3(Float(ctr.x), Float(t), Float(ctr.z))
        default:
            plane.width = sz.x; plane.height = sz.y
            cols = ([1, 0, 0], [0, 1, 0], [0, 0, 1]); pos = SIMD3(Float(ctr.x), Float(ctr.y), Float(t))
        }
        cap.simdTransform = simd_float4x4(SIMD4(cols.0, 0), SIMD4(cols.1, 0), SIMD4(cols.2, 0), SIMD4(pos, 1))
    }
}
