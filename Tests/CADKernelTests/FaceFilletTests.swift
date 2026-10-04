// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// A fillet or chamfer on a face rounds every edge around it, and follows the face as it changes.
@Suite struct FaceFilletTests {
    private func box(_ extra: [Feature] = []) -> CADDocument {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10")))] + extra
        return d
    }

    @Test func aBoxTopHasFourEdgesAndACylinderTopOne() throws {
        let r = Regenerator.regenerate(box())
        let body = try #require(r.body("b"))
        #expect(try body.faceEdges("b.top").count == 4)
        var d = CADDocument()
        d.features = [Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "10", diameter: "20")))]
        let cyl = try #require(Regenerator.regenerate(d).body("c"))
        let faces = try #require(try cyl.tessellate()).faceNames
        let top = try #require(faces.first { $0.hasSuffix("top") })
        #expect(try cyl.faceEdges(top).count == 1, "the seam isn't an edge to round")
    }

    @Test func aChamferAsBigAsARoundedCornerSaysSo() throws {
        func cylinder(chamfer size: String) -> RegenResult {
            var d = CADDocument()
            d.features = [
                Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "10", diameter: "20"))),
                Feature(id: "k", name: "Chamfer1", .chamfer(EdgeFeature(edges: [], faces: [FaceRef(body: "c", face: "c.top")], size: size))),
            ]
            return Regenerator.regenerate(d)
        }
        let body = try #require(cylinder(chamfer: "1 mm").edgeFeatureInputs["k"]?["c"])
        #expect(body.chamferLimit(edges: try body.faceEdges("c.top")) == 10, "the top's circle, 10 mm in radius")
        #expect(cylinder(chamfer: "9.9 mm").errors.isEmpty)
        let error = try #require(cylinder(chamfer: "12 mm").errors["k"])
        #expect(error.contains("radius of 10 mm"), "\(error)")
    }

    @Test func filletAndChamferAllRoundAFace() throws {
        let plain = try #require(Regenerator.regenerate(box()).body("b")).volume
        let top = FaceRef(body: "b", face: "b.top")
        let fillet = Regenerator.regenerate(box([Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [], faces: [top], size: "2 mm")))]))
        #expect(fillet.errors.isEmpty, "\(fillet.errors)")
        // Four 20 mm edges, each losing (1 − π/4)·r² of section, less the corner overlaps: close to 4·20·0.858.
        let lost = plain - (try #require(fillet.body("b")).volume)
        #expect(lost > 60 && lost < 70, "\(lost)")
        let chamfer = Regenerator.regenerate(box([Feature(id: "c", name: "Chamfer1", .chamfer(EdgeFeature(edges: [], faces: [top], size: "1 mm")))]))
        #expect(chamfer.errors.isEmpty, "\(chamfer.errors)")
        #expect(try #require(chamfer.body("b")).volume < plain)
        let back = try CADDocument.decode(try box([Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [], faces: [top], size: "2 mm")))]).encoded())
        guard case .fillet(let ef) = back.features[1].kind else { Issue.record("expected a fillet"); return }
        #expect(ef.faces == [top])
    }
}

/// The loop of edges through an edge, around either of its faces.
@Suite struct EdgeLoopTests {
    @Test func aBoxTopEdgeIsInTwoLoopsOfFour() throws {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10")))]
        let body = try #require(Regenerator.regenerate(d).body("b"))
        let edge = try #require(try body.faceEdges("b.top").first)
        let faces = try body.edgeFaces(edge)
        #expect(faces.count == 2 && faces.contains("b.top"))
        let top = try body.loopEdges(face: "b.top", edge: edge)
        #expect(Set(top) == Set(try body.faceEdges("b.top")))
        let side = try #require(faces.first { $0 != "b.top" })
        #expect(try body.loopEdges(face: side, edge: edge).count == 4 && Set(try body.loopEdges(face: side, edge: edge)) != Set(top))
    }
}
