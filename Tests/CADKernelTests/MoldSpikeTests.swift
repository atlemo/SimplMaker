// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CKernel
import Foundation
import simd
import Testing
@testable import CADKernel

/// Phase 0 of the Mold plan (docs/MOLD-PLAN.md): a mold built by hand with the kernel, no UI, to learn what OpenCASCADE
/// does with real parts: block around the part, subtract the part, cut the gate and vents, split at the parting plane,
/// add cone keys. It prints a timing line per step and does not assert on speed. Run it with
///   SIMPLMAKER_MOLD_SPIKE=1 swift test --filter MoldSpike
/// (off by default: the STL cases take a while).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SIMPLMAKER_MOLD_SPIKE"] != nil))
struct MoldSpikeTests {
    // MARK: - the recipe

    /// What one run found, printed at the end.
    struct Report {
        var name: String
        var steps: [(String, Double)] = []
        var notes: [String] = []
        var failure: String?
        mutating func time<T>(_ step: String, _ body: () throws -> T) rethrows -> T {
            let t0 = Date()
            defer { steps.append((step, Date().timeIntervalSince(t0))) }
            return try body()
        }
        func print() {
            let total = steps.reduce(0) { $0 + $1.1 }
            let line = steps.map { "\($0.0) \(String(format: "%.2f", $0.1))s" }.joined(separator: " | ")
            Swift.print("MOLDSPIKE \(name): \(failure.map { "FAILED at \($0)" } ?? "ok") total \(String(format: "%.2f", total))s")
            Swift.print("MOLDSPIKE   steps: \(line)")
            for n in notes { Swift.print("MOLDSPIKE   - \(n)") }
        }
    }

    struct Setup {
        var wall = 8.0           // block margin around the part on every side
        var normal = SIMD3<Double>(0, 0, 1)   // parting plane normal (the plane goes through the part's bbox middle)
        var up = SIMD3<Double>(0, 0, 1)       // pour direction
        var gateDiameter = 8.0
        var ventDiameter = 2.0
        var keyRadius = 3.0
        var keyHeight = 3.0
        var keyClearance = 0.3
        /// false: block - part, then gate, vents, split, keys (every boolean touches the finished cavity).
        /// true: gate and vents (one tool) and keys go into the plain block and its halves first, the part is subtracted last.
        var cheapFirst = false
        /// The parting plane's distance from the bounding box middle along `normal` (mm).
        var planeOffset = 0.0
    }

    /// An axis-aligned box centred at `centre`.
    static func block(centre c: SIMD3<Double>, size s: SIMD3<Double>) throws -> KBody {
        let frame = Frame(origin: SIMD3(c.x, c.y, c.z - s.z / 2), normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0))
        return try KBody.primitive(.box(width: s.x, length: s.y, height: s.z), on: frame, featureID: "block")
    }

    /// A cylinder from `from` along `dir` for `length`.
    static func rod(from: SIMD3<Double>, dir: SIMD3<Double>, diameter: Double, length: Double, id: String) throws -> KBody {
        let n = simd_normalize(dir)
        let x = abs(n.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let xa = simd_normalize(x - simd_dot(x, n) * n)
        return try KBody.primitive(.cylinder(diameter: diameter, height: length), on: Frame(origin: from, normal: n, xAxis: xa), featureID: id)
    }

    /// A cone (a revolved triangle) standing on `base` along `dir`: base radius r0 narrowing to r1 over h.
    static func cone(base: SIMD3<Double>, dir: SIMD3<Double>, r0: Double, r1: Double, h: Double, id: String) throws -> KBody {
        let n = simd_normalize(dir)
        let x = abs(n.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let xa = simd_normalize(x - simd_dot(x, n) * n)
        // Sketch plane contains the axis: x axis = radial, normal = axis × radial, so the sketch's v is along the axis.
        let ya = n
        let frame = Frame(origin: base, normal: simd_cross(xa, ya), xAxis: xa)
        let s = try KSketch(frame: frame)
        try s.addLine("a", SIMD2(0, 0), SIMD2(r0, 0))
        try s.addLine("b", SIMD2(r0, 0), SIMD2(r1, h))
        try s.addLine("c", SIMD2(r1, h), SIMD2(0, h))
        try s.addLine("d", SIMD2(0, h), SIMD2(0, 0))
        let regions = try s.buildRegions()
        guard let r = regions.first else { throw KernelError(message: "cone profile") }
        return try KBody.revolve([s.profile(r.index)], axisOrigin: base, axisDirection: n, angle: 2 * .pi, featureID: id)
    }

    /// The whole recipe on one part. `gateAt` = a point on the part where the gate goes in (inside the part's material is not
    /// needed: the rod starts inside the cavity), nil = the middle of the bounding box.
    @discardableResult
    static func buildMold(_ name: String, part: KBody, setup s: Setup = Setup(), gateAt: SIMD3<Double>? = nil,
                          extraVents: Int = 1, export: Bool = false) -> Report {
        var r = Report(name: name)
        do {
            guard let b = part.bounds else { throw KernelError(message: "no bounds") }
            let centre = (b.min + b.max) / 2, ext = b.max - b.min
            r.notes.append(String(format: "part: %.1f x %.1f x %.1f mm, volume %.0f mm3, %d faces, valid %@",
                                  ext.x, ext.y, ext.z, part.volume, part.faceNames.count, part.isValid ? "yes" : "NO"))

            // Block: the part's bounds plus the wall on every side (a bigger block along the parting normal's perpendicular
            // axes would be needed for keys; the wall carries them).
            let size = ext + SIMD3(repeating: 2 * s.wall)
            let blockBody = try r.time("block") { try block(centre: centre, size: size) }
            let blockVolume = blockBody.volume
            let planePoint = centre + s.normal * s.planeOffset

            // Gate and vents along "up": one tool body (fused), a single cut. Positions: the gate over the part, vents beside it.
            let topOfPart = (centre + s.up * (simd_dot(ext, abs(s.up)) / 2))
            let gateStart = (gateAt ?? centre) - s.up * 0.5
            let reach = simd_dot(topOfPart - gateStart, s.up) + s.wall + 1
            var channels = try rod(from: gateStart, dir: s.up, diameter: s.gateDiameter, length: reach, id: "gate")
            let perp = abs(s.up.z) > 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 0, 1)
            try r.time("gate+vents tool") {
                for i in 0..<extraVents {
                    let off = perp * (ext.x * 0.3) * (i % 2 == 0 ? 1 : -1)
                    let v = try rod(from: (gateAt ?? centre) + off - s.up * 0.5, dir: s.up, diameter: s.ventDiameter, length: reach, id: "vent\(i)")
                    channels = try channels.boolean(v, SK_FUSE)
                }
            }

            // Cone keys at the corners of the margin ring (asymmetric: the last one is bigger). Pegs on `front` (along the
            // normal), sockets in `back`; the pegs go into the back half.
            let u = abs(s.normal.z) > 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 0, 1)
            let w = simd_cross(s.normal, u)
            let reachU = size.x / 2 - s.wall / 2, reachW = size.y / 2 - s.wall / 2
            let spots = [planePoint + u * reachU + w * reachW, planePoint - u * reachU + w * reachW,
                         planePoint + u * reachU - w * reachW, planePoint - u * reachU - w * reachW * 0.999]
            func addKeys(front: KBody, back: KBody) throws -> (KBody, KBody) {
                var pegs: KBody?, sockets: KBody?
                for (i, p) in spots.enumerated() {
                    let rad = s.keyRadius * (i == 3 ? 1.4 : 1)
                    let peg = try cone(base: p, dir: -s.normal, r0: rad, r1: rad * 0.6, h: s.keyHeight, id: "peg\(i)")
                    let socket = try cone(base: p + s.normal * 0.01, dir: -s.normal, r0: rad + s.keyClearance,
                                          r1: rad * 0.6 + s.keyClearance, h: s.keyHeight + s.keyClearance, id: "socket\(i)")
                    pegs = try pegs.map { try $0.boolean(peg, SK_FUSE) } ?? peg
                    sockets = try sockets.map { try $0.boolean(socket, SK_FUSE) } ?? socket
                }
                return (try front.boolean(pegs!, SK_FUSE), try back.boolean(sockets!, SK_CUT))
            }

            var front: KBody, back: KBody
            if !s.cheapFirst {
                var cavity = try r.time("cut part") { try blockBody.boolean(part, SK_CUT) }
                r.notes.append(String(format: "after cut: volume %.0f (expected %.0f), valid %@, %d faces", cavity.volume,
                                      blockVolume - part.volume, cavity.isValid ? "yes" : "NO", cavity.faceNames.count))
                cavity = try r.time("gate+vents") { try cavity.boolean(channels, SK_CUT) }
                let halves = try r.time("split") { try cavity.split(planeThrough: planePoint, normal: s.normal, featureID: "mold.split") }
                guard halves.count == 2 else { r.failure = "split gave \(halves.count) pieces"; r.print(); return r }
                (front, back) = (halves[1], halves[0])
                (front, back) = try r.time("keys") { try addKeys(front: front, back: back) }
            } else {
                let drilled = try r.time("block - channels") { try blockBody.boolean(channels, SK_CUT) }
                let halves = try r.time("split block") { try drilled.split(planeThrough: planePoint, normal: s.normal, featureID: "mold.split") }
                guard halves.count == 2 else { r.failure = "split gave \(halves.count) pieces"; r.print(); return r }
                (front, back) = try r.time("keys") { try addKeys(front: halves[1], back: halves[0]) }
                front = try r.time("front - part") { try front.boolean(part, SK_CUT) }
                back = try r.time("back - part") { try back.boolean(part, SK_CUT) }
            }
            let v0 = back.volume, v1 = front.volume
            r.notes.append(String(format: "front %.0f (valid %@, %d faces), back %.0f (valid %@, %d faces); both %.0f; block - part - channels = %.0f",
                                  v1, front.isValid ? "yes" : "NO", front.faceNames.count, v0, back.isValid ? "yes" : "NO", back.faceNames.count,
                                  v0 + v1, blockVolume - part.volume - channels.volume))
            for (i, h) in [back, front].enumerated() {
                let pieces = try h.splitIntoParts(featureID: "chk")
                if pieces.count != 1 { r.notes.append("half \(i) falls into \(pieces.count) solids") }
            }

            // Tessellation and export, as the studio would show and write them.
            let mesh = try r.time("tessellate") { try front.tessellate(linearDeflection: 0.05) }
            r.notes.append("front mesh: \(mesh.indices.count / 3) triangles")
            if export {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moldspike", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try r.time("export STL") {
                    try KBody.exportSTL([front], to: dir.appendingPathComponent("\(name)-front.stl"))
                    try KBody.exportSTL([back], to: dir.appendingPathComponent("\(name)-back.stl"))
                }
                r.notes.append("exported to \(dir.path)")
            }
        } catch {
            r.failure = "\(error)"
        }
        r.print()
        return r
    }

    // MARK: - real parts built with the kernel

    /// A filleted bracket: plate with two holes and a rib-like boss.
    static func bracket() throws -> KBody {
        var b = try block(centre: SIMD3(0, 0, 6), size: SIMD3(60, 30, 12))
        let edges = b.edgeNames.filter { b.hasEdge($0) }
        b = try b.fillet(edges: edges, radius: 2.5, featureID: "bf")
        for x in [-20.0, 20.0] {
            let hole = try rod(from: SIMD3(x, 0, -1), dir: SIMD3(0, 0, 1), diameter: 6, length: 14, id: "h\(x)")
            b = try b.boolean(hole, SK_CUT)
        }
        let boss = try rod(from: SIMD3(0, 0, 11), dir: SIMD3(0, 0, 1), diameter: 14, length: 10, id: "boss")
        b = try b.boolean(boss, SK_FUSE)
        let bore = try rod(from: SIMD3(0, 0, 14), dir: SIMD3(0, 0, 1), diameter: 7, length: 10, id: "bore")
        return try b.boolean(bore, SK_CUT)
    }

    /// A bottle: a revolved profile with a Bézier shoulder, standing on the floor, axis z.
    static func bottle() throws -> KBody {
        let s = try KSketch(frame: .xz)
        try s.addLine("base", SIMD2(0, 0), SIMD2(18, 0))
        try s.addLine("side", SIMD2(18, 0), SIMD2(18, 60))
        try s.addBezier("shoulder", [SIMD2(18, 60), SIMD2(18, 80), SIMD2(7, 78), SIMD2(7, 90)])
        try s.addLine("neck", SIMD2(7, 90), SIMD2(7, 105))
        try s.addLine("lip", SIMD2(7, 105), SIMD2(0, 105))
        try s.addLine("axis", SIMD2(0, 105), SIMD2(0, 0))
        let regions = try s.buildRegions()
        guard let region = regions.first else { throw KernelError(message: "bottle profile") }
        return try KBody.revolve([s.profile(region.index)], axisOrigin: .zero, axisDirection: SIMD3(0, 0, 1), angle: 2 * .pi, featureID: "bottle")
    }

    /// A mug: hollow cylinder with a torus handle. The handle is why the parting plane must run through its middle.
    static func mug() throws -> KBody {
        var m = try rod(from: .zero, dir: SIMD3(0, 0, 1), diameter: 60, length: 80, id: "mug")
        let inner = try rod(from: SIMD3(0, 0, 4), dir: SIMD3(0, 0, 1), diameter: 52, length: 80, id: "in")
        m = try m.boolean(inner, SK_CUT)
        // Handle: a torus in the xz plane (axis along y) at the right-hand side, fused.
        let frame = Frame(origin: SIMD3(36, 0, 42), normal: SIMD3(0, 1, 0), xAxis: SIMD3(1, 0, 0))
        let handle = try KBody.primitive(.torus(diameter: 40, tube: 9), on: frame, featureID: "handle")
        return try m.boolean(handle, SK_FUSE)
    }

    /// A smooth organic body: a sphere fused with a smaller one and a cone-ish neck (a "figurine" blob).
    static func figurine() throws -> KBody {
        var body = try KBody.primitive(.sphere(diameter: 50), on: Frame(origin: SIMD3(0, 0, 25), normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0)), featureID: "body")
        let head = try KBody.primitive(.sphere(diameter: 28), on: Frame(origin: SIMD3(0, 0, 58), normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0)), featureID: "head")
        body = try body.boolean(head, SK_FUSE)
        for sx in [-1.0, 1.0] {
            let ear = try KBody.primitive(.sphere(diameter: 12), on: Frame(origin: SIMD3(sx * 12, 0, 74), normal: SIMD3(0, 0, 1), xAxis: SIMD3(1, 0, 0)), featureID: "ear\(sx)")
            body = try body.boolean(ear, SK_FUSE)
        }
        return body
    }

    // MARK: - the cases

    @Test func bracketHorizontalParting() throws {
        let part = try Self.bracket()
        // Parting plane through the middle of a lying bracket; poured from the top.
        _ = Self.buildMold("bracket", part: part, export: true)
    }

    @Test func bottleVerticalParting() throws {
        let part = try Self.bottle()
        var s = Setup()
        s.normal = SIMD3(1, 0, 0)  // vertical parting plane, poured from the top (up stays z)
        _ = Self.buildMold("bottle", part: part, setup: s, gateAt: SIMD3(0, 0, 95), export: true)
    }

    @Test func mugVerticalParting() throws {
        let part = try Self.mug()
        var s = Setup()
        s.normal = SIMD3(0, 1, 0)  // plane through the handle's middle
        _ = Self.buildMold("mug", part: part, setup: s, gateAt: SIMD3(0, 0, 70), export: true)
    }

    @Test func figurineVerticalParting() throws {
        let part = try Self.figurine()
        var s = Setup()
        s.normal = SIMD3(0, 1, 0)
        _ = Self.buildMold("figurine", part: part, setup: s, gateAt: SIMD3(0, 0, 60), export: true)
    }

    // MARK: - awkward planes and the cheap order

    @Test func bracketPlaneOnAFace() throws {
        // The bracket's plate is 12 thick: a plane at z = 12 lies exactly in the top face of the plate.
        let part = try Self.bracket()
        var s = Setup(); s.planeOffset = 12 - 10.5
        _ = Self.buildMold("bracket plane on face z=12", part: part, setup: s)
        s.cheapFirst = true
        _ = Self.buildMold("bracket plane on face z=12 (cheap)", part: part, setup: s)
    }

    @Test func bracketPlaneOnTheBottom() throws {
        let part = try Self.bracket()
        var s = Setup(); s.planeOffset = -10.5   // the plate's underside, z = 0
        _ = Self.buildMold("bracket plane on bottom z=0", part: part, setup: s)
    }

    @Test func figurineThroughTheSeamAndNudged() throws {
        let part = try Self.figurine()
        for (label, off, cheap) in [("on the sphere seam", 0.0, false), ("nudged 0.05", 0.05, false), ("on the sphere seam, cheap", 0.0, true)] {
            var s = Setup(); s.normal = SIMD3(0, 1, 0); s.planeOffset = off; s.cheapFirst = cheap
            _ = Self.buildMold("figurine \(label)", part: part, setup: s, gateAt: SIMD3(0, 0, 60))
        }
        var s = Setup(); s.normal = SIMD3(1, 0, 0)   // the other axis, away from the sphere seam
        _ = Self.buildMold("figurine plane x=0", part: part, setup: s, gateAt: SIMD3(0, 0, 60))
    }

    @Test func cheapOrderOnTheFourPartsAndMug() throws {
        var s = Setup(); s.cheapFirst = true
        _ = Self.buildMold("bracket (cheap)", part: try Self.bracket(), setup: s)
        s.normal = SIMD3(1, 0, 0)
        _ = Self.buildMold("bottle (cheap)", part: try Self.bottle(), setup: s, gateAt: SIMD3(0, 0, 95))
        s.normal = SIMD3(0, 1, 0)
        _ = Self.buildMold("mug (cheap)", part: try Self.mug(), setup: s, gateAt: SIMD3(0, 0, 70))
    }

    // MARK: - an imported STL

    /// Where the OCCT sample meshes are (the repo's own build tree); override with SIMPLMAKER_SPIKE_STL_DIR.
    static var stlDir: URL {
        if let d = ProcessInfo.processInfo.environment["SIMPLMAKER_SPIKE_STL_DIR"] { return URL(fileURLWithPath: d) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build-occt/src-V8_0_1/data/stl")
    }

    private func stlCase(_ file: String, normal: SIMD3<Double> = SIMD3(0, 0, 1), cheapOnly: Bool = false) throws {
        let url = Self.stlDir.appendingPathComponent(file)
        guard let data = try? Data(contentsOf: url) else { Swift.print("MOLDSPIKE \(file): file missing, skipped"); return }
        var r = Report(name: "stl:\(file)")
        let tris = KBody.stlTriangleCount(data) ?? -1
        r.notes.append("\(tris) triangles in the file (limit \(KBody.maxSTLTriangles))")
        guard tris > 0, tris <= KBody.maxSTLTriangles else { r.failure = "not importable (count)"; r.print(); return }
        let part: KBody
        do { part = try r.time("import STL") { try KBody.importSTL(data, featureID: "imp") } } catch {
            r.failure = "import: \(error)"; r.print(); return
        }
        for cheap in (cheapOnly ? [true] : [false, true]) {
            var s = Setup(); s.normal = normal; s.cheapFirst = cheap
            Self.buildMold("stl:\(file)\(cheap ? " (cheap)" : "")", part: part, setup: s)
        }
    }

    /// Every other mesh in the folder, cheap order only (run with SIMPLMAKER_MOLD_SPIKE_ALL=1: some take minutes).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIMPLMAKER_MOLD_SPIKE_ALL"] != nil))
    func importedSTLRest() throws {
        for f in ["sh2.stl", "propeller.stl", "TR12J_OCC64K.stl", "bearing.stl", "motor.stl", "head.stl"] { try stlCase(f, cheapOnly: true) }
    }

    @Test func importedSTLShape() throws { try stlCase("shape.stl") }
    @Test func importedSTLSh1() throws { try stlCase("sh1.stl") }
    @Test func importedSTLVideoPart() throws { try stlCase("video_part.stl") }
    @Test func importedSTLTR12J() throws { try stlCase("TR12J_OCC.stl") }
}
