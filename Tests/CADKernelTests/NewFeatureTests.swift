// Revolve, sweep, pipe, loft, rib, hole and primitives, end to end through the regenerator.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import CADKernel

@Suite struct NewFeatureTests {
    static func sketch(_ id: FeatureID, on plane: PlaneRef = .xy, _ build: (inout Sketch) -> Void) -> Feature {
        var s = Sketch()
        build(&s)
        return Feature(id: id, name: id, .sketch(SketchFeature(plane: plane, sketch: s)))
    }

    static func rect(_ s: inout Sketch, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, ids: [EntityID]) {
        let r = s.addRectangle(x0, y0, x1, y1, lineIDs: ids)
        s.constrain(.fix(r.corners[0], x: x0, y: y0))
        s.constrain(.fix(r.corners[2], x: x1, y: y1))
    }

    static func box(_ id: FeatureID, on plane: PlaneRef = .xy, u: String = "0 mm", v: String = "0 mm", _ w: String, _ l: String,
                    _ h: String, _ op: BodyOperation = .newBody) -> Feature {
        Feature(id: id, name: id, .primitive(PrimitiveFeature(kind: .box, plane: plane, u: u, v: v, width: w, length: l,
                                                              height: h, operation: op)))
    }

    static func regen(_ features: [Feature]) throws -> RegenResult {
        var doc = CADDocument()
        doc.features = features
        let r = Regenerator.regenerate(doc)
        #expect(r.errors.isEmpty, "\(r.errors)")
        return r
    }

    static func close(_ a: Double, _ b: Double, _ rel: Double = 1e-3) -> Bool { abs(a - b) <= rel * max(abs(b), 1) }

    @Test func primitivesHaveTheRightVolumesAndNamedFaces() throws {
        let r = try Self.regen([
            Self.box("b", "10 mm", "20 mm", "30 mm"),
            Feature(id: "c", name: "c", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, u: "50", height: "20", diameter: "10"))),
            Feature(id: "s", name: "s", .primitive(PrimitiveFeature(kind: .sphere, plane: .xy, u: "100", diameter: "10"))),
            Feature(id: "t", name: "t", .primitive(PrimitiveFeature(kind: .torus, plane: .xy, u: "150", diameter: "20", tube: "4"))),
            Feature(id: "k", name: "k", .primitive(PrimitiveFeature(kind: .coil, plane: .xy, u: "200", diameter: "20", tube: "2",
                                                                    pitch: "5", turns: "3"))),
        ])
        #expect(r.bodies.count == 5)
        let box = try #require(r.body("b"))
        #expect(Self.close(box.volume, 6000, 1e-9))
        #expect(Set(box.faceNames) == ["b.top", "b.bottom", "b.left", "b.right", "b.front", "b.back"])
        #expect(try box.faceFrame("b.top").origin.z == 30)
        #expect(Self.close(try #require(r.body("c")).volume, .pi * 25 * 20))
        #expect(try #require(r.body("c")).hasFace("c.top"))
        #expect(Self.close(try #require(r.body("s")).volume, 4.0 / 3 * .pi * 125))
        #expect(Self.close(try #require(r.body("t")).volume, 2 * .pi * .pi * 10 * 4))
        let coil = try #require(r.body("k"))
        #expect(coil.isValid)
        let circumference: Double = .pi * 20
        let helix: Double = 3 * (circumference * circumference + 25).squareRoot()
        #expect(Self.close(coil.volume, .pi * 1 * helix, 0.02))
        #expect(coil.hasFace("k.start") && coil.hasFace("k.end"))
    }

    @Test func revolveFullAndPartial() throws {
        let profile = Self.sketch("sk", on: .xz) { Self.rect(&$0, 5, 0, 15, 20, ids: ["A", "B", "C", "D"]) }
        let ref = ProfileRef(curves: ["A", "B", "C", "D"])
        let full = try Self.regen([profile, Feature(id: "rv", name: "rv", .revolve(RevolveFeature(sketch: "sk", profiles: [ref], axis: .sketchY)))])
        let body = try #require(full.body("rv"))
        #expect(Self.close(body.volume, .pi * (225 - 25) * 20))
        #expect(body.hasFace("rv.side.A") && body.hasFace("rv.side.C"), "\(body.faceNames)")

        let quarter = try Self.regen([profile, Feature(id: "rv", name: "rv", .revolve(RevolveFeature(
            sketch: "sk", profiles: [ref], axis: .z, angle: "90")))])
        let q = try #require(quarter.body("rv"))
        #expect(Self.close(q.volume, .pi * (225 - 25) * 20 / 4))
        #expect(q.hasFace("rv.start") && q.hasFace("rv.end"))

        var crossing = CADDocument()
        crossing.features = [Self.sketch("sk", on: .xz) { Self.rect(&$0, -5, 0, 15, 20, ids: ["A", "B", "C", "D"]) },
                             Feature(id: "rv", name: "rv", .revolve(RevolveFeature(sketch: "sk", profiles: [ref], axis: .sketchY)))]
        #expect(Regenerator.regenerate(crossing).errors["rv"] != nil, "a profile across the axis is an error, not a crash")
    }

    @Test func sweepAndPipeAlongAPath() throws {
        let path = Self.sketch("path") { s in
            let a = s.addPoint(0, 0), b = s.addPoint(0, 30), c = s.addPoint(20, 30)
            s.constrain(.fix(a, x: 0, y: 0)); s.constrain(.fix(b, x: 0, y: 30)); s.constrain(.fix(c, x: 20, y: 30))
            s.addLine(a, b, id: "P1")
            s.addLine(b, c, id: "P2")
        }
        let circle = Self.sketch("prof", on: .xz) { s in
            let c = s.addPoint(0, 0)
            s.constrain(.fix(c, x: 0, y: 0))
            s.addCircle(center: c, radius: 2, id: "C")
        }
        let straight = CurveRef(sketch: "path", curves: ["P1"])
        let r = try Self.regen([path, circle,
                                Feature(id: "sw", name: "sw", .sweep(SweepFeature(sketch: "prof", profiles: [ProfileRef(curves: ["C"])],
                                                                                   path: straight))),
                                Feature(id: "pp", name: "pp", .pipe(PipeFeature(path: straight, diameter: "5", wall: "1 mm"))),
                                Feature(id: "el", name: "el", .pipe(PipeFeature(path: CurveRef(sketch: "path", curves: ["P2", "P1"]),
                                                                                diameter: "4")))])
        let sweep = try #require(r.body("sw"))
        #expect(Self.close(sweep.volume, .pi * 4 * 30))
        #expect(sweep.hasFace("sw.start") && sweep.hasFace("sw.side.C"))
        let pipe = try #require(r.body("pp"))
        #expect(Self.close(pipe.volume, .pi * (6.25 - 2.25) * 30))
        #expect(pipe.hasFace("pp.outer") && pipe.hasFace("pp.inner"))
        let elbow = try #require(r.body("el"))
        #expect(elbow.isValid)
        #expect(elbow.volume > .pi * 4 * 45 && elbow.volume < .pi * 4 * 50, "\(elbow.volume)")  // two legs, rounded corner
    }

    @Test func loftBetweenASquareAndACircleOnAFace() throws {
        let base = Self.box("base", "30", "30", "20")
        var doc = CADDocument()
        doc.features = [base]
        let top = try Regenerator.regenerate(doc).body("base")!.faceFrame("base.top")
        let d = SIMD3<Double>(0, 0, 20) - top.origin
        let cu = (d * top.xAxis).sum(), cv = (d * top.yAxis).sum()
        let r = try Self.regen([
            base,
            Self.sketch("sq") { Self.rect(&$0, -5, -5, 5, 5, ids: ["A", "B", "C", "D"]) },
            Self.sketch("ci", on: .face(FaceRef(body: "base", face: "base.top"))) { s in
                let c = s.addPoint(cu, cv)
                s.constrain(.fix(c, x: cu, y: cv))
                s.addCircle(center: c, radius: 4, id: "K")
            },
            Feature(id: "lf", name: "lf", .loft(LoftFeature(sections: [
                LoftSection(sketch: "sq", profile: ProfileRef(curves: ["A", "B", "C", "D"])),
                LoftSection(sketch: "ci", profile: ProfileRef(curves: ["K"])),
            ]))),
        ])
        let loft = try #require(r.body("lf"))
        #expect(loft.isValid)
        #expect(loft.volume > .pi * 16 * 20 && loft.volume < 100 * 20)
        #expect(loft.hasFace("lf.start") && loft.hasFace("lf.end"))
    }

    @Test func loftOfRingsStaysHollow() throws {
        let base = Self.box("base", "30", "30", "20")
        var doc = CADDocument()
        doc.features = [base]
        let top = try Regenerator.regenerate(doc).body("base")!.faceFrame("base.top")
        let d = SIMD3<Double>(0, 0, 20) - top.origin
        let cu = (d * top.xAxis).sum(), cv = (d * top.yAxis).sum()
        let r = try Self.regen([
            base,
            Self.sketch("lo") { s in
                let c = s.addPoint(0, 0)
                s.constrain(.fix(c, x: 0, y: 0))
                s.addCircle(center: c, radius: 6, id: "O1")
                s.addCircle(center: c, radius: 4, id: "I1")
            },
            Self.sketch("hi", on: .face(FaceRef(body: "base", face: "base.top"))) { s in
                let c = s.addPoint(cu, cv)
                s.constrain(.fix(c, x: cu, y: cv))
                s.addCircle(center: c, radius: 5, id: "O2")
                s.addCircle(center: c, radius: 3, id: "I2")
            },
            Feature(id: "lf", name: "lf", .loft(LoftFeature(sections: [
                LoftSection(sketch: "lo", profile: ProfileRef(curves: ["O1", "I1"])),
                LoftSection(sketch: "hi", profile: ProfileRef(curves: ["O2", "I2"])),
            ], operation: .newBody))),
        ])
        let loft = try #require(r.body("lf"))
        #expect(loft.isValid)
        // A ring-section frustum: outer cone minus the inner one, not a solid.
        let cone = { (a: Double, b: Double) in .pi * 20 / 3 * (a * a + a * b + b * b) }
        #expect(Self.close(loft.volume, cone(6, 5) - cone(4, 3), 0.02), "\(loft.volume)")
        #expect(loft.hasFace("lf.start") && loft.hasFace("lf.end"))
    }

    @Test func straightSidedLoftOfRingsTakesChamfersOnEveryEdge() throws {
        func centre(_ feats: [Feature], _ body: String, _ z: Double) throws -> (Double, Double) {
            var doc = CADDocument(); doc.features = feats
            let f = try Regenerator.regenerate(doc).body(body)!.faceFrame("\(body).top")
            let d = SIMD3<Double>(0, 0, z) - f.origin
            return ((d * f.xAxis).sum(), (d * f.yAxis).sum())
        }
        let base = Self.box("base", "60", "60", "20")
        let (cu, cv) = try centre([base], "base", 20)
        let b2 = Self.box("b2", on: .face(FaceRef(body: "base", face: "base.top")), "60", "60", "20", .newBody)
        let (du, dv) = try centre([base, b2], "b2", 40)
        let r = try Self.regen([
            base, b2,
            Self.sketch("lo") { s in
                let c = s.addPoint(0, 0); s.constrain(.fix(c, x: 0, y: 0))
                s.addCircle(center: c, radius: 17, id: "O1"); s.addCircle(center: c, radius: 15, id: "I1")
            },
            Self.sketch("mid", on: .face(FaceRef(body: "base", face: "base.top"))) { s in
                let c = s.addPoint(cu, cv); s.constrain(.fix(c, x: cu, y: cv))
                s.addCircle(center: c, radius: 21, id: "O2"); s.addCircle(center: c, radius: 19, id: "I2")
            },
            Self.sketch("hi", on: .face(FaceRef(body: "b2", face: "b2.top"))) { s in
                let c = s.addPoint(du, dv); s.constrain(.fix(c, x: du, y: dv))
                s.addCircle(center: c, radius: 22, id: "O3"); s.addCircle(center: c, radius: 20, id: "I3")
            },
            Feature(id: "lf", name: "lf", .loft(LoftFeature(sections: [
                LoftSection(sketch: "lo", profile: ProfileRef(curves: ["O1", "I1"])),
                LoftSection(sketch: "mid", profile: ProfileRef(curves: ["O2", "I2"])),
                LoftSection(sketch: "hi", profile: ProfileRef(curves: ["O3", "I3"])),
            ], ruled: true, operation: .newBody))),
        ])
        let loft = try #require(r.body("lf"))
        #expect(loft.isValid)
        // The bore is lofted from clockwise hole wires; its surfaces must still accept a chamfer at both ends.
        for face in ["lf.start", "lf.end"] {
            let edges = try loft.faceEdges(face)
            #expect(edges.count == 2)
            for e in edges {
                let chamfered = try loft.chamfer(edges: [e], distance: 0.4, featureID: "c")
                #expect(chamfered.isValid && chamfered.volume < loft.volume, "\(e)")
            }
        }
    }

    @Test func ribFillsTheCornerOfABracket() throws {
        let plate = Self.box("plate", "40", "40", "5")
        let wall = Self.box("wall", v: "17.5", "40", "5", "40", .join)
        let bracket = try Self.regen([plate, wall])
        let before = try #require(bracket.body("plate")).volume
        let rib = Self.sketch("ribsk", on: .yz) { s in
            let a = s.addPoint(15, 25), b = s.addPoint(-10, 5)
            s.constrain(.fix(a, x: 15, y: 25)); s.constrain(.fix(b, x: -10, y: 5))
            s.addLine(a, b, id: "R")
        }
        let r = try Self.regen([plate, wall, rib,
                                Feature(id: "rib", name: "rib", .rib(RibFeature(path: CurveRef(sketch: "ribsk", curves: ["R"]),
                                                                                thickness: "3 mm")))])
        let body = try #require(r.body("plate"))
        #expect(body.isValid)
        #expect(Self.close(body.volume - before, 0.5 * 25 * 20 * 3, 0.1), "\(body.volume - before)")
    }

    @Test func holesCutTheBody() throws {
        let block = Self.box("blk", "40", "40", "10")
        var doc = CADDocument()
        doc.features = [block]
        let top = try Regenerator.regenerate(doc).body("blk")!.faceFrame("blk.top")
        let d = SIMD3<Double>(0, 0, 10) - top.origin
        let u = "\((d * top.xAxis).sum()) mm", v = "\((d * top.yAxis).sum()) mm"
        let face = FaceRef(body: "blk", face: "blk.top")

        func removed(_ hole: HoleFeature) throws -> (Double, KBody) {
            let r = try Self.regen([block, Feature(id: "h", name: "h", .hole(hole))])
            let b = try #require(r.body("blk"))
            #expect(b.isValid)
            return (16000 - b.volume, b)
        }
        let (through, tb) = try removed(HoleFeature(face: face, u: u, v: v, diameter: "5", depth: nil))
        #expect(Self.close(through, .pi * 6.25 * 10))
        #expect(tb.hasFace("h.hole.wall"))
        let (blind, _) = try removed(HoleFeature(face: face, u: u, v: v, diameter: "5", depth: "6", tipAngle: "0"))
        #expect(Self.close(blind, .pi * 6.25 * 6))
        let (drilled, _) = try removed(HoleFeature(face: face, u: u, v: v, diameter: "5", depth: "6"))
        #expect(drilled > blind)
        let (cbore, _) = try removed(HoleFeature(face: face, u: u, v: v, kind: .counterbore, diameter: "5", depth: nil,
                                                 headDiameter: "9", headDepth: "3"))
        #expect(Self.close(cbore, .pi * 6.25 * 7 + .pi * 20.25 * 3))
        let (csink, _) = try removed(HoleFeature(face: face, u: u, v: v, kind: .countersink, diameter: "5", depth: nil,
                                                 headDiameter: "9", headAngle: "90"))
        #expect(csink > through)
    }

    @Test func visibilityIsSavedAndOlderFilesStillOpen() throws {
        var doc = CADDocument.demo()
        doc.hidden = ["base", "plate"]
        let back = try CADDocument.decode(try doc.encoded())
        #expect(back.hidden == ["base", "plate"])
        #expect(back.ignoringPresentation == doc.ignoringPresentation && back.ignoringPresentation != back)

        var json = try JSONSerialization.jsonObject(with: try CADDocument.demo().encoded()) as! [String: Any]
        json["hidden"] = nil
        let old = try CADDocument.decode(try JSONSerialization.data(withJSONObject: json))
        #expect(old.hidden.isEmpty && old.features.count == 6)
    }
}

@Suite struct RibDemoTests {
    @Test func theRibExampleRegeneratesIntoOneValidBracket() throws {
        let r = Regenerator.regenerate(.ribDemo())
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.count == 1)
        let body = try #require(r.body("plate"))
        #expect(body.isValid)
        // Plate + wall, two 4 mm ribs (each a 24 × 32 mm triangle, less where the rib is cut off), minus two holes.
        let plateAndWall = 80.0 * 60 * 6 + 80 * 6 * 44
        let holes = 2 * Double.pi * 9 * 6
        #expect(body.volume > plateAndWall - holes + 2 * 4 * 0.4 * 0.5 * 24 * 32)
        #expect(body.volume < plateAndWall - holes + 2 * 4 * 0.5 * 30 * 32)
    }
}

@Suite struct ManifoldDemoTests {
    @Test func theManifoldExampleIsFiveColouredBodiesAndANestOfBolts() throws {
        let doc = CADDocument.manifoldDemo()
        let r = Regenerator.regenerate(doc)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(Set(r.bodies.map(\.id)) == ["block", "oring", "flange", "pipe", "bolt", "bolts"])
        for b in r.bodies { #expect(b.body.isValid, "\(b.id)") }
        #expect(Set(doc.bodyColors.keys) == Set(r.bodies.map(\.id)))
        // The pattern makes three more bolts, so four in all.
        let bolt = try #require(r.body("bolt")).volume
        #expect(abs(try #require(r.body("bolts")).volume - 3 * bolt) < 1e-6 * bolt)
        // The pipe ends well clear of the block, so its path bends.
        let end = try #require(r.body("pipe")).faceFrame("pipe.end").origin
        #expect(end.x > 100 && end.z > 100)
        // Threads are cut in the tapped holes, the side port and the bolts.
        #expect(try #require(r.body("block")).faceNames.contains { $0.hasPrefix("tapthread") })
        #expect(try #require(r.body("block")).faceNames.contains { $0.hasPrefix("portthread") })
        #expect(try #require(r.body("bolt")).faceNames.contains { $0.hasPrefix("boltthread") })
    }
}
