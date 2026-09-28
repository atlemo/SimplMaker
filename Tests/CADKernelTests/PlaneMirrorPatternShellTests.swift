// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
import simd
@testable import CADKernel

/// Construction planes, mirror, patterns and shell.
@Suite struct PlaneMirrorPatternShellTests {
    /// A 20 × 10 × 5 block from x = 10 to 30, y = 0 to 10, as an extruded rectangle.
    private func block(on plane: PlaneRef = .xy, extra: [Feature] = []) throws -> CADDocument {
        var s = Sketch()
        s.addRectangle(10, 0, 30, 10)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: plane, sketch: s)))]
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk",
            profiles: [ProfileRef(curves: [], hintU: 20, hintV: 5)], extent: .distance("5 mm")))))
        d.features += extra
        return d
    }

    private func run(_ d: CADDocument) throws -> RegenResult {
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        return r
    }

    @Test func offsetAndTiltedPlanes() throws {
        var r = RegenResult()
        let up = try Regenerator.plane(PlaneFeature(base: .xy, offset: "10 mm"), r)
        #expect(simd_length(up.origin - SIMD3(0, 0, 10)) < 1e-9 && simd_length(up.normal - SIMD3(0, 0, 1)) < 1e-9)
        let tilted = try Regenerator.plane(PlaneFeature(base: .xy, offset: "0 mm", angle: "90 deg", axis: .horizontal), r)
        #expect(simd_length(tilted.normal - SIMD3(0, -1, 0)) < 1e-9, "\(tilted.normal)")
        r.planes["p"] = up
        let resolved = try Regenerator.resolvePlane(.plane("p"), r)
        #expect(resolved == up)

        // A sketch on the plane builds up there.
        var d = try block(on: .plane("p"))
        d.features.insert(Feature(id: "p", name: "Plane1", .plane(PlaneFeature(base: .xy, offset: "10 mm"))), at: 0)
        let built = try run(d)
        let box = try #require(built.body("e")?.bounds)
        #expect(abs(box.min.z - 10) < 1e-6 && abs(box.max.z - 15) < 1e-6)
    }

    @Test func mirrorJoinsACopyAcrossThePlane() throws {
        let d = try block(extra: [Feature(id: "m", name: "Mirror1", .mirror(MirrorFeature(bodies: ["e"], plane: .yz)))])
        let mirrored = try run(d)
        let body = try #require(mirrored.body("e"))
        #expect(abs(body.volume - 2 * 1000) < 1e-6)
        let box = try #require(body.bounds)
        #expect(abs(box.min.x + 30) < 1e-6 && abs(box.max.x - 30) < 1e-6)
    }

    @Test func linearCircularAndEdgePatterns() throws {
        let linear = try block(extra: [Feature(id: "p", name: "Pattern1", .pattern(PatternFeature(
            kind: .linear, bodies: ["e"], axis: .y, count: "3", spacing: "15 mm")))])
        let lr = try run(linear)
        let l = try #require(lr.body("e"))
        #expect(abs(l.volume - 3000) < 1e-6 && abs((l.bounds?.max.y ?? 0) - 40) < 1e-6)

        let circular = try block(extra: [Feature(id: "c", name: "Pattern2", .pattern(PatternFeature(
            kind: .circular, bodies: ["e"], axis: .z, count: "4")))])
        let cr = try run(circular)
        let c = try #require(cr.body("e"))
        #expect(abs(c.volume - 4000) < 1e-6, "four copies a quarter turn apart, not touching")

        // Along a straight edge of the block (its long bottom edge runs along X), as a new body.
        var along = try block()
        let base = try run(along)
        let body = try #require(base.body("e"))
        let startEdges = try body.faceEdges("e.start")
        let edge = try #require(startEdges.first { (try? body.edgeLine($0).direction).map { abs($0.x) > 0.99 } == true })
        along.features.append(Feature(id: "q", name: "Pattern3", .pattern(PatternFeature(
            kind: .linear, bodies: ["e"], axis: .edge(EdgeRef(body: "e", edge: edge)), count: "2", spacing: "30 mm", operation: .newBody))))
        let r = try run(along)
        let copy = try #require(r.body("q"))
        #expect(r.bodies.count == 2 && abs(copy.volume - 1000) < 1e-6)
    }

    @Test func shellHollowsTheBlock() throws {
        let d = try block(extra: [Feature(id: "s", name: "Shell1", .shell(ShellFeature(
            body: "e", faces: [FaceRef(body: "e", face: "e.end")], thickness: "1 mm")))])
        let shelled = try run(d)
        let body = try #require(shelled.body("e"))
        #expect(abs(body.volume - (1000 - 18 * 8 * 4)) < 1e-3, "walls 1 mm thick, open at the top: \(body.volume)")
        var bad = d
        if case .shell(var s) = bad.features[2].kind { s.thickness = "6 mm"; bad.features[2].kind = .shell(s) }
        let badResult = Regenerator.regenerate(bad)
        #expect(badResult.errors["s"] != nil, "walls thicker than the block can't be built: \(badResult.body("e")?.volume ?? -1)")
    }
}

/// Extrudes that go through everything, or up to a face.
@Suite struct ExtentTests {
    /// A 40 × 40 × 10 block, and a 10 × 10 square sketched in the middle of its top face.
    private func doc(_ extent: ExtrudeExtent, flipped: Bool = false, operation: BodyOperation = .cut) -> CADDocument {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "0 mm", v: "0 mm",
                                                                                width: "40", length: "40", height: "10")))]
        var s = Sketch()
        s.addRectangle(15, 15, 25, 25)  // the top face's sketch plane starts at the box's corner
        d.features.append(Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .face(FaceRef(body: "b", face: "b.top")), sketch: s))))
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk",
            profiles: [ProfileRef(curves: [], hintU: 20, hintV: 20)], extent: extent, flipped: flipped, operation: operation))))
        return d
    }

    @Test func throughAllCutsAHole() throws {
        let r = Regenerator.regenerate(doc(.throughAll, flipped: true))
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(abs((try #require(r.body("b")).volume) - (16000 - 1000)) < 1e-6, "a 10 × 10 hole all the way down")
        #expect(Regenerator.regenerate(doc(.throughAll)).errors["e"]?.contains("flip") == true, "upward, nothing to go through")
    }

    @Test func upToAFace() throws {
        // From the top face down to the bottom face: the same hole, found from the face.
        let r = Regenerator.regenerate(doc(.toFace(FaceRef(body: "b", face: "b.bottom")), flipped: true))
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(abs((try #require(r.body("b")).volume) - (16000 - 1000)) < 1e-6)
        let side = Regenerator.regenerate(doc(.toFace(FaceRef(body: "b", face: "b.front")), flipped: true))
        #expect(side.errors["e"]?.contains("parallel") == true)
    }
}
