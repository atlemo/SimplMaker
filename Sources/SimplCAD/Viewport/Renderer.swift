// Metal renderer: shaded faces, screen-space edges, grid, and an ID buffer for picking.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADKernel
import Metal
import MetalKit
import simd

/// What the pick buffer encodes (0 = nothing):
///   body face  (body+1) << 20 | face           (bodies < 1023)
///   body edge  0x8000_0000 | (body+1) << 20 | edge
///   sketch     0x4000_0000 point, 0x5000_0000 curve, 0x6000_0000 profile region | index
struct PickID: Hashable, Sendable {
    enum Kind: Sendable { case none, face, edge, sketchPoint, sketchCurve, region }
    static let edgeFlag: UInt32 = 0x8000_0000
    static let sketchFlag: UInt32 = 0x4000_0000
    var raw: UInt32

    init(raw: UInt32) { self.raw = raw }
    init(body: Int, face: Int) { raw = UInt32(body + 1) << 20 | UInt32(face) }
    init(body: Int, edge: Int) { raw = PickID.edgeFlag | UInt32(body + 1) << 20 | UInt32(edge) }
    init(sketchPoint i: Int) { raw = 0x4000_0000 | UInt32(i) }
    init(sketchCurve i: Int) { raw = 0x5000_0000 | UInt32(i) }
    init(region i: Int) { raw = 0x6000_0000 | UInt32(i) }

    var kind: Kind {
        if raw == 0 { return .none }
        if raw & PickID.edgeFlag != 0 { return .edge }
        if raw & PickID.sketchFlag != 0 {
            switch (raw >> 28) & 0x3 {
            case 0: return .sketchPoint
            case 1: return .sketchCurve
            default: return .region
            }
        }
        return .face
    }
    var isEdge: Bool { kind == .edge }
    var isFace: Bool { kind == .face }
    /// Body index (faces and edges only).
    var body: Int { Int((raw & 0x3FF0_0000) >> 20) - 1 }
    /// Face/edge index within the body, or the sketch point/curve/region index.
    var element: Int {
        switch kind {
        case .face, .edge: return Int(raw & 0xFFFFF)
        default: return Int(raw & 0x0FFF_FFFF)
        }
    }
}

/// Sketch geometry to draw on top of the bodies.
struct SketchOverlay {
    var regionVertices: [FaceVertex] = []
    var regionIndices: [UInt32] = []
    var curves: [SegmentInstance] = []
    var construction: [SegmentInstance] = []
    var inactive: [SegmentInstance] = []   // other visible sketches: thin, not pickable
    var preview: [SegmentInstance] = []
    var points: [SegmentInstance] = []     // zero-length segments drawn as squares
    var fullyConstrained = false
}

struct Uniforms {
    var viewProj: simd_float4x4
    var eye: SIMD4<Float>
    var viewport: SIMD2<Float>
    var hovered: UInt32
    var selectedCount: UInt32
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
    private let depthState: MTLDepthStencilState

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
        var curves: MTLBuffer?, curveCount = 0
        var construction: MTLBuffer?, constructionCount = 0
        var inactive: MTLBuffer?, inactiveCount = 0
        var preview: MTLBuffer?, previewCount = 0
        var points: MTLBuffer?, pointCount = 0
        var fullyConstrained = false
    }
    private var overlay = GPUOverlay()

    private var idTexture: MTLTexture?
    private let pickBuffer: MTLBuffer

    var camera = Camera()
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
        } catch {
            print("SimplCAD: Metal setup failed: \(error)")
            return nil
        }
        let ds = MTLDepthStencilDescriptor()
        ds.depthCompareFunction = .lessEqual
        ds.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: ds) else { return nil }
        self.depthState = depthState
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
        g.curves = makeBuffer(o.curves); g.curveCount = o.curves.count
        g.construction = makeBuffer(o.construction); g.constructionCount = o.construction.count
        g.inactive = makeBuffer(o.inactive); g.inactiveCount = o.inactive.count
        g.preview = makeBuffer(o.preview); g.previewCount = o.preview.count
        g.points = makeBuffer(o.points); g.pointCount = o.points.count
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
                                hovered: hovered, selectedCount: UInt32(min(selected.count, 256)))
        var sel = Array(selected.prefix(256))
        if sel.isEmpty { sel = [0] }
        let scale = Float(view.window?.backingScaleFactor ?? 2)

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

        enc.setRenderPipelineState(segmentPipeline)
        func segments(_ buffer: MTLBuffer?, _ count: Int, _ params: DrawParams) {
            guard let buffer, count > 0 else { return }
            var p = params
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&p, length: MemoryLayout<DrawParams>.stride, index: 3)
            enc.setFragmentBytes(&p, length: MemoryLayout<DrawParams>.stride, index: 3)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        let gridColor = SIMD4<Float>(0.8, 0.82, 0.86, 1)
        segments(grid, gridCount, DrawParams(color: gridColor, hoverColor: gridColor, selectColor: gridColor,
                                             thickness: 1 * scale, depthBias: 0, pickable: 0))
        for (buffer, color) in axes {
            segments(buffer, 1, DrawParams(color: color, hoverColor: color, selectColor: color,
                                           thickness: 1.5 * scale, depthBias: 0.0001, pickable: 0))
        }
        for b in bodies {
            segments(b.segments, b.segmentCount,
                     DrawParams(color: SIMD4(0.12, 0.13, 0.16, 1), hoverColor: SIMD4(0.1, 0.5, 1, 1),
                                selectColor: SIMD4(0.0, 0.35, 1, 1), thickness: 1.6 * scale,
                                depthBias: 0.0004, pickable: 1))
        }
        // Sketch overlay, drawn last with increasing depth bias so it sits on top of faces it lies on.
        let hover = SIMD4<Float>(0.1, 0.55, 1, 1), select = SIMD4<Float>(0.95, 0.45, 0.05, 1)
        segments(overlay.inactive, overlay.inactiveCount,
                 DrawParams(color: SIMD4(0.35, 0.45, 0.7, 1), hoverColor: hover, selectColor: select,
                            thickness: 1.2 * scale, depthBias: 0.0006, pickable: 0))
        let curveColor: SIMD4<Float> = overlay.fullyConstrained ? SIMD4(0.08, 0.08, 0.1, 1) : SIMD4(0.1, 0.3, 0.85, 1)
        segments(overlay.curves, overlay.curveCount,
                 DrawParams(color: curveColor, hoverColor: hover, selectColor: select,
                            thickness: 2 * scale, depthBias: 0.0008, pickable: 1))
        segments(overlay.construction, overlay.constructionCount,
                 DrawParams(color: SIMD4(0.9, 0.55, 0.15, 1), hoverColor: hover, selectColor: select,
                            thickness: 1.4 * scale, depthBias: 0.0008, pickable: 1))
        segments(overlay.preview, overlay.previewCount,
                 DrawParams(color: SIMD4(0.45, 0.45, 0.5, 1), hoverColor: hover, selectColor: select,
                            thickness: 1.5 * scale, depthBias: 0.0009, pickable: 0))
        segments(overlay.points, overlay.pointCount,
                 DrawParams(color: SIMD4(0.15, 0.2, 0.35, 1), hoverColor: hover, selectColor: select,
                            thickness: 7 * scale, depthBias: 0.0012, pickable: 1))
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
