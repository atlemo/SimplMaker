// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
import simd
@testable import CADKernel

/// Split: dividing bodies into new bodies with a plane, a face or a profile.
@Suite struct SplitTests {
    /// A 20 × 10 × 5 block "e" from x = 10 to 30, y = 0 to 10, z = 0 to 5, and a construction plane "pl" at x = 20.
    private func block(extra: [Feature] = []) -> CADDocument {
        var s = Sketch()
        s.addRectangle(10, 0, 30, 10)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk",
            profiles: [ProfileRef(curves: [], hintU: 20, hintV: 5)], extent: .distance("5 mm")))))
        d.features.append(Feature(id: "pl", name: "Plane1", .plane(PlaneFeature(base: .yz, offset: "20 mm"))))
        d.features += extra
        return d
    }

    private func split(_ tool: SplitFeature.Tool, bodies: [FeatureID] = ["e"], extra: [Feature] = []) -> RegenResult {
        var d = block(extra: extra)
        d.features.append(Feature(id: "s", name: "Split1", .split(SplitFeature(bodies: bodies, tool: tool))))
        return Regenerator.regenerate(d)
    }

    @Test func aPlaneThroughTheMiddleMakesTwoBodies() throws {
        let r = split(.plane(.plane("pl")))
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.map(\.id) == ["e", Regenerator.splitPieceID(of: "e", by: "s", 1)])
        let a = try #require(r.bodies.first?.body), b = try #require(r.bodies.last?.body)
        #expect(abs(a.volume - 500) < 1e-6 && abs(b.volume - 500) < 1e-6, "\(a.volume) \(b.volume)")
        // The part behind the plane (along its normal) keeps the body's identity.
        let boxA = try #require(a.bounds), boxB = try #require(b.bounds)
        #expect(abs(boxA.max.x - 20) < 1e-6 && abs(boxB.min.x - 20) < 1e-6, "\(boxA) \(boxB)")
        // Each piece has a cut face of its own, and keeps the names of the faces it had.
        for body in [a, b] {
            #expect(body.faceNames.contains("s.split"), "\(body.faceNames)")
            #expect(body.faceNames.contains { $0.hasPrefix("e.") }, "\(body.faceNames)")
        }
        #expect(r.bodies.map(\.name) == ["Body1", "Body2"], "\(r.bodies.map(\.name))")
    }

    @Test func aBodyTheToolMissesStaysAsItIs() throws {
        // Plane yz at the origin lies clear of the block.
        let r = split(.plane(.yz))
        #expect(r.bodies.count == 1)
        #expect(r.errors["s"]?.contains("doesn't cut") == true, "\(r.errors)")
        let body = try #require(r.body("e"))
        #expect(abs(body.volume - 1000) < 1e-6)
    }

    @Test func onlyTheBodiesTheToolCrossesAreCut() throws {
        // A second block well away from the plane (x 40 to 50).
        var s = Sketch()
        s.addRectangle(40, 0, 50, 10)
        let far = [Feature(id: "sk2", name: "Sketch2", .sketch(SketchFeature(plane: .xy, sketch: s))),
                   Feature(id: "e2", name: "Extrude2", .extrude(ExtrudeFeature(sketch: "sk2",
                       profiles: [ProfileRef(curves: [], hintU: 45, hintV: 5)], extent: .distance("5 mm"))))]
        let r = split(.plane(.plane("pl")), bodies: ["e", "e2"], extra: far)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.count == 3, "\(r.bodies.map(\.id))")
        #expect(r.bodies.map(\.id) == ["e", Regenerator.splitPieceID(of: "e", by: "s", 1), "e2"], "pieces sit beside their parent")
        #expect(abs((r.body("e2")?.volume ?? 0) - 500) < 1e-6)
    }

    @Test func aFlatFaceOfAnotherBodyCutsAlongItsPlane() throws {
        // A thin slab (x 15 to 16) across the block; its face at x = 15 is the tool.
        var s = Sketch()
        s.addRectangle(15, -5, 16, 15)
        let slab = [Feature(id: "sk2", name: "Sketch2", .sketch(SketchFeature(plane: .xy, sketch: s))),
                    Feature(id: "e2", name: "Extrude2", .extrude(ExtrudeFeature(sketch: "sk2",
                        profiles: [ProfileRef(curves: [], hintU: 15.5, hintV: 5)], extent: .distance("20 mm"))))]
        let base = Regenerator.regenerate(block(extra: slab))
        let slabBody = try #require(base.body("e2"))
        let face = try #require(slabBody.faceNames.first { (try? slabBody.faceFrame($0))?.normal.x ?? 0 < -0.99 })
        let r = split(.face(FaceRef(body: "e2", face: face)), extra: slab)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let volumes = r.bodies.filter { $0.id != "e2" }.map { $0.body.volume }.sorted()
        #expect(volumes.count == 2 && abs(volumes[0] - 250) < 1e-6 && abs(volumes[1] - 750) < 1e-6, "\(volumes)")
    }

    @Test func aCurvedFaceCutsWhereItIs() throws {
        // A cylinder of radius 3 standing through the block's middle: its wall cuts the block in two.
        var s = Sketch()
        let c = s.addPoint(20, 5)
        s.addCircle(center: c, radius: 3, id: "C")
        let tube = [Feature(id: "sk2", name: "Sketch2", .sketch(SketchFeature(plane: .xy, sketch: s))),
                    Feature(id: "e2", name: "Extrude2", .extrude(ExtrudeFeature(sketch: "sk2",
                        profiles: [ProfileRef(curves: ["C"], hintU: 20, hintV: 5)], extent: .distance("20 mm"), flipped: false)))]
        let base = Regenerator.regenerate(block(extra: tube))
        let tool = try #require(base.body("e2"))
        let wall = try #require(tool.faceNames.first { (try? tool.faceFrame($0)) == nil && (try? tool.faceCylinder($0)) != nil })
        let r = split(.face(FaceRef(body: "e2", face: wall)), extra: tube)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let pieces = r.bodies.filter { $0.id != "e2" }.map { $0.body.volume }.sorted()
        #expect(pieces.count == 2, "\(pieces)")
        #expect(abs(pieces[0] - Double.pi * 9 * 5) < 0.5 && abs(pieces[0] + pieces[1] - 1000) < 1e-3, "\(pieces)")
    }

    @Test func aSketchProfileCutsAlongTheSketchPlane() throws {
        var s = Sketch()
        s.addRectangle(0, 0, 4, 4)
        let sketch = [Feature(id: "sk2", name: "Sketch2", .sketch(SketchFeature(plane: .plane("pl"), sketch: s)))]
        let r = split(.profile("sk2"), extra: sketch)
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.bodies.count == 2)
        // The sketch is hidden once a split has used it, as for any other feature.
        let feature = Feature(id: "s", name: "Split1", .split(SplitFeature(bodies: ["e"], tool: .profile("sk2"))))
        #expect(feature.sketchesUsed == ["sk2"])
        #expect(feature.references.contains("sk2") && feature.changedBodies == ["e"])
    }

    @Test func pieceIDsAreTheSameOnEveryRebuild() throws {
        let a = split(.plane(.plane("pl"))), b = split(.plane(.plane("pl")))
        #expect(a.bodies.map(\.id) == b.bodies.map(\.id))
        #expect(a.bodies.map { $0.body.volume } == b.bodies.map { $0.body.volume })
        #expect(Regenerator.rootBody(a.bodies[1].id) == "e")
        #expect(Regenerator.rootBody("e") == "e")
    }

    @Test func laterFeaturesCanUseAPieceAndItsFaces() throws {
        let r0 = split(.plane(.plane("pl")))
        let piece = try #require(r0.bodies.last)
        let cut = try #require(piece.body.faceNames.first { $0 == "s.split" })
        var d = block()
        d.features.append(Feature(id: "s", name: "Split1", .split(SplitFeature(bodies: ["e"], tool: .plane(.plane("pl"))))))
        d.features.append(Feature(id: "x", name: "Extrude2", .extrude(ExtrudeFeature(face: FaceRef(body: piece.id, face: cut),
                                                                                  extent: .distance("3 mm")))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let grown = try #require(r.body(piece.id))
        #expect(abs(grown.volume - (500 + 3 * 10 * 5)) < 1e-6, "\(grown.volume)")
    }

    // MARK: split into parts

    /// Two blocks that don't touch, extruded together into one body.
    private func twoBlocks(_ tool: SplitFeature.Tool) -> RegenResult {
        var s = Sketch()
        s.addRectangle(0, 0, 10, 10)
        s.addRectangle(30, 0, 40, 10)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        d.features.append(Feature(id: "e", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk",
            profiles: [ProfileRef(curves: [], hintU: 5, hintV: 5), ProfileRef(curves: [], hintU: 35, hintV: 5)],
            extent: .distance("5 mm")))))
        d.features.append(Feature(id: "pl", name: "Plane1", .plane(PlaneFeature(base: .yz, offset: "100 mm"))))
        d.features.append(Feature(id: "s", name: "Split1", .split(SplitFeature(bodies: ["e"], tool: tool))))
        return Regenerator.regenerate(d)
    }

    @Test func loosePiecesBecomeBodiesOfTheirOwn() throws {
        let r = twoBlocks(.parts)
        #expect(r.errors.isEmpty)
        #expect(r.bodies.count == 2)
        #expect(r.bodies.first?.id == "e")
        for b in r.bodies { #expect(abs(b.body.volume - 500) < 1e-6) }
    }

    @Test func aPlaneThatMissesBothStillSeparatesThem() throws {
        let r = twoBlocks(.plane(.plane("pl")))
        #expect(r.bodies.count == 2)
    }

    @Test func aBodyInOnePieceHasNothingToSeparate() throws {
        let r = split(.parts)
        #expect(!r.errors.isEmpty)
        #expect(r.bodies.count == 1)
    }
}
