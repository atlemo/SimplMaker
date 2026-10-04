// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

/// Curves drawn point by point: smooth handles, pulled handles, and closing a shape.
@Suite struct CurveChainTests {
    /// How far the curve turns between the end of one segment and the start of the next (0 = smooth).
    private func kink(_ a: [SIMD2<Double>], _ b: [SIMD2<Double>]) -> Double {
        let d0 = Bezier.derivative(a, 1), d1 = Bezier.derivative(b, 0)
        return abs(vcross(d0, d1)) / (vlen(d0) * vlen(d1))
    }

    private func poles(_ s: Sketch, _ id: EntityID) -> [SIMD2<Double>] {
        guard let c = s.curve(id) else { return [] }
        return s.pointIDs(of: c).compactMap { s.position($0) }
    }

    @Test func twoPointsAreStraight() {
        let h = Bezier.smoothHandles(through: [SIMD2(0, 0), SIMD2(30, 0)], pulled: [nil, nil], closed: false)
        #expect(h.count == 1 && vlen(h[0].0 - SIMD2(10, 0)) < 1e-9 && vlen(h[0].1 - SIMD2(20, 0)) < 1e-9)
    }

    @Test func pointsOnACircleGiveARoundSmoothBend() {
        let p: [SIMD2<Double>] = [SIMD2(1, 0), SIMD2(0, 1), SIMD2(-1, 0)]
        let h = Bezier.smoothHandles(through: p, pulled: [nil, nil, nil], closed: false)
        #expect(h.count == 2)
        let a = [p[0], h[0].0, h[0].1, p[1]], b = [p[1], h[1].0, h[1].1, p[2]]
        #expect(kink(a, b) < 1e-9, "the two curves meet without a corner")
        #expect(abs(h[0].0.x - 1) < 1e-9 && h[0].0.y > 0, "it leaves the first point straight up, as the circle does")
        for t in stride(from: 0.0, through: 1, by: 0.1) {
            for c in [a, b] { #expect(abs(vlen(Bezier.point(c, t)) - 1) < 0.05) }
        }
    }

    @Test func aPulledHandleIsKeptAndMirrored() {
        let p: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(20, 0)]
        let h = Bezier.smoothHandles(through: p, pulled: [nil, SIMD2(0, 4), nil], closed: false)
        #expect(vlen(h[1].0 - SIMD2(10, 4)) < 1e-9, "forward")
        #expect(vlen(h[0].1 - SIMD2(10, -4)) < 1e-9, "back")
    }

    @Test func aClosedRunIsSmoothAllTheWayRound() {
        let p: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)]
        let h = Bezier.smoothHandles(through: p, pulled: [nil, nil, nil, nil], closed: true)
        #expect(h.count == 4)
        let c = (0..<4).map { [p[$0], h[$0].0, h[$0].1, p[($0 + 1) % 4]] }
        for i in 0..<4 { #expect(kink(c[i], c[(i + 1) % 4]) < 1e-9) }
    }

    @Test func buildingAChainAddsCurvesThatShareTheirAnchors() throws {
        var s = Sketch()
        var chain = CurveChain(anchors: [s.resolve(SketchSnap(SIMD2(0, 0)))])
        for p in [SIMD2(10.0, 8), SIMD2(20, -4), SIMD2(30, 6)] {
            let r = s.extendCurve(chain, to: SketchSnap(p), pulled: nil)
            #expect(r.continues)
            chain = r.chain
        }
        #expect(chain.anchors.count == 4 && chain.segments.count == 3 && s.curves.count == 3)
        #expect(s.contains(chain))
        let c = chain.segments.map { poles(s, $0.curve) }
        #expect(vlen(c[0][3] - SIMD2(10, 8)) < 1e-9 && vlen(c[1][0] - SIMD2(10, 8)) < 1e-9)
        #expect(kink(c[0], c[1]) < 1e-9 && kink(c[1], c[2]) < 1e-9, "each join is smooth once the next point is there")
        guard case .bezier(_, _, _, let end0)? = s.curve(chain.segments[0].curve)?.geometry,
              case .bezier(let start1, _, _, _)? = s.curve(chain.segments[1].curve)?.geometry else { Issue.record("expected Béziers"); return }
        #expect(end0 == start1, "one shared point, not two touching ones")
    }

    @Test func comingBackToTheFirstPointClosesIt() throws {
        var s = Sketch()
        let first = s.resolve(SketchSnap(SIMD2(0, 0)))
        var chain = CurveChain(anchors: [first])
        for p in [SIMD2(10.0, 0), SIMD2(10, 10), SIMD2(0, 10)] { chain = s.extendCurve(chain, to: SketchSnap(p), pulled: nil).chain }
        let r = s.extendCurve(chain, to: SketchSnap(SIMD2(0, 0), point: first), pulled: nil)
        #expect(!r.continues && r.chain.closed && r.chain.anchors.count == 4 && r.chain.segments.count == 4)
        let c = r.chain.segments.map { poles(s, $0.curve) }
        for i in 0..<4 { #expect(kink(c[i], c[(i + 1) % 4]) < 1e-9, "including where it closes") }
        #expect(s.points.count == 1 + 4 + 8, "origin, four anchors, eight handles: no stray point at the close")
    }

    @Test func aTwoPointRunDoesNotCloseIntoALens() {
        var s = Sketch()
        let first = s.resolve(SketchSnap(SIMD2(0, 0)))
        var chain = CurveChain(anchors: [first])
        chain = s.extendCurve(chain, to: SketchSnap(SIMD2(10, 0)), pulled: nil).chain
        let r = s.extendCurve(chain, to: SketchSnap(SIMD2(0, 0), point: first), pulled: nil)
        #expect(!r.continues && !r.chain.closed)
    }

    @Test func meetingExistingGeometryEndsTheRun() {
        var s = Sketch()
        let line = s.addLine(s.addPoint(0, 20), s.addPoint(30, 20))
        var chain = CurveChain(anchors: [s.resolve(SketchSnap(SIMD2(0, 0)))])
        chain = s.extendCurve(chain, to: SketchSnap(SIMD2(10, 5)), pulled: nil).chain
        let r = s.extendCurve(chain, to: SketchSnap(SIMD2(20, 20), curve: line), pulled: SIMD2(0, 3))
        #expect(!r.continues)
        #expect(s.constraints.contains { if case .pointOnCurve(_, let c) = $0.kind { return c == line }; return false })
    }

    @Test func undoingACurveInvalidatesTheChain() {
        var s = Sketch()
        var chain = CurveChain(anchors: [s.resolve(SketchSnap(SIMD2(0, 0)))])
        chain = s.extendCurve(chain, to: SketchSnap(SIMD2(10, 5)), pulled: nil).chain
        var undone = s
        undone.delete([chain.segments[0].curve])
        #expect(s.contains(chain) && !undone.contains(chain))
    }
}
