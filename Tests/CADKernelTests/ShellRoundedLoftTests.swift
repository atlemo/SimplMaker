// A shell of a lofted body whose corner rounds die away to a point at the round end.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import simd
import Testing
@testable import CADKernel

/// A circle (radius 25) on the floor lofted to a 75 mm square 50 mm up, with the four corner creases rounded. The
/// creases run out tangent at the circle, so each round ends in a point there (a degenerate edge), and OCCT's plain
/// offset refuses to shell such a body at any wall thickness (found on a part where Shell said "could not be made").
@Suite struct ShellRoundedLoftTests {
    typealias T = NewFeatureTests

    static func features(round: String? = "15 mm", wall: String? = "2 mm") -> [Feature] {
        var f: [Feature] = [
            T.sketch("ci") { s in
                let c = s.addPoint(0, 0)
                s.constrain(.fix(c, x: 0, y: 0))
                s.addCircle(center: c, radius: 25, id: "K")
            },
            Feature(id: "up", name: "up", .plane(PlaneFeature(base: .xy, offset: "50 mm"))),
            T.sketch("sq", on: .plane("up")) { T.rect(&$0, -37.5, -37.5, 37.5, 37.5, ids: ["A", "B", "C", "D"]) },
            Feature(id: "lf", name: "lf", .loft(LoftFeature(sections: [
                LoftSection(sketch: "sq", profile: ProfileRef(curves: ["A", "B", "C", "D"])),
                LoftSection(sketch: "ci", profile: ProfileRef(curves: ["K"])),
            ]))),
        ]
        if let round {
            // The circle's seam splits one side in two, so the four corners are these.
            let corners = ["lf.side.A|lf.side.D", "lf.side.C|lf.side.D", "lf.face|lf.side.A", "lf.face#2|lf.side.C"]
            f.append(Feature(id: "fl", name: "Fillet1", .fillet(EdgeFeature(edges: corners.map { EdgeRef(body: "lf", edge: $0) }, size: round))))
        }
        if let wall {
            f.append(Feature(id: "sh", name: "Shell1", .shell(ShellFeature(body: "lf", faces: [FaceRef(body: "lf", face: "lf.start")], thickness: wall))))
        }
        return f
    }

    @Test func aRoundedLoftShellsAndTheWallHoldsEverywhere() throws {
        var d = CADDocument()
        d.features = Self.features()
        let r = Regenerator.regenerate(d)
        #expect(r.errors.isEmpty, "\(r.errors)")
        let body = try #require(r.body("lf"))
        #expect(body.isValid)
        d.features = Self.features(wall: nil)
        let solid = try #require(Regenerator.regenerate(d).body("lf"))
        // Hollow, and walls of about 2 mm: 2 mm times the outside (sides and floor) is the most there can be.
        let outside = try solid.faceNames.filter { $0 != "lf.start" }.reduce(0.0) { $0 + (try solid.measure(.face($1)).size) }
        #expect(body.volume > 0.5 * 2 * outside && body.volume < 1.1 * 2 * outside, "\(body.volume) against \(2 * outside)")
        try Self.expectWall(body, 2)
    }

    /// Every outer face has an inside face one wall away and no closer, and the other way round: a body that shells
    /// without a breach and without a thin spot (BRepCheck passes a body whose wall a round has cut through).
    static func expectWall(_ body: KBody, _ wall: Double, _ label: String = "") throws {
        let inner = body.faceNames.filter { $0.contains(".shell.") }
        // The rim (what is left of the opened face) touches the inside by construction.
        let outer = body.faceNames.filter { !$0.contains(".shell.") && $0 != "lf.start" }
        #expect(!inner.isEmpty && !outer.isEmpty, "\(label) \(body.faceNames)")
        func gap(_ a: String, _ others: [String]) -> Double {
            others.compactMap { try? body.distance(.face(a), to: body, .face($0)).distance }.min() ?? -1
        }
        for a in outer {
            let g = gap(a, inner)
            #expect(abs(g - wall) < 0.03 * wall, "\(label) outer \(a) is \(g) from the inside, not \(wall)")
        }
        for a in inner {
            let g = gap(a, outer)
            #expect(abs(g - wall) < 0.03 * wall, "\(label) inner \(a) is \(g) from the outside, not \(wall)")
        }
    }

    @Test func thinnerAndThickerWallsShellToo() throws {
        for (wall, mm) in [("0.8 mm", 0.8), ("3 mm", 3.0)] {
            var d = CADDocument()
            d.features = Self.features(wall: wall)
            let r = Regenerator.regenerate(d)
            #expect(r.errors.isEmpty, "\(wall): \(r.errors)")
            let body = try #require(r.body("lf"))
            #expect(body.isValid, "\(wall)")
            try Self.expectWall(body, mm, wall)
        }
    }

    @Test func aWallThatCannotFitStillSaysSo() {
        var d = CADDocument()
        d.features = Self.features(wall: "30 mm")
        let r = Regenerator.regenerate(d)
        #expect(r.errors["sh"] != nil)
    }
}
