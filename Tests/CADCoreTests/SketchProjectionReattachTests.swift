// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import simd
import Testing
@testable import CADCore

/// Project Again: a projection takes another edge and keeps what is tied to it.
@Suite struct SketchProjectionReattachTests {
    private func line(_ edge: String, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> ModelSnap {
        ModelSnap(edge: EdgeRef(body: "body", edge: edge), start: a, end: b)
    }

    private func circle(_ edge: String, at c: SIMD2<Double>, radius r: Double) -> ModelSnap {
        ModelSnap(edge: EdgeRef(body: "body", edge: edge), start: c + SIMD2(r, 0), end: c + SIMD2(r, 0), center: c, isFullCircle: true)
    }

    private func curve(_ edge: String, pieces: Int, at x: Double = 0) -> ModelSnap {
        var chain: [SIMD2<Double>] = []
        for i in 0..<pieces {
            let a = Double(i) * 10 + x
            chain += [SIMD2(a, 0), SIMD2(a + 3, 4), SIMD2(a + 7, 4)]
        }
        chain.append(SIMD2(Double(pieces) * 10 + x, 0))
        return ModelSnap(edge: EdgeRef(body: "body", edge: edge), start: chain[0], end: chain[chain.count - 1], chain: chain)
    }

    @Test func aStraightProjectionMovesToTheNewEdgeAndKeepsWhatIsTiedToIt() throws {
        var s = Sketch()
        let p = s.project(line("old", SIMD2(0, 0), SIMD2(10, 0)))
        // A point held on the projected line, as a corner of something drawn against it.
        let corner = s.addPoint(4, 0)
        s.constrain(.pointOnCurve(point: corner, curve: p.line))
        let made = try s.reattachProjection(p.id, to: line("new", SIMD2(0, 5), SIMD2(20, 5)))
        #expect(made.id == p.id && made.edge.edge == "new")
        #expect(s.projections.count == 1 && s.projections[0].edge.edge == "new")
        #expect(s.point(p.start)?.x == 0 && s.point(p.start)?.y == 5)
        #expect(s.point(p.end)?.x == 20 && s.point(p.end)?.y == 5)
        #expect(s.point(p.start)?.fixed == true && s.point(p.end)?.fixed == true)
        // The same ids: the line and the constraint on it are still there.
        #expect(s.curve(p.line) != nil)
        #expect(s.constraints.contains { if case .pointOnCurve(let q, let c) = $0.kind { return q == corner && c == p.line } else { return false } })
    }

    @Test func aStraightProjectionRefusesARoundEdge() throws {
        var s = Sketch()
        let p = s.project(line("old", SIMD2(0, 0), SIMD2(10, 0)))
        let before = s
        #expect(throws: ProjectionMismatch.self) { try s.reattachProjection(p.id, to: circle("c", at: .zero, radius: 5)) }
        #expect(s == before, "a refused edge changes nothing")
        do { try s.reattachProjection(p.id, to: curve("w", pieces: 2)); Issue.record("should refuse") } catch {
            #expect("\(error)".contains("a curved edge") && "\(error)".contains("a straight edge"), "\(error)")
        }
    }

    @Test func aCircleTakesAnotherCircleAndRefusesAnArc() throws {
        var s = Sketch()
        let p = s.project(circle("old", at: .zero, radius: 5))
        let arc = ModelSnap(edge: EdgeRef(body: "body", edge: "arc"), start: SIMD2(10, 0), end: SIMD2(0, 10), center: .zero)
        #expect(throws: ProjectionMismatch.self) { try s.reattachProjection(p.id, to: arc) }
        try s.reattachProjection(p.id, to: circle("new", at: SIMD2(30, 30), radius: 8))
        let centre = try #require(p.center.flatMap { s.point($0) })
        #expect(centre.x == 30 && centre.y == 30)
        guard case .circle(_, let r) = try #require(s.curve(p.line)).geometry else { Issue.record("expected a circle"); return }
        #expect(abs(r - 8) < 1e-9)
    }

    @Test func anArcTakesAnotherArc() throws {
        var s = Sketch()
        let first = ModelSnap(edge: EdgeRef(body: "body", edge: "a"), start: SIMD2(10, 0), end: SIMD2(0, 10), center: .zero)
        let p = s.project(first)
        #expect(p.kind == .arc)
        let second = ModelSnap(edge: EdgeRef(body: "body", edge: "b"), start: SIMD2(30, 20), end: SIMD2(20, 30), center: SIMD2(20, 20))
        try s.reattachProjection(p.id, to: second)
        #expect(s.point(p.start)?.x == 30 && s.point(p.end)?.y == 30 && s.point(p.center!)?.x == 20)
    }

    @Test func aCurveTakesAnotherCurveEvenOfADifferentLength() throws {
        var s = Sketch()
        let p = s.project(curve("old", pieces: 2))
        #expect(p.kind == .curve)
        // Same number of pieces: the points go where the new chain's are.
        try s.reattachProjection(p.id, to: curve("same", pieces: 2, at: 100))
        let ids = try #require(s.projections[0].chainPoints)
        #expect(s.point(ids[0])?.x == 100)
        // A different number: the edge changes, and the next rebuild samples it into as many pieces as the projection has.
        try s.reattachProjection(p.id, to: curve("other", pieces: 5))
        #expect(s.projections[0].edge.edge == "other" && s.projections[0].chainPoints?.count == ids.count)
    }

    @Test func anEdgeProjectedAlreadyIsRefused() throws {
        var s = Sketch()
        let a = s.project(line("a", SIMD2(0, 0), SIMD2(10, 0)))
        s.project(line("b", SIMD2(0, 5), SIMD2(10, 5)))
        #expect(throws: ProjectionMismatch.self) { try s.reattachProjection(a.id, to: line("b", SIMD2(0, 5), SIMD2(10, 5))) }
        // Its own edge again is fine: it is just refreshed.
        try s.reattachProjection(a.id, to: line("a", SIMD2(0, 1), SIMD2(10, 1)))
        #expect(s.point(a.start)?.y == 1)
    }

    @Test func anEdgePointingAtTheSketchHasNoLengthToTake() throws {
        var s = Sketch()
        let p = s.project(line("a", SIMD2(0, 0), SIMD2(10, 0)))
        #expect(throws: ProjectionMismatch.self) { try s.reattachProjection(p.id, to: line("dot", SIMD2(3, 3), SIMD2(3, 3))) }
    }

    @Test func aMissingProjectionIsRefused() {
        var s = Sketch()
        #expect(throws: ProjectionMismatch.self) { try s.reattachProjection("nope", to: line("a", .zero, SIMD2(1, 0))) }
    }

    @Test func theProjectionOwningAPointOrCurveIsFound() {
        var s = Sketch()
        let p = s.project(line("a", SIMD2(0, 0), SIMD2(10, 0)))
        #expect(s.projection(owning: p.start)?.id == p.id && s.projection(owning: p.line)?.id == p.id)
        #expect(s.projection(owning: "origin") == nil)
    }
}
