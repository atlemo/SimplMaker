// Copyright © 2026 Atle Mo. All rights reserved.
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

    @Test func mirrorAlongAnAxisUsesThePlaneThroughItSquareToTheFloor() throws {
        // The block runs x 10…30, y 0…10, z 0…5.
        let x = try run(try block(extra: [Feature(id: "m", name: "Mirror1", .mirror(MirrorFeature(bodies: ["e"], line: .x)))]))
        let bx = try #require(x.body("e"))
        #expect(abs(bx.volume - 2000) < 1e-6, "mirrored across the XZ plane, the copy meets the block along y = 0")
        let boxX = try #require(bx.bounds)
        #expect(abs(boxX.min.y + 10) < 1e-6 && abs(boxX.max.y - 10) < 1e-6 && abs(boxX.min.x - 10) < 1e-6)

        for axis in [PatternAxis.y, .z] {
            let r = try run(try block(extra: [Feature(id: "m", name: "Mirror1", .mirror(MirrorFeature(bodies: ["e"], line: axis)))]))
            let box = try #require(r.body("e")?.bounds)
            #expect(abs(box.min.x + 30) < 1e-6 && abs(box.max.x - 30) < 1e-6, "left and right swap, as with the YZ plane")
        }
        let frame = try Regenerator.mirrorPlane(along: .x, RegenResult())
        #expect(abs(abs(frame.normal.y) - 1) < 1e-9 && simd_length(frame.origin) < 1e-9)
    }

    @Test func mirrorAlongAStraightEdgeMakesATrueMirrorImage() throws {
        var doc = try block()  // (its curve ids are made afresh each time, so the edge name belongs to this document)
        let base = try run(doc)
        let body = try #require(base.body("e"))
        let edge = try #require(try body.faceEdges("e.start").first { (try? body.edgeLine($0).direction).map { abs($0.x) > 0.99 } == true })
        let ref = EdgeRef(body: "e", edge: edge)
        doc.features.append(Feature(id: "m", name: "Mirror1", .mirror(MirrorFeature(bodies: ["e"], line: .edge(ref)))))
        let along = try run(doc)
        let result = try #require(along.body("e"))
        #expect(abs(result.volume - 2000) < 1e-6, "the copy lies against the block, in the plane through the edge")
        let plane = try Regenerator.mirrorPlane(along: .edge(ref), base)
        let direction = try body.edgeLine(edge).direction
        #expect(abs(simd_dot(plane.normal, simd_normalize(direction))) < 1e-9, "the edge lies in the mirror plane")
        // Square to the face the edge borders: the plane's normal lies in that face's plane.
        let faceNormals = try body.edgeFaces(edge).compactMap { try? body.faceFrame($0).normal }
        #expect(faceNormals.contains { abs(simd_dot($0, plane.normal)) < 1e-9 })
    }

    @Test func mirrorAlongAnEdgeKeepsWorkingWhenSavedAndReloaded() throws {
        let m = MirrorFeature(bodies: ["e"], line: .edge(EdgeRef(body: "e", edge: "a|b")))
        let back = try JSONDecoder().decode(MirrorFeature.self, from: JSONEncoder().encode(m))
        #expect(back == m)
        let plain = MirrorFeature(bodies: ["e"], plane: .yz)
        let text = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!text.contains("line"), "a mirror across a plane is saved as before")
        #expect(try JSONDecoder().decode(MirrorFeature.self, from: Data(text.utf8)) == plain, "and an older file has no line")
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

    /// A 40 × 40 × 10 block, with a 10 × 10 square sketched on the XY plane (the block's bottom), extruded from `start`.
    private func fromFace(_ start: FaceRef?, extent: ExtrudeExtent, flipped: Bool = false, operation: BodyOperation = .join,
                          taper: String? = nil) -> CADDocument {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, u: "0 mm", v: "0 mm",
                                                                                width: "40", length: "40", height: "10")))]
        var s = Sketch()
        s.addRectangle(-5, -5, 5, 5)  // the box is centred on the origin
        d.features.append(Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))))
        var e = ExtrudeFeature(sketch: "sk", profiles: [ProfileRef(curves: [], hintU: 0, hintV: 0)], extent: extent,
                               flipped: flipped, operation: operation)
        e.start = start
        e.taper = taper
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(e)))
        return d
    }

    @Test func startingFromAFaceAbove() throws {
        // The square sits on the bottom, but the extrude starts on the top face and rises 5 mm from there.
        let r = Regenerator.regenerate(fromFace(FaceRef(body: "b", face: "b.top"), extent: .distance("5 mm")))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("b"))
        #expect(abs(body.volume - (16000 + 500)) < 1e-6, "\(body.volume)")
        #expect(abs(Double(try #require(body.bounds).max.z) - 15) < 1e-6)
        #expect(abs((r.extrudeStarts["e"] ?? 0) - 10) < 1e-9)
        // Without a start face the same extrude is inside the block and adds nothing.
        let plain = Regenerator.regenerate(fromFace(nil, extent: .distance("5 mm")))
        #expect(plain.errors.isEmpty, "\(plain.errors) \(plain.bodies.map(\.id))")
        let plainVolume = try #require(plain.body("b")).volume
        #expect(abs(plainVolume - 16000) < 1e-6, "\(plainVolume)")
    }

    @Test func startingFromAFaceBelowCutsFromThere() throws {
        // Sketch on the bottom plane, start on the top face, go back down 3 mm: a pocket in the top.
        let r = Regenerator.regenerate(fromFace(FaceRef(body: "b", face: "b.top"), extent: .distance("3 mm"), flipped: true, operation: .cut))
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.map(\.id) == ["b"], "\(r.bodies.map(\.id))")
        let volume = try #require(r.body("b")).volume
        #expect(abs(volume - (16000 - 300)) < 1e-6, "\(volume)")
    }

    @Test func startingFromAFaceKeepsTheTaperOnIt() throws {
        let r = Regenerator.regenerate(fromFace(FaceRef(body: "b", face: "b.top"), extent: .distance("5 mm"), taper: "-10 deg"))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let v = try #require(r.body("b")).volume
        #expect(v > 16000 + 300 && v < 16000 + 500, "narrowing as it rises: \(v)")
    }

    @Test func aStartFaceMustBeParallel() throws {
        let r = Regenerator.regenerate(fromFace(FaceRef(body: "b", face: "b.front"), extent: .distance("5 mm")))
        #expect(r.errors["e"]?.contains("parallel") == true, "\(r.errors)")
    }
}

/// A sketch mirrored across a line it touches is one profile with its image.
@Suite struct SketchMirrorProfileTests {
    @Test func theHalfAndItsImageExtrudeAsOneBody() throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0), c = s.addPoint(8, 5), d = s.addPoint(2, 5)
        let base = s.addLine(a, b, construction: true)
        let lines = [s.addLine(b, c), s.addLine(c, d), s.addLine(d, a)]
        s.mirrors = [SketchMirrorDef(id: "m", sources: lines, line: base)]
        var doc = CADDocument()
        doc.features = [
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
            Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk", profiles: [ProfileRef(curves: [], hintU: 5, hintV: 0)],
                                                                          extent: .distance("3 mm")))),
        ]
        let r = Regenerator.regenerate(doc)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("e"))
        #expect(abs(body.volume - 2 * 40 * 3) < 1e-6, "one profile of both halves, 80 mm² (got \(body.volume / 3))")
    }
}
