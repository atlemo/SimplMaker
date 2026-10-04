// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import CADCore

/// The distance from a circle's rim to another item ("a hole 4 mm from the edge").
@Suite struct GapDimensionTests {
    /// A fixed 20 × 10 rectangle (lines B, R, T, L) and a circle "C" of radius 2 centered at (8, 5).
    private func sketch() -> (sketch: Sketch, center: EntityID) {
        var s = Sketch()
        let r = s.addRectangle(0, 0, 20, 10, lineIDs: ["B", "R", "T", "L"])
        for p in r.corners { s.constrain(.fix(p, x: s.position(p)!.x, y: s.position(p)!.y)) }
        let c = s.addPoint(8, 5)
        s.addCircle(center: c, radius: 2, id: "C")
        return (s, c)
    }

    @Test func circleToEdgeMeasuresFromTheRim() {
        let (s, _) = sketch()
        #expect(s.suggestDistance(for: ["C", "L"])?.kind == .gap("C", "L"))
        #expect(abs(s.suggestDistance(for: ["L", "C"])!.value - 6) < 1e-9, "order doesn't matter: 8 - 2")
        #expect(abs(s.suggestDistance(for: ["C", "R"])!.value - 10) < 1e-9, "20 - 8 - 2")
    }

    @Test func settingTheGapMovesTheCircleAndKeepsItsSide() {
        var (s, c) = sketch()
        let applied = s.applyDimension(.gap("C", "L"), expression: "4 mm", value: 4, values: ["g": 4], id: "g")
        #expect(applied)
        #expect(abs(s.position(c)!.x - 6) < 1e-6, "rim 4 mm from the left edge: center at 4 + 2")
        // Typing a bigger gap moves it right, not through the edge.
        var v: [EntityID: Double] = ["g": 7]
        #expect(SketchSolver.solve(&s, dimensionValues: v).status == .solved)
        #expect(abs(s.position(c)!.x - 9) < 1e-6)
        v["g"] = 0
        #expect(SketchSolver.solve(&s, dimensionValues: v).status == .solved)
        #expect(abs(s.position(c)!.x - 2) < 1e-6, "touching the edge")
    }

    @Test func gapFollowsTheRadius() {
        var (s, c) = sketch()
        s.dimension(.gap("C", "L"), "4 mm", id: "g")
        s.dimension(.radius("C"), "3 mm", id: "r")
        #expect(SketchSolver.solve(&s, dimensionValues: ["g": 4, "r": 3]).status == .solved)
        #expect(abs(s.position(c)!.x - 7) < 1e-6, "the edge-to-rim gap holds when the circle grows")
    }

    @Test func circleToPointAndToCircle() {
        var (s, c) = sketch()
        let p = s.addPoint(30, 5)
        #expect(abs(s.suggestDistance(for: [p, "C"])!.value - 20) < 1e-9, "22 from the center, minus the radius")
        // The circle's own center has no gap to it.
        #expect(s.suggestDistance(for: ["C", c]) == nil)
        let other = s.addPoint(15, 5)
        s.addCircle(center: other, radius: 1, id: "D")
        #expect(abs(s.suggestDistance(for: ["C", "D"])!.value - 4) < 1e-9, "7 between centers, minus 2 and 1")
        // One inside the other: the room between them on that side.
        let mid = s.addPoint(8, 5)
        s.addCircle(center: mid, radius: 6, id: "E")
        #expect(abs(s.suggestDistance(for: ["C", "E"])!.value - 4) < 1e-9, "6 - 2 - 0")
        #expect(SketchSolver.solve(&s, dimensionValues: [:]).status == .solved)
    }

    @Test func otherPairsKeepTheirUsualDistances() {
        var (s, _) = sketch()
        #expect(s.suggestDistance(for: ["B", "T"])?.kind == .pointLineDistance(point: s.lineEndPoint("T"), line: "B"))
        #expect(s.suggestDistance(for: ["B", "R"]) == nil, "lines that aren't parallel have an angle, not a distance")
        #expect(s.suggestDistance(for: ["B", "B"]) == nil)
        let p = s.addPoint(5, 20)
        #expect(abs(s.suggestDistance(for: [p, "T"])!.value - 10) < 1e-9)
        s.addBezier(start: p, control1: p, control2: p, end: p, id: "S")
        #expect(s.suggestDistance(for: ["C", "S"]) == nil, "a spline has no single distance")
    }

    @Test func gapSurvivesSaving() throws {
        var (s, _) = sketch()
        s.dimension(.gap("C", "L"), "4 mm", id: "g")
        let back = try JSONDecoder().decode(Sketch.self, from: JSONEncoder().encode(s))
        #expect(back.dimensions.last?.kind == .gap("C", "L"))
        #expect(back.gapEnds("C", "L") != nil)
    }
}

@Suite struct DimensionLineTests {
    @Test func linesStandOffByTheirOffsetAndKeepTheirLength() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(10, 5)
        s.addLine(a, b, id: "diag")
        let aligned = SketchDimension(.distance(a, b), "11.18 mm", offset: 2)
        let l = s.dimensionLine(of: aligned)!
        #expect(abs(vlen(l.q2 - l.q1) - vlen(l.p2 - l.p1)) < 1e-12 && abs(vlen(l.q1 - l.p1) - 2) < 1e-12)
        #expect(abs(vdot(l.q2 - l.q1, l.q1 - l.p1)) < 1e-12, "square to the measured line")
        let across = s.dimensionLine(of: SketchDimension(.horizontalDistance(a, b), "10 mm", offset: 3))!
        #expect(across.q1 == SIMD2(0, 3) && across.q2 == SIMD2(10, 3), "level, 3 above the first point")
        #expect(abs(across.value(through: SIMD2(4, 7)) - 7) < 1e-12)
        let up = s.dimensionLine(of: SketchDimension(.verticalDistance(a, b), "5 mm", offset: -1))!
        #expect(up.q1 == SIMD2(-1, 0) && up.q2 == SIMD2(-1, 5))
        #expect(s.dimensionLine(of: SketchDimension(.length("diag"), "5 mm")) == nil, "sizes aren't drawn this way")
    }

    @Test func pointToLineIsDrawnAcrossAndTheOffsetSurvivesSaving() throws {
        var s = Sketch()
        let a = s.addPoint(0, 10), b = s.addPoint(20, 10), p = s.addPoint(8, 4)
        s.addLine(a, b, id: "top")
        let d = SketchDimension(.pointLineDistance(point: p, line: "top"), "6 mm", offset: 5)
        let l = s.dimensionLine(of: d)!
        #expect(l.q1 == SIMD2(13, 4) && l.q2 == SIMD2(13, 10), "straight up to the line, 5 along it from the point")
        s.dimensions = [d]
        let back = try JSONDecoder().decode(Sketch.self, from: JSONEncoder().encode(s))
        #expect(back.dimensions.first?.offset == 5)
        // Older files have no offset.
        let old = try JSONDecoder().decode(SketchDimension.self, from: Data(#"{"id":"x","kind":{"length":{"_0":"a"}},"expression":"5 mm"}"#.utf8))
        #expect(old.offset == nil)
    }

    @Test func aDiameterIsALineThroughTheCenterThatTurnsWhenMoved() {
        var s = Sketch()
        let c = s.addPoint(5, 5)
        s.addCircle(center: c, radius: 6.5, id: "C")
        let d = SketchDimension(.diameter("C"), "13 mm")
        let l = s.dimensionLine(of: d)!
        #expect(abs(vlen(l.q2 - l.q1) - 13) < 1e-12 && vlen((l.q1 + l.q2) / 2 - SIMD2(5, 5)) < 1e-12, "across the whole circle, through the center")
        #expect(l.arrowAtStart)
        let turned = SketchDimension(.diameter("C"), "13 mm", offset: .pi / 2)
        let up = s.dimensionLine(of: turned)!
        #expect(vlen(up.q2 - SIMD2(5, 11.5)) < 1e-9 && vlen(up.q1 - SIMD2(5, -1.5)) < 1e-9)
        #expect(abs(l.value(through: SIMD2(5, 9)) - .pi / 2) < 1e-12, "dragging stores an angle about the center")
        let radius = s.dimensionLine(of: SketchDimension(.radius("C"), "6.5 mm"))!
        #expect(radius.q1 == SIMD2(5, 5) && !radius.arrowAtStart && abs(vlen(radius.q2 - radius.q1) - 6.5) < 1e-12)
    }

    @Test func aCircleGapIsDrawnFromItsRim() {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(0, 10), c = s.addPoint(8, 5)
        s.addLine(a, b, id: "L")
        s.addCircle(center: c, radius: 2, id: "C")
        let l = s.dimensionLine(of: SketchDimension(.gap("C", "L"), "6 mm", offset: 0))!
        #expect(l.p1 == SIMD2(6, 5) && l.p2 == SIMD2(0, 5), "from the near side of the rim to the edge")
        #expect(abs((s.defaultOffset(for: .gap("C", "L"), value: 6) ?? 0) - 4.4) < 1e-12, "clear of the circle: its radius plus 0.4 of the gap")
    }
}

private extension Sketch {
    /// The first end of a line, for building expected kinds.
    func lineEndPoint(_ line: EntityID) -> EntityID {
        guard case .line(let a, _)? = curve(line)?.geometry else { return "" }
        return a
    }
}
