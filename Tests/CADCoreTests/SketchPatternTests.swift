// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

/// Linked copies of sketch geometry in a grid and around a point.
@Suite struct SketchPatternTests {
    private let none = ParameterValues()

    /// A dimensioned 10 × 4 rectangle with a corner at (20, 20), and a separate circle of radius 2.
    private func sample() -> (Sketch, corners: [EntityID], lines: [EntityID], circle: EntityID) {
        var s = Sketch()
        let (lines, corners) = s.addRectangle(20, 20, 30, 24)
        s.dimension(.length(lines[0]), "10 mm", id: "w")
        s.constrain(.fix(corners[0], x: 20, y: 20))
        let circle = s.addCircle(center: s.addPoint(0, 50), radius: 2)
        return (s, corners, lines, circle)
    }

    private func generated(_ s: Sketch) -> (points: [SketchPoint], curves: [SketchCurve]) {
        (s.points.filter { Sketch.isGenerated($0.id) }, s.curves.filter { Sketch.isGenerated($0.id) })
    }

    @Test func gridMakesCountMinusOneCopiesPerCellWithStableIds() throws {
        var (s, corners, lines, _) = sample()
        s.patterns = [SketchPatternDef(id: "p", sources: lines, countX: "3", spacingX: "15 mm", countY: "2", spacingY: "-8 mm")]
        #expect(s.refreshPatterns(none).isEmpty)
        let g = generated(s)
        #expect(g.curves.count == 5 * 4 && g.points.count == 5 * 4)
        #expect(g.points.allSatisfy { $0.fixed }, "copies are not the solver's to move")
        #expect(s.point(corners[0])!.position == SIMD2(20, 20), "the original stays")
        #expect(s.points.contains { vlen($0.position - SIMD2(50, 12)) < 1e-9 }, "column 3, row 2: 30 right and 8 down")
        #expect(s.point("p~1~\(corners[0])")?.position == SIMD2(35, 20), "the first copy is a column along")
        let ids = Set(s.points.map(\.id)), again = s.refreshPatterns(none)
        #expect(again.isEmpty && Set(s.points.map(\.id)) == ids, "the same copies have the same ids")
    }

    @Test func copiesFollowTheOriginalsAndTheParameters() throws {
        var (s, corners, lines, _) = sample()
        s.patterns = [SketchPatternDef(id: "p", sources: lines, countX: "n", spacingX: "gap", countY: "1")]
        var params = ParameterValues()
        params = ParameterEvaluator.evaluate([Parameter("n", "2", unit: .none), Parameter("gap", "15 mm")])
        s.refreshPatterns(params)
        #expect(s.curves.filter { Sketch.isGenerated($0.id) }.count == 4)
        let k = s.points.firstIndex { $0.id == corners[2] }!
        s.points[k].x += 3  // the original's corner moves
        s.refreshPatterns(params)
        #expect(s.point("p~1~\(corners[2])")!.position.x == 30 + 3 + 15, "the copy moved with it")
        params = ParameterEvaluator.evaluate([Parameter("n", "3", unit: .none), Parameter("gap", "12 mm")])
        s.refreshPatterns(params)
        #expect(generated(s).curves.count == 8)
        #expect(s.point("p~2~\(corners[0])")!.position.x == 20 + 24)
    }

    @Test func circleSpreadsAllTheWayRoundOrToTheEndOfTheAngle() throws {
        var s = Sketch()
        let p = s.addPoint(10, 0), q = s.addPoint(12, 0)
        let line = s.addLine(p, q)
        s.patterns = [SketchPatternDef(id: "c", kind: .circular, sources: [line], count: "4", angle: "360 deg")]
        s.refreshPatterns(none)
        let ends = generated(s).points.map(\.position)
        #expect(ends.count == 6)
        #expect(ends.contains { vlen($0 - SIMD2(0, 10)) < 1e-9 } && ends.contains { vlen($0 - SIMD2(-10, 0)) < 1e-9 } && ends.contains { vlen($0 - SIMD2(0, -10)) < 1e-9 })

        s.patterns[0].count = "3"
        s.patterns[0].angle = "90 deg"
        s.refreshPatterns(none)
        #expect(generated(s).points.contains { vlen($0.position - SIMD2(0, 10)) < 1e-9 }, "the last copy lands at the end of the angle")

        let pivot = s.addPoint(0, 10)
        s.patterns[0].center = pivot
        s.refreshPatterns(none)
        #expect(generated(s).points.contains { vlen($0.position - SIMD2(10, 20)) < 1e-9 }, "going round another point")
    }

    @Test func textsAndCirclesAreCopiedAndTurned() throws {
        var s = Sketch()
        let anchor = s.addPoint(5, 0)
        s.texts.append(SketchText(id: "t", text: "A", position: anchor))
        let circle = s.addCircle(center: s.addPoint(0, 5), radius: 2)
        s.patterns = [SketchPatternDef(id: "c", kind: .circular, sources: s.patternSources([]), count: "2", angle: "90 deg")]
        s.refreshPatterns(none)
        let copy = try #require(s.texts.first { $0.id == "c~1~t" })
        #expect(abs(copy.angle - .pi / 2) < 1e-12 && vlen(s.point(copy.position)!.position - SIMD2(0, 5)) < 1e-9)
        #expect(s.curve("c~1~\(circle)") != nil)
    }

    @Test func badCountsMakeNoCopiesAndSayWhy() {
        var (s, _, lines, _) = sample()
        s.patterns = [SketchPatternDef(id: "p", sources: lines, countX: "2.5")]
        let problems = s.refreshPatterns(none)
        #expect(problems["p"] != nil && generated(s).curves.isEmpty)
        s.patterns[0].countX = "30"; s.patterns[0].countY = "30"
        #expect(s.refreshPatterns(none)["p"]?.contains("400") == true)
        s.patterns[0].countX = "1"; s.patterns[0].countY = "1"
        #expect(s.refreshPatterns(none).isEmpty && generated(s).curves.isEmpty, "a count of 1 is just the original")
    }

    @Test func copiesDontTakePartInSolvingOrFreedom() {
        var (s, _, lines, _) = sample()
        let before = SketchSolver.solve(&s, dimensionValues: s.dimensionValues(none))
        s.patterns = [SketchPatternDef(id: "p", sources: lines + s.patternSources([]).filter { s.curve($0).map { if case .circle = $0.geometry { return true } else { return false } } ?? false })]
        s.refreshPatterns(none)
        let count = s.points.count
        let after = SketchSolver.solve(&s, dimensionValues: s.dimensionValues(none))
        #expect(after.status == .solved && after.degreesOfFreedom == before.degreesOfFreedom)
        let local = SketchSolver.solveLocally(&s, dimensionValues: s.dimensionValues(none))
        #expect(local.status == .solved && s.points.count == count, "the copies are still there")
    }

    @Test func deletingTheOriginalsRemovesThePatternAndSavingKeepsIt() throws {
        var (s, _, lines, circle) = sample()
        s.patterns = [SketchPatternDef(id: "p", sources: lines + [circle])]
        s.refreshPatterns(none)
        let data = try JSONEncoder().encode(s)
        var back = try JSONDecoder().decode(Sketch.self, from: data)
        #expect(back == s && back.patterns.count == 1)
        back.delete(Set(lines))
        #expect(back.patterns[0].sources == [circle], "a pattern keeps what is left")
        back.delete([circle])
        back.refreshPatterns(none)
        #expect(back.patterns.isEmpty && generated(back).curves.isEmpty)
    }

    @Test func wholeSketchSkipsProjectedEdgesAndOtherCopies() throws {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 0)
        s.addLine(s.addPoint(1, 1), s.addPoint(2, 2))
        let line = s.addLine(a, b, construction: true)
        s.projections.append(SketchProjection(edge: EdgeRef(body: "b", edge: "e"), start: a, end: b, line: line))
        #expect(s.patternSources([]).count == 1)
        s.patterns = [SketchPatternDef(id: "p", sources: s.patternSources([]), countX: "2", countY: "1")]
        s.refreshPatterns(none)
        #expect(generated(s).curves.count == 1)
        #expect(s.patternSources([]).count == 1, "the copy is not a source")
    }

    @Test func pickingACirclesCentreDotCopiesTheCircle() {
        var s = Sketch()
        let centre = s.addPoint(10, 10)
        let circle = s.addCircle(center: centre, radius: 5)
        let corner = s.addPoint(40, 40)
        #expect(s.patternSources([centre]) == [circle], "the dot stands for the shape it centres")
        #expect(s.patternSources([corner]) == [corner], "a loose point is copied as a point")
        s.patterns = [SketchPatternDef(id: "p", sources: s.patternSources([centre]), countX: "3", countY: "1")]
        s.refreshPatterns(none)
        #expect(generated(s).curves.count == 2, "two circles, not just their dots")
    }
}
