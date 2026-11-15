// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import CADCore

/// The offset of a spline follows the spline: it is stored as a definition and its curves are made again at every change.
@Suite struct LiveOffsetTests {
    private func spline() -> (s: Sketch, id: EntityID, c1: EntityID) {
        var s = Sketch()
        let c1 = s.addPoint(10, 0)
        let id = s.addBezier(start: s.addPoint(0, 0), control1: c1, control2: s.addPoint(20, 5), end: s.addPoint(20, 20))
        return (s, id, c1)
    }

    /// The ends of the offset's curves, to see whether they moved.
    private func footprint(_ s: Sketch, _ ids: [EntityID]) -> [SIMD2<Double>] {
        ids.flatMap { id -> [SIMD2<Double>] in
            guard case .bezier(let p)? = s.geometry(of: id) else { return [] }
            return [p[0], p[3]]
        }
    }

    private func generated(_ s: Sketch, _ def: SketchOffsetDef) -> [EntityID] {
        s.curves.map(\.id).filter { Sketch.pattern(ofGenerated: $0) == def.id }
    }

    @Test func aSplineOffsetIsAGeneratedDefinition() {
        var (s, id, _) = spline()
        let made = s.offset([id], distance: 2, expression: "2 mm")
        #expect(!made.isEmpty)
        #expect(s.offsets.count == 1 && s.offsets[0].sources == [id] && s.offsets[0].expression == "2 mm")
        #expect(made.allSatisfy(Sketch.isGenerated))
        #expect(s.dimensions.isEmpty && s.constraints.isEmpty, "nothing ties it: it is made again instead")
    }

    @Test func theSameSketchMakesTheSameIds() {
        var (s, id, _) = spline()
        let made = s.offset([id], distance: 2, expression: "2 mm")
        s.refreshGenerated(ParameterValues())
        #expect(generated(s, s.offsets[0]) == made, "so a selection survives a change that keeps the number of pieces")
    }

    @Test func movingTheSplineMovesItsOffset() {
        var (s, id, c1) = spline()
        let made = s.offset([id], distance: 2, expression: "2 mm")
        let before = footprint(s, made)
        let k = s.points.firstIndex { $0.id == c1 }!
        s.points[k].y = 8
        s.refreshGenerated(ParameterValues())
        let after = s.curves.map(\.id).filter { Sketch.pattern(ofGenerated: $0) == s.offsets[0].id }
        #expect(!after.isEmpty && after.allSatisfy(Sketch.isGenerated))
        #expect(footprint(s, after) != before, "the offset curves moved with the spline")
        // And they are still the distance away from the new spline.
        guard case .bezier(let original)? = s.geometry(of: id) else { Issue.record("no spline"); return }
        let line = Bezier.flatten(original, steps: 400)
        for q in footprint(s, after) { #expect(abs((line.map { vlen($0 - q) }.min() ?? 0) - 2) < 0.1) }
    }

    @Test func theDistanceFollowsAParameter() throws {
        var (s, id, _) = spline()
        _ = s.offset([id], distance: 2, expression: "wall")
        var p = ParameterValues()
        p.values["wall"] = Quantity(2, length: 1)
        s.refreshGenerated(p)
        let thin = footprint(s, generated(s, s.offsets[0]))
        p.values["wall"] = Quantity(5, length: 1)
        s.refreshGenerated(p)
        #expect(footprint(s, generated(s, s.offsets[0])) != thin)
    }

    @Test func aNegativeDistanceGoesTheOtherWay() {
        var (s, id, _) = spline()
        let out = s.offset([id], distance: 2, expression: "2 mm", liveExpression: "2 mm")
        var (t, id2, _) = spline()
        let back = t.offset([id2], distance: -2, expression: "2 mm", liveExpression: "-2 mm")
        #expect(t.offsets[0].expression == "-2 mm")
        #expect(footprint(s, out).first != footprint(t, back).first)
        t.refreshGenerated(ParameterValues())
        #expect(footprint(t, generated(t, t.offsets[0])).first == footprint(t, back).first, "made again the same way")
    }

    @Test func aLineJoinedToASplineIsOffsetWithIt() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        let line = s.addLine(a, b)
        let curve = s.addBezier(start: b, control1: s.addPoint(15, 0), control2: s.addPoint(20, 5), end: s.addPoint(20, 20))
        let made = s.offset([line, curve], distance: 2, expression: "2 mm")
        #expect(s.offsets.count == 1 && Set(s.offsets[0].sources) == [line, curve])
        #expect(made.allSatisfy(Sketch.isGenerated))
        #expect(s.dimensions.isEmpty, "the whole outline is made again, so the line needs no dimension")
    }

    @Test func linesAndArcsStillFollowByConstraints() {
        var s = Sketch()
        let (lines, _) = s.addRectangle(0, 0, 10, 4)
        let made = s.offset(lines, distance: 2, expression: "2 mm")
        #expect(s.offsets.isEmpty)
        #expect(!made.contains(where: Sketch.isGenerated))
        #expect(!s.dimensions.isEmpty)
    }

    @Test func deletingTheSplineTakesItsOffsetAway() {
        var (s, id, _) = spline()
        _ = s.offset([id], distance: 2, expression: "2 mm")
        s.delete([id])
        s.refreshGenerated(ParameterValues())
        #expect(s.offsets.isEmpty)
        #expect(s.curves.isEmpty && !s.points.contains { Sketch.isGenerated($0.id) })
    }

    @Test func itSurvivesSavingAndLoading() throws {
        var (s, id, _) = spline()
        _ = s.offset([id], distance: 2, expression: "2 mm")
        _ = s.takeGenerated()  // (what is saved is the definition, not the copies)
        let back = try JSONDecoder().decode(Sketch.self, from: JSONEncoder().encode(s))
        #expect(back.offsets == s.offsets)
        var again = back
        again.refreshGenerated(ParameterValues())
        #expect(!generated(again, again.offsets[0]).isEmpty)
    }
}
