// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import simd
import Testing

/// A rounded rectangle (four equal corner arcs) and a tangent arc (carrying on from a line or arc) in a sketch.
@Suite struct SketchCornerAndArcTests {
    @Test func aRoundedRectangleHasFourEqualCornersThatSolve() {
        var s = Sketch()
        let made = s.addRoundedRectangle(from: SketchSnap(SIMD2(0, 0)), to: SketchSnap(SIMD2(20, 10)), radius: 2, expression: "2")
        #expect(made?.arcs.count == 4 && made?.lines.count == 4)
        // One radius dimension, on the first arc; the others are equal to it.
        let radius = s.dimensions.first { if case .radius = $0.kind { return true } else { return false } }
        #expect(s.dimensions.filter { if case .radius = $0.kind { return true } else { return false } }.count == 1)
        #expect(SketchSolver.solve(&s, dimensionValues: [radius?.id ?? "": 2]).status == .solved)
        for arc in made?.arcs ?? [] {
            #expect(abs((s.curve(arc).flatMap { s.radius(of: $0) } ?? 0) - 2) < 1e-6)
        }
    }

    @Test func aRoundedRectangleRefusesARadiusOverHalfTheShorterSide() {
        var s = Sketch()
        #expect(s.addRoundedRectangle(from: SketchSnap(SIMD2(0, 0)), to: SketchSnap(SIMD2(20, 10)), radius: 6, expression: "6") == nil)
        #expect(s.curves.isEmpty)
    }

    @Test func aTangentArcCarriesOnFromALine() throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        _ = s.addLine(a, b)
        let free = try #require(s.freeEnd(at: b))
        #expect(abs(free.direction.x - 1) < 1e-9 && abs(free.direction.y) < 1e-9, "the line heads on past its end")
        let made = s.addTangentArc(from: SketchSnap(SIMD2(10, 0), point: b), to: SketchSnap(SIMD2(20, 10)))
        let arc = try #require(made?.arc)
        let center = try #require(arcCenter(s, arc).flatMap { s.position($0) })
        #expect(abs(center.x - 10) < 1e-6, "the center is straight up from the joint, so the arc is tangent to the line")
        #expect(SketchSolver.solve(&s, dimensionValues: [:]).status == .solved)
    }

    @Test func aTangentArcRefusesAPointBehindTheEnd() throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        _ = s.addLine(a, b)
        #expect(s.addTangentArc(from: SketchSnap(SIMD2(10, 0), point: b), to: SketchSnap(SIMD2(5, 0))) == nil)
        #expect(s.curves.count == 1)
    }

    @Test func aTangentArcNeedsAFreeEnd() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0), c = s.addPoint(10, 10)
        _ = s.addLine(a, b)
        _ = s.addLine(b, c)  // b is now a joint of two lines, not a free end
        #expect(s.freeEnd(at: b) == nil)
        #expect(s.freeEnd(at: a) != nil)
    }

    private func arcCenter(_ s: Sketch, _ arc: EntityID) -> EntityID? {
        guard let c = s.curve(arc), case .arc(let center, _, _) = c.geometry else { return nil }
        return center
    }
}

/// An ellipse in a sketch: its axes stay square, and a point placed on it stays on it through a solve.
@Suite struct SketchEllipseTests {
    @Test func aPointOnTheEllipseStaysOnItWhenItsAxesMove() throws {
        var s = Sketch()
        let made = s.addEllipse(center: SketchSnap(SIMD2(0, 0)), major: SketchSnap(SIMD2(10, 0)), minor: SketchSnap(SIMD2(0, 5)))
        let ellipse = try #require(made?.curve)
        // A point on the ellipse (x = 10·cos 45°, y = 5·sin 45°), dragged off it, then solved back on.
        let p = s.addPoint(7.5, 3.0)
        s.constrain(.pointOnCurve(point: p, curve: ellipse))
        #expect(SketchSolver.solve(&s, dimensionValues: [:]).status == .solved)
        let pos = try #require(s.position(p))
        let g = try #require(s.geometry(of: ellipse))
        let t = g.parameter(of: pos)
        #expect(simd_length(g.point(t) - pos) < 1e-6, "the point is on the ellipse")
    }

    @Test func theAxesAreSquareAndTheMajorDimensionIsTheMajorAxis() throws {
        var s = Sketch()
        let made = s.addEllipse(center: SketchSnap(SIMD2(0, 0)), major: SketchSnap(SIMD2(10, 0)), minor: SketchSnap(SIMD2(0, 5)))
        let dim = try #require(made?.majorDimension)
        #expect(s.dimensions.first { $0.id == dim }?.expression.hasPrefix("10") == true)
        #expect(SketchSolver.solve(&s, dimensionValues: [dim: 12]).status == .solved)
        let ellipse = try #require(made?.curve)
        // The center is free to move, so the major axis is measured from it, not from the origin.
        let g = try #require(s.geometry(of: ellipse))
        guard case .ellipse(let c, let u, _) = g else { Issue.record("not an ellipse"); return }
        #expect(abs(simd_length(u) - 12) < 1e-6, "the major axis is 12 mm long, measured from the center \(c)")
    }
}
