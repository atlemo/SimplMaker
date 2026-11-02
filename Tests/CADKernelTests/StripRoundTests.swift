// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import CADKernel

/// A fillet or chamfer that uses up a whole face: half its width on each side, as 1 mm does on a 2 mm strip.
@Suite struct StripRoundTests {
    /// A 2 mm strip following a spline (the spline and its offset, closed at the ends by two lines), 10 mm wide.
    private func strip() -> CADDocument {
        var s = Sketch()
        let p0 = s.addPoint(0, 0), p1 = s.addPoint(63, 0), p2 = s.addPoint(88, 8), p3 = s.addPoint(98, 20)
        let b1 = s.addBezier(start: p0, control1: s.addPoint(30, 0), control2: s.addPoint(45, 0), end: p1)
        let b2 = s.addBezier(start: p1, control1: s.addPoint(75, 0), control2: s.addPoint(85, 3), end: p2)
        let b3 = s.addBezier(start: p2, control1: s.addPoint(89.8, 11), control2: s.addPoint(95, 16), end: p3)
        let made = s.offset([b1, b2, b3], distance: 2, expression: "2 mm")
        var ends: [EntityID] = []
        for id in made { if case .bezier(let a, _, _, let b)? = s.curve(id)?.geometry { ends += [a, b] } }
        let l1 = s.addLine(p0, ends.first!, id: "L1"), l2 = s.addLine(p3, ends.last!)
        var doc = CADDocument()
        doc.features = [
            Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xz, sketch: s))),
            Feature(id: "ex", name: "Extrude1", .extrude(ExtrudeFeature(
                sketch: "sk", profiles: [ProfileRef(curves: [b1, b2, b3] + made + [l1, l2])], extent: .distance("10 mm")))),
        ]
        return doc
    }

    private func rounded(fillet: Bool, _ size: String) -> RegenResult {
        var doc = strip()
        let ef = EdgeFeature(edges: [], faces: [FaceRef(body: "ex", face: "ex.side.L1")], size: size)  // the strip's 2 mm end
        doc.features.append(Feature(id: "f", name: "Round", fillet ? .fillet(ef) : .chamfer(ef)))
        return Regenerator.regenerate(doc)
    }

    @Test func halfTheWidthOnEachSideWorks() throws {
        for fillet in [true, false] {
            let name = fillet ? "fillet" : "chamfer"
            let exact = rounded(fillet: fillet, "1 mm")
            #expect(exact.errors.isEmpty, "a 1 mm \(name) on a 2 mm face: \(exact.errors)")
            let near = rounded(fillet: fillet, "0.99 mm")
            let a = try #require(exact.body("ex")).volume, b = try #require(near.body("ex")).volume
            #expect(abs(a - b) < 0.5, "\(name): the same bevel, give or take the flat left between: \(a) vs \(b)")
            #expect(a < (try #require(Regenerator.regenerate(strip()).body("ex")).volume), "\(name) removed material")
        }
    }

    @Test func tooLargeStillFails() throws {
        for fillet in [true, false] {
            let r = rounded(fillet: fillet, "1.5 mm")
            #expect(r.errors["f"] != nil, "1.5 mm on a 2 mm face can't be built")
        }
    }
}
