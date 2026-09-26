// Metal renderer: shaded faces, screen-space edges, grid, and an ID buffer for picking.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADKernel
import Metal
import MetalKit
import simd

/// What the pick buffer encodes (0 = nothing):
///   body face  (body+1) << 20 | face           (bodies < 1023)
///   body edge  0x8000_0000 | (body+1) << 20 | edge
///   sketch     0x4000_0000 point, 0x5000_0000 curve, 0x6000_0000 profile region | slot << 16 | index
///              (slot 0 = the sketch being edited, n = the n-th sketch in the document)
///   handle     0x7000_0000 (the extrude drag handle)
///   plane      0x7100_0000 | index (an origin plane offered when choosing where to sketch)
struct PickID: Hashable, Sendable {
    enum Kind: Sendable { case none, face, edge, sketchPoint, sketchCurve, region, handle, plane }
    static let edgeFlag: UInt32 = 0x8000_0000
    static let sketchFlag: UInt32 = 0x4000_0000
    static let planeFlag: UInt32 = 0x0100_0000
    var raw: UInt32

    init(raw: UInt32) { self.raw = raw }
    init(body: Int, face: Int) { raw = UInt32(body + 1) << 20 | UInt32(face) }
    init(body: Int, edge: Int) { raw = PickID.edgeFlag | UInt32(body + 1) << 20 | UInt32(edge) }
    init(sketchPoint i: Int, slot: Int = 0) { raw = 0x4000_0000 | UInt32(slot & 0xFFF) << 16 | UInt32(i & 0xFFFF) }
    init(sketchCurve i: Int, slot: Int = 0) { raw = 0x5000_0000 | UInt32(slot & 0xFFF) << 16 | UInt32(i & 0xFFFF) }
    init(region i: Int, slot: Int = 0) { raw = 0x6000_0000 | UInt32(slot & 0xFFF) << 16 | UInt32(i & 0xFFFF) }
    init(plane i: Int) { raw = 0x7000_0000 | PickID.planeFlag | UInt32(i) }
    static let handle = PickID(raw: 0x7000_0000)

    var kind: Kind {
        if raw == 0 { return .none }
        if raw & PickID.edgeFlag != 0 { return .edge }
        if raw & PickID.sketchFlag != 0 {
            switch (raw >> 28) & 0x3 {
            case 0: return .sketchPoint
            case 1: return .sketchCurve
            case 2: return .region
            default: return raw & PickID.planeFlag != 0 ? .plane : .handle
            }
        }
        return .face
    }
    var isEdge: Bool { kind == .edge }
    var isFace: Bool { kind == .face }
    /// Body index (faces and edges only).
    var body: Int { Int((raw & 0x3FF0_0000) >> 20) - 1 }
    /// Face/edge index within the body, or the sketch point/curve/region/plane index.
    var element: Int {
        switch kind {
        case .face, .edge: return Int(raw & 0xFFFFF)
        case .plane: return Int(raw & 0xFF)
        case .sketchPoint, .sketchCurve, .region: return Int(raw & 0xFFFF)
        default: return Int(raw & 0x0FFF_FFFF)
        }
    }
    /// Which sketch a sketch point, curve or region belongs to (see the table above).
    var sketchSlot: Int {
        switch kind {
        case .sketchPoint, .sketchCurve, .region: return Int((raw >> 16) & 0xFFF)
        default: return 0
        }
    }
}

/// Sketch geometry to draw on top of the bodies.
struct SketchOverlay {
    var regionVertices: [FaceVertex] = []
    var regionIndices: [UInt32] = []
    /// Origin planes offered while choosing where to sketch: 4 vertices and 6 indices per plane.
    var planeVertices: [FaceVertex] = []
    var planeIndices: [UInt32] = []
    var planeOutline: [SegmentInstance] = []
    var curves: [SegmentInstance] = []
    var construction: [SegmentInstance] = []
    var inactive: [SegmentInstance] = []   // finished sketches: thin, pickable as paths and axes
    var preview: [SegmentInstance] = []
    var points: [SegmentInstance] = []     // zero-length segments drawn as squares
    var handle: [SegmentInstance] = []     // drag handle: shaft + tip (zero-length)
    var snap: [SegmentInstance] = []       // where the cursor snapped: a zero-length marker
    var handleInvalid = false               // the previewed size can't be built
    var fullyConstrained = false
}

struct Uniforms {
    var viewProj: simd_float4x4
    var eye: SIMD4<Float>
    var viewport: SIMD2<Float>
    var hovered: UInt32
    var selectedCount: UInt32
    var faceColor: SIMD4<Float>
    var faceHoverColor: SIMD4<Float>
    var faceSelectedColor: SIMD4<Float>
    var regionColor: SIMD4<Float>
}

/// Viewport colours for the current appearance (light/dark) and Increase Contrast.
struct ViewportPalette: Equatable {
    var background: SIMD4<Float>
    var grid: SIMD4<Float>
    var axes: (x: SIMD4<Float>, y: SIMD4<Float>, z: SIMD4<Float>)
    var face, faceHover, faceSelected: SIMD4<Float>
    var edge, hover, selection: SIMD4<Float>
    var sketch, sketchConstrained, construction, preview, point, inactiveSketch, handle, invalid: SIMD4<Float>
    var region: SIMD4<Float>
    /// Origin planes offered when choosing where to sketch (rgb + fill alpha; outlines are opaque).
    var plane: SIMD4<Float>
    /// Line width multiplier (thicker with Increase Contrast).
    var lineScale: Float

    static func == (a: ViewportPalette, b: ViewportPalette) -> Bool {
        a.background == b.background && a.face == b.face && a.lineScale == b.lineScale && a.sketch == b.sketch
    }

    static func make(dark: Bool, increaseContrast: Bool) -> ViewportPalette {
        var p: ViewportPalette
        if dark {
            p = ViewportPalette(
                background: SIMD4(0.12, 0.125, 0.14, 1), grid: SIMD4(0.24, 0.25, 0.28, 1),
                axes: (SIMD4(0.9, 0.35, 0.35, 1), SIMD4(0.4, 0.8, 0.45, 1), SIMD4(0.4, 0.55, 1, 1)),
                face: SIMD4(0.56, 0.59, 0.64, 1), faceHover: SIMD4(0.52, 0.66, 0.88, 1), faceSelected: SIMD4(0.25, 0.52, 1, 1),
                edge: SIMD4(0.04, 0.04, 0.05, 1), hover: SIMD4(0.45, 0.72, 1, 1), selection: SIMD4(0.2, 0.55, 1, 1),
                sketch: SIMD4(0.45, 0.68, 1, 1), sketchConstrained: SIMD4(0.93, 0.93, 0.95, 1),
                construction: SIMD4(1, 0.62, 0.25, 1), preview: SIMD4(0.65, 0.65, 0.7, 1), point: SIMD4(0.85, 0.87, 0.92, 1),
                inactiveSketch: SIMD4(0.5, 0.6, 0.85, 1), handle: SIMD4(1, 0.58, 0.1, 1), invalid: SIMD4(1, 0.3, 0.3, 1),
                region: SIMD4(0.35, 0.6, 1, 0.18), plane: SIMD4(1, 0.65, 0.2, 0.22), lineScale: 1)
        } else {
            p = ViewportPalette(
                background: SIMD4(0.95, 0.96, 0.97, 1), grid: SIMD4(0.8, 0.82, 0.86, 1),
                axes: (SIMD4(0.85, 0.25, 0.25, 1), SIMD4(0.25, 0.7, 0.3, 1), SIMD4(0.3, 0.45, 0.9, 1)),
                face: SIMD4(0.64, 0.67, 0.72, 1), faceHover: SIMD4(0.55, 0.72, 0.95, 1), faceSelected: SIMD4(0.3, 0.56, 1, 1),
                edge: SIMD4(0.12, 0.13, 0.16, 1), hover: SIMD4(0.1, 0.55, 1, 1), selection: SIMD4(0, 0.4, 1, 1),
                sketch: SIMD4(0.1, 0.3, 0.85, 1), sketchConstrained: SIMD4(0.08, 0.08, 0.1, 1),
                construction: SIMD4(0.9, 0.55, 0.15, 1), preview: SIMD4(0.45, 0.45, 0.5, 1), point: SIMD4(0.15, 0.2, 0.35, 1),
                inactiveSketch: SIMD4(0.35, 0.45, 0.7, 1), handle: SIMD4(0.95, 0.5, 0.05, 1), invalid: SIMD4(0.9, 0.12, 0.12, 1),
                region: SIMD4(0.25, 0.5, 0.95, 0.16), plane: SIMD4(0.95, 0.6, 0.15, 0.2), lineScale: 1)
        }
        if increaseContrast {
            p.lineScale = 1.6
            p.grid = dark ? SIMD4(0.4, 0.42, 0.46, 1) : SIMD4(0.6, 0.62, 0.66, 1)
            p.edge = dark ? SIMD4(0, 0, 0, 1) : SIMD4(0, 0, 0, 1)
            p.region.w = 0.3
            p.plane.w = 0.35
        }
        return p
    }
}

struct FaceVertex {
    var px, py, pz: Float
    var nx, ny, nz: Float
    var id: UInt32
}

struct SegmentInstance {
    var ax, ay, az: Float
    var bx, by, bz: Float
    var id: UInt32
}

struct DrawParams {
    var color: SIMD4<Float>
    var hoverColor: SIMD4<Float>
    var selectColor: SIMD4<Float>
    var thickness: Float
    var depthBias: Float
    var pickable: UInt32
    var pad: UInt32 = 0
}

@MainActor
final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let facePipeline: MTLRenderPipelineState
    private let segmentPipeline: MTLRenderPipelineState
    private let regionPipeline: MTLRenderPipelineState
    private let planePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let onTopDepthState: MTLDepthStencilState
    /// Depth-tested but not depth-writing: translucent planes hide nothing drawn after them.
    private let noWriteDepthState: MTLDepthStencilState

    private struct GPUBody {
        var faces: MTLBuffer?
        var indices: MTLBuffer?
        var indexCount = 0
        var segments: MTLBuffer?
        var segmentCount = 0
    }
    private var bodies: [GPUBody] = []
    private var grid: MTLBuffer?
    private var gridCount = 0
    private var axes: [(MTLBuffer, SIMD4<Float>)] = []

    private struct GPUOverlay {
        var regions: MTLBuffer?
        var regionIndices: MTLBuffer?
        var regionIndexCount = 0
        var planes: MTLBuffer?
        var planeIndices: MTLBuffer?
        /// One centre per plane (6 indices each), to draw them back to front.
        var planeCenters: [SIMD3<Float>] = []
        var planeOutline: MTLBuffer?, planeOutlineCount = 0
        var curves: MTLBuffer?, curveCount = 0
        var construction: MTLBuffer?, constructionCount = 0
        var inactive: MTLBuffer?, inactiveCount = 0
        var preview: MTLBuffer?, previewCount = 0
        var points: MTLBuffer?, pointCount = 0
        var handle: MTLBuffer?, handleCount = 0
        var snap: MTLBuffer?, snapCount = 0
        var handleInvalid = false
        var fullyConstrained = false
    }
    private var overlay = GPUOverlay()

    private var idTexture: MTLTexture?
    private let pickBuffer: MTLBuffer

    var camera = Camera()
    var palette = ViewportPalette.make(dark: false, increaseContrast: false)
    var showGrid = true
    var hovered: UInt32 = 0
    var selected: [UInt32] = []
    /// Pixel (in drawable coordinates, origin top-left) to read from the ID buffer on the next frame.
    var pickRequest: SIMD2<Int>?
    var onPick: (@MainActor @Sendable (UInt32) -> Void)?

    static let colorFormat = MTLPixelFormat.bgra8Unorm
    static let depthFormat = MTLPixelFormat.depth32Float

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let pickBuffer = device.makeBuffer(length: 16, options: .storageModeShared) else { return nil }
        self.device = device
        self.queue = queue
        self.pickBuffer = pickBuffer
        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            func pipeline(_ vertex: String, _ fragment: String, blend: Bool = false) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                d.colorAttachments[0].pixelFormat = Renderer.colorFormat
                if blend {  // colour only; the integer ID attachment can't blend
                    d.colorAttachments[0].isBlendingEnabled = true
                    d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                    d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                    d.colorAttachments[0].sourceAlphaBlendFactor = .one
                    d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                d.colorAttachments[1].pixelFormat = .r32Uint
                d.depthAttachmentPixelFormat = Renderer.depthFormat
                return try device.makeRenderPipelineState(descriptor: d)
            }
            facePipeline = try pipeline("faceVertex", "faceFragment")
            segmentPipeline = try pipeline("segmentVertex", "segmentFragment")
            regionPipeline = try pipeline("regionVertex", "regionFragment", blend: true)
            planePipeline = try pipeline("regionVertex", "planeFragment", blend: true)
        } catch {
            print("SimplCAD: Metal setup failed: \(error)")
            return nil
        }
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .lessEqual
        ds.isDepthWriteEnabled = true
        let top = MTLDepthStencilDescriptor()
        top.depthCompareFunction = .always
        top.isDepthWriteEnabled = true
        let noWrite = MTLDepthStencilDescriptor()
        noWrite.depthCompareFunction = .lessEqual
        noWrite.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: ds),
              let onTop = device.makeDepthStencilState(descriptor: top),
              let noWriteState = device.makeDepthStencilState(descriptor: noWrite) else { return nil }
        self.depthState = depthState
        self.onTopDepthState = onTop
        self.noWriteDepthState = noWriteState
        buildGrid(size: 200, step: 10)
    }

    // MARK: scene

    func setScene(_ meshes: [BodyMesh]) {
        bodies = meshes.map { upload($0) }
    }

    func setOverlay(_ o: SketchOverlay) {
        var g = GPUOverlay()
        g.regions = makeBuffer(o.regionVertices)
        g.regionIndices = makeBuffer(o.regionIndices)
        g.regionIndexCount = o.regionIndices.count
        g.planes = makeBuffer(o.planeVertices)
        g.planeIndices = makeBuffer(o.planeIndices)
        g.planeCenters = (0..<(o.planeIndices.count / 6)).map { i in
            var c = SIMD3<Float>.zero
            for v in o.planeVertices[(i * 4)..<min(i * 4 + 4, o.planeVertices.count)] { c += SIMD3(v.px, v.py, v.pz) }
            return c / 4
        }
        g.planeOutline = makeBuffer(o.planeOutline); g.planeOutlineCount = o.planeOutline.count
        g.curves = makeBuffer(o.curves); g.curveCount = o.curves.count
        g.construction = makeBuffer(o.construction); g.constructionCount = o.construction.count
        g.inactive = makeBuffer(o.inactive); g.inactiveCount = o.inactive.count
        g.preview = makeBuffer(o.preview); g.previewCount = o.preview.count
        g.points = makeBuffer(o.points); g.pointCount = o.points.count
        g.handle = makeBuffer(o.handle); g.handleCount = o.handle.count
        g.snap = makeBuffer(o.snap); g.snapCount = o.snap.count
        g.handleInvalid = o.handleInvalid
        g.fullyConstrained = o.fullyConstrained
        overlay = g
    }

    private func upload(_ m: BodyMesh) -> GPUBody {
        let mesh = m.mesh
        var vertexFace = [UInt32](repeating: 0, count: mesh.positions.count / 3)
        for t in 0..<mesh.triangleFace.count {
            for k in 0..<3 { vertexFace[Int(mesh.indices[t * 3 + k])] = mesh.triangleFace[t] }
        }
        var verts: [FaceVertex] = []
        verts.reserveCapacity(vertexFace.count)
        for v in 0..<vertexFace.count {
            let p = v * 3
            verts.append(FaceVertex(px: mesh.positions[p], py: mesh.positions[p + 1], pz: mesh.positions[p + 2],
                                    nx: mesh.normals[p], ny: mesh.normals[p + 1], nz: mesh.normals[p + 2],
                                    id: PickID(body: m.index, face: Int(vertexFace[v])).raw))
        }
        var segs: [SegmentInstance] = []
        segs.reserveCapacity(mesh.segmentEdge.count)
        for s in 0..<mesh.segmentEdge.count {
            let q = s * 6
            segs.append(SegmentInstance(ax: mesh.segments[q], ay: mesh.segments[q + 1], az: mesh.segments[q + 2],
                                        bx: mesh.segments[q + 3], by: mesh.segments[q + 4], bz: mesh.segments[q + 5],
                                        id: PickID(body: m.index, edge: Int(mesh.segmentEdge[s])).raw))
        }
        var g = GPUBody()
        g.faces = makeBuffer(verts)
        g.indices = makeBuffer(mesh.indices)
        g.indexCount = mesh.indices.count
        g.segments = makeBuffer(segs)
        g.segmentCount = segs.count
        return g
    }

    private func makeBuffer<T>(_ array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return array.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    func buildGrid(size: Float, step: Float) {
        var lines: [SegmentInstance] = []
        let n = Int(size / step)
        for i in -n...n where i != 0 {
            let t = Float(i) * step
            lines.append(SegmentInstance(ax: t, ay: -size, az: 0, bx: t, by: size, bz: 0, id: 0))
            lines.append(SegmentInstance(ax: -size, ay: t, az: 0, bx: size, by: t, bz: 0, id: 0))
        }
        grid = makeBuffer(lines)
        gridCount = lines.count
        axes = [
            (makeBuffer([SegmentInstance(ax: 0, ay: 0, az: 0, bx: size, by: 0, bz: 0, id: 0)])!, SIMD4(0.85, 0.25, 0.25, 1)),
            (makeBuffer([SegmentInstance(ax: 0, ay: 0, az: 0, bx: 0, by: size, bz: 0, id: 0)])!, SIMD4(0.25, 0.7, 0.3, 1)),
            (makeBuffer([SegmentInstance(ax: 0, ay: 0, az: 0, bx: 0, by: 0, bz: size / 2, id: 0)])!, SIMD4(0.3, 0.45, 0.9, 1)),
        ]
    }

    // MARK: drawing

    func draw(in view: MTKView) {
        let size = view.drawableSize
        guard size.width >= 1, size.height >= 1,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }

        if idTexture == nil || idTexture!.width != Int(size.width) || idTexture!.height != Int(size.height) {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint, width: Int(size.width),
                                                             height: Int(size.height), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            idTexture = device.makeTexture(descriptor: d)
        }
        pass.colorAttachments[1].texture = idTexture
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].storeAction = .store
        pass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let aspect = Float(size.width / size.height)
        var uniforms = Uniforms(viewProj: camera.projectionMatrix(aspect: aspect) * camera.viewMatrix(),
                                eye: SIMD4(camera.eye, 1), viewport: SIMD2(Float(size.width), Float(size.height)),
                                hovered: hovered, selectedCount: UInt32(min(selected.count, 256)),
                                faceColor: palette.face, faceHoverColor: palette.faceHover,
                                faceSelectedColor: palette.faceSelected, regionColor: palette.region)
        var sel = Array(selected.prefix(256))
        if sel.isEmpty { sel = [0] }
        let scale = Float(view.window?.backingScaleFactor ?? 2) * palette.lineScale

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setDepthStencilState(depthState)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&sel, length: MemoryLayout<UInt32>.stride * sel.count, index: 2)

        enc.setRenderPipelineState(facePipeline)
        enc.setCullMode(.none)
        for b in bodies {
            guard let faces = b.faces, let indices = b.indices else { continue }
            enc.setVertexBuffer(faces, offset: 0, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount, indexType: .uint32,
                                      indexBuffer: indices, indexBufferOffset: 0)
        }

        if let regions = overlay.regions, let indices = overlay.regionIndices {
            enc.setRenderPipelineState(regionPipeline)
            enc.setVertexBuffer(regions, offset: 0, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: overlay.regionIndexCount, indexType: .uint32,
                                      indexBuffer: indices, indexBufferOffset: 0)
        }

        // Origin planes: translucent, back to front so the nearest one is what the cursor picks.
        if let planes = overlay.planes, let indices = overlay.planeIndices, !overlay.planeCenters.isEmpty {
            let fill = palette.plane, hoverFill = SIMD4(fill.x, fill.y, fill.z, min(fill.w * 2.2, 0.75))
            var planeParams = DrawParams(color: fill, hoverColor: hoverFill, selectColor: fill,
                                         thickness: 0, depthBias: 0, pickable: 1)
            enc.setRenderPipelineState(planePipeline)
            enc.setDepthStencilState(noWriteDepthState)
            enc.setVertexBuffer(planes, offset: 0, index: 0)
            enc.setFragmentBytes(&planeParams, length: MemoryLayout<DrawParams>.stride, index: 3)
            let forward = camera.forward, centers = overlay.planeCenters  // farthest along the view direction first
            let order = centers.indices.sorted { simd_dot(centers[$0], forward) > simd_dot(centers[$1], forward) }
            for i in order {
                enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint32,
                                          indexBuffer: indices, indexBufferOffset: i * 6 * MemoryLayout<UInt32>.stride)
            }
            enc.setDepthStencilState(depthState)
        }

        enc.setRenderPipelineState(segmentPipeline)
        func segments(_ buffer: MTLBuffer?, _ count: Int, _ params: DrawParams) {
            guard let buffer, count > 0 else { return }
            var p = params
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&p, length: MemoryLayout<DrawParams>.stride, index: 3)
            enc.setFragmentBytes(&p, length: MemoryLayout<DrawParams>.stride, index: 3)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        let p = palette
        if showGrid {
            segments(grid, gridCount, DrawParams(color: p.grid, hoverColor: p.grid, selectColor: p.grid,
                                                 thickness: 1 * scale, depthBias: 0, pickable: 0))
        }
        for (i, (buffer, _)) in axes.enumerated() {
            let color = i == 0 ? p.axes.x : i == 1 ? p.axes.y : p.axes.z
            segments(buffer, 1, DrawParams(color: color, hoverColor: color, selectColor: color,
                                           thickness: 1.5 * scale, depthBias: 0.0001, pickable: 0))
        }
        for b in bodies {
            segments(b.segments, b.segmentCount,
                     DrawParams(color: p.edge, hoverColor: p.hover, selectColor: p.selection, thickness: 1.6 * scale,
                                depthBias: 0.0004, pickable: 1))
        }
        // Sketch overlay, drawn last with increasing depth bias so it sits on top of faces it lies on.
        let hover = p.hover, select = p.selection
        let planeLine = SIMD4(p.plane.x, p.plane.y, p.plane.z, 1)
        segments(overlay.planeOutline, overlay.planeOutlineCount,
                 DrawParams(color: planeLine, hoverColor: planeLine, selectColor: planeLine,
                            thickness: 1.2 * scale, depthBias: 0.0005, pickable: 1))
        segments(overlay.inactive, overlay.inactiveCount,
                 DrawParams(color: p.inactiveSketch, hoverColor: hover, selectColor: select,
                            thickness: 1.6 * scale, depthBias: 0.0006, pickable: 1))
        let curveColor = overlay.fullyConstrained ? p.sketchConstrained : p.sketch
        segments(overlay.curves, overlay.curveCount,
                 DrawParams(color: curveColor, hoverColor: hover, selectColor: select,
                            thickness: 2 * scale, depthBias: 0.0008, pickable: 1))
        segments(overlay.construction, overlay.constructionCount,
                 DrawParams(color: p.construction, hoverColor: hover, selectColor: select,
                            thickness: 1.4 * scale, depthBias: 0.0008, pickable: 1))
        segments(overlay.preview, overlay.previewCount,
                 DrawParams(color: p.preview, hoverColor: hover, selectColor: select,
                            thickness: 1.5 * scale, depthBias: 0.0009, pickable: 0))
        segments(overlay.points, overlay.pointCount,
                 DrawParams(color: p.point, hoverColor: hover, selectColor: select,
                            thickness: 7 * scale, depthBias: 0.0012, pickable: 1))
        segments(overlay.snap, overlay.snapCount,
                 DrawParams(color: p.handle, hoverColor: p.handle, selectColor: p.handle,
                            thickness: 9 * scale, depthBias: 0.0014, pickable: 0))
        // The extrude handle is drawn on top of everything so it can always be grabbed.
        enc.setDepthStencilState(onTopDepthState)
        let handleColor = overlay.handleInvalid ? p.invalid : p.handle
        segments(overlay.handle, overlay.handleCount,
                 DrawParams(color: handleColor, hoverColor: overlay.handleInvalid ? p.invalid : hover, selectColor: select,
                            thickness: 3 * scale, depthBias: 0, pickable: 1))
        if let handle = overlay.handle, overlay.handleCount > 1 {
            var tip = DrawParams(color: handleColor, hoverColor: overlay.handleInvalid ? p.invalid : hover, selectColor: select,
                                 thickness: 11 * scale, depthBias: 0, pickable: 1)
            enc.setVertexBuffer(handle, offset: MemoryLayout<SegmentInstance>.stride * (overlay.handleCount - 1), index: 0)
            enc.setVertexBytes(&tip, length: MemoryLayout<DrawParams>.stride, index: 3)
            enc.setFragmentBytes(&tip, length: MemoryLayout<DrawParams>.stride, index: 3)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
        }
        enc.endEncoding()

        if let pick = pickRequest, let idTexture,
           pick.x >= 0, pick.y >= 0, pick.x < idTexture.width, pick.y < idTexture.height,
           let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: idTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: pick.x, y: pick.y, z: 0),
                      sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: pickBuffer, destinationOffset: 0,
                      destinationBytesPerRow: 4, destinationBytesPerImage: 4)
            blit.endEncoding()
            pickRequest = nil
            nonisolated(unsafe) let buffer = pickBuffer
            let callback = onPick
            cmd.addCompletedHandler { _ in
                let id = buffer.contents().load(as: UInt32.self)
                Task { @MainActor in callback?(id) }
            }
        }
        cmd.present(drawable)
        cmd.commit()
    }
}
