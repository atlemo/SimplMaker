// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import simd
import Testing

/// Clean Up Projections and Clean Up Stale Projections: the projected edges nothing uses, or whose edge is gone.
@Suite struct SketchProjectionCleanupTests {
    private func snap(_ edge: String, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> ModelSnap {
        ModelSnap(edge: EdgeRef(body: "body", edge: edge), start: a, end: b)
    }

    @Test func anUnusedProjectionIsCleanedUpWithItsGeometry() {
        var s = Sketch()
        s.project(snap("e1", SIMD2(0, 0), SIMD2(10, 0)))
        s.project(snap("e2", SIMD2(0, 5), SIMD2(10, 5)))
        #expect(s.unusedProjections().count == 2)
        let n = s.cleanUpProjections()
        #expect(n == 2)
        #expect(s.projections.isEmpty && s.curves.isEmpty && s.points.filter { $0.id != "origin" }.isEmpty)
    }

    @Test func aProjectionADrawnLineEndsOnStays() {
        var s = Sketch()
        let p = s.project(snap("e1", SIMD2(0, 0), SIMD2(10, 0)))
        s.project(snap("e2", SIMD2(0, 5), SIMD2(10, 5)))
        _ = s.addLine(from: SketchSnap(SIMD2(0, 0), point: p.start), to: SketchSnap(SIMD2(0, 8)))
        #expect(s.unusedProjections().map(\.edge.edge) == ["e2"], "the one a line starts from is in use")
        let n = s.cleanUpProjections()
        #expect(n == 1)
        #expect(s.projections.map(\.edge.edge) == ["e1"])
        #expect(s.curves.contains { !$0.construction }, "the drawn line is untouched")
    }

    @Test func aDimensionOnAProjectionKeepsIt() {
        var s = Sketch()
        let p = s.project(snap("e1", SIMD2(0, 0), SIMD2(10, 0)))
        s.dimension(.length(p.line), "10", id: "d")
        #expect(s.unusedProjections().isEmpty)
        let n = s.cleanUpProjections()
        #expect(n == 0)
    }

    @Test func aCircularProjectionsOwnPinDoesNotCountAsUse() {
        var s = Sketch()
        s.project(ModelSnap(edge: EdgeRef(body: "body", edge: "c"), start: SIMD2(5, 0), end: SIMD2(5, 0), center: .zero, isFullCircle: true))
        #expect(s.unusedProjections().count == 1, "the circle's point lies on its own circle by a constraint inside the projection")
        let n = s.cleanUpProjections()
        #expect(n == 1)
        #expect(s.curves.isEmpty && s.constraints.isEmpty)
    }

    @Test func removingAProjectionTakesWhatIsTiedToItToo() {
        var s = Sketch()
        let p = s.project(snap("e1", SIMD2(0, 0), SIMD2(10, 0)))
        let l = s.addLine(from: SketchSnap(SIMD2(0, 0), point: p.start), to: SketchSnap(SIMD2(0, 8)))
        let n = s.removeProjections([p.id])
        #expect(n == 1)
        #expect(s.projections.isEmpty)
        #expect(s.curve(l.line) == nil, "a line that started on the removed point goes with it, as with any delete")
    }

    @Test func removingAnUnknownProjectionDoesNothing() {
        var s = Sketch()
        let one = s.removeProjection("nope"), many = s.removeProjections(["nope"])
        #expect(!one && many == 0)
    }
}
