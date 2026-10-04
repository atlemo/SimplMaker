// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

/// Bézier sketch curves: drawing, trimming, and constraints on them.
@Suite struct BezierTests {
    /// A curve from (0, 0) to (30, 0) bending up through (15, 10).
    func arch() -> (Sketch, curve: EntityID) {
        var s = Sketch()
        let id = s.addBezier(from: SketchSnap(SIMD2(0, 0)), to: SketchSnap(SIMD2(30, 0)), through: SIMD2(15, 10))
        return (s, id)
    }

    @Test func itBendsThroughTheThirdClick() throws {
        let (s, id) = arch()
        let g = try #require(s.geometry(of: id))
        #expect(vlen(g.point(0) - SIMD2(0, 0)) < 1e-9 && vlen(g.point(1) - SIMD2(30, 0)) < 1e-9)
        #expect(vlen(g.point(0.5) - SIMD2(15, 10)) < 1e-9)
        #expect(s.points.count == 5, "origin, two ends and two handles")
        #expect(abs(g.parameter(of: SIMD2(15, 20)) - 0.5) < 1e-6, "closest point on the curve")
    }

    @Test func pieceKeepsTheShape() {
        let p: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(5, 13), SIMD2(25, 13), SIMD2(30, 0)]
        let piece = Bezier.piece(p, from: 0.25, to: 0.75)
        for u in stride(from: 0.0, through: 1, by: 0.1) {
            #expect(vlen(Bezier.point(piece, u) - Bezier.point(p, 0.25 + 0.5 * u)) < 1e-9)
        }
    }

    @Test func aLineCrossingTheCurveTrimsIt() throws {
        var (s, id) = arch()
        s.addLine(s.addPoint(10, -5), s.addPoint(10, 20))
        let hits = intersect(try #require(s.geometry(of: id)), .line(SIMD2(10, -5), SIMD2(10, 20)))
        #expect(hits.count == 1 && abs(hits[0].x - 10) < 1e-6)
        let before = try #require(s.geometry(of: id))
        let trimmed = s.trim(id, at: SIMD2(2, 3))  // cut off the part left of the line
        #expect(trimmed)
        let after = try #require(s.geometry(of: id))
        #expect(abs(after.point(0).x - 10) < 1e-6 && vlen(after.point(1) - SIMD2(30, 0)) < 1e-9)
        let mid = after.point(0.5)
        #expect(vlen(before.point(before.parameter(of: mid)) - mid) < 1e-6, "the rest keeps its shape")
    }

    @Test func pointOnCurveAndTangentSolve() throws {
        var (s, id) = arch()
        let p = s.addPoint(15, 14)
        s.constrain(.pointOnCurve(point: p, curve: id))
        guard case .bezier(let a, _, _, _)? = s.curve(id)?.geometry else { Issue.record("expected a Bézier"); return }
        let line = s.addLine(s.addPoint(-10, 0), a)
        s.constrain(.horizontal(line))
        s.constrain(.tangent(line, id))
        #expect(s.constraints(.tangent, for: [line, id]) != nil)
        #expect(SketchSolver.solve(&s, dimensionValues: [:]).status == .solved)
        let g = try #require(s.geometry(of: id))
        let q = try #require(s.position(p))
        #expect(vlen(g.point(g.parameter(of: q)) - q) < 1e-6, "the point sits on the curve")
        guard case .bezier(let ctrl) = g else { return }
        #expect(abs(ctrl[1].y - ctrl[0].y) < 1e-6, "the curve leaves along the horizontal line")
    }

    @Test func draggingTheCurveMovesItsHandlesToo() throws {
        var (s, id) = arch()
        let dragged = s.drag(id, to: SIMD2(5, 5), grabOffset: .zero, values: [:])
        #expect(dragged)
        let g = try #require(s.geometry(of: id))
        #expect(vlen(g.point(0) - SIMD2(5, 5)) < 1e-6 && vlen(g.point(0.5) - SIMD2(20, 15)) < 1e-6)
    }
}
