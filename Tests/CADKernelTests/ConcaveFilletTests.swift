// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// A concave fillet curves the other way: a scoop cut into a convex edge, a bead added in a concave corner, the arc
/// centred on the edge.
@Suite struct ConcaveFilletTests {
    private func box(_ extra: [Feature] = []) -> CADDocument {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10")))] + extra
        return d
    }

    @Test func aScoopTakesAQuarterRoundOutOfEachConvexEdge() throws {
        let plain = try #require(Regenerator.regenerate(box()).body("b")).volume
        let top = FaceRef(body: "b", face: "b.top")
        let r = Regenerator.regenerate(box([Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [], faces: [top], size: "2 mm", concave: true)))]))
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("b"))
        // Four 20 mm edges, each losing a quarter disc of radius 2 (π mm²), less what the corners share.
        let lost = plain - body.volume
        #expect(lost > 200 && lost < 255, "\(lost)")
        #expect(body.faceNames.contains { $0.hasPrefix("f.fillet.") }, "\(body.faceNames)")
        // The normal fillet takes less: it is the other way round.
        let normal = Regenerator.regenerate(box([Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [], faces: [top], size: "2 mm")))]))
        #expect(try #require(normal.body("b")).volume > body.volume)
    }

    @Test func aBeadFillsTheInsideCornerOfAnLShape() throws {
        var s = Sketch()
        let pts = [(0.0, 0.0), (20, 0), (20, 10), (10, 10), (10, 20), (0, 20)].map { s.addPoint($0.0, $0.1) }
        var lines: [EntityID] = []
        for i in 0..<pts.count { lines.append(s.addLine(pts[i], pts[(i + 1) % pts.count], id: "L\(i + 1)")) }
        var d = CADDocument()
        d.features = [
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
            Feature(id: "ex", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk", profiles: [ProfileRef(curves: lines)], extent: .distance("8 mm")))),
        ]
        let plainBody = try #require(Regenerator.regenerate(d).body("ex"))
        let inside = try #require(plainBody.edgeNames.first { $0.contains("ex.side.L3") && $0.contains("ex.side.L4") })
        d.features.append(Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [EdgeRef(body: "ex", edge: inside)], size: "2 mm", concave: true))))
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let gained = try #require(r.body("ex")).volume - plainBody.volume
        // A quarter disc of radius 2 along 8 mm of corner.
        #expect(abs(gained - Double.pi * 8) < 1, "\(gained)")
    }

    @Test func aPocketRimGetsACoveAroundItsCorners() throws {
        var s = Sketch()
        let r = s.addRectangle(-8, -8, 8, 8)
        var d = box()
        d.features += [
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
            Feature(id: "pk", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk", profiles: [ProfileRef(curves: r.lines)], extent: .distance("6 mm"), operation: .cut, target: "b"))),
        ]
        let pocketed = try #require(Regenerator.regenerate(d).body("b"))
        let rim = pocketed.edgeNames.filter { $0.contains("b.bottom") && $0.contains("pk.") }
        #expect(rim.count == 4, "\(pocketed.edgeNames)")
        d.features.append(Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: rim.map { EdgeRef(body: "b", edge: $0) }, size: "1.5 mm", concave: true))))
        let result = Regenerator.regenerate(d)
        #expect(result.errors.isEmpty, "\(result.errors)")
        let lost = pocketed.volume - (try #require(result.body("b"))).volume
        // Four 16 mm rim edges, each losing a quarter disc of radius 1.5 (1.77 mm²): 113, plus the ball that rounds each corner (about 2 each).
        #expect(lost > 105 && lost < 130, "\(lost)")
    }

    @Test func theFlagSurvivesSavingAndOldFilesReadAsNormal() throws {
        let top = FaceRef(body: "b", face: "b.top")
        let doc = box([Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [], faces: [top], size: "2 mm", concave: true)))])
        guard case .fillet(let back) = try CADDocument.decode(try doc.encoded()).features[1].kind else { Issue.record("expected a fillet"); return }
        #expect(back.concave)
        let plain = box([Feature(id: "f", name: "Fillet1", .fillet(EdgeFeature(edges: [], faces: [top], size: "2 mm")))])
        let text = String(decoding: try plain.encoded(), as: UTF8.self)
        #expect(!text.contains("concave"))
    }
}
