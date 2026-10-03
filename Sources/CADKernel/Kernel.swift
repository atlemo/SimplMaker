// Swift wrappers around the SimplKernel C API. Handles are released in deinit.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CKernel
import Foundation

public struct KernelError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public var description: String { message }
    static func last(_ context: String) -> KernelError {
        let msg = String(cString: sk_last_error())
        return KernelError(message: msg.isEmpty ? context : "\(context): \(msg)")
    }
}

/// Version of the OpenCASCADE Technology the kernel is built on, e.g. "8.0.1".
public let occtVersion = String(cString: sk_occt_version())

/// A plane frame in world space (mm).
public struct Frame: Sendable, Equatable {
    public var origin: SIMD3<Double>
    public var normal: SIMD3<Double>
    public var xAxis: SIMD3<Double>
    public var yAxis: SIMD3<Double> {
        SIMD3(normal.y * xAxis.z - normal.z * xAxis.y, normal.z * xAxis.x - normal.x * xAxis.z,
              normal.x * xAxis.y - normal.y * xAxis.x)
    }
    public init(origin: SIMD3<Double>, normal: SIMD3<Double>, xAxis: SIMD3<Double>) {
        self.origin = origin; self.normal = normal; self.xAxis = xAxis
    }
    public func point(_ u: Double, _ v: Double) -> SIMD3<Double> { origin + u * xAxis + v * yAxis }

    /// The same plane with its x axis level and its y axis upward, as the view (Z up) shows it; a
    /// level plane keeps x along world X. The origin planes are already this way.
    public var upright: Frame {
        func unit(_ v: SIMD3<Double>) -> SIMD3<Double> { v / (v * v).sum().squareRoot() }
        let n = unit(normal)
        var x = SIMD3(-n.y, n.x, 0)  // Z × n: level, square to the normal
        if (x * x).sum() < 1e-12 { x = SIMD3(1, 0, 0) - n.x * n }  // a level plane: world X, kept in the plane
        return Frame(origin: origin, normal: n, xAxis: unit(x))
    }

    public static let xy = Frame(origin: .zero, normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0))
    public static let xz = Frame(origin: .zero, normal: SIMD3(0, -1, 0), xAxis: SIMD3(1, 0, 0))
    public static let yz = Frame(origin: .zero, normal: SIMD3(1, 0, 0), xAxis: SIMD3(0, 1, 0))

    var c: SKFrame {
        SKFrame(ox: origin.x, oy: origin.y, oz: origin.z, nx: normal.x, ny: normal.y, nz: normal.z,
                xx: xAxis.x, xy: xAxis.y, xz: xAxis.z)
    }
    init(_ f: SKFrame) {
        self.init(origin: SIMD3(f.ox, f.oy, f.oz), normal: SIMD3(f.nx, f.ny, f.nz), xAxis: SIMD3(f.xx, f.xy, f.xz))
    }
}

/// Kernel objects are immutable once built and the kernel arena is thread-safe,
/// so wrappers can be handed between the regeneration task and the UI.
public final class KSketch: @unchecked Sendable {
    let handle: SKHandle
    public let frame: Frame

    public init(frame: Frame) throws {
        handle = sk_sketch_new(frame.c)
        self.frame = frame
        if handle == 0 { throw KernelError.last("sketch") }
    }
    deinit { sk_release(handle) }

    public func addLine(_ tag: String, _ a: SIMD2<Double>, _ b: SIMD2<Double>) throws {
        guard sk_sketch_add_line(handle, tag, a.x, a.y, b.x, b.y) else { throw KernelError.last("line \(tag)") }
    }
    public func addCircle(_ tag: String, center: SIMD2<Double>, radius: Double) throws {
        guard sk_sketch_add_circle(handle, tag, center.x, center.y, radius) else { throw KernelError.last("circle \(tag)") }
    }
    /// A quadratic (3 points) or cubic (4 points) Bézier curve.
    public func addBezier(_ tag: String, _ points: [SIMD2<Double>]) throws {
        let flat = points.flatMap { [$0.x, $0.y] }
        guard sk_sketch_add_bezier(handle, tag, flat, Int32(points.count)) else { throw KernelError.last("curve \(tag)") }
    }

    public func addArc(_ tag: String, center: SIMD2<Double>, radius: Double, from a0: Double, to a1: Double) throws {
        guard sk_sketch_add_arc(handle, tag, center.x, center.y, radius, a0, a1) else { throw KernelError.last("arc \(tag)") }
    }

    public struct Region: Sendable {
        public var index: Int
        public var tags: String
        public var area: Double
        public var sample: SIMD2<Double>
    }

    /// Whether a sketch point lies inside a region (not on its edge, not in a hole in it).
    public func regionContains(_ index: Int, _ p: SIMD2<Double>) -> Bool {
        sk_sketch_region_contains(handle, Int32(index), p.x, p.y)
    }

    /// Splits the plane by the curves; returns the closed regions.
    public func buildRegions() throws -> [Region] {
        let n = sk_sketch_build_regions(handle)
        guard n >= 0 else { throw KernelError.last("profile detection") }
        return (0..<Int(n)).map { i in
            var u = 0.0, v = 0.0
            _ = sk_sketch_region_sample(handle, Int32(i), &u, &v)
            return Region(index: i, tags: String(cString: sk_sketch_region_tags(handle, Int32(i))),
                          area: sk_sketch_region_area(handle, Int32(i)), sample: SIMD2(u, v))
        }
    }

    /// Triangulated region for display and picking.
    public func regionMesh(_ region: Int, deflection: Double = 0.05) throws -> Mesh {
        guard let m = sk_sketch_region_tessellate(handle, Int32(region), deflection) else {
            throw KernelError.last("region tessellation")
        }
        defer { sk_mesh_free(m) }
        return Mesh(m.pointee, faceNames: [], edgeNames: [])
    }

    /// A path through the curves with these ids (they must connect end to end).
    public func path(_ curves: [String]) throws -> KPath {
        let h = withCStrings(curves) { sk_sketch_path(handle, $0, Int32(curves.count)) }
        guard h != 0 else { throw KernelError.last("path") }
        return KPath(handle: h)
    }

    public func profile(_ region: Int) throws -> KProfile {
        let h = sk_sketch_region_profile(handle, Int32(region))
        guard h != 0 else { throw KernelError.last("profile") }
        return KProfile(handle: h)
    }
}

public final class KProfile: @unchecked Sendable {
    let handle: SKHandle
    init(handle: SKHandle) { self.handle = handle }
    deinit { sk_release(handle) }
}

public final class KPath: @unchecked Sendable {
    let handle: SKHandle
    init(handle: SKHandle) { self.handle = handle }
    deinit { sk_release(handle) }
}

public enum KPrimitive: Sendable {
    case box(width: Double, length: Double, height: Double)
    case cylinder(diameter: Double, height: Double)
    case sphere(diameter: Double)
    case torus(diameter: Double, tube: Double)
    case coil(diameter: Double, section: Double, pitch: Double, turns: Double)
}

/// A round face (see KBody.faceCylinder): the axis from the end a thread starts at, going along the face.
public struct KCylinder: Sendable, Equatable {
    public var start: SIMD3<Double>
    public var direction: SIMD3<Double>
    public var radius: Double
    public var length: Double
    /// The wall of a hole (material outside it), not the side of a shaft.
    public var isHole: Bool
}

public enum KHole: Sendable {
    case simple
    case counterbore(diameter: Double, depth: Double)
    case countersink(diameter: Double, angle: Double)
}

public final class KBody: @unchecked Sendable {
    let handle: SKHandle
    init(handle: SKHandle) { self.handle = handle }
    deinit { sk_release(handle) }

    static func wrap(_ h: SKHandle, _ context: String) throws -> KBody {
        guard h != 0 else { throw KernelError.last(context) }
        return KBody(handle: h)
    }

    public static func extrude(_ profiles: [KProfile], direction d: SIMD3<Double>, distance: Double,
                               back: Double = 0, featureID: String) throws -> KBody {
        let hs = profiles.map(\.handle)
        return try wrap(sk_extrude(hs, Int32(hs.count), d.x, d.y, d.z, distance, back, featureID), "extrude")
    }

    public static func revolve(_ profiles: [KProfile], axisOrigin o: SIMD3<Double>, axisDirection d: SIMD3<Double>,
                               angle: Double, featureID: String) throws -> KBody {
        let hs = profiles.map(\.handle)
        return try wrap(sk_revolve(hs, Int32(hs.count), o.x, o.y, o.z, d.x, d.y, d.z, angle, featureID), "revolve")
    }

    public static func sweep(_ profiles: [KProfile], along path: KPath, featureID: String) throws -> KBody {
        let hs = profiles.map(\.handle)
        return try wrap(sk_sweep(hs, Int32(hs.count), path.handle, featureID), "sweep")
    }

    public static func pipe(along path: KPath, diameter: Double, wall: Double, featureID: String) throws -> KBody {
        try wrap(sk_pipe(path.handle, diameter, wall, featureID), "pipe")
    }

    public static func loft(_ profiles: [KProfile], ruled: Bool, featureID: String) throws -> KBody {
        let hs = profiles.map(\.handle)
        return try wrap(sk_loft(hs, Int32(hs.count), ruled, featureID), "loft")
    }

    public func rib(along path: KPath, thickness: Double, featureID: String) throws -> KBody {
        try KBody.wrap(sk_rib(handle, path.handle, thickness, featureID), "rib")
    }

    /// The solid to cut for a hole whose top centre is the frame origin, drilled against the normal.
    public static func hole(at frame: Frame, _ kind: KHole, diameter: Double, depth: Double, tipAngle: Double,
                            featureID: String) throws -> KBody {
        let h: SKHandle
        switch kind {
        case .simple:
            h = sk_hole(frame.c, SK_HOLE_SIMPLE, diameter, depth, tipAngle, 0, 0, 0, featureID)
        case .counterbore(let d, let depth2):
            h = sk_hole(frame.c, SK_HOLE_COUNTERBORE, diameter, depth, tipAngle, d, depth2, 0, featureID)
        case .countersink(let d, let angle):
            h = sk_hole(frame.c, SK_HOLE_COUNTERSINK, diameter, depth, tipAngle, d, 0, angle, featureID)
        }
        return try wrap(h, "hole")
    }

    /// A primitive standing on the frame's plane, centred at its origin.
    public static func primitive(_ p: KPrimitive, on frame: Frame, featureID: String) throws -> KBody {
        let h: SKHandle
        switch p {
        case .box(let w, let l, let height): h = sk_primitive(SK_BOX, frame.c, w, l, height, 0, featureID)
        case .cylinder(let d, let height): h = sk_primitive(SK_CYLINDER, frame.c, d, 0, height, 0, featureID)
        case .sphere(let d): h = sk_primitive(SK_SPHERE, frame.c, d, 0, 0, 0, featureID)
        case .torus(let d, let tube): h = sk_primitive(SK_TORUS, frame.c, d, tube, 0, 0, featureID)
        case .coil(let d, let section, let pitch, let turns): h = sk_primitive(SK_COIL, frame.c, d, section, pitch, turns, featureID)
        }
        return try wrap(h, "primitive")
    }

    public func translated(_ d: SIMD3<Double>) throws -> KBody {
        try KBody.wrap(sk_translate(handle, d.x, d.y, d.z), "move")
    }

    public func rotated(about origin: SIMD3<Double>, axis a: SIMD3<Double>, angle: Double) throws -> KBody {
        try KBody.wrap(sk_rotate(handle, origin.x, origin.y, origin.z, a.x, a.y, a.z, angle), "rotate")
    }

    /// Copies for mirror and pattern features, with every face name prefixed so the copies' faces
    /// stay distinct from the original's when they're joined.
    public func translatedCopy(_ d: SIMD3<Double>, prefix: String) throws -> KBody {
        try KBody.wrap(sk_translate_copy(handle, d.x, d.y, d.z, prefix), "pattern")
    }

    public func rotatedCopy(about origin: SIMD3<Double>, axis a: SIMD3<Double>, angle: Double, prefix: String) throws -> KBody {
        try KBody.wrap(sk_rotate_copy(handle, origin.x, origin.y, origin.z, a.x, a.y, a.z, angle, prefix), "pattern")
    }

    public func mirroredCopy(through origin: SIMD3<Double>, normal n: SIMD3<Double>, prefix: String) throws -> KBody {
        try KBody.wrap(sk_mirror_copy(handle, origin.x, origin.y, origin.z, n.x, n.y, n.z, prefix), "mirror")
    }

    /// Hollows the body: the faces are removed and the rest becomes walls `thickness` thick.
    public func shell(removing faces: [String], thickness: Double, inside: Bool, featureID: String) throws -> KBody {
        try withCStrings(faces) { try KBody.wrap(sk_shell(handle, $0, Int32(faces.count), thickness, inside, featureID), "shell") }
    }

    /// A straight edge's line (a point on it and its direction); throws for a curved edge.
    public func edgeLine(_ edge: String) throws -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        var o = [Double](repeating: 0, count: 6)
        guard sk_body_edge_line(handle, edge, &o) else { throw KernelError.last("edge direction") }
        return (SIMD3(o[0], o[1], o[2]), SIMD3(o[3], o[4], o[5]))
    }

    /// A straight edge's two ends; throws for a curved edge.
    public func edgeEnds(_ edge: String) throws -> (start: SIMD3<Double>, end: SIMD3<Double>) {
        var o = [Double](repeating: 0, count: 6)
        guard sk_body_edge_ends(handle, edge, &o) else { throw KernelError.last("edge ends") }
        return (SIMD3(o[0], o[1], o[2]), SIMD3(o[3], o[4], o[5]))
    }

    /// Cuts a thread into a round face (see sk_thread); `length` nil = the whole face.
    public func thread(face: String, majorDiameter: Double, pitch: Double, length: Double?, flipped: Bool, leftHanded: Bool,
                       featureID: String) throws -> KBody {
        try KBody.wrap(sk_thread(handle, face, majorDiameter, pitch, length ?? 0, flipped, leftHanded, featureID), "thread")
    }

    public func boolean(_ tool: KBody, _ op: SKBooleanOp) throws -> KBody {
        try KBody.wrap(sk_boolean(handle, tool.handle, op), "boolean")
    }

    public func fillet(edges: [String], radius: Double, featureID: String) throws -> KBody {
        try withCStrings(edges) { try KBody.wrap(sk_fillet(handle, $0, Int32(edges.count), radius, featureID), "fillet") }
    }

    public func chamfer(edges: [String], distance: Double, featureID: String) throws -> KBody {
        try withCStrings(edges) { try KBody.wrap(sk_chamfer(handle, $0, Int32(edges.count), distance, featureID), "chamfer") }
    }

    /// A chamfer measured on each side. The first distance is on `faces[i]` (when that is one of the edge's two
    /// faces, else on the one with the smaller name), the second on the other: a second distance, or an angle.
    public func chamfer(edges: [String], faces: [String], mode: ChamferMode, first: Double, second: Double, flipped: Bool,
                        featureID: String) throws -> KBody {
        precondition(edges.count == faces.count)
        let raw: SKChamferMode = mode == .twoDistances ? SK_CHAMFER_TWO_DISTANCES : mode == .distanceAngle ? SK_CHAMFER_DISTANCE_ANGLE : SK_CHAMFER_EQUAL
        return try withCStrings(edges) { e in
            try withCStrings(faces) { f in
                try KBody.wrap(sk_chamfer_ex(handle, e, f, Int32(edges.count), raw, first, second, flipped, featureID), "chamfer")
            }
        }
    }

    /// Where a chamfer's drag handles go on an edge: its midpoint, the directions across the two faces away from
    /// the edge (the first is the one the first distance is measured on) and that face's outward normal.
    public func chamferHandle(_ edge: String, face: String = "", flipped: Bool = false)
        throws -> (origin: SIMD3<Double>, first: SIMD3<Double>, second: SIMD3<Double>, normal: SIMD3<Double>) {
        var o = [Double](repeating: 0, count: 12)
        guard sk_body_chamfer_handle(handle, edge, face, flipped, &o) else { throw KernelError.last("chamfer handle") }
        return (SIMD3(o[0], o[1], o[2]), SIMD3(o[3], o[4], o[5]), SIMD3(o[6], o[7], o[8]), SIMD3(o[9], o[10], o[11]))
    }

    public var faceNames: [String] {
        (0..<Int(max(sk_body_face_count(handle), 0))).map { String(cString: sk_body_face_name(handle, Int32($0))) }
    }
    public var edgeNames: [String] {
        (0..<Int(max(sk_body_edge_count(handle), 0))).map { String(cString: sk_body_edge_name(handle, Int32($0))) }
    }
    public func hasFace(_ name: String) -> Bool { sk_body_find_face(handle, name) >= 0 }
    public func hasEdge(_ name: String) -> Bool { sk_body_find_edge(handle, name) >= 0 }

    /// A flat face as a profile, for extruding it.
    public func faceProfile(_ name: String) throws -> KProfile {
        let h = sk_body_face_profile(handle, name)
        guard h != 0 else { throw KernelError.last("face profile") }
        return KProfile(handle: h)
    }

    public func faceCenter(_ name: String) throws -> SIMD3<Double> {
        var o = [Double](repeating: 0, count: 3)
        guard sk_body_face_center(handle, name, &o) else { throw KernelError.last("face centre") }
        return SIMD3(o[0], o[1], o[2])
    }

    /// The middle of a face's outline: the centre of the area inside its outer edge, so holes
    /// already in the face don't pull it aside.
    public func faceOutlineCenter(_ name: String) throws -> SIMD3<Double> {
        var o = [Double](repeating: 0, count: 3)
        guard sk_body_face_outline_center(handle, name, &o) else { throw KernelError.last("face centre") }
        return SIMD3(o[0], o[1], o[2])
    }

    public func faceFrame(_ name: String) throws -> Frame {
        var f = SKFrame()
        guard sk_body_face_frame(handle, name, &f) else { throw KernelError.last("sketch plane") }
        return Frame(f)
    }

    /// A round face: its axis from the end a thread starts at, radius, length, and whether it's a hole.
    public func faceCylinder(_ name: String, flipped: Bool = false) throws -> KCylinder {
        var o = [Double](repeating: 0, count: 9)
        guard sk_body_face_cylinder(handle, name, flipped, &o) else { throw KernelError.last("round face") }
        return KCylinder(start: SIMD3(o[0], o[1], o[2]), direction: SIMD3(o[3], o[4], o[5]), radius: o[6], length: o[7],
                         isHole: o[8] > 0.5)
    }

    /// Names of the edges around a face (seams left out).
    public func faceEdges(_ name: String) throws -> [String] {
        try indices("face edges") { sk_body_face_edges(handle, name, $0, $1) }
            .compactMap { sk_body_edge_name(handle, $0).map { String(cString: $0) } }
    }

    /// Names of the faces on either side of an edge.
    public func edgeFaces(_ edge: String) throws -> [String] {
        try indices("edge faces") { sk_body_edge_faces(handle, edge, $0, $1) }
            .compactMap { sk_body_face_name(handle, $0).map { String(cString: $0) } }
    }

    /// Names of the edges in the loop of `face` that runs through `edge` (seams left out).
    public func loopEdges(face: String, edge: String) throws -> [String] {
        try indices("edge loop") { sk_body_loop_edges(handle, face, edge, $0, $1) }
            .compactMap { sk_body_edge_name(handle, $0).map { String(cString: $0) } }
    }

    /// Calls a kernel query that fills an index buffer, growing it if the answer doesn't fit.
    private func indices(_ what: String, _ query: (UnsafeMutablePointer<Int32>, Int32) -> Int32) throws -> [Int32] {
        var out = [Int32](repeating: 0, count: 256)
        var n = Int(out.withUnsafeMutableBufferPointer { query($0.baseAddress!, Int32($0.count)) })
        guard n >= 0 else { throw KernelError.last(what) }
        if n > out.count {
            out = [Int32](repeating: 0, count: n)
            n = Int(out.withUnsafeMutableBufferPointer { query($0.baseAddress!, Int32($0.count)) })
        }
        return Array(out.prefix(n))
    }

    /// Where a fillet/chamfer drag handle goes on an edge: its midpoint and the growth direction.
    public func edgeHandle(_ edge: String) throws -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        var o = [Double](repeating: 0, count: 6)
        guard sk_body_edge_handle(handle, edge, &o) else { throw KernelError.last("edge handle") }
        return (SIMD3(o[0], o[1], o[2]), SIMD3(o[3], o[4], o[5]))
    }

    public var volume: Double { sk_body_volume(handle) }
    public var isValid: Bool { sk_body_is_valid(handle) }
    public var bounds: (min: SIMD3<Double>, max: SIMD3<Double>)? {
        var b = [Double](repeating: 0, count: 6)
        guard sk_body_bounds(handle, &b) else { return nil }
        return (SIMD3(b[0], b[1], b[2]), SIMD3(b[3], b[4], b[5]))
    }

    public func tessellate(linearDeflection: Double = 0.05, angularDeflection: Double = 0.35) throws -> Mesh {
        guard let m = sk_body_tessellate(handle, linearDeflection, angularDeflection) else {
            throw KernelError.last("tessellation")
        }
        defer { sk_mesh_free(m) }
        return Mesh(m.pointee, faceNames: faceNames, edgeNames: edgeNames)
    }

    /// Reads a STEP file's contents into one body with all its solids. Faces are named
    /// "<featureID>.face<n>" by their place in the file.
    public static func importSTEP(_ data: Data, featureID: String) throws -> KBody {
        try data.withUnsafeBytes { buf in
            try wrap(sk_import_step(buf.baseAddress?.assumingMemoryBound(to: CChar.self), buf.count, featureID), "STEP import")
        }
    }

    public static func exportSTEP(_ bodies: [KBody], to url: URL) throws {
        let hs = bodies.map(\.handle)
        guard sk_export_step(hs, Int32(hs.count), url.path) else { throw KernelError.last("STEP export") }
    }
    public static func exportSTL(_ bodies: [KBody], to url: URL, deflection: Double = 0.02) throws {
        let hs = bodies.map(\.handle)
        guard sk_export_stl(hs, Int32(hs.count), url.path, deflection) else { throw KernelError.last("STL export") }
    }
}

/// Plain-array tessellation of a body, ready to upload to the GPU.
public struct Mesh: Sendable {
    public var positions: [Float]      // xyz per vertex
    public var normals: [Float]        // xyz per vertex
    public var indices: [UInt32]       // 3 per triangle
    public var triangleFace: [UInt32]  // face index per triangle
    public var segments: [Float]       // 6 per edge segment
    public var segmentEdge: [UInt32]   // edge index per segment
    public var faceNames: [String]
    public var edgeNames: [String]

    public static let empty = Mesh(positions: [], normals: [], indices: [], triangleFace: [], segments: [],
                                   segmentEdge: [], faceNames: [], edgeNames: [])

    public init(positions: [Float], normals: [Float], indices: [UInt32], triangleFace: [UInt32], segments: [Float],
                segmentEdge: [UInt32], faceNames: [String], edgeNames: [String]) {
        self.positions = positions; self.normals = normals; self.indices = indices; self.triangleFace = triangleFace
        self.segments = segments; self.segmentEdge = segmentEdge; self.faceNames = faceNames; self.edgeNames = edgeNames
    }

    init(_ s: SKMesh, faceNames: [String], edgeNames: [String]) {
        func array<T>(_ p: UnsafeMutablePointer<T>?, _ n: Int) -> [T] {
            p.map { Array(UnsafeBufferPointer(start: $0, count: n)) } ?? []
        }
        positions = array(s.positions, Int(s.vertexCount) * 3)
        normals = array(s.normals, Int(s.vertexCount) * 3)
        indices = array(s.indices, Int(s.triangleCount) * 3)
        triangleFace = array(s.triangleFace, Int(s.triangleCount))
        segments = array(s.segments, Int(s.segmentCount) * 6)
        segmentEdge = array(s.segmentEdge, Int(s.segmentCount))
        self.faceNames = faceNames
        self.edgeNames = edgeNames
    }
}

/// Calls `body` with a C array of C strings that stays valid for the duration of the call.
func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> R) rethrows -> R {
    let dups: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer { dups.forEach { free($0) } }
    let ptrs: [UnsafePointer<CChar>?] = dups.map { $0.map { UnsafePointer($0) } }
    return try ptrs.withUnsafeBufferPointer { try body($0.baseAddress!) }
}
