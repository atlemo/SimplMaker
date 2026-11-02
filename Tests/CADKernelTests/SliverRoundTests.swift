// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// Two rounds that use up a whole face between them (1.5 mm each on a 3 mm tab) leave a hair-thin strip face behind.
/// A chamfer or round that runs across the tab's end used to fail whatever its size.
@Suite struct SliverRoundTests {
    /// A 40 × 20 plate with a 3 mm wide, 10 mm long tab, 5 mm thick, and the tab's two end corners rounded by 1.5 mm.
    private func tab() -> CADDocument {
        var s = Sketch()
        let pts = [(0.0, 0.0), (40, 0), (40, 20), (21.5, 20), (21.5, 30), (18.5, 30), (18.5, 20), (0, 20)].map { s.addPoint($0.0, $0.1) }
        var lines: [EntityID] = []
        for i in 0..<pts.count { lines.append(s.addLine(pts[i], pts[(i + 1) % pts.count], id: "L\(i + 1)")) }
        var doc = CADDocument()
        doc.features = [
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s))),
            Feature(id: "ex", name: "Extrude1", .extrude(ExtrudeFeature(sketch: "sk", profiles: [ProfileRef(curves: lines)], extent: .distance("5 mm")))),
            Feature(id: "r", name: "Fillet1", .fillet(EdgeFeature(edges: [EdgeRef(body: "ex", edge: "ex.side.L4|ex.side.L5"),
                                                                          EdgeRef(body: "ex", edge: "ex.side.L5|ex.side.L6")], size: "1.5 mm"))),
        ]
        return doc
    }

    private func chamfered(face: String, _ size: String) -> RegenResult {
        var doc = tab()
        doc.features.append(Feature(id: "c", name: "Chamfer1", .chamfer(EdgeFeature(edges: [], faces: [FaceRef(body: "ex", face: face)], size: size))))
        return Regenerator.regenerate(doc)
    }

    @Test func aChamferRunsAcrossTheTabEnd() throws {
        let before = try #require(Regenerator.regenerate(tab()).body("ex")).volume
        for face in ["ex.start", "ex.end"] {
            let r = chamfered(face: face, "0.5 mm")
            #expect(r.errors.isEmpty, "a 0.5 mm chamfer round the \(face) face: \(r.errors)")
            let after = try #require(r.body("ex")).volume
            #expect(after < before && after > before - 60, "\(face): material came off, but only a thin bevel: \(before) to \(after)")
        }
    }

    @Test func aRoundRunsAcrossTheTabEndToo() throws {
        var doc = tab()
        doc.features.append(Feature(id: "f2", name: "Fillet2", .fillet(EdgeFeature(edges: [], faces: [FaceRef(body: "ex", face: "ex.end")], size: "0.5 mm"))))
        let r = Regenerator.regenerate(doc)
        #expect(r.errors.isEmpty, "a 0.5 mm round of the end face: \(r.errors)")
    }

    @Test func aSizeThatReallyIsTooBigStillFailsAndSaysWhy() throws {
        let r = chamfered(face: "ex.end", "1.6 mm")
        let why = try #require(r.errors["c"])
        #expect(why.contains("1.5 mm"), "names the 1.5 mm corner: \(why)")
    }
}
