// Metal renderer: shaded faces, screen-space edges, grid, and an ID buffer for picking.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Metal
import MetalKit
import simd

/// What the pick buffer encodes (0 = nothing):
///   body face  (body+1) << 20 | face           (bodies < 1023)
///   body edge  0x8000_0000 | (body+1) << 20 | edge
///   sketch     0x4000_0000 point, 0x5000_0000 curve, 0x6000_0000 profile region | slot << 16 | index
///              (slot 0 = the sketch being edited, n = the n-th sketch in the document)
///   handle     0x7000_0000 (the extrude drag handle), 0x7000_0001 (the dot that moves a hole),
///              0x7000_0002 (a hole's diameter arrow), 0x7000_0003 (the dot of an extrude's taper dial),
///              0x7000_0004 (the arrow that slides the section analysis's cutting plane)
///   plane      0x7100_0000 | index (an origin plane offered when choosing where to sketch)
///   plane edge 0x7200_0000 | plane << 8 | edge (a construction plane's border: 0 bottom, 1 right, 2 top, 3 left)
struct PickID: Hashable, Sendable {
    enum Kind: Sendable { case none, face, edge, sketchPoint, sketchCurve, region, handle, plane, planeEdge }
    static let edgeFlag: UInt32 = 0x8000_0000
    static let sketchFlag: UInt32 = 0x4000_0000
    static let planeFlag: UInt32 = 0x0100_0000
    static let planeEdgeFlag: UInt32 = 0x0200_0000
    var raw: UInt32

    init(raw: UInt32) { self.raw = raw }
    init(body: Int, face: Int) { raw = UInt32(body + 1) << 20 | UInt32(face) }
    init(body: Int, edge: Int) { raw = PickID.edgeFlag | UInt32(body + 1) << 20 | UInt32(edge) }
    init(sketchPoint i: Int, slot: Int = 0) { raw = 0x4000_0000 | UInt32(slot & 0xFFF) << 16 | UInt32(i & 0xFFFF) }
    init(sketchCurve i: Int, slot: Int = 0) { raw = 0x5000_0000 | UInt32(slot & 0xFFF) << 16 | UInt32(i & 0xFFFF) }
    init(region i: Int, slot: Int = 0) { raw = 0x6000_0000 | UInt32(slot & 0xFFF) << 16 | UInt32(i & 0xFFFF) }
    init(plane i: Int) { raw = 0x7000_0000 | PickID.planeFlag | UInt32(i) }
    init(planeEdge edge: Int, plane i: Int) { raw = 0x7000_0000 | PickID.planeEdgeFlag | UInt32(i & 0xFF) << 8 | UInt32(edge & 0xF) }
    /// A whole body, picked from the browser (no real face has this index). It counts as a face of
    /// the body for tools that pick bodies, and the highlight covers every face.
    init(wholeBody i: Int) { raw = UInt32(i + 1) << 20 | 0xFFFFF }
    var isWholeBody: Bool { isFace && raw & 0xFFFFF == 0xFFFFF }
    static let handle = PickID(raw: 0x7000_0000)
    /// The dot at a selected hole's centre, dragged to slide the hole over its face.
    static let moveHandle = PickID(raw: 0x7000_0001)
    /// A hole's second arrow, for its diameter (the first, `handle`, is its depth).
    static let diameterHandle = PickID(raw: 0x7000_0002)
    /// The dot on an extrude's taper dial (the third handle of the feature).
    static let dialHandle = PickID(raw: 0x7000_0003)
    /// The arrow that slides the section analysis's cutting plane in and out.
    static let sectionHandle = PickID(raw: 0x7000_0004)
    /// Which side of a construction plane a plane-edge pick is: 0 bottom, 1 right, 2 top, 3 left.
    var planeEdge: Int { Int(raw & 0xF) }
    /// Which of a feature's arrows this picks (0 for any other pick).
    var handleSlot: Int { self == PickID.dialHandle ? 2 : self == PickID.diameterHandle ? 1 : 0 }

    var kind: Kind {
        if raw == 0 { return .none }
        if raw & PickID.edgeFlag != 0 { return .edge }
        if raw & PickID.sketchFlag != 0 {
            switch (raw >> 28) & 0x3 {
            case 0: return .sketchPoint
            case 1: return .sketchCurve
            case 2: return .region
            default:
                if raw & PickID.planeEdgeFlag != 0 { return .planeEdge }
                return raw & PickID.planeFlag != 0 ? .plane : .handle
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
        case .planeEdge: return Int((raw >> 8) & 0xFF)
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

/// A reference image to draw: a picture on a quad in world space.
struct ImageDraw {
    var id: FeatureID
    /// The image file's contents; the texture is made again only when they change.
    var data: Data
    /// Top left, top right, bottom right, bottom left, as the picture reads.
    var corners: [SIMD3<Float>]
    var opacity: Float
}

struct ImageParams {
    var corners: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var opacity: Float
    var depthBias: Float
    var pad: SIMD2<Float> = .zero
}

/// Sketch geometry to draw on top of the bodies.
struct SketchOverlay {
    var regionVertices: [FaceVertex] = []
    var regionIndices: [UInt32] = []
    /// Origin planes offered while choosing where to sketch: 4 vertices and 6 indices per plane.
    var planeVertices: [FaceVertex] = []
    var planeIndices: [UInt32] = []
    /// How many of the planes, the first ones, are origin planes: the planes after them are the user's own
    /// construction planes, drawn over the origin planes so one that overlaps them can still be picked.
    var originPlaneCount = 0
    var planeOutline: [SegmentInstance] = []
    /// The borders of the construction planes, one segment per side, to drag a side and resize the plane.
    var planeEdges: [SegmentInstance] = []
    /// A plane is being asked for: planes show through bodies, and their borders pick through them,
    /// so one that lies under or inside a body (the floor, under a part sitting on it) can still be chosen.
    var planesSeeThrough = false
    /// Reference images, and the border of the one selected.
    var images: [ImageDraw] = []
    var imageBorder: [SegmentInstance] = []
    var curves: [SegmentInstance] = []
    var construction: [SegmentInstance] = []
    /// A sketch axis picked to constrain against, drawn in the selection colour over the sketch's own axis.
    var axisSelected: [SegmentInstance] = []
    var inactive: [SegmentInstance] = []   // finished sketches: thin, pickable as paths and axes
    var preview: [SegmentInstance] = []
    var points: [SegmentInstance] = []     // zero-length segments drawn as squares
    var handle: [SegmentInstance] = []     // drag handle: shaft + tip (zero-length)
    var moveHandle: [SegmentInstance] = [] // a hole's move dot (zero-length)
    var dialDot: [SegmentInstance] = []    // the dot on an extrude's taper dial (zero-length)
    var dialArc: [SegmentInstance] = []    // the dial's arc, faded out toward its ends (the id carries the fade, see DrawStyle.fade)
    var snap: [SegmentInstance] = []       // where the cursor snapped: a zero-length marker
    var measure: [SegmentInstance] = []    // the Measure tool's line between two pieces, drawn over the bodies
    var measurePoints: [SegmentInstance] = []  // and its ends (zero-length)
    var section: [SegmentInstance] = []    // the border of the section analysis's cutting plane
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
    var wholeBodies: UInt32 = 0
    /// Sketching: faces are lit evenly from the camera's side (see shadeFace), so no glare sweeps over them.
    var evenLight: UInt32 = 0
    /// The print preview's layer height and nozzle width, in mm (see printLook in the shader).
    var printLayer: Float = 0.2
    var printNozzle: Float = 0.4
    /// Section analysis: the unit normal and distance of the cutting plane (the side where dot(p, n) > d is cut
    /// away), the camera's direction (w = 1: parallel rays), and whether the cut is on.
    var clipPlane: SIMD4<Float> = .zero
    var viewDir: SIMD4<Float> = .zero
    var clipOn: UInt32 = 0
    var padClip2: Float = 0
    /// How many ids follow the selected ones in the selection buffer: profiles lit like the hovered one (see Renderer.hoverGroup).
    var hoverGroupCount: UInt32 = 0
    var padClip1: UInt32 = 0
    /// The Render view's main light: xyz = the unit vector toward it, w = its strength.
    var lightDir: SIMD4<Float> = .zero
    /// The Render view: x = 1 when it is on, y = the ambient light, z = 1 while the reflection is drawn, w = its strength.
    var renderParams: SIMD4<Float> = .zero
    /// The Render view's shadow map: the main light's view of the bodies.
    var lightViewProj = matrix_identity_float4x4
    /// x = 1 when shadows are on, y = how wide the light is, w = the depth the map covers, in mm.
    var shadowParams: SIMD4<Float> = .zero
    /// xy = what the map covers, in mm, z = a texel of it, in mm, w = the height a reflection fades out at.
    var shadowExtent: SIMD4<Float> = .zero
    /// The camera's right and up, so the everyday key light can sit at a fixed spot in the view (see shadeFace).
    var cameraRight: SIMD4<Float> = SIMD4(1, 0, 0, 0)
    var cameraUp: SIMD4<Float> = SIMD4(0, 0, 1, 0)
    /// The Render view: xyz = the middle of the part, w = the size of the room a shiny face reflects (see shadeFace).
    var sceneCenter: SIMD4<Float> = SIMD4(0, 0, 0, 100)
}

/// The Render view's floor, as the shader reads it (see floorVertex).
struct FloorParams {
    /// xy = the middle of the part, z = the floor's height, w = half the floor's side.
    var centerHalf: SIMD4<Float>
    /// rgb = the floor's colour as lit, w = where it starts to fade into the backdrop (distance from the middle).
    var lit: SIMD4<Float>
    /// rgb = the backdrop, w = where the fade ends.
    var backdrop: SIMD4<Float>
    /// rgb = the floor where the main light does not reach.
    var shadowed: SIMD4<Float>
}

/// The grid drawn in the plane of the sketch being edited: minor and major lines over the visible
/// area, and the sketch's own axes through its origin. Ranges are in sketch mm, on major lines.
struct SketchGrid: Equatable {
    var frame: Frame
    var minor: Double
    var major: Double
    var u: ClosedRange<Double>
    var v: ClosedRange<Double>
    /// Grid lines (off with View ▸ Show Grid); the axes always show.
    var lines: Bool
}

/// Viewport colours for the current appearance (light/dark) and Increase Contrast.
struct ViewportPalette: Equatable {
    var background: SIMD4<Float>
    var grid: SIMD4<Float>
    /// Sketch mode: faint minor grid lines, and its horizontal / vertical axes.
    var gridMinor: SIMD4<Float>
    var sketchAxisU: SIMD4<Float>, sketchAxisV: SIMD4<Float>
    var axes: (x: SIMD4<Float>, y: SIMD4<Float>, z: SIMD4<Float>)
    var face, faceHover, faceSelected: SIMD4<Float>
    var edge, hover, selection: SIMD4<Float>
    /// A selected sketch curve or point: not a blue, so it stands out from the sketch's own and the hover colour.
    var sketchSelected: SIMD4<Float>
    /// Edges in the wireframe styles, where they're drawn over the background instead of a face.
    var wireEdge: SIMD4<Float>
    var sketch, sketchConstrained, construction, preview, point, inactiveSketch, handle, invalid: SIMD4<Float>
    var region: SIMD4<Float>
    /// Origin planes offered when choosing where to sketch (rgb + fill alpha; outlines are opaque).
    var plane: SIMD4<Float>
    /// Line width multiplier (thicker with Increase Contrast).
    var lineScale: Float

    static func == (a: ViewportPalette, b: ViewportPalette) -> Bool {
        a.background == b.background && a.face == b.face && a.lineScale == b.lineScale && a.sketch == b.sketch
    }

    static func make(dark: Bool, increaseContrast: Bool, paper: SIMD3<Float>? = nil) -> ViewportPalette {
        var p: ViewportPalette
        if dark {
            p = ViewportPalette(
                background: SIMD4(0.12, 0.125, 0.14, 1), grid: SIMD4(0.24, 0.25, 0.28, 1),
                gridMinor: SIMD4(0.165, 0.17, 0.19, 1), sketchAxisU: SIMD4(0.5, 0.52, 0.56, 1), sketchAxisV: SIMD4(0.35, 0.78, 0.4, 1),
                axes: (SIMD4(0.9, 0.35, 0.35, 1), SIMD4(0.4, 0.8, 0.45, 1), SIMD4(0.4, 0.55, 1, 1)),
                face: SIMD4(0.56, 0.59, 0.64, 1), faceHover: SIMD4(0.52, 0.66, 0.88, 1), faceSelected: SIMD4(0.25, 0.52, 1, 1),
                edge: SIMD4(0.04, 0.04, 0.05, 1), hover: SIMD4(0.45, 0.72, 1, 1), selection: SIMD4(0.2, 0.55, 1, 1),
                sketchSelected: SIMD4(1, 0.4, 0.75, 1),
                wireEdge: SIMD4(0.8, 0.82, 0.86, 1),
                sketch: SIMD4(0.45, 0.68, 1, 1), sketchConstrained: SIMD4(0.35, 0.9, 0.45, 1),
                construction: SIMD4(1, 0.62, 0.25, 1), preview: SIMD4(0.65, 0.65, 0.7, 1), point: SIMD4(0.85, 0.87, 0.92, 1),
                inactiveSketch: SIMD4(0.5, 0.6, 0.85, 1), handle: SIMD4(1, 0.58, 0.1, 1), invalid: SIMD4(1, 0.3, 0.3, 1),
                region: SIMD4(0.35, 0.6, 1, 0.18), plane: SIMD4(1, 0.65, 0.2, 0.22), lineScale: 1)
        } else {
            p = ViewportPalette(
                background: SIMD4(0.95, 0.96, 0.97, 1), grid: SIMD4(0.8, 0.82, 0.86, 1),
                gridMinor: SIMD4(0.89, 0.9, 0.92, 1), sketchAxisU: SIMD4(0.55, 0.56, 0.6, 1), sketchAxisV: SIMD4(0.5, 0.86, 0.5, 1),
                axes: (SIMD4(0.85, 0.25, 0.25, 1), SIMD4(0.25, 0.7, 0.3, 1), SIMD4(0.3, 0.45, 0.9, 1)),
                face: SIMD4(0.64, 0.67, 0.72, 1), faceHover: SIMD4(0.55, 0.72, 0.95, 1), faceSelected: SIMD4(0.3, 0.56, 1, 1),
                edge: SIMD4(0.12, 0.13, 0.16, 1), hover: SIMD4(0.1, 0.55, 1, 1), selection: SIMD4(0, 0.4, 1, 1),
                sketchSelected: SIMD4(0.85, 0.08, 0.55, 1),
                wireEdge: SIMD4(0.12, 0.13, 0.16, 1),
                sketch: SIMD4(0.1, 0.3, 0.85, 1), sketchConstrained: SIMD4(0.1, 0.62, 0.25, 1),
                construction: SIMD4(0.9, 0.55, 0.15, 1), preview: SIMD4(0.45, 0.45, 0.5, 1), point: SIMD4(0.15, 0.2, 0.35, 1),
                inactiveSketch: SIMD4(0.35, 0.45, 0.7, 1), handle: SIMD4(0.95, 0.5, 0.05, 1), invalid: SIMD4(0.9, 0.12, 0.12, 1),
                region: SIMD4(0.25, 0.5, 0.95, 0.16), plane: SIMD4(0.95, 0.6, 0.15, 0.2), lineScale: 1)
        }
        if increaseContrast {
            p.lineScale = 1.6
            p.grid = dark ? SIMD4(0.4, 0.42, 0.46, 1) : SIMD4(0.6, 0.62, 0.66, 1)
            p.gridMinor = dark ? SIMD4(0.28, 0.29, 0.32, 1) : SIMD4(0.75, 0.77, 0.8, 1)
            p.edge = dark ? SIMD4(0, 0, 0, 1) : SIMD4(0, 0, 0, 1)
            p.wireEdge = dark ? SIMD4(0.96, 0.96, 0.98, 1) : SIMD4(0, 0, 0, 1)
            p.region.w = 0.3
            p.plane.w = 0.35
        }
        if let paper {
            // Tinted drafting paper: the grid is the paper itself, a little darker (lighter in a dark window).
            func line(_ strength: Float) -> SIMD4<Float> {
                let ink: SIMD3<Float> = dark ? SIMD3(1, 1, 1) : SIMD3(0.1, 0.2, 0.4)
                let s = increaseContrast ? strength * 1.8 : strength
                return SIMD4(simd_mix(paper, ink, SIMD3(repeating: s)), 1)
            }
            p.background = SIMD4(paper, 1)
            p.gridMinor = line(dark ? 0.07 : 0.12)
            p.grid = line(dark ? 0.15 : 0.25)
        }
        return p
    }
}

struct FaceVertex {
    var px, py, pz: Float
    var nx, ny, nz: Float
    var id: UInt32
}

/// A corner of a triangle drawn for the print preview, which needs to know how far a point is from the edge of its
/// face (the layout of PrintVertex in the shader).
struct PrintVertex {
    var px, py, pz: Float
    var nx, ny, nz: Float
    var id: UInt32
    /// The mesh vertices of the triangle's corners.
    var c0, c1, c2: UInt32
    /// Bit j: corner j is on the boundary of the face.
    var mask: UInt32
}

/// A mesh vertex, and the vertices next to it along the boundary of its face (w = 0: there is none).
struct PrintCorner {
    var p: SIMD4<Float>
    var a: SIMD4<Float>
    var b: SIMD4<Float>
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
    /// A selected body edge's, sketch curve's or point's width, in pixels; 0 = it keeps its width.
    var selectedThickness: Float = 0
    /// How to draw (DrawStyle bits).
    var style: UInt32 = 0
    /// An arrowhead's outline layer reaches this far past its edge, in pixels.
    var grow: Float = 0
    /// The rounding of an arrowhead's corners, in pixels.
    var radius: Float = 0
    /// A segment shorter than this on screen is drawn this long, in pixels; 0 = as it is.
    var minLength: Float = 0
    /// An arrowhead's outline reaches this far past its slanted sides, in pixels (`grow` is the rest).
    var growSide: Float = 0
    /// A dashed line's dashes start this far apart, and are this long, in pixels; `radius` is half a
    /// dash's width and `grow` the reach of its outline.
    var dashPitch: Float = 0
    var dashLength: Float = 0
    /// The Render view's material: 0 plain, 1 metal, 2 glass, 3 wood (see shadeFace).
    var material: UInt32 = 0
}

/// Ways of drawing, as DrawParams.style bits.
enum DrawStyle {
    /// A line shows only while hovered or selected.
    static let highlightedOnly: UInt32 = 1
    static let dashed: UInt32 = 2
    /// A face in its plain colour, without lighting.
    static let flat: UInt32 = 4
    /// A segment drawn as an arrowhead: a triangle whose tip is the segment's end.
    static let arrowHead: UInt32 = 8
    /// A line drawn as rounded dashes, from its start (see DrawParams.dashPitch).
    static let dashedRound: UInt32 = 32
    /// A zero-length segment drawn as a round dot, as wide as `thickness`.
    static let roundDot: UInt32 = 64
    /// A body edge, cut by the section analysis's plane (see Renderer.sectionPlane).
    static let clipped: UInt32 = 128
    /// A face drawn only where the section analysis shows the cut face (see sectionFace in the shader), not elsewhere.
    static let capsOnly: UInt32 = 256
    /// A line whose opacity runs from the start's to the end's along each segment: the segment's id holds both, as
    /// 16-bit fractions (start in the low half, end in the high half). Its ends are cut square so neighbours don't overlap.
    static let fade: UInt32 = 512
    /// A line that fades in along each segment, from nothing at its start to full strength toward its end (an arrow's shaft).
    static let fadeAlong: UInt32 = 1024
    /// Glass: only the faces turned away from the viewer (the far wall), or only those turned toward it.
    static let glassBack: UInt32 = 2048
    static let glassFront: UInt32 = 4096
}

/// How bodies are drawn (View ▸ Visual Style), as in Fusion.
enum VisualStyle: String, CaseIterable, Identifiable, Sendable {
    case shaded, shadedWithHiddenEdges, shadedWithVisibleEdges, wireframe, wireframeWithHiddenEdges, wireframeWithVisibleEdges

    var id: String { rawValue }
    static let standard = VisualStyle.shadedWithVisibleEdges

    var title: String {
        switch self {
        case .shaded: return "Shaded"
        case .shadedWithHiddenEdges: return "Shaded with Hidden Edges"
        case .shadedWithVisibleEdges: return "Shaded with Visible Edges Only"
        case .wireframe: return "Wireframe"
        case .wireframeWithHiddenEdges: return "Wireframe with Hidden Edges"
        case .wireframeWithVisibleEdges: return "Wireframe with Visible Edges Only"
        }
    }

    /// Faces are shaded (otherwise the edges are what show).
    var isShaded: Bool { self == .shaded || self == .shadedWithHiddenEdges || self == .shadedWithVisibleEdges }
    /// Edges behind faces show too, dashed.
    var showsHiddenEdges: Bool { self == .shadedWithHiddenEdges || self == .wireframeWithHiddenEdges }
}

@MainActor
final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let facePipeline: MTLRenderPipelineState
    /// Glass: the faces blended over what is behind them, after the floor.
    private let glassPipeline: MTLRenderPipelineState
    private let printFacePipeline: MTLRenderPipelineState
    /// The faces again with the section analysis's cut face (and its own depth), plain and as a print preview.
    private let sectionFacePipeline: MTLRenderPipelineState
    private let sectionPrintPipeline: MTLRenderPipelineState
    /// Faces in the ID buffer and depth only (the Wireframe style: faces can be picked but don't show).
    private let faceIDPipeline: MTLRenderPipelineState
    private let segmentPipeline: MTLRenderPipelineState
    /// Lines drawn only to be seen (grid, axes, previews, the snap marker): they write colour but
    /// leave the ID buffer alone, so they never hide what's picked beneath them.
    private let decorationPipeline: MTLRenderPipelineState
    /// For shapes the fragment shader cuts out (rounded arrowheads, dashes): their edges are antialiased
    /// by alpha-to-coverage, which needs multisampling (without it they have hard edges).
    private let shapePipeline: MTLRenderPipelineState
    private let shapeDecorationPipeline: MTLRenderPipelineState
    /// For lines that fade out (the taper dial's arc): blended, so a translucent line shows what is behind it.
    private let fadePipeline: MTLRenderPipelineState
    /// The same for an arrow's shaft, which can also be picked (`Shape`: its dashes are antialiased by the blending).
    private let fadeShapePipeline: MTLRenderPipelineState
    private let fadeShapeDecorationPipeline: MTLRenderPipelineState
    /// Reads a pixel of the multisampled ID buffer.
    private var pickSamplePipeline: MTLComputePipelineState?
    /// Samples per pixel (View ▸ Settings ▸ Viewport ▸ Antialiasing), fixed at launch.
    let sampleCount: Int
    /// Lines written to the ID buffer only: an unseen band around each body edge, so a click
    /// just beside an edge still picks it.
    private let pickBandPipeline: MTLRenderPipelineState
    private let hiddenPlanePipeline: MTLRenderPipelineState
    private let regionPipeline: MTLRenderPipelineState
    private let planePipeline: MTLRenderPipelineState
    private let imagePipeline: MTLRenderPipelineState
    /// The Render view's floor: colour only, so it never hides what is picked.
    private let floorPipeline: MTLRenderPipelineState
    /// The shadow map: the bodies' depth from the main light.
    private let shadowPipeline: MTLRenderPipelineState
    /// The reflection in the floor: its depth first, so each pixel is blended once, then its colour.
    private let reflectDepthPipeline: MTLRenderPipelineState
    private let reflectPipeline: MTLRenderPipelineState
    /// A blurred reflection: many tilted mirror views added up in a texture (depth first, then colour, per view), then
    /// laid over the floor.
    private let blurDepthPipeline: MTLRenderPipelineState
    private let blurAccumulatePipeline: MTLRenderPipelineState
    private let blurCompositePipeline: MTLRenderPipelineState
    /// The Render view's grain: added to what is there, and taken away from it.
    private let noiseAddPipeline: MTLRenderPipelineState
    private let noiseTakePipeline: MTLRenderPipelineState
    private var reflectionTexture: MTLTexture?
    private var reflectionDepth: MTLTexture?
    /// How many mirror views make up a blurred reflection.
    static let reflectionViews = 16
    private var shadowMap: MTLTexture?
    /// Bound where no shadow map is wanted, as the shaders always take one.
    private let emptyShadowMap: MTLTexture
    static let shadowMapSize = 2048
    private let depthState: MTLDepthStencilState
    /// Body edges while the section analysis cuts: not where its cut face shows (stencil 1, set by `capState`).
    private let depthCutState: MTLDepthStencilState
    private let noWriteCutState: MTLDepthStencilState
    private let hiddenCutState: MTLDepthStencilState
    /// The cut face's own draw: like `depthState`, and marks the pixels it wins with stencil 1.
    private let capState: MTLDepthStencilState
    private let onTopDepthState: MTLDepthStencilState
    /// Depth-tested but not depth-writing: translucent planes hide nothing drawn after them.
    private let noWriteDepthState: MTLDepthStencilState
    /// Only where something nearer is already drawn (the hidden part of a plane), without writing depth.
    private let hiddenDepthState: MTLDepthStencilState
    /// Over everything, without writing depth.
    private let overEverythingDepthState: MTLDepthStencilState

    private struct GPUBody {
        var faces: MTLBuffer?
        var indices: MTLBuffer?
        var indexCount = 0
        var segments: MTLBuffer?
        var segmentCount = 0
        /// The triangles apart, with their distances to the face's edge: made when the print preview first needs them.
        var printFaces: MTLBuffer?
        var printCorners: MTLBuffer?
        var printVertexCount = 0
    }
    private var bodies: [GPUBody] = []
    /// Each body's own colour, in the order of setScene's meshes; nil = the palette's face colour.
    /// Set apart from the meshes, so a colour change doesn't upload them again.
    var bodyColors: [SIMD4<Float>?] = []
    /// Each body's material (0 plain, 1 metal, 2 glass, 3 wood), in the same order. Only the Render view shows them.
    var bodyMaterials: [UInt32] = []
    /// How long the GPU took over the last frame, in seconds (for timing tests).
    nonisolated(unsafe) private(set) var lastGPUSeconds: Double = 0
    /// The ground grid (the XY plane when not sketching): rebuilt as the view moves, to cover what's in view.
    private var worldGrid: (key: WorldGridKey, minor: MTLBuffer?, minorCount: Int, major: MTLBuffer?, majorCount: Int)?
    private var axes: [(MTLBuffer, SIMD4<Float>)] = []
    private var axesLength: Float = 0
    /// While sketching: the grid in the sketch's plane (replaces the world grid and axes).
    private(set) var sketchGrid: SketchGrid?
    private var sketchGridBuffers: (minor: MTLBuffer?, minorCount: Int, major: MTLBuffer?, majorCount: Int,
                                    axisU: MTLBuffer?, axisV: MTLBuffer?) = (nil, 0, nil, 0, nil, nil)

    private struct GPUOverlay {
        var regions: MTLBuffer?
        var regionIndices: MTLBuffer?
        var regionIndexCount = 0
        var planes: MTLBuffer?
        var planeIndices: MTLBuffer?
        /// One centre per plane (6 indices each), to draw them back to front.
        var planeCenters: [SIMD3<Float>] = []
        var originPlaneCount = 0
        var planeOutline: MTLBuffer?, planeOutlineCount = 0
        var planeEdges: MTLBuffer?, planeEdgeCount = 0
        var planesSeeThrough = false
        /// Images with their textures, farthest first once drawn (see draw).
        var images: [(draw: ImageDraw, texture: MTLTexture)] = []
        var imageBorder: MTLBuffer?, imageBorderCount = 0
        var curves: MTLBuffer?, curveCount = 0
        var construction: MTLBuffer?, constructionCount = 0
        var axisSelected: MTLBuffer?, axisSelectedCount = 0
        var inactive: MTLBuffer?, inactiveCount = 0
        var preview: MTLBuffer?, previewCount = 0
        var points: MTLBuffer?, pointCount = 0
        var handle: MTLBuffer?, handleCount = 0
        var moveHandle: MTLBuffer?, moveHandleCount = 0
        var dialDot: MTLBuffer?, dialDotCount = 0
        var dialArc: MTLBuffer?, dialArcCount = 0
        var snap: MTLBuffer?, snapCount = 0
        var measure: MTLBuffer?, measureCount = 0
        var measurePoints: MTLBuffer?, measurePointCount = 0
        var section: MTLBuffer?, sectionCount = 0
        var handleInvalid = false
        var fullyConstrained = false
    }
    private var overlay = GPUOverlay()
    /// The textures made for reference images, kept while their picture stays the same.
    private var imageTextures: [FeatureID: (data: Data, texture: MTLTexture)] = [:]

    private var idTexture: MTLTexture?
    private let pickBuffer: MTLBuffer

    var camera = Camera()
    var palette = ViewportPalette.make(dark: false, increaseContrast: false)
    var showGrid = true
    /// The red, green and blue X, Y and Z axes through the origin.
    var showAxes = true
    var visualStyle = VisualStyle.standard
    /// Bodies drawn as if FDM printed. Only for the shaded styles, and without edges, which would spoil it.
    var printPreview = false
    /// The print preview's layer height and nozzle width, in mm.
    var printLayer: Float = 0.2
    var printNozzle: Float = 0.4
    /// The Render view's floor and light; nil: not rendering. Only for the shaded styles, and not while sketching.
    var renderSettings: RenderSettings?
    /// What the bodies take up, for the size of the Render view's floor.
    var sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    /// Section analysis: the plane the bodies are cut by, as its unit normal and its distance from the origin along
    /// it; what lies on the side the normal points to is cut away. Nil: not cutting.
    var sectionPlane: SIMD4<Float>?
    /// Sketching with the slice on: the sketch plane, which everything between it and the camera is cut away at.
    var sketchSlice: (origin: SIMD3<Float>, normal: SIMD3<Float>)?
    var hovered: UInt32 = 0
    /// Other profiles that light up with the hovered one: the rest of a text whose letter is under the cursor.
    var hoverGroup: [UInt32] = []
    /// A tool is picking bodies: hovering and selecting a face lights up its whole body.
    var wholeBodies = false
    var selected: [UInt32] = []
    /// Pixel (in drawable coordinates, origin top-left) to read from the ID buffer on the next frame.
    var pickRequest: SIMD2<Int>?
    /// Asks the next frame to hand over its picture, as PNG data (nil if it could not be made): the Render view's
    /// Export render. The view must allow reading its drawable (framebufferOnly off) for that frame.
    var captureHandler: (@MainActor @Sendable (Data?) -> Void)?
    /// Called with the ID under a requested pixel, and that pixel (a result can arrive after the pointer moved on).
    var onPick: (@MainActor @Sendable (UInt32, SIMD2<Int>) -> Void)?

    static let colorFormat = MTLPixelFormat.bgra8Unorm
    /// How wide (in points) a construction plane's side is for clicking and hovering.
    static let edgePickWidth: Float = 5
    /// How wide (in points) a body edge is for clicking and hovering; it is drawn 0.8 wide, so most
    /// of the band is unseen. Wide enough to hit without aiming, narrow enough to leave small faces pickable.
    static let bodyEdgePickWidth: Float = 12
    /// A selected body edge, in the body's highlight colour (blue unless the body has a colour of its own).
    static let selectedEdgeWidth: Float = 4
    /// Depth, and a stencil that marks where the section analysis's cut face shows, so the edges behind it stay hidden.
    static let depthFormat = MTLPixelFormat.depth32Float_stencil8

    /// The antialiasing setting as it was at launch (changing it takes effect on the next launch), cut down to
    /// what the GPU supports.
    private static let launchSetting = Preferences.antialiasingSamples
    static func sampleCount(for device: MTLDevice) -> Int {
        [8, 4, 2].first { $0 <= launchSetting && device.supportsTextureSampleCount($0) } ?? 1
    }

    init?() {
        let emptyDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1, mipmapped: false)
        emptyDescriptor.usage = .shaderRead
        emptyDescriptor.storageMode = .private
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let pickBuffer = device.makeBuffer(length: 16, options: .storageModeShared),
              let empty = device.makeTexture(descriptor: emptyDescriptor) else { return nil }
        self.emptyShadowMap = empty
        let samples = Self.sampleCount(for: device)
        self.sampleCount = samples
        self.device = device
        self.queue = queue
        self.pickBuffer = pickBuffer
        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            func pipeline(_ vertex: String, _ fragment: String, blend: Bool = false, premultiplied: Bool = false,
                          writesID: Bool = true, writesColor: Bool = true,
                          alphaToCoverage: Bool = false) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.rasterSampleCount = samples
                d.isAlphaToCoverageEnabled = alphaToCoverage && samples > 1
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                d.colorAttachments[0].pixelFormat = Renderer.colorFormat
                if blend {  // colour only; the integer ID attachment can't blend
                    d.colorAttachments[0].isBlendingEnabled = true
                    d.colorAttachments[0].sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
                    d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                    d.colorAttachments[0].sourceAlphaBlendFactor = .one
                    d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                if !writesColor { d.colorAttachments[0].writeMask = [] }
                d.colorAttachments[1].pixelFormat = .r32Uint
                if !writesID { d.colorAttachments[1].writeMask = [] }
                d.depthAttachmentPixelFormat = Renderer.depthFormat
                d.stencilAttachmentPixelFormat = Renderer.depthFormat
                return try device.makeRenderPipelineState(descriptor: d)
            }
            facePipeline = try pipeline("faceVertex", "faceFragment")
            glassPipeline = try pipeline("faceVertex", "faceFragment", blend: true, writesID: false)
            printFacePipeline = try pipeline("printFaceVertex", "printFaceFragment")
            sectionFacePipeline = try pipeline("faceVertex", "sectionFaceFragment")
            sectionPrintPipeline = try pipeline("printFaceVertex", "sectionPrintFragment")
            faceIDPipeline = try pipeline("faceVertex", "faceFragment", writesColor: false)
            segmentPipeline = try pipeline("segmentVertex", "segmentFragment")
            decorationPipeline = try pipeline("segmentVertex", "segmentFragment", writesID: false)
            shapePipeline = try pipeline("segmentVertex", "segmentFragment", alphaToCoverage: true)
            shapeDecorationPipeline = try pipeline("segmentVertex", "segmentFragment", writesID: false, alphaToCoverage: true)
            fadePipeline = try pipeline("segmentVertex", "segmentFragment", blend: true, writesID: false)
            fadeShapePipeline = try pipeline("segmentVertex", "segmentFragment", blend: true)
            fadeShapeDecorationPipeline = try pipeline("segmentVertex", "segmentFragment", blend: true, writesID: false)
            if samples > 1, let kernel = library.makeFunction(name: "pickSample") {
                pickSamplePipeline = try device.makeComputePipelineState(function: kernel)
            }
            pickBandPipeline = try pipeline("segmentVertex", "segmentFragment", writesColor: false)
            regionPipeline = try pipeline("regionVertex", "regionFragment", blend: true)
            planePipeline = try pipeline("regionVertex", "planeFragment", blend: true)
            hiddenPlanePipeline = try pipeline("regionVertex", "planeFragment", blend: true, writesID: false)
            imagePipeline = try pipeline("imageVertex", "imageFragment", blend: true, premultiplied: true, writesID: false)
            floorPipeline = try pipeline("floorVertex", "floorFragment", writesID: false)
            reflectDepthPipeline = try pipeline("faceVertex", "faceFragment", writesID: false, writesColor: false)
            reflectPipeline = try pipeline("faceVertex", "faceFragment", blend: true, writesID: false)
            func offscreen(accumulate: Bool) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: "faceVertex")
                d.fragmentFunction = library.makeFunction(name: "reflectionFragment")
                d.colorAttachments[0].pixelFormat = .rgba16Float
                if accumulate {
                    d.colorAttachments[0].isBlendingEnabled = true
                    d.colorAttachments[0].sourceRGBBlendFactor = .one
                    d.colorAttachments[0].destinationRGBBlendFactor = .one
                    d.colorAttachments[0].sourceAlphaBlendFactor = .one
                    d.colorAttachments[0].destinationAlphaBlendFactor = .one
                } else {
                    d.colorAttachments[0].writeMask = []
                }
                d.depthAttachmentPixelFormat = .depth32Float
                return try device.makeRenderPipelineState(descriptor: d)
            }
            blurDepthPipeline = try offscreen(accumulate: false)
            blurAccumulatePipeline = try offscreen(accumulate: true)
            blurCompositePipeline = try pipeline("floorVertex", "reflectionCompositeFragment", blend: true, writesID: false)
            func grain(_ operation: MTLBlendOperation) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.rasterSampleCount = samples
                d.vertexFunction = library.makeFunction(name: "noiseVertex")
                d.fragmentFunction = library.makeFunction(name: "noiseFragment")
                d.colorAttachments[0].pixelFormat = Renderer.colorFormat
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].rgbBlendOperation = operation
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .one
                d.colorAttachments[1].pixelFormat = .r32Uint
                d.colorAttachments[1].writeMask = []
                d.depthAttachmentPixelFormat = Renderer.depthFormat
                d.stencilAttachmentPixelFormat = Renderer.depthFormat
                return try device.makeRenderPipelineState(descriptor: d)
            }
            noiseAddPipeline = try grain(.add)
            noiseTakePipeline = try grain(.reverseSubtract)
            let shadow = MTLRenderPipelineDescriptor()
            shadow.vertexFunction = library.makeFunction(name: "shadowVertex")
            shadow.depthAttachmentPixelFormat = .depth32Float
            shadowPipeline = try device.makeRenderPipelineState(descriptor: shadow)
        } catch {
            print("SimplMaker: Metal setup failed: \(error)")
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
        let behind = MTLDepthStencilDescriptor()
        behind.depthCompareFunction = .greater
        behind.isDepthWriteEnabled = false
        let over = MTLDepthStencilDescriptor()
        over.depthCompareFunction = .always
        over.isDepthWriteEnabled = false
        // Section analysis: mark where the cut face shows, and keep edges off those pixels.
        func stencil(_ d: MTLDepthStencilDescriptor, compare: MTLCompareFunction, replace: Bool) -> MTLDepthStencilDescriptor {
            let copy = MTLDepthStencilDescriptor()
            copy.depthCompareFunction = d.depthCompareFunction
            copy.isDepthWriteEnabled = d.isDepthWriteEnabled
            let s = MTLStencilDescriptor()
            s.stencilCompareFunction = compare
            s.depthStencilPassOperation = replace ? .replace : .keep
            s.readMask = 1
            s.writeMask = replace ? 1 : 0
            copy.frontFaceStencil = s
            copy.backFaceStencil = s
            return copy
        }
        guard let depthState = device.makeDepthStencilState(descriptor: ds),
              let depthCut = device.makeDepthStencilState(descriptor: stencil(ds, compare: .notEqual, replace: false)),
              let noWriteCut = device.makeDepthStencilState(descriptor: stencil(noWrite, compare: .notEqual, replace: false)),
              let hiddenCut = device.makeDepthStencilState(descriptor: stencil(behind, compare: .notEqual, replace: false)),
              let cap = device.makeDepthStencilState(descriptor: stencil(ds, compare: .always, replace: true)),
              let onTop = device.makeDepthStencilState(descriptor: top),
              let noWriteState = device.makeDepthStencilState(descriptor: noWrite),
              let behindState = device.makeDepthStencilState(descriptor: behind),
              let overState = device.makeDepthStencilState(descriptor: over) else { return nil }
        self.depthState = depthState
        self.depthCutState = depthCut
        self.noWriteCutState = noWriteCut
        self.hiddenCutState = hiddenCut
        self.capState = cap
        self.onTopDepthState = onTop
        self.noWriteDepthState = noWriteState
        self.hiddenDepthState = behindState
        self.overEverythingDepthState = overState
        buildAxes(length: 200)
    }

    // MARK: scene

    /// Returns once everything drawn so far has finished on the GPU, so a frame can be read back (the AI interface's snapshots).
    func waitForGPU() {
        guard let cmd = queue.makeCommandBuffer() else { return }
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    /// `offsets` shifts each body (same order) as the exploded view asks; empty: every body in place.
    func setScene(_ meshes: [BodyMesh], offsets: [SIMD3<Float>] = []) {
        bodies = meshes.enumerated().map { upload($1, shift: offsets[safe: $0] ?? .zero) }
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
        g.originPlaneCount = o.originPlaneCount
        g.planeOutline = makeBuffer(o.planeOutline); g.planeOutlineCount = o.planeOutline.count
        g.planeEdges = makeBuffer(o.planeEdges); g.planeEdgeCount = o.planeEdges.count
        g.planesSeeThrough = o.planesSeeThrough
        g.images = o.images.compactMap { d in texture(for: d).map { (d, $0) } }
        imageTextures = imageTextures.filter { key, _ in o.images.contains { $0.id == key } }
        g.imageBorder = makeBuffer(o.imageBorder); g.imageBorderCount = o.imageBorder.count
        g.curves = makeBuffer(o.curves); g.curveCount = o.curves.count
        g.construction = makeBuffer(o.construction); g.constructionCount = o.construction.count
        g.axisSelected = makeBuffer(o.axisSelected); g.axisSelectedCount = o.axisSelected.count
        g.inactive = makeBuffer(o.inactive); g.inactiveCount = o.inactive.count
        g.preview = makeBuffer(o.preview); g.previewCount = o.preview.count
        g.points = makeBuffer(o.points); g.pointCount = o.points.count
        g.handle = makeBuffer(o.handle); g.handleCount = o.handle.count
        g.moveHandle = makeBuffer(o.moveHandle); g.moveHandleCount = o.moveHandle.count
        g.dialDot = makeBuffer(o.dialDot); g.dialDotCount = o.dialDot.count
        g.dialArc = makeBuffer(o.dialArc); g.dialArcCount = o.dialArc.count
        g.snap = makeBuffer(o.snap); g.snapCount = o.snap.count
        g.section = makeBuffer(o.section); g.sectionCount = o.section.count
        g.measure = makeBuffer(o.measure); g.measureCount = o.measure.count
        g.measurePoints = makeBuffer(o.measurePoints); g.measurePointCount = o.measurePoints.count
        g.handleInvalid = o.handleInvalid
        g.fullyConstrained = o.fullyConstrained
        overlay = g
    }

    /// The texture for a reference image, made when it is new or its picture changed.
    private func texture(for d: ImageDraw) -> MTLTexture? {
        if let kept = imageTextures[d.id], kept.data == d.data { return kept.texture }
        guard let image = ReferenceImage.decode(d.data), let pixels = ReferenceImage.premultipliedPixels(image) else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixels.width, height: pixels.height,
                                                            mipmapped: true)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        pixels.bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, pixels.width, pixels.height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: pixels.width * 4)
        }
        // Mip levels, so a big picture seen small doesn't shimmer.
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cmd.commit()
        }
        imageTextures[d.id] = (d.data, texture)
        return texture
    }

    private func upload(_ m: BodyMesh, shift: SIMD3<Float> = .zero) -> GPUBody {
        let mesh = m.mesh
        var vertexFace = [UInt32](repeating: 0, count: mesh.positions.count / 3)
        for t in 0..<mesh.triangleFace.count {
            for k in 0..<3 { vertexFace[Int(mesh.indices[t * 3 + k])] = mesh.triangleFace[t] }
        }
        var verts: [FaceVertex] = []
        verts.reserveCapacity(vertexFace.count)
        for v in 0..<vertexFace.count {
            let p = v * 3
            verts.append(FaceVertex(px: mesh.positions[p] + shift.x, py: mesh.positions[p + 1] + shift.y, pz: mesh.positions[p + 2] + shift.z,
                                    nx: mesh.normals[p], ny: mesh.normals[p + 1], nz: mesh.normals[p + 2],
                                    id: PickID(body: m.index, face: Int(vertexFace[v])).raw))
        }
        var segs: [SegmentInstance] = []
        segs.reserveCapacity(mesh.segmentEdge.count)
        for s in 0..<mesh.segmentEdge.count {
            let q = s * 6
            segs.append(SegmentInstance(ax: mesh.segments[q] + shift.x, ay: mesh.segments[q + 1] + shift.y, az: mesh.segments[q + 2] + shift.z,
                                        bx: mesh.segments[q + 3] + shift.x, by: mesh.segments[q + 4] + shift.y, bz: mesh.segments[q + 5] + shift.z,
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

    /// Makes a body's triangles for the print preview, each apart from the others, and for each vertex on the edge of
    /// its face the vertices next to it along the edge. A side that only one triangle of the face has is on the
    /// boundary. (The mesh shares vertices within a face, never between faces.)
    private func makePrintFaces(of body: Int) {
        guard let faceBuffer = bodies[body].faces, let indexBuffer = bodies[body].indices else { return }
        let indexCount = bodies[body].indexCount
        let vertexCount = faceBuffer.length / MemoryLayout<FaceVertex>.stride
        let verts = faceBuffer.contents().bindMemory(to: FaceVertex.self, capacity: vertexCount)
        let idx = indexBuffer.contents().bindMemory(to: UInt32.self, capacity: indexCount)
        struct Side: Hashable { var a: UInt32, b: UInt32 }
        func side(_ p: UInt32, _ q: UInt32) -> Side { Side(a: min(p, q), b: max(p, q)) }
        var uses: [Side: Int] = [:]
        uses.reserveCapacity(indexCount)
        for t in 0..<(indexCount / 3) {
            let i0 = idx[t * 3], i1 = idx[t * 3 + 1], i2 = idx[t * 3 + 2]
            uses[side(i0, i1), default: 0] += 1
            uses[side(i1, i2), default: 0] += 1
            uses[side(i2, i0), default: 0] += 1
        }
        func position(_ i: UInt32) -> SIMD4<Float> { SIMD4(verts[Int(i)].px, verts[Int(i)].py, verts[Int(i)].pz, 1) }
        var corners = (0..<vertexCount).map { PrintCorner(p: position(UInt32($0)), a: .zero, b: .zero) }
        var onBoundary = [Bool](repeating: false, count: vertexCount)
        func link(_ v: UInt32, to w: UInt32) {
            onBoundary[Int(v)] = true
            if corners[Int(v)].a.w == 0 { corners[Int(v)].a = position(w) } else if corners[Int(v)].b.w == 0 { corners[Int(v)].b = position(w) }
        }
        for (side, count) in uses where count == 1 { link(side.a, to: side.b); link(side.b, to: side.a) }
        var out: [PrintVertex] = []
        out.reserveCapacity(indexCount)
        for t in 0..<(indexCount / 3) {
            let c = [idx[t * 3], idx[t * 3 + 1], idx[t * 3 + 2]]
            var mask: UInt32 = 0
            for j in 0..<3 where onBoundary[Int(c[j])] { mask |= 1 << UInt32(j) }
            for j in 0..<3 {
                let v = verts[Int(c[j])]
                out.append(PrintVertex(px: v.px, py: v.py, pz: v.pz, nx: v.nx, ny: v.ny, nz: v.nz, id: v.id,
                                       c0: c[0], c1: c[1], c2: c[2], mask: mask))
            }
        }
        bodies[body].printFaces = makeBuffer(out)
        bodies[body].printCorners = makeBuffer(corners)
        bodies[body].printVertexCount = out.count
    }

    private func makeBuffer<T>(_ array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return array.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    /// Sets (or, with nil, removes) the sketch-plane grid; lines are rebuilt only when it changes.
    func setSketchGrid(_ g: SketchGrid?) {
        guard g != sketchGrid else { return }
        sketchGrid = g
        guard let g else { sketchGridBuffers = (nil, 0, nil, 0, nil, nil); return }
        func w(_ u: Double, _ v: Double) -> SIMD3<Float> { let p = g.frame.point(u, v); return SIMD3(Float(p.x), Float(p.y), Float(p.z)) }
        func seg(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SegmentInstance {
            SegmentInstance(ax: a.x, ay: a.y, az: a.z, bx: b.x, by: b.y, bz: b.z, id: 0)
        }
        var minor: [SegmentInstance] = [], major: [SegmentInstance] = []
        if g.lines {
            // Lines at multiples of the minor step; every fifth (a multiple of the major) is darker.
            let ratio = max(Int((g.major / g.minor).rounded()), 1)
            let i0 = Int((g.u.lowerBound / g.minor).rounded()), i1 = Int((g.u.upperBound / g.minor).rounded())
            let j0 = Int((g.v.lowerBound / g.minor).rounded()), j1 = Int((g.v.upperBound / g.minor).rounded())
            for i in i0...max(i0, i1) where i != 0 {
                let s = seg(w(Double(i) * g.minor, g.v.lowerBound), w(Double(i) * g.minor, g.v.upperBound))
                if i % ratio == 0 { major.append(s) } else { minor.append(s) }
            }
            for j in j0...max(j0, j1) where j != 0 {
                let s = seg(w(g.u.lowerBound, Double(j) * g.minor), w(g.u.upperBound, Double(j) * g.minor))
                if j % ratio == 0 { major.append(s) } else { minor.append(s) }
            }
        }
        sketchGridBuffers = (makeBuffer(minor), minor.count, makeBuffer(major), major.count,
                             makeBuffer([seg(w(g.u.lowerBound, 0), w(g.u.upperBound, 0))]),
                             makeBuffer([seg(w(0, g.v.lowerBound), w(0, g.v.upperBound))]))
    }

    /// What the ground grid covers: lines at multiples of `minor` (every `major` one darker), from
    /// index i0 to i1 across and j0 to j1 along.
    struct WorldGridKey: Equatable {
        var minor: Double, major: Double
        var i0: Int, i1: Int, j0: Int, j1: Int
        /// The ground the lines cover, in mm: x range, y range.
        var x: ClosedRange<Double> { Double(i0) * minor...Double(i1) * minor }
        var y: ClosedRange<Double> { Double(j0) * minor...Double(j1) * minor }
    }

    /// Where the ground grid has to reach to fill the view: the part of the XY plane in view, a little
    /// beyond it, and no more than 60 major steps from the middle (a plane seen edge-on runs to the horizon).
    func worldGridKey(viewSize: CGSize) -> WorldGridKey {
        let mmPerPoint = Double(2 * camera.halfHeight) / Double(max(viewSize.height, 1))
        let steps = ViewportMTKView.gridSteps(mmPerPixel: mmPerPoint)
        let reach = 60 * steps.major
        func onGround(_ p: CGPoint) -> SIMD2<Double>? {
            let r = camera.ray(at: p, viewSize: viewSize)
            guard abs(r.direction.z) > 1e-3 else { return nil }
            let t = -r.origin.z / r.direction.z
            guard t > 0 else { return nil }
            let h = r.origin + t * r.direction
            return SIMD2(Double(h.x), Double(h.y))
        }
        let w = viewSize.width, h = viewSize.height
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: w, y: h)]
        let hits = points.compactMap(onGround)
        let centre = onGround(CGPoint(x: w / 2, y: h / 2)) ?? SIMD2(Double(camera.target.x), Double(camera.target.y))
        var lo = centre - reach, hi = centre + reach
        if hits.count == points.count {  // everything in view meets the ground: only what's seen
            lo = simd_max(lo, hits.reduce(hits[0], simd_min) - steps.major)
            hi = simd_min(hi, hits.reduce(hits[0], simd_max) + steps.major)
        }
        // Whole major steps, so the grid is rebuilt only when the view has moved a good way.
        func index(_ v: Double, up: Bool) -> Int {
            let m = (v / steps.major)
            return Int((up ? m.rounded(.up) : m.rounded(.down))) * max(Int((steps.major / steps.minor).rounded()), 1)
        }
        return WorldGridKey(minor: steps.minor, major: steps.major, i0: index(lo.x, up: false), i1: index(hi.x, up: true),
                            j0: index(lo.y, up: false), j1: index(hi.y, up: true))
    }

    /// Makes the ground grid and the axes cover the view, when they don't already.
    private func updateWorldGrid(viewSize: CGSize) {
        let key = worldGridKey(viewSize: viewSize)
        if worldGrid?.key != key {
            let x0 = Float(Double(key.i0) * key.minor), x1 = Float(Double(key.i1) * key.minor)
            let y0 = Float(Double(key.j0) * key.minor), y1 = Float(Double(key.j1) * key.minor)
            let ratio = max(Int((key.major / key.minor).rounded()), 1)
            var minor: [SegmentInstance] = [], major: [SegmentInstance] = []
            // The lines through the origin too: the axes cover only their positive halves, and are hidden while sketching.
            for i in key.i0...max(key.i0, key.i1) {
                let t = Float(Double(i) * key.minor)
                let s = SegmentInstance(ax: t, ay: y0, az: 0, bx: t, by: y1, bz: 0, id: 0)
                if i % ratio == 0 { major.append(s) } else { minor.append(s) }
            }
            for j in key.j0...max(key.j0, key.j1) {
                let t = Float(Double(j) * key.minor)
                let s = SegmentInstance(ax: x0, ay: t, az: 0, bx: x1, by: t, bz: 0, id: 0)
                if j % ratio == 0 { major.append(s) } else { minor.append(s) }
            }
            worldGrid = (key, makeBuffer(minor), minor.count, makeBuffer(major), major.count)
        }
        // The axes run out to the edge of the grid, and the vertical one stands a few major steps high.
        let length = Float(max(200, Double(key.i1) * key.minor, Double(key.j1) * key.minor, 5 * key.major))
        if length != axesLength { buildAxes(length: length) }
    }

    func buildAxes(length size: Float) {
        axesLength = size
        axes = [
            (makeBuffer([SegmentInstance(ax: 0, ay: 0, az: 0, bx: size, by: 0, bz: 0, id: 0)])!, SIMD4(0.85, 0.25, 0.25, 1)),
            (makeBuffer([SegmentInstance(ax: 0, ay: 0, az: 0, bx: 0, by: size, bz: 0, id: 0)])!, SIMD4(0.25, 0.7, 0.3, 1)),
            (makeBuffer([SegmentInstance(ax: 0, ay: 0, az: 0, bx: 0, by: 0, bz: size / 2, id: 0)])!, SIMD4(0.3, 0.45, 0.9, 1)),
        ]
    }

    // MARK: drawing

    /// The colours a body is drawn in, and its hover and selection highlights.
    struct BodyTint: Equatable {
        var face, faceHover, faceSelected, edgeHover, edgeSelected: SIMD4<Float>
    }

    /// The main light's view of the bodies: a square (orthographic) view along the light that takes in every body,
    /// its size in mm, and the depth it covers. (The matrix maps the part to Metal's clip space, depth 0 to 1.)
    static func lightProjection(toward light: SIMD3<Float>, lo: SIMD3<Float>, hi: SIMD3<Float>)
        -> (matrix: simd_float4x4, extent: SIMD2<Float>, depth: Float) {
        let f = -simd_normalize(light)
        let s = simd_normalize(simd_cross(f, abs(f.z) > 0.99 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)))
        let u = simd_cross(s, f)
        let c = (lo + hi) / 2
        var mn = SIMD3<Float>(repeating: .infinity), mx = SIMD3<Float>(repeating: -.infinity)
        func seen(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let d = p - c
            return SIMD3(simd_dot(s, d), simd_dot(u, d), -simd_dot(f, d))  // as the light sees it: it looks down -Z
        }
        for i in 0..<8 {
            let q = seen(SIMD3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z))
            mn = simd_min(mn, q)
            mx = simd_max(mx, q)
        }
        // The floor under it is in the depth range too, as far as the map's width reaches along the light.
        var deepest = mn.z, nearest = mx.z
        for i in 0..<4 {
            let x = i & 1 == 0 ? lo.x : hi.x, y = i & 2 == 0 ? lo.y : hi.y
            for z in [Float(0), lo.z, hi.z] {
                let q = seen(SIMD3(x, y, z))
                deepest = min(deepest, q.z)
                nearest = max(nearest, q.z)
            }
        }
        mn.z = deepest
        mx.z = nearest
        let pad = max(simd_length(hi - lo) * 0.05, 2)
        mn -= pad
        mx += pad
        let near = -mx.z, far = -mn.z
        let w = mx.x - mn.x, h = mx.y - mn.y
        let view = simd_float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
                                           SIMD4(-simd_dot(s, c), -simd_dot(u, c), simd_dot(f, c), 1)))
        let projection = simd_float4x4(columns: (SIMD4(2 / w, 0, 0, 0), SIMD4(0, 2 / h, 0, 0), SIMD4(0, 0, 1 / (near - far), 0),
                                                 SIMD4(-(mx.x + mn.x) / w, -(mx.y + mn.y) / h, near / (near - far), 1)))
        return (projection * view, SIMD2(w, h), far - near)
    }

    /// The reflection with blur: the bodies drawn upside down, many times with the mirror tilted a little differently
    /// each time, added up in a texture of half the view's size (see reflectionFragment). A tilt moves a point sideways
    /// by its height, so what touches the floor stays sharp and the blur grows with height.
    private func drawBlurredReflection(_ cmd: MTLCommandBuffer, _ uniforms: Uniforms, strength: Float, blur: Float, size: CGSize,
                                       tints: [BodyTint], materials: [UInt32], shadowing: Bool) {
        let w = max(Int(size.width) / 2, 1), h = max(Int(size.height) / 2, 1)
        if reflectionTexture?.width != w || reflectionTexture?.height != h {
            let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            c.usage = [.renderTarget, .shaderRead]
            c.storageMode = .private
            reflectionTexture = device.makeTexture(descriptor: c)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = .private
            reflectionDepth = device.makeTexture(descriptor: d)
        }
        let views = Self.reflectionViews
        for view in 0..<views {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = reflectionTexture
            pass.colorAttachments[0].loadAction = view == 0 ? .clear : .load
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = reflectionDepth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1
            pass.depthAttachment.storeAction = .dontCare
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
            // This view's tilt: a point of the disc of tilts, which together make the blur.
            let r = sqrt((Float(view) + 0.5) / Float(views)), a = Float(view) * 2.39996323
            let shear = SIMD2(cos(a), sin(a)) * (r * blur * 0.5)
            var m = uniforms
            m.viewProj = uniforms.viewProj * simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                                                                    SIMD4(shear.x, shear.y, -1, 0), SIMD4(0, 0, 0, 1)))
            m.eye.z = -m.eye.z
            m.viewDir.z = -m.viewDir.z
            m.clipPlane = SIMD4(0, 0, -1, 0)  // what stands below the floor is not reflected
            m.clipOn = 1
            m.hovered = 0
            m.selectedCount = 0
            m.hoverGroupCount = 0
            m.renderParams.w = strength / Float(views)
            var none: [UInt32] = [0]
            enc.setCullMode(.none)
            enc.setVertexBytes(&m, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&m, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&none, length: MemoryLayout<UInt32>.stride, index: 2)
            enc.setFragmentTexture(shadowing ? shadowMap : emptyShadowMap, index: 1)
            for (pipeline, depth) in [(blurDepthPipeline, depthState), (blurAccumulatePipeline, noWriteDepthState)] {
                enc.setRenderPipelineState(pipeline)
                enc.setDepthStencilState(depth)
                for (i, b) in bodies.enumerated() {
                    guard let faces = b.faces, let indices = b.indices else { continue }
                    var params = DrawParams(color: tints[i].face, hoverColor: tints[i].faceHover, selectColor: tints[i].faceSelected,
                                            thickness: 0, depthBias: 0, pickable: 0, material: materials[i])
                    enc.setFragmentBytes(&params, length: MemoryLayout<DrawParams>.stride, index: 3)
                    enc.setVertexBuffer(faces, offset: 0, index: 0)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount, indexType: .uint32,
                                              indexBuffer: indices, indexBufferOffset: 0)
                }
            }
            enc.endEncoding()
        }
    }

    /// Draws the bodies' depth as the main light sees it, into the shadow map.
    private func drawShadowMap(_ cmd: MTLCommandBuffer, _ uniforms: inout Uniforms, materials: [UInt32]) {
        if shadowMap == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: Self.shadowMapSize,
                                                             height: Self.shadowMapSize, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            shadowMap = device.makeTexture(descriptor: d)
        }
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = shadowMap
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(shadowPipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        for (i, b) in bodies.enumerated() {
            guard let faces = b.faces, let indices = b.indices, materials[i] != 2 else { continue }  // glass casts no shadow
            enc.setVertexBuffer(faces, offset: 0, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount, indexType: .uint32,
                                      indexBuffer: indices, indexBufferOffset: 0)
        }
        enc.endEncoding()
    }

    /// The Render view's floor: a square on the XY plane around the part that fades into the backdrop, drawn behind
    /// nothing and in front of everything below it (it writes no depth and no ID, so picking goes through).
    private func drawFloor(_ enc: MTLRenderCommandEncoder, _ look: RenderSettings) {
        let lo = sceneBounds?.min ?? SIMD3(-50, -50, 0), hi = sceneBounds?.max ?? SIMD3(50, 50, 0)
        let size = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, 20)
        let fadeStart = size * 1.2, fadeEnd = size * 3.2
        var params = FloorParams(centerHalf: SIMD4((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, 0, fadeEnd * 1.1),
                                 lit: SIMD4(look.floorColor, fadeStart),
                                 backdrop: SIMD4(look.backdropColor, fadeEnd),
                                 shadowed: SIMD4(look.floorShadowColor, Float(look.reflectionBlur)))
        enc.setRenderPipelineState(floorPipeline)
        enc.setDepthStencilState(noWriteDepthState)
        enc.setVertexBytes(&params, length: MemoryLayout<FloorParams>.stride, index: 3)
        enc.setFragmentBytes(&params, length: MemoryLayout<FloorParams>.stride, index: 3)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// How much of the ground grid to draw, 0...1, from the view direction: full while the view looks down at
    /// the floor at 25° of elevation or more, gone by 5°. `forward` is the unit direction the camera looks in,
    /// so its Z is minus the sine of the elevation (the same in perspective and orthographic).
    static func groundGridOpacity(forward: SIMD3<Float>) -> Float {
        let t = min(max((abs(forward.z) - 0.087) / (0.423 - 0.087), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Highlights made from the body's own colour, as Fusion does: a red body lights up in lighter
    /// red, with red borders, rather than turning blue. A very light colour (white, aluminium)
    /// darkens instead, since lightening it would show nothing. Without a colour of its own, a body
    /// uses the palette: grey, highlighted in blue.
    static func tint(_ own: SIMD4<Float>?, palette p: ViewportPalette) -> BodyTint {
        guard let c = own else {
            return BodyTint(face: p.face, faceHover: p.faceHover, faceSelected: p.faceSelected,
                            edgeHover: p.hover, edgeSelected: p.selection)
        }
        let white = SIMD4<Float>(1, 1, 1, 1), black = SIMD4<Float>(0, 0, 0, 1)
        func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> { a + (b - a) * t }
        let luminance = 0.3 * c.x + 0.59 * c.y + 0.11 * c.z
        if luminance > 0.75 {
            return BodyTint(face: c, faceHover: mix(c, black, 0.1), faceSelected: mix(c, black, 0.2),
                            edgeHover: mix(c, black, 0.35), edgeSelected: mix(c, black, 0.5))
        }
        return BodyTint(face: c, faceHover: mix(c, white, 0.25), faceSelected: mix(c, white, 0.45),
                        edgeHover: c, edgeSelected: c)
    }

    /// A line colour that stays readable over `base`: near-white over dark colours, near-black over light ones,
    /// pulled slightly toward `base` so it still reads as secondary to the visible edges.
    static func hiddenEdgeColor(over base: SIMD4<Float>) -> SIMD4<Float> {
        let luminance = 0.3 * base.x + 0.59 * base.y + 0.11 * base.z
        let target: Float = luminance < 0.5 ? 1 : 0
        let line = SIMD4<Float>(target, target, target, 1)
        return simd_mix(line, SIMD4(base.x, base.y, base.z, 1), SIMD4(repeating: 0.15))
    }

    func draw(in view: MTKView) {
        let size = view.drawableSize
        guard size.width >= 1, size.height >= 1,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }

        if idTexture == nil || idTexture!.width != Int(size.width) || idTexture!.height != Int(size.height) {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint, width: Int(size.width),
                                                             height: Int(size.height), mipmapped: false)
            if sampleCount > 1 {
                d.textureType = .type2DMultisample
                d.sampleCount = sampleCount
            }
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            idTexture = device.makeTexture(descriptor: d)
        }
        pass.colorAttachments[1].texture = idTexture
        pass.colorAttachments[1].loadAction = .clear
        // The IDs are only read back for a pick, and a multisampled buffer is costly to keep.
        pass.colorAttachments[1].storeAction = pickRequest == nil && sampleCount > 1 ? .dontCare : .store
        pass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        let aspect = Float(size.width / size.height)
        if (showGrid || showAxes) && sketchGrid == nil && renderSettings == nil { updateWorldGrid(viewSize: view.bounds.size) }
        let printing = printPreview && visualStyle.isShaded
        let look = visualStyle.isShaded && sketchGrid == nil && !printing ? renderSettings : nil
        if let look {
            let c = look.backdropColor
            pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: 1)
        }
        var uniforms = Uniforms(viewProj: camera.projectionMatrix(aspect: aspect) * camera.viewMatrix(),
                                eye: SIMD4(camera.eye, 1), viewport: SIMD2(Float(size.width), Float(size.height)),
                                hovered: hovered, selectedCount: UInt32(min(selected.count, 256)),
                                faceColor: palette.face, faceHoverColor: palette.faceHover,
                                faceSelectedColor: palette.faceSelected, regionColor: palette.region,
                                wholeBodies: wholeBodies ? 1 : 0,
                                printLayer: printLayer, printNozzle: printNozzle)
        uniforms.evenLight = sketchGrid != nil ? 1 : 0
        var shadowing = false
        if let look {
            uniforms.lightDir = SIMD4(look.lightDirection, Float(look.brightness))
            uniforms.renderParams = SIMD4(1, Float(look.ambient), 0, look.reflectionStrength)
            if let b = sceneBounds {
                uniforms.sceneCenter = SIMD4((b.min + b.max) * 0.5, max(simd_length(b.max - b.min), 20) * 1.2)
            }
            if look.shadows, let b = sceneBounds, !bodies.isEmpty {
                let light = Self.lightProjection(toward: look.lightDirection, lo: b.min, hi: b.max)
                uniforms.lightViewProj = light.matrix
                uniforms.shadowParams = SIMD4(1, look.lightWidth, 0, light.depth)
                uniforms.shadowExtent = SIMD4(light.extent.x, light.extent.y, max(light.extent.x, light.extent.y) / Float(Self.shadowMapSize),
                                              max(b.max.z - b.min.z, 10) * 0.8)
                shadowing = true
            } else {
                uniforms.shadowExtent.w = max((sceneBounds.map { $0.max.z - $0.min.z } ?? 0), 10) * 0.8
            }
        }
        let forward = camera.forward
        uniforms.viewDir = SIMD4(forward.x, forward.y, forward.z, camera.orthographic ? 1 : 0)
        uniforms.cameraRight = SIMD4(camera.right, 0)
        uniforms.cameraUp = SIMD4(camera.up, 0)
        var cutPlane = sectionPlane
        if cutPlane == nil, let s = sketchSlice {
            // The side of the sketch plane the camera is on goes; a hair of room keeps a face lying in the plane.
            let n = simd_dot(camera.eye - s.origin, s.normal) < 0 ? -s.normal : s.normal
            cutPlane = SIMD4(n.x, n.y, n.z, simd_dot(n, s.origin) + 0.01)
        }
        let sectioning = cutPlane != nil
        let cuttingShaded = sectioning && (printing || visualStyle.isShaded)
        if let plane = cutPlane {
            uniforms.clipPlane = plane
            uniforms.clipOn = 1
        }
        let clipStyle: UInt32 = sectioning ? DrawStyle.clipped : 0
        let tints = bodies.indices.map { Self.tint(bodyColors[safe: $0].flatMap { $0 }, palette: palette) }
        // Materials show in the Render view only, and not in the section analysis or print preview, which draw their own way.
        let materials: [UInt32] = bodies.indices.map { look != nil && !sectioning && !printing ? bodyMaterials[safe: $0] ?? 0 : 0 }
        var sel = Array(selected.prefix(256))
        let group = Array(hoverGroup.prefix(256))
        sel += group  // after the selected ids, which are the first `selectedCount`
        uniforms.hoverGroupCount = UInt32(group.count)
        if sel.isEmpty { sel = [0] }
        let scale = Float(view.window?.backingScaleFactor ?? 2) * palette.lineScale

        if shadowing { drawShadowMap(cmd, &uniforms, materials: materials) }
        // A reflection with blur is made in its own passes first; without, it is drawn straight into the view.
        let blurredReflection = look.map { $0.reflectionStrength > 0 && $0.reflectionBlur > 0.02 && !sectioning && !bodies.isEmpty
                                          && !camera.isBelowGround } ?? false
        if blurredReflection, let look {
            drawBlurredReflection(cmd, uniforms, strength: look.reflectionStrength, blur: Float(look.reflectionBlur), size: size,
                                  tints: tints, materials: materials, shadowing: shadowing)
        }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setFragmentTexture(shadowing ? shadowMap : emptyShadowMap, index: 1)
        enc.setDepthStencilState(depthState)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setVertexBytes(&sel, length: MemoryLayout<UInt32>.stride * sel.count, index: 2)  // selected edges draw thicker
        enc.setFragmentBytes(&sel, length: MemoryLayout<UInt32>.stride * sel.count, index: 2)

        enc.setCullMode(.none)
        enc.setStencilReferenceValue(1)
        let style = printing || (look != nil && look?.showEdges == false) ? VisualStyle.shaded : visualStyle
        /// Faces: shaded, or in the wireframe styles flat in the background colour (hiding what's
        /// behind them) with hover and selection as a light wash. Wireframe draws them later, unseen.
        /// Glass is left to its own pass after the floor (`glassOnly`), unless `withGlass` (the reflection draws it too).
        func drawFaces(_ pipeline: MTLRenderPipelineState, wireframe: Bool, capsOnly: Bool = false,
                       glassOnly: Bool = false, withGlass: Bool = false, glassSide: UInt32 = 0) {
            enc.setRenderPipelineState(pipeline)
            let bg = palette.background
            for (i, b) in bodies.enumerated() {
                guard let faces = b.faces, let indices = b.indices else { continue }
                let glass = materials[i] == 2
                if glass ? !(glassOnly || withGlass) : glassOnly { continue }
                if printing && !wireframe {
                    if b.printFaces == nil, b.printVertexCount == 0 { makePrintFaces(of: i) }
                    guard let printFaces = bodies[i].printFaces else { continue }
                    var params = DrawParams(color: tints[i].face, hoverColor: tints[i].faceHover, selectColor: tints[i].faceSelected,
                                            thickness: 0, depthBias: 0, pickable: 1, style: capsOnly ? DrawStyle.capsOnly : 0)
                    enc.setFragmentBytes(&params, length: MemoryLayout<DrawParams>.stride, index: 3)
                    enc.setVertexBuffer(printFaces, offset: 0, index: 0)
                    enc.setFragmentBuffer(bodies[i].printCorners, offset: 0, index: 4)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: bodies[i].printVertexCount)
                    continue
                }
                let t = tints[i]
                var params = wireframe
                    ? DrawParams(color: bg, hoverColor: simd_mix(bg, t.faceHover, SIMD4(repeating: 0.3)),
                                 selectColor: simd_mix(bg, t.faceSelected, SIMD4(repeating: 0.45)),
                                 thickness: 0, depthBias: 0, pickable: 1, style: DrawStyle.flat)
                    : DrawParams(color: t.face, hoverColor: t.faceHover, selectColor: t.faceSelected,
                                 thickness: 0, depthBias: 0, pickable: 1, style: (capsOnly ? DrawStyle.capsOnly : 0) | glassSide,
                                 material: materials[i])
                enc.setFragmentBytes(&params, length: MemoryLayout<DrawParams>.stride, index: 3)
                enc.setVertexBuffer(faces, offset: 0, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount, indexType: .uint32,
                                          indexBuffer: indices, indexBufferOffset: 0)
            }
        }
        if style != .wireframe {
            let cutting = sectioning && style.isShaded
            let pipeline = printing ? (cutting ? sectionPrintPipeline : printFacePipeline) : (cutting ? sectionFacePipeline : facePipeline)
            drawFaces(pipeline, wireframe: !style.isShaded)
            if cutting {
                // The cut faces, after every body's other faces, so only those nothing nearer hides are marked.
                enc.setDepthStencilState(capState)
                drawFaces(pipeline, wireframe: false, capsOnly: true)
                enc.setDepthStencilState(depthState)
            }
        }

        // Depth bias per layer, as a fraction of the view depth (0.001 ≈ 0.2 mm at the default zoom).
        let biasScale = camera.depthBiasScale * 2.5

        // Reference images, over the faces they lie on but under the grid and everything drawn in the
        // sketch. They don't write depth or the ID buffer, so picking and sketching see right through them.
        if !overlay.images.isEmpty {
            enc.setRenderPipelineState(imagePipeline)
            enc.setDepthStencilState(noWriteDepthState)
            let forward = camera.forward
            func depth(_ d: ImageDraw) -> Float { d.corners.reduce(0) { $0 + simd_dot($1, forward) } }
            for (draw, texture) in overlay.images.sorted(by: { depth($0.draw) > depth($1.draw) }) {  // farthest first
                func corner(_ i: Int) -> SIMD4<Float> { SIMD4(draw.corners[i], 1) }
                var params = ImageParams(corners: (corner(0), corner(1), corner(2), corner(3)), opacity: draw.opacity,
                                         depthBias: 0.00003 * biasScale)
                enc.setVertexBytes(&params, length: MemoryLayout<ImageParams>.stride, index: 3)
                enc.setFragmentBytes(&params, length: MemoryLayout<ImageParams>.stride, index: 3)
                enc.setFragmentTexture(texture, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.setDepthStencilState(depthState)
        }
        func segments(_ buffer: MTLBuffer?, _ count: Int, _ params: DrawParams, pipeline: MTLRenderPipelineState? = nil) {
            guard let buffer, count > 0 else { return }
            var p = params
            p.depthBias *= biasScale
            enc.setRenderPipelineState(pipeline ?? (p.pickable != 0 ? segmentPipeline : decorationPipeline))
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&p, length: MemoryLayout<DrawParams>.stride, index: 3)
            enc.setFragmentBytes(&p, length: MemoryLayout<DrawParams>.stride, index: 3)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
        let p = palette
        segments(overlay.imageBorder, overlay.imageBorderCount,
                 DrawParams(color: p.selection, hoverColor: p.selection, selectColor: p.selection,
                            thickness: 2 * scale, depthBias: 0.0001, pickable: 0))
        // The grid goes under the translucent profile fills, so it shows through them.
        if sketchGrid != nil {
            // Just in front of a face being sketched on, behind everything drawn in the sketch.
            let b = sketchGridBuffers
            func line(_ buffer: MTLBuffer?, _ count: Int, _ color: SIMD4<Float>, _ width: Float) {
                segments(buffer, count, DrawParams(color: color, hoverColor: color, selectColor: color,
                                                   thickness: width * scale, depthBias: 0.00005, pickable: 0))
            }
            line(b.minor, b.minorCount, p.gridMinor, 1)
            line(b.major, b.majorCount, p.grid, 1)
            line(b.axisU, 1, p.sketchAxisU, 1.2)
            line(b.axisV, 1, p.sketchAxisV, 1.2)
        } else if let look {
            if !camera.isBelowGround {
                drawFloor(enc, look)
                if blurredReflection {
                    enc.setRenderPipelineState(blurCompositePipeline)
                    enc.setFragmentTexture(reflectionTexture, index: 2)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                } else if look.reflectionStrength > 0, !sectioning, !bodies.isEmpty {
                    // The bodies again, upside down under the floor, over it where nothing stands in their way.
                    var mirrored = uniforms
                    mirrored.viewProj = uniforms.viewProj * simd_float4x4(diagonal: SIMD4(1, 1, -1, 1))
                    mirrored.eye.z = -mirrored.eye.z
                    mirrored.viewDir.z = -mirrored.viewDir.z
                    mirrored.clipPlane = SIMD4(0, 0, -1, 0)  // what stands below the floor is not reflected
                    mirrored.clipOn = 1
                    mirrored.renderParams.z = 1
                    enc.setVertexBytes(&mirrored, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.setFragmentBytes(&mirrored, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.setDepthStencilState(depthState)
                    drawFaces(reflectDepthPipeline, wireframe: false, withGlass: true)
                    enc.setDepthStencilState(noWriteDepthState)
                    drawFaces(reflectPipeline, wireframe: false, withGlass: true)
                    enc.setDepthStencilState(depthState)
                    enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                    enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                }
            }
            // Glass, over the floor and what stands behind it: the far wall, then a depth pass, so only the nearest surface is blended over it.
            if materials.contains(2) {
                enc.setDepthStencilState(noWriteDepthState)
                drawFaces(glassPipeline, wireframe: false, glassOnly: true, glassSide: DrawStyle.glassBack)
                enc.setDepthStencilState(depthState)
                drawFaces(faceIDPipeline, wireframe: false, glassOnly: true)
                enc.setDepthStencilState(noWriteDepthState)
                drawFaces(glassPipeline, wireframe: false, glassOnly: true, glassSide: DrawStyle.glassFront)
                enc.setDepthStencilState(depthState)
            }
            // Grain over all of it: the backdrop, the floor, the bodies and the reflection (not what is drawn after, like edges).
            if look.noise > 0 {
                enc.setDepthStencilState(overEverythingDepthState)
                for (pipeline, sign) in [(noiseAddPipeline, Float(1)), (noiseTakePipeline, Float(-1))] {
                    var grain = SIMD4<Float>(Float(look.noise) * 0.1, Float(view.window?.backingScaleFactor ?? 2), sign, 0)
                    enc.setRenderPipelineState(pipeline)
                    enc.setFragmentBytes(&grain, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                enc.setDepthStencilState(depthState)
            }
        } else if showGrid, !camera.isBelowGround, let g = worldGrid {  // seen from under the floor the grid would only be in the way
            // Seen almost edge-on the lines pile up into moiré, so the grid fades out as the view flattens. Blended
            // (fadePipeline) so the opacity shows; at full opacity it is the same as drawing it solid.
            let opacity = Self.groundGridOpacity(forward: camera.forward)
            func faded(_ c: SIMD4<Float>) -> SIMD4<Float> { SIMD4(c.x, c.y, c.z, c.w * opacity) }
            if opacity > 0 {
                segments(g.minor, g.minorCount, DrawParams(color: faded(p.gridMinor), hoverColor: faded(p.gridMinor), selectColor: faded(p.gridMinor),
                                                           thickness: 1 * scale, depthBias: 0, pickable: 0), pipeline: fadePipeline)
                segments(g.major, g.majorCount, DrawParams(color: faded(p.grid), hoverColor: faded(p.grid), selectColor: faded(p.grid),
                                                           thickness: 1 * scale, depthBias: 0, pickable: 0), pipeline: fadePipeline)
            }
        }
        // Fills sit just in front of the faces they lie on, but behind every edge and sketch line.
        let fillBias = 0.0002 * biasScale
        if let regions = overlay.regions, let indices = overlay.regionIndices {
            var regionParams = DrawParams(color: .zero, hoverColor: .zero, selectColor: .zero,
                                          thickness: 0, depthBias: fillBias, pickable: 1)
            enc.setRenderPipelineState(regionPipeline)
            // Tested against the bodies but not written to the depth buffer: fills of layered sketches lie in the
            // same plane, and with depth writes the first one drawn would knock out stripes of the next (z-fighting)
            // instead of every fill blending over the one below.
            enc.setDepthStencilState(noWriteDepthState)
            enc.setVertexBuffer(regions, offset: 0, index: 0)
            enc.setVertexBytes(&regionParams, length: MemoryLayout<DrawParams>.stride, index: 3)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: overlay.regionIndexCount, indexType: .uint32,
                                      indexBuffer: indices, indexBufferOffset: 0)
            enc.setDepthStencilState(depthState)
        }

        // Origin planes: translucent, back to front so the nearest one is what the cursor picks.
        if let planes = overlay.planes, let indices = overlay.planeIndices, !overlay.planeCenters.isEmpty {
            let fill = palette.plane, hoverFill = SIMD4(fill.x, fill.y, fill.z, min(fill.w * 2.2, 0.75))
            var planeParams = DrawParams(color: fill, hoverColor: hoverFill, selectColor: fill,
                                         thickness: 0, depthBias: fillBias, pickable: 1)
            enc.setRenderPipelineState(planePipeline)
            enc.setDepthStencilState(noWriteDepthState)
            enc.setVertexBuffer(planes, offset: 0, index: 0)
            enc.setVertexBytes(&planeParams, length: MemoryLayout<DrawParams>.stride, index: 3)
            enc.setFragmentBytes(&planeParams, length: MemoryLayout<DrawParams>.stride, index: 3)
            // The origin planes first, farthest along the view direction first; then the construction planes the same way.
            let forward = camera.forward, centers = overlay.planeCenters, origin = overlay.originPlaneCount
            let order = centers.indices.sorted { a, b in
                let ga = a < origin ? 0 : 1, gb = b < origin ? 0 : 1
                return ga != gb ? ga < gb : simd_dot(centers[a], forward) > simd_dot(centers[b], forward)
            }
            for i in order {
                enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint32,
                                          indexBuffer: indices, indexBufferOffset: i * 6 * MemoryLayout<UInt32>.stride)
            }
            // While a plane is being asked for, the parts hidden by a body show faintly through it
            // (colour only: the body stays what's picked there; the border band below picks the plane).
            if overlay.planesSeeThrough {
                var hidden = planeParams
                hidden.color.w *= 0.6
                hidden.hoverColor.w *= 0.6
                enc.setRenderPipelineState(hiddenPlanePipeline)
                enc.setDepthStencilState(hiddenDepthState)
                enc.setVertexBytes(&hidden, length: MemoryLayout<DrawParams>.stride, index: 3)
                enc.setFragmentBytes(&hidden, length: MemoryLayout<DrawParams>.stride, index: 3)
                for i in order {
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: 6, indexType: .uint32,
                                              indexBuffer: indices, indexBufferOffset: i * 6 * MemoryLayout<UInt32>.stride)
                }
            }
            enc.setDepthStencilState(depthState)
        }

        for (i, (buffer, _)) in axes.enumerated() where showAxes && look == nil {
            let color = i == 0 ? p.axes.x : i == 1 ? p.axes.y : p.axes.z
            segments(buffer, 1, DrawParams(color: color, hoverColor: color, selectColor: color,
                                           thickness: 1.5 * scale, depthBias: 0.0001, pickable: 0))
        }
        // Wireframe: the faces now, in the ID buffer and depth only, so they can still be picked
        // without hiding the grid or the planes drawn above. The edges then draw over everything.
        if style == .wireframe { drawFaces(faceIDPipeline, wireframe: true) }
        // First an unseen, wider band around each edge, in the ID buffer only (no depth either, so
        // it hides nothing): a click or hover a few pixels off an edge still finds it.
        enc.setDepthStencilState(cuttingShaded ? noWriteCutState : noWriteDepthState)
        for b in bodies {
            segments(b.segments, b.segmentCount,
                     DrawParams(color: p.edge, hoverColor: p.hover, selectColor: p.selection, thickness: Self.bodyEdgePickWidth * scale,
                                depthBias: 0.0004, pickable: 1, style: clipStyle), pipeline: pickBandPipeline)
        }
        let edgeColor = style.isShaded ? p.edge : p.wireEdge
        // Edges behind faces, dashed and softened toward what they're seen through.
        if style.showsHiddenEdges {
            enc.setDepthStencilState(cuttingShaded ? hiddenCutState : hiddenDepthState)
            // The colour is picked against what the line is seen through: the body's own colour when shaded,
            // so a dark blue body gets light lines and a pale one dark lines, whatever the theme's edge colour is.
            for (i, b) in bodies.enumerated() {
                let hidden = Self.hiddenEdgeColor(over: style.isShaded ? tints[i].face : p.background)
                segments(b.segments, b.segmentCount,
                         DrawParams(color: hidden, hoverColor: hidden, selectColor: hidden, thickness: 1.2 * scale,
                                    depthBias: 0.0004, pickable: 0, style: DrawStyle.dashed | clipStyle))
            }
        }
        enc.setDepthStencilState(style == .wireframe ? overEverythingDepthState : cuttingShaded ? depthCutState : depthState)
        for (i, b) in bodies.enumerated() {
            segments(b.segments, b.segmentCount,
                     DrawParams(color: edgeColor, hoverColor: tints[i].edgeHover, selectColor: tints[i].edgeSelected,
                                thickness: 0.8 * scale, depthBias: 0.0004, pickable: 1,
                                selectedThickness: Self.selectedEdgeWidth * scale,
                                style: (style == .shaded ? DrawStyle.highlightedOnly : 0) | clipStyle))
        }
        enc.setDepthStencilState(depthState)
        // Sketch overlay, drawn last with increasing depth bias so it sits on top of faces it lies on.
        let hover = p.hover, select = p.sketchSelected
        let planeLine = SIMD4(p.plane.x, p.plane.y, p.plane.z, 1)
        segments(overlay.planeOutline, overlay.planeOutlineCount,
                 DrawParams(color: planeLine, hoverColor: planeLine, selectColor: planeLine,
                            thickness: 1.2 * scale, depthBias: 0.0005, pickable: 1))
        segments(overlay.section, overlay.sectionCount,
                 DrawParams(color: planeLine, hoverColor: planeLine, selectColor: planeLine,
                            thickness: 1.4 * scale, depthBias: 0.0005, pickable: 0))
        // A construction plane's sides, to grab and drag: a band wide enough to hit, and the side itself
        // lighting up under the pointer.
        enc.setDepthStencilState(noWriteDepthState)
        segments(overlay.planeEdges, overlay.planeEdgeCount,
                 DrawParams(color: planeLine, hoverColor: hover, selectColor: planeLine,
                            thickness: Self.edgePickWidth * scale, depthBias: 0.0005, pickable: 1), pipeline: pickBandPipeline)
        enc.setDepthStencilState(depthState)
        segments(overlay.planeEdges, overlay.planeEdgeCount,
                 DrawParams(color: planeLine, hoverColor: hover, selectColor: planeLine,
                            thickness: 1.6 * scale, depthBias: 0.0005, pickable: 1))
        
        if overlay.planesSeeThrough {
            // An unseen band along each plane's border, in the ID buffer over everything: a plane
            // covered by a body (the floor under a part) is still picked by clicking its border.
            enc.setDepthStencilState(overEverythingDepthState)
            segments(overlay.planeOutline, overlay.planeOutlineCount,
                     DrawParams(color: planeLine, hoverColor: planeLine, selectColor: planeLine,
                                thickness: Self.edgePickWidth * scale, depthBias: 0, pickable: 1), pipeline: pickBandPipeline)
            enc.setDepthStencilState(depthState)
        }
        let curveColor = overlay.fullyConstrained ? p.sketchConstrained : p.sketch
        // With hidden edges on, the part of a sketch that lies inside or behind a body shows too, dashed and softened like the edges.
        if style.showsHiddenEdges {
            enc.setDepthStencilState(cuttingShaded ? hiddenCutState : hiddenDepthState)
            let seenThrough = style.isShaded ? p.face : p.background
            for (buffer, count, color) in [(overlay.inactive, overlay.inactiveCount, p.inactiveSketch),
                                           (overlay.curves, overlay.curveCount, curveColor),
                                           (overlay.construction, overlay.constructionCount, p.construction)] {
                let hidden = simd_mix(color, seenThrough, SIMD4(repeating: 0.3))
                segments(buffer, count, DrawParams(color: hidden, hoverColor: hidden, selectColor: hidden, thickness: 1.6 * scale,
                                                   depthBias: 0.0006, pickable: 0, style: DrawStyle.dashed | clipStyle))
            }
            enc.setDepthStencilState(depthState)
        }
        segments(overlay.inactive, overlay.inactiveCount,
                 DrawParams(color: p.inactiveSketch, hoverColor: hover, selectColor: select,
                            thickness: 1.6 * scale, depthBias: 0.0006, pickable: 1, selectedThickness: 3.6 * scale))
        segments(overlay.curves, overlay.curveCount,
                 DrawParams(color: curveColor, hoverColor: hover, selectColor: select,
                            thickness: 2 * scale, depthBias: 0.0008, pickable: 1, selectedThickness: 4.5 * scale))
        // Construction lines are dotted. The gaps between dots would be unpickable, so an unseen band
        // along each line (just behind the real curves) keeps the whole line clickable.
        segments(overlay.construction, overlay.constructionCount,
                 DrawParams(color: p.construction, hoverColor: p.construction, selectColor: p.construction,
                            thickness: 6 * scale, depthBias: 0.0007, pickable: 1), pipeline: pickBandPipeline)
        segments(overlay.construction, overlay.constructionCount,
                 DrawParams(color: p.construction, hoverColor: hover, selectColor: select,
                            thickness: 3 * scale, depthBias: 0.0008, pickable: 1,
                            style: DrawStyle.dashedRound, radius: 0.9 * scale, dashPitch: 5 * scale, dashLength: 1.8 * scale),
                 pipeline: shapePipeline)
        segments(overlay.axisSelected, overlay.axisSelectedCount,
                 DrawParams(color: select, hoverColor: select, selectColor: select, thickness: 3.6 * scale, depthBias: 0.0009, pickable: 0))
        segments(overlay.preview, overlay.previewCount,
                 DrawParams(color: p.preview, hoverColor: hover, selectColor: select,
                            thickness: 1.5 * scale, depthBias: 0.0009, pickable: 0))
        segments(overlay.points, overlay.pointCount,
                 DrawParams(color: p.point, hoverColor: hover, selectColor: select,
                            thickness: 7 * scale, depthBias: 0.0012, pickable: 1, selectedThickness: 11 * scale))
        segments(overlay.snap, overlay.snapCount,
                 DrawParams(color: p.handle, hoverColor: p.handle, selectColor: p.handle,
                            thickness: 9 * scale, depthBias: 0.0014, pickable: 0))
        // The extrude handle is drawn on top of everything so it can always be grabbed.
        enc.setDepthStencilState(onTopDepthState)
        let handleColor = overlay.handleInvalid ? p.invalid : p.handle
        segments(overlay.measure, overlay.measureCount,
                 DrawParams(color: p.handle, hoverColor: p.handle, selectColor: p.handle, thickness: 2 * scale, depthBias: 0, pickable: 0))
        segments(overlay.dialArc, overlay.dialArcCount,
                 DrawParams(color: handleColor, hoverColor: handleColor, selectColor: handleColor, thickness: 3 * scale,
                            depthBias: 0, pickable: 0, style: DrawStyle.fade),
                 pipeline: fadePipeline)
        segments(overlay.measurePoints, overlay.measurePointCount,
                 DrawParams(color: p.handle, hoverColor: p.handle, selectColor: p.handle, thickness: 9 * scale, depthBias: 0, pickable: 0))
        // The arrows (a shaft and a rounded head) are drawn in three layers, so their outline is one shape:
        // dark, then white, then the colour itself.
        let outlineWhite = SIMD4<Float>(1, 1, 1, 1), outlineDark = SIMD4<Float>(0.05, 0.05, 0.06, 1)
        let ring: Float = 1.25 * scale
        let headWidth = 16 * scale
        // The slanted sides of the head look thinner than the shaft's at the same width; its back edge keeps the plain width.
        let headOutlineBoost: Float = 1.8
        // However short the arrow is (a fillet not yet dragged out), a little of its dashed shaft shows behind its head.
        let tailLength = 0.416 * headWidth + 14 * scale
        for (layer, color) in [(2, outlineDark), (1, outlineWhite), (0, handleColor)] {
            let grow = Float(layer) * ring, solid = layer == 0
            let hoverTint = solid ? (overlay.handleInvalid ? p.invalid : hover) : color
            let selectTint = solid ? p.selection : color
            if let handle = overlay.handle, overlay.handleCount > 0 {
                // The shaft fades in from its start. Each arrow's first segment is drawn here (blended, so once only);
                // its second is the same line again, kept for the head.
                var shaft = DrawParams(color: color, hoverColor: hoverTint, selectColor: selectTint,
                                       thickness: 3 * scale + 2 * grow, depthBias: 0, pickable: solid ? 1 : 0,
                                       style: DrawStyle.dashedRound | DrawStyle.fadeAlong, grow: grow, radius: 1.5 * scale,
                                       minLength: tailLength, dashPitch: 9 * scale, dashLength: 5 * scale)
                enc.setRenderPipelineState(solid ? fadeShapePipeline : fadeShapeDecorationPipeline)
                enc.setVertexBytes(&shaft, length: MemoryLayout<DrawParams>.stride, index: 3)
                enc.setFragmentBytes(&shaft, length: MemoryLayout<DrawParams>.stride, index: 3)
                for first in stride(from: 0, to: overlay.handleCount, by: 2) {
                    enc.setVertexBuffer(handle, offset: MemoryLayout<SegmentInstance>.stride * first, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
                }
            }
            if let handle = overlay.handle, overlay.handleCount > 1 {
                var tip = DrawParams(color: color, hoverColor: hoverTint, selectColor: selectTint,
                                     thickness: headWidth, depthBias: 0, pickable: solid ? 1 : 0,
                                     style: DrawStyle.arrowHead, grow: grow, radius: 1.5 * scale, minLength: tailLength,
                                     growSide: grow * headOutlineBoost)
                enc.setRenderPipelineState(solid ? shapePipeline : shapeDecorationPipeline)
                enc.setVertexBytes(&tip, length: MemoryLayout<DrawParams>.stride, index: 3)
                enc.setFragmentBytes(&tip, length: MemoryLayout<DrawParams>.stride, index: 3)
                for head in stride(from: 1, to: overlay.handleCount, by: 2) {  // every arrow's second segment
                    enc.setVertexBuffer(handle, offset: MemoryLayout<SegmentInstance>.stride * head, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
                }
            }
        }
        // The taper dial's dot: round, outlined the same way as the arrows (dark, white, then the colour).
        for (layer, color) in [(2, outlineDark), (1, outlineWhite), (0, handleColor)] {
            let grow = Float(layer) * ring, solid = layer == 0
            segments(overlay.dialDot, overlay.dialDotCount,
                     DrawParams(color: color, hoverColor: solid ? (overlay.handleInvalid ? p.invalid : hover) : color,
                                selectColor: solid ? p.selection : color, thickness: 12 * scale + 2 * grow, depthBias: 0,
                                pickable: solid ? 1 : 0, style: DrawStyle.roundDot),
                     pipeline: solid ? shapePipeline : shapeDecorationPipeline)
        }
        segments(overlay.moveHandle, overlay.moveHandleCount,
                 DrawParams(color: handleColor, hoverColor: overlay.handleInvalid ? p.invalid : hover, selectColor: p.selection,
                            thickness: 12 * scale, depthBias: 0, pickable: 1))
        enc.endEncoding()

        if let pick = pickRequest, let idTexture,
           pick.x >= 0, pick.y >= 0, pick.x < idTexture.width, pick.y < idTexture.height {
            if let kernel = pickSamplePipeline, let compute = cmd.makeComputeCommandEncoder() {
                var pixel = SIMD2<UInt32>(UInt32(pick.x), UInt32(pick.y))
                compute.setComputePipelineState(kernel)
                compute.setTexture(idTexture, index: 0)
                compute.setBytes(&pixel, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
                compute.setBuffer(pickBuffer, offset: 0, index: 1)
                compute.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
                compute.endEncoding()
            } else if let blit = cmd.makeBlitCommandEncoder() {
                blit.copy(from: idTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: pick.x, y: pick.y, z: 0),
                          sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: pickBuffer, destinationOffset: 0,
                          destinationBytesPerRow: 4, destinationBytesPerImage: 4)
                blit.endEncoding()
            }
            pickRequest = nil
            nonisolated(unsafe) let buffer = pickBuffer
            let callback = onPick
            cmd.addCompletedHandler { _ in
                let id = buffer.contents().load(as: UInt32.self)
                Task { @MainActor in callback?(id, pick) }
            }
        }
        if let handler = captureHandler {
            captureHandler = nil
            let texture = drawable.texture
            let (w, h) = (texture.width, texture.height)
            if let buffer = device.makeBuffer(length: w * h * 4, options: .storageModeShared), let blit = cmd.makeBlitCommandEncoder() {
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer, destinationOffset: 0,
                          destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
                blit.endEncoding()
                nonisolated(unsafe) let pixels = buffer
                cmd.addCompletedHandler { _ in
                    let bytes = [UInt8](UnsafeBufferPointer(start: pixels.contents().assumingMemoryBound(to: UInt8.self), count: w * h * 4))
                    let png = ViewportSnapshot.png(bgra: bytes, width: w, height: h)
                    Task { @MainActor in handler(png) }
                }
            } else {
                Task { @MainActor in handler(nil) }
            }
        }
        cmd.addCompletedHandler { [weak self] c in self?.lastGPUSeconds = c.gpuEndTime - c.gpuStartTime }
        cmd.present(drawable)
        cmd.commit()
    }
}
