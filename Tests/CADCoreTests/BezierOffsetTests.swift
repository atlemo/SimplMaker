// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

/// Offsetting Béziers: a run of cubics fitted to the offset, whether alone or chained to lines.
@Suite struct BezierOffsetTests {
    /// How far a point is from the nearest point on a finely sampled curve.
    private func distance(_ q: SIMD2<Double>, to curve: [SIMD2<Double>]) -> Double {
        curve.map { vlen($0 - q) }.min() ?? .infinity
    }

    private func samples(_ s: Sketch, _ ids: [EntityID]) -> [SIMD2<Double>] {
        ids.flatMap { id -> [SIMD2<Double>] in
            guard case .bezier(let p)? = s.geometry(of: id) else { return [] }
            return Bezier.flatten(p, steps: 200)
        }
    }

    /// A straight run that bends up into a curve, like the Curve tool makes: two cubics meeting smoothly.
    private func bend() -> (s: Sketch, ids: [EntityID]) {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0), c = s.addPoint(30, 0), d = s.addPoint(40, 0)
        let g1 = s.addBezier(start: a, control1: s.addPoint(4, 0), control2: s.addPoint(7, 0), end: b)
        let g2 = s.addBezier(start: b, control1: c, control2: d, end: s.addPoint(40, 0))
        let g3 = s.addBezier(start: g2Point(s, g2), control1: s.addPoint(46, 0), control2: s.addPoint(52, 6), end: s.addPoint(50, 20))
        return (s, [g1, g2, g3])
    }

    private func g2Point(_ s: Sketch, _ id: EntityID) -> EntityID {
        guard case .bezier(_, _, _, let end)? = s.curve(id)?.geometry else { return "" }
        return end
    }

    @Test func aBezierOffsetStaysTheDistanceAway() {
        var s = Sketch()
        let id = s.addBezier(start: s.addPoint(0, 0), control1: s.addPoint(10, 0), control2: s.addPoint(20, 5), end: s.addPoint(20, 20))
        let original = samples(s, [id])
        let made = s.offset([id], distance: 2, expression: "2 mm")
        #expect(!made.isEmpty)
        let offset = samples(s, made)
        for q in offset { #expect(abs(distance(q, to: original) - 2) < 0.03, "a point strayed: \(q)") }
        // The ends are exactly 2 mm to the left of where the curve starts and finishes.
        let first = offset.first!, last = offset.last!
        #expect(vlen(first - SIMD2(0, 2)) < 1e-6, "\(first)")
        let t = Bezier.tangent([SIMD2(0, 0), SIMD2(10, 0), SIMD2(20, 5), SIMD2(20, 20)], 1)!
        #expect(vlen(last - (SIMD2(20, 20) + 2 * SIMD2(-t.y, t.x))) < 1e-6, "\(last)")
    }

    @Test func theOtherSideAndBothDirectionsOfTravelAgree() {
        var s = Sketch()
        let p = [SIMD2(0.0, 0), SIMD2(10, 0), SIMD2(20, 5), SIMD2(20, 20)]
        let id = s.addBezier(start: s.addPoint(p[0].x, p[0].y), control1: s.addPoint(p[1].x, p[1].y),
                             control2: s.addPoint(p[2].x, p[2].y), end: s.addPoint(p[3].x, p[3].y))
        let original = samples(s, [id])
        let made = s.offset([id], distance: -1.5, expression: "1.5 mm")  // to the right
        for q in samples(s, made) { #expect(abs(distance(q, to: original) - 1.5) < 0.03) }
        #expect(samples(s, made).first!.y < 0, "right of a curve that heads along +x is below it")
        // Against the grain: the same curve drawn backwards, offset to the same side of the page.
        var r = Sketch()
        let rid = r.addBezier(start: r.addPoint(p[3].x, p[3].y), control1: r.addPoint(p[2].x, p[2].y),
                              control2: r.addPoint(p[1].x, p[1].y), end: r.addPoint(p[0].x, p[0].y))
        let made2 = r.offset([rid], distance: 1.5, expression: "1.5 mm")  // left of the backwards travel = below
        #expect(samples(r, made2).allSatisfy { abs(distance($0, to: original) - 1.5) < 0.03 })
        #expect(samples(r, made2).last!.y < 0)
    }

    @Test func aSmoothRunOfBeziersOffsetsAsOneConnectedRun() {
        var (s, ids) = bend()
        let original = samples(s, ids)
        let made = s.offset(ids, distance: 3, expression: "3 mm")
        #expect(made.count >= ids.count)
        for q in samples(s, made) { #expect(abs(distance(q, to: original) - 3) < 0.02, "strayed at \(q)") }
        // Connected end to end: each curve starts where the one before ends.
        var ends: [EntityID] = []
        for id in made {
            guard case .bezier(let a, _, _, let b)? = s.curve(id)?.geometry else { Issue.record("not a Bézier"); return }
            ends.append(a); ends.append(b)
        }
        let joins = Set(ends).count
        #expect(joins == made.count + 1, "\(made.count) curves should share their ends: \(joins) distinct end points")
        // The straight part stays straight, 3 mm to the left (above, for a run that heads along +x).
        #expect(samples(s, [made[0]]).allSatisfy { abs($0.y - 3) < 1e-3 })
    }

    @Test func theInsideOfATightBendIsRefused() {
        var s = Sketch()
        // A bend with a radius of curvature near 2 mm: 5 mm to the inside folds over.
        let id = s.addBezier(start: s.addPoint(0, 0), control1: s.addPoint(4, 0), control2: s.addPoint(4, 4), end: s.addPoint(0, 4))
        #expect(s.offset([id], distance: 5, expression: "5 mm").isEmpty)
        #expect(!s.offset([id], distance: -5, expression: "5 mm").isEmpty, "the outside of it is fine")
    }

    @Test func aClosedPairOfBeziersOffsetsOutward() {
        var s = Sketch()
        let a = s.addPoint(-10, 0), b = s.addPoint(10, 0)
        let top = s.addBezier(start: a, control1: s.addPoint(-10, 10), control2: s.addPoint(10, 10), end: b)
        let bottom = s.addBezier(start: b, control1: s.addPoint(10, -10), control2: s.addPoint(-10, -10), end: a)
        let original = samples(s, [top, bottom])
        let made = s.offset([top, bottom], distance: 1, expression: "1 mm")
        #expect(!made.isEmpty)
        let box = samples(s, made).map(\.y)
        let originalTop = original.map(\.y).max()!
        #expect(box.max()! > originalTop, "a positive offset of a closed shape goes outward")
        for q in samples(s, made) { #expect(abs(distance(q, to: original) - 1) < 0.02) }
    }

    @Test func aLineJoinedToABezierKeepsTheirJoint() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        let line = s.addLine(a, b)
        let curve = s.addBezier(start: b, control1: s.addPoint(16, 0), control2: s.addPoint(20, 4), end: s.addPoint(20, 12))
        let made = s.offset([line, curve], distance: 2, expression: "2 mm")
        #expect(made.count >= 2)
        guard case .line(_, let lineEnd)? = s.geometry(of: made[0]) else {
            Issue.record("the line should come first"); return
        }
        guard case .bezier(let p)? = s.geometry(of: made[1]) else { Issue.record("then the Bézier"); return }
        #expect(vlen(lineEnd - p[0]) < 1e-9, "the pieces share a joint")
        #expect(vlen(lineEnd - SIMD2(10, 2)) < 1e-3, "\(lineEnd)")
    }

    @Test func handleSitsOnTheChainAndPointsTheWayOffsetGoes() {
        var (s, ids) = bend()
        let h = s.offsetHandle(ids)!
        #expect(abs(vlen(h.direction) - 1) < 1e-9)
        #expect(distance(h.origin, to: samples(s, ids)) < 1e-6, "it stands on the curve")
        // A positive distance goes where the handle points.
        let made = s.offset(ids, distance: 2, expression: "2 mm")
        let away = h.origin + 2 * h.direction
        #expect(distance(away, to: samples(s, made)) < 0.02)
        // A circle's handle points outward from its center.
        var c = Sketch()
        let id = c.addCircle(center: c.addPoint(3, 4), radius: 5)
        let ch = c.offsetHandle([id])!
        #expect(vlen(ch.origin - SIMD2(8, 4)) < 1e-9 && vlen(ch.direction - SIMD2(1, 0)) < 1e-9)
    }

    @Test func anEllipseOffsetStaysTheDistanceAwayOnBothSides() {
        for distance in [3.0, -3.0] {
            var s = Sketch()
            let c = SketchSnap(SIMD2(0, 0)), m = SketchSnap(SIMD2(20, 0)), n = SketchSnap(SIMD2(0, 10))
            guard let ellipse = s.addEllipse(center: c, major: m, minor: n)?.curve,
                  case .ellipse(let center, let u, let v)? = s.geometry(of: ellipse) else { Issue.record("no ellipse"); return }
            var original: [SIMD2<Double>] = []
            for k in 0..<2000 {
                let t: Double = Double(k) / 2000 * 2 * Double.pi
                original.append(center + u * cos(t) + v * sin(t))
            }
            let made = s.offset([ellipse], distance: distance, expression: "3 mm")
            #expect(made.count >= 4)
            for q in samples(s, made) {
                #expect(abs(self.distance(q, to: original) - 3) < 0.1)
            }
            #expect(s.offsetHandle([ellipse]) != nil)
        }
    }
}
