// Swift wrappers around the SimplKernel C API. Handles are released in deinit.
// Copyright © 2026 Atle Mo. All rights reserved.
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

/// What a measured piece of a body is (see `KMeasure`).
public enum KGeometry: Sendable, Equatable {
    case other, body, plane, cylinder, cone, sphere, torus, line, circle, arc
}

/// A face, an edge or a whole body, measured: its size, and the geometry that sets it apart (a plane's
/// normal, a hole's radius and axis, a straight edge's ends). Lengths in mm, angles in radians.
public struct KMeasure: Sendable, Equatable {
    public var geometry: KGeometry
    /// A body's or face's area, an edge's length.
    public var size: Double
    /// A body's volume.
    public var volume: Double
    /// The length of all the edges around a face.
    public var perimeter: Double
    /// A round piece's radius (a cone's at its start, a torus's major radius).
    public var radius: Double
    /// A torus's tube radius, a cone's radius at its other end.
    public var radius2: Double
    /// The angle an arc spans, or half a cone's opening.
    public var angle: Double
    /// A cylinder's or cone's length along its axis.
    public var length: Double
    /// A circle's, arc's, sphere's or torus's centre; for a cylinder or cone a point on its axis.
    public var center: SIMD3<Double>?
    /// A plane's normal out of the material; the axis of a cylinder, cone or torus; a line's direction; a circle's normal.
    public var direction: SIMD3<Double>?
    /// Where an edge starts and ends.
    public var ends: (start: SIMD3<Double>, end: SIMD3<Double>)?
    /// The centre of mass.
    public var centroid: SIMD3<Double>
    public var bounds: (min: SIMD3<Double>, max: SIMD3<Double>)

    /// The size along each world axis.
    public var extent: SIMD3<Double> { bounds.max - bounds.min }

    public static func == (a: KMeasure, b: KMeasure) -> Bool {
        a.geometry == b.geometry && a.size == b.size && a.volume == b.volume && a.perimeter == b.perimeter && a.radius == b.radius
            && a.radius2 == b.radius2 && a.angle == b.angle && a.length == b.length && a.center == b.center
            && a.direction == b.direction && a.ends?.start == b.ends?.start && a.ends?.end == b.ends?.end
            && a.centroid == b.centroid && a.bounds.min == b.bounds.min && a.bounds.max == b.bounds.max
    }

    init(_ m: SKMeasure) {
        func v(_ a: (Double, Double, Double)) -> SIMD3<Double> { SIMD3(a.0, a.1, a.2) }
        switch m.geom {
        case Int32(SK_GEOM_BODY.rawValue): geometry = .body
        case Int32(SK_GEOM_PLANE.rawValue): geometry = .plane
        case Int32(SK_GEOM_CYLINDER.rawValue): geometry = .cylinder
        case Int32(SK_GEOM_CONE.rawValue): geometry = .cone
        case Int32(SK_GEOM_SPHERE.rawValue): geometry = .sphere
        case Int32(SK_GEOM_TORUS.rawValue): geometry = .torus
        case Int32(SK_GEOM_LINE.rawValue): geometry = .line
        case Int32(SK_GEOM_CIRCLE.rawValue): geometry = .circle
        case Int32(SK_GEOM_ARC.rawValue): geometry = .arc
        default: geometry = .other
        }
        size = m.size; volume = m.volume; perimeter = m.perimeter; radius = m.radius; radius2 = m.radius2
        angle = m.angle; length = m.length
        center = m.hasCenter ? v(m.center) : nil
        direction = m.hasDirection ? v(m.direction) : nil
        ends = m.hasEnds ? (v(m.start), v(m.end)) : nil
        centroid = v(m.centroid)
        bounds = (SIMD3(m.bounds.0, m.bounds.1, m.bounds.2), SIMD3(m.bounds.3, m.bounds.4, m.bounds.5))
    }
}

/// Something on a body to measure: the whole body, one face or one edge (by persistent name).
public enum KPiece: Sendable, Hashable {
    case body
    case face(String)
    case edge(String)
}

/// The shortest distance between two pieces, and the points on each that are that far apart.
public struct KDistance: Sendable, Equatable {
    public var distance: Double
    public var a: SIMD3<Double>
    public var b: SIMD3<Double>
}

public final class KBody: @unchecked Sendable {
    let handle: SKHandle
    init(handle: SKHandle) { self.handle = handle }
    deinit { sk_release(handle) }

    /// Answers about this body that cost a boolean-sized amount of work but never change (a body is never
    /// edited once built): where a drag handle goes, which the viewport asks for on every frame.
    private let memoLock = NSLock()
    private var memo: [String: Result<Any, KernelError>] = [:]

    private func memoized<T>(_ key: String, _ compute: () throws -> T) throws -> T {
        memoLock.lock()
        let hit = memo[key]
        memoLock.unlock()
        let result: Result<Any, KernelError>
        if let hit {
            result = hit
        } else {
            result = Result { try compute() as Any }.mapError { $0 as? KernelError ?? KernelError(message: "\($0)") }
            memoLock.lock()
            memo[key] = result
            memoLock.unlock()
        }
        return try result.get() as! T
    }

    static func wrap(_ h: SKHandle, _ context: String) throws -> KBody {
        guard h != 0 else { throw KernelError.last(context) }
        return KBody(handle: h)
    }

    public static func extrude(_ profiles: [KProfile], direction d: SIMD3<Double>, distance: Double,
                               back: Double = 0, taper: Double = 0, featureID: String) throws -> KBody {
        let hs = profiles.map(\.handle)
        return try wrap(sk_extrude_tapered(hs, Int32(hs.count), d.x, d.y, d.z, distance, back, taper, featureID), "extrude")
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

    /// Leans faces by a draft angle (radians) about the plane of the flat face `fixed`, which stays put (see sk_draft).
    public func draft(faces: [String], fixed: String, angle: Double, featureID: String) throws -> KBody {
        try withCStrings(faces) { try KBody.wrap(sk_draft(handle, $0, Int32(faces.count), fixed, angle, featureID), "draft") }
    }

    /// The relief made by projecting profiles onto this body along `direction` (see sk_project_relief): a solid that
    /// follows the surface, `height` thick, standing out of it when positive and going into it when negative. `faces`
    /// are the faces to project onto (every face when empty). `origin` and `normal` give a point on the surface where
    /// the first patch is and the way the surface faces there.
    public func projectRelief(_ profiles: [KProfile], onto faces: [String], direction d: SIMD3<Double>, height: Double,
                              featureID: String) throws -> (body: KBody, origin: SIMD3<Double>, normal: SIMD3<Double>) {
        let hs = profiles.map(\.handle)
        var out = [Double](repeating: 0, count: 6)
        func project(_ names: UnsafePointer<UnsafePointer<CChar>?>?) throws -> KBody {
            try KBody.wrap(sk_project_relief(handle, names, Int32(faces.count), hs, Int32(hs.count), d.x, d.y, d.z, height, featureID, &out),
                           "project")
        }
        let made = faces.isEmpty ? try project(nil) : try withCStrings(faces) { try project($0) }
        return (made, SIMD3(out[0], out[1], out[2]), SIMD3(out[3], out[4], out[5]))
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

    /// The smallest radius of a rounded corner that an equal-distance chamfer along these edges (and the edges that
    /// continue them) would shrink, e.g. a plate's rounded corners under a chamfered top edge. A chamfer that big
    /// can't be built. Nil when no corner limits it.
    public func chamferLimit(edges: [String]) -> Double? {
        guard !edges.isEmpty else { return nil }
        return try? memoized("chamferLimit \(edges.joined(separator: "|"))") { () throws -> Double in
            var limit = 0.0
            guard withCStrings(edges, { sk_edge_round_limit(handle, $0, Int32(edges.count), &limit) }) else {
                throw KernelError(message: "no limit")
            }
            return limit
        }
    }

    /// Where a chamfer's drag handles go on an edge: its midpoint, the directions across the two faces away from
    /// the edge (the first is the one the first distance is measured on) and that face's outward normal.
    public func chamferHandle(_ edge: String, face: String = "", flipped: Bool = false)
        throws -> (origin: SIMD3<Double>, first: SIMD3<Double>, second: SIMD3<Double>, normal: SIMD3<Double>) {
        try memoized("chamferHandle \(edge)|\(face)|\(flipped)") {
            var o = [Double](repeating: 0, count: 12)
            guard sk_body_chamfer_handle(handle, edge, face, flipped, &o) else { throw KernelError.last("chamfer handle") }
            return (SIMD3(o[0], o[1], o[2]), SIMD3(o[3], o[4], o[5]), SIMD3(o[6], o[7], o[8]), SIMD3(o[9], o[10], o[11]))
        }
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
        // Remembered: it asks the body what lies beyond each end of the face, which takes long on a threaded one.
        try memoized("faceCylinder \(name)|\(flipped)") {
            var o = [Double](repeating: 0, count: 9)
            guard sk_body_face_cylinder(handle, name, flipped, &o) else { throw KernelError.last("round face") }
            return KCylinder(start: SIMD3(o[0], o[1], o[2]), direction: SIMD3(o[3], o[4], o[5]), radius: o[6], length: o[7],
                             isHole: o[8] > 0.5)
        }
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
        try memoized("edgeHandle \(edge)") {
            var o = [Double](repeating: 0, count: 6)
            guard sk_body_edge_handle(handle, edge, &o) else { throw KernelError.last("edge handle") }
            return (SIMD3(o[0], o[1], o[2]), SIMD3(o[3], o[4], o[5]))
        }
    }

    /// Measures the whole body, a face or an edge.
    public func measure(_ piece: KPiece = .body) throws -> KMeasure {
        var m = SKMeasure()
        let ok: Bool
        switch piece {
        case .body: ok = sk_measure_element(handle, false, nil, &m)
        case .face(let name): ok = sk_measure_element(handle, true, name, &m)
        case .edge(let name): ok = sk_measure_element(handle, false, name, &m)
        }
        guard ok else { throw KernelError.last("measure") }
        return KMeasure(m)
    }

    /// The shortest distance from a piece of this body to a piece of another (or the same) body.
    public func distance(_ piece: KPiece, to other: KBody, _ otherPiece: KPiece) throws -> KDistance {
        func parts(_ p: KPiece) -> (isFace: Bool, name: String?) {
            switch p {
            case .body: return (false, nil)
            case .face(let n): return (true, n)
            case .edge(let n): return (false, n)
            }
        }
        let (fa, na) = parts(piece), (fb, nb) = parts(otherPiece)
        var o = [Double](repeating: 0, count: 7)
        guard sk_measure_distance(handle, fa, na, other.handle, fb, nb, &o) else { throw KernelError.last("distance") }
        return KDistance(distance: o[0], a: SIMD3(o[1], o[2], o[3]), b: SIMD3(o[4], o[5], o[6]))
    }

    // Remembered like the handles above: the inspector asks again on every redraw, and the volume of a threaded body
    // is an integral over its helical faces.
    public var volume: Double { (try? memoized("volume") { sk_body_volume(handle) }) ?? 0 }
    public var isValid: Bool { (try? memoized("isValid") { sk_body_is_valid(handle) }) ?? false }
    public var bounds: (min: SIMD3<Double>, max: SIMD3<Double>)? {
        try? memoized("bounds") { () throws -> (min: SIMD3<Double>, max: SIMD3<Double>) in
            var b = [Double](repeating: 0, count: 6)
            guard sk_body_bounds(handle, &b) else { throw KernelError(message: "no bounds") }
            return (SIMD3(b[0], b[1], b[2]), SIMD3(b[3], b[4], b[5]))
        }
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
