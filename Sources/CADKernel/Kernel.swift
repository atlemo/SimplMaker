// Swift wrappers around the SimplKernel C API. Handles are released in deinit.
// SPDX-License-Identifier: GPL-3.0-or-later
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
    public func addArc(_ tag: String, center: SIMD2<Double>, radius: Double, from a0: Double, to a1: Double) throws {
        guard sk_sketch_add_arc(handle, tag, center.x, center.y, radius, a0, a1) else { throw KernelError.last("arc \(tag)") }
    }

    public struct Region: Sendable {
        public var index: Int
        public var tags: String
        public var area: Double
        public var sample: SIMD2<Double>
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

    public func boolean(_ tool: KBody, _ op: SKBooleanOp) throws -> KBody {
        try KBody.wrap(sk_boolean(handle, tool.handle, op), "boolean")
    }

    public func fillet(edges: [String], radius: Double, featureID: String) throws -> KBody {
        try withCStrings(edges) { try KBody.wrap(sk_fillet(handle, $0, Int32(edges.count), radius, featureID), "fillet") }
    }

    public func chamfer(edges: [String], distance: Double, featureID: String) throws -> KBody {
        try withCStrings(edges) { try KBody.wrap(sk_chamfer(handle, $0, Int32(edges.count), distance, featureID), "chamfer") }
    }

    public var faceNames: [String] {
        (0..<Int(max(sk_body_face_count(handle), 0))).map { String(cString: sk_body_face_name(handle, Int32($0))) }
    }
    public var edgeNames: [String] {
        (0..<Int(max(sk_body_edge_count(handle), 0))).map { String(cString: sk_body_edge_name(handle, Int32($0))) }
    }
    public func hasFace(_ name: String) -> Bool { sk_body_find_face(handle, name) >= 0 }
    public func hasEdge(_ name: String) -> Bool { sk_body_find_edge(handle, name) >= 0 }

    public func faceFrame(_ name: String) throws -> Frame {
        var f = SKFrame()
        guard sk_body_face_frame(handle, name, &f) else { throw KernelError.last("sketch plane") }
        return Frame(f)
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
        let s = m.pointee
        func array<T>(_ p: UnsafeMutablePointer<T>?, _ n: Int) -> [T] { p.map { Array(UnsafeBufferPointer(start: $0, count: n)) } ?? [] }
        return Mesh(positions: array(s.positions, Int(s.vertexCount) * 3),
                    normals: array(s.normals, Int(s.vertexCount) * 3),
                    indices: array(s.indices, Int(s.triangleCount) * 3),
                    triangleFace: array(s.triangleFace, Int(s.triangleCount)),
                    segments: array(s.segments, Int(s.segmentCount) * 6),
                    segmentEdge: array(s.segmentEdge, Int(s.segmentCount)),
                    faceNames: faceNames, edgeNames: edgeNames)
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
}

/// Calls `body` with a C array of C strings that stays valid for the duration of the call.
func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> R) rethrows -> R {
    let dups: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer { dups.forEach { free($0) } }
    let ptrs: [UnsafePointer<CChar>?] = dups.map { $0.map { UnsafePointer($0) } }
    return try ptrs.withUnsafeBufferPointer { try body($0.baseAddress!) }
}
