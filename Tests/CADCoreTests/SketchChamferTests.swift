// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import simd
import Testing

/// A sketch chamfer: a straight cut across a corner where two lines meet, with its leg length as the dimension.
@Suite struct SketchChamferTests {
    @Test func aChamferCutsARectangleCornerToItsLegLength() throws {
        var s = Sketch()
        let r = s.addRectangle(0, 0, 20, 10)
        let made = s.chamferCorner(r.corners[0], distance: 2, expression: "2")
        let dim = try #require(made)
        #expect(SketchSolver.solve(&s, dimensionValues: [dim: 2]).status == .solved)
        // Five straight sides now: the four of the rectangle (shortened) and the cut.
        #expect(s.curves.filter { !$0.construction }.count == 5)
        // The cut runs from (2, 0) to (0, 2): its legs are 2 mm each.
        let ends = try #require(s.curves.last).geometry
        if case .line(let a, let b) = ends {
            let pa = try #require(s.position(a)), pb = try #require(s.position(b))
            #expect(abs(simd_length(pa - pb) - 2 * 2.0.squareRoot()) < 1e-6)
        } else {
            Issue.record("the chamfer should be a line")
        }
    }

    @Test func aChamferLongerThanTheShortLineIsRefused() throws {
        var s = Sketch()
        let r = s.addRectangle(0, 0, 20, 10)
        #expect(s.chamferCorner(r.corners[0], distance: 12, expression: "12") == nil)
    }
}
