// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import simd
import Testing

/// The extra ways to draw lines, rectangles, circles, polygons, slots and splines.
@Suite struct SketchShapesTests {
    private func pos(_ s: Sketch, _ id: EntityID) -> SIMD2<Double> { s.position(id) ?? .zero }

    // MARK: lines and rectangles

    @Test func aMidpointLineIsCenteredOnItsFirstClickAndStaysThere() throws {
        var s = Sketch()
        let madeMade = s.addMidpointLine(center: SketchSnap(SIMD2(10, 5)), end: SketchSnap(SIMD2(16, 13)))
        let made = try #require(madeMade)
        #expect(simd_length(pos(s, made.start) - SIMD2(4, -3)) < 1e-9)
        #expect(simd_length(pos(s, made.end) - SIMD2(16, 13)) < 1e-9)
        #expect(simd_length(pos(s, made.middle) - SIMD2(10, 5)) < 1e-9)
        s.dimension(.length(made.line), "30", id: "l")
        #expect(SketchSolver.solve(&s, dimensionValues: ["l": 30]).status == .solved)
        let mid = (pos(s, made.start) + pos(s, made.end)) / 2
        #expect(simd_length(mid - pos(s, made.middle)) < 1e-6, "the center stays in the middle when the line is resized")
        #expect(abs(simd_length(pos(s, made.end) - pos(s, made.start)) - 30) < 1e-6)
    }

    @Test func aMidpointLineNeedsTwoDifferentPoints() {
        var s = Sketch()
        #expect(s.addMidpointLine(center: SketchSnap(SIMD2(1, 1)), end: SketchSnap(SIMD2(1, 1))) == nil)
    }

    @Test func aThreePointRectangleHasSquareCornersOnASlant() throws {
        var s = Sketch()
        let lMade = s.addThreePointRectangle(from: SketchSnap(SIMD2(0, 0)), to: SketchSnap(SIMD2(10, 10)), depth: SketchSnap(SIMD2(0, 10)))
        let l = try #require(lMade)
        #expect(l.count == 4)
        let corners = l.compactMap { s.lineEnds($0)?.0 }
        #expect(corners.count == 4)
        // The side runs along (1,1); the depth is how far the clicked point lies to its left (7.07).
        #expect(simd_length(corners[2] - SIMD2(5, 15)) < 1e-9 && simd_length(corners[3] - SIMD2(-5, 5)) < 1e-9, "the far side is a depth away, square to the first")
        #expect(SketchSolver.solve(&s, dimensionValues: [:]).status == .solved)
        for i in 0..<4 {
            let a = s.lineEnds(l[i])!, b = s.lineEnds(l[(i + 1) % 4])!
            #expect(abs(simd_dot(a.1 - a.0, b.1 - b.0)) < 1e-6, "neighbouring sides are square")
        }
    }

    @Test func aThreePointRectangleOnAnAxisIsKeptAligned() throws {
        var s = Sketch()
        let lMade = s.addThreePointRectangle(from: SketchSnap(SIMD2(0, 0)), to: SketchSnap(SIMD2(10, 0.1)), depth: SketchSnap(SIMD2(3, 4)))
        let l = try #require(lMade)
        let first = try #require(s.lineEnds(l[0]))
        #expect(abs(first.0.y - first.1.y) < 1e-9, "a nearly horizontal first side becomes horizontal")
    }

    @Test func aThreePointRectangleNeedsADepth() {
        var s = Sketch()
        #expect(s.addThreePointRectangle(from: SketchSnap(SIMD2(0, 0)), to: SketchSnap(SIMD2(10, 0)), depth: SketchSnap(SIMD2(5, 0))) == nil)
    }

    @Test func aCenterRoundedRectangleStaysCenteredOnItsFirstClick() throws {
        var s = Sketch()
        let madeMade = s.addCenterRoundedRectangle(center: SketchSnap(SIMD2(0, 0)), corner: SketchSnap(SIMD2(20, 10)), radius: 3, expression: "3 mm")
        let made = try #require(madeMade)
        #expect(made.arcs.count == 4)
        let xs = made.corners.map { pos(s, $0).x }, ys = made.corners.map { pos(s, $0).y }
        #expect(abs(xs.min()! + 20) < 1e-9 && abs(xs.max()! - 20) < 1e-9 && abs(ys.min()! + 10) < 1e-9 && abs(ys.max()! - 10) < 1e-9)
        #expect(SketchSolver.solve(&s, dimensionValues: s.dimensionValues(ParameterValues())).status == .solved)
    }

    // MARK: circles

    @Test func aThreePointCircleGoesThroughItsPoints() throws {
        var s = Sketch()
        let idMade = s.addCircle(through: SketchSnap(SIMD2(5, 0)), SketchSnap(SIMD2(0, 5)), SketchSnap(SIMD2(-5, 0)))
        let id = try #require(idMade)
        guard case .circle(let center, let r)? = s.curve(id)?.geometry else { Issue.record("not a circle"); return }
        #expect(simd_length(pos(s, center)) < 1e-9)
        #expect(abs(r - 5) < 1e-9)
    }

    @Test func aThreePointCircleRefusesPointsOnALine() {
        var s = Sketch()
        #expect(s.addCircle(through: SketchSnap(SIMD2(0, 0)), SketchSnap(SIMD2(1, 1)), SketchSnap(SIMD2(2, 2))) == nil)
    }

    @Test func theCircleTangentToTwoCrossingLinesSlidesAlongTheBisector() throws {
        let a = CurveGeometry.line(SIMD2(0, 0), SIMD2(10, 0)), b = CurveGeometry.line(SIMD2(0, 0), SIMD2(0, 10))
        let r = try #require(TangentCircle.solve(a, b, near: SIMD2(6, 6)))
        #expect(abs(r.center.x - r.center.y) < 1e-4, "the center is on the bisector")
        #expect(abs(r.radius - r.center.x) < 1e-4, "and as far from each line as the radius")
        let typed = try #require(TangentCircle.solve(a, b, near: SIMD2(30, 30), radius: 4))
        #expect(simd_length(typed.center - SIMD2(4, 4)) < 1e-9)
    }

    @Test func aCircleTangentToALineAndACircle() throws {
        let line = CurveGeometry.line(SIMD2(-50, 0), SIMD2(50, 0))
        let circle = CurveGeometry.circle(center: SIMD2(0, 20), radius: 10)
        let r = try #require(TangentCircle.solve(line, circle, near: SIMD2(25, 6)))
        #expect(abs(abs(r.center.y) - r.radius) < 1e-3, "touches the line")
        #expect(abs(simd_length(r.center - SIMD2(0, 20)) - (10 + r.radius)) < 1e-3 || abs(simd_length(r.center - SIMD2(0, 20)) - abs(10 - r.radius)) < 1e-3, "touches the circle")
    }

    @Test func theCircleTangentToThreeLinesIsTheInscribedOne() throws {
        // A triangle with its corners at (0,0), (12,0) and (0,9): the incircle has radius 3 and center (3,3).
        let a = CurveGeometry.line(SIMD2(0, 0), SIMD2(12, 0)), b = CurveGeometry.line(SIMD2(0, 0), SIMD2(0, 9)), c = CurveGeometry.line(SIMD2(12, 0), SIMD2(0, 9))
        let r = try #require(TangentCircle.solve(a, b, c, near: SIMD2(3.5, 3)))
        #expect(simd_length(r.center - SIMD2(3, 3)) < 1e-6 && abs(r.radius - 3) < 1e-6)
    }

    @Test func aTangentCircleStaysTangentWhenALineMoves() throws {
        var s = Sketch()
        let o = s.addPoint(0, 0), x = s.addPoint(20, 0), y = s.addPoint(0, 20)
        let bottom = s.addLine(o, x), left = s.addLine(o, y)
        let g1 = try #require(s.geometry(of: bottom)), g2 = try #require(s.geometry(of: left))
        let r = try #require(TangentCircle.solve(g1, g2, near: SIMD2(6, 6)))
        let circle = s.addTangentCircle(r, tangentTo: [bottom, left])
        s.dimension(.radius(circle), "6", id: "r")
        #expect(SketchSolver.solve(&s, dimensionValues: ["r": 6]).status == .solved)
        guard case .circle(let center, let radius)? = s.curve(circle)?.geometry else { Issue.record("not a circle"); return }
        #expect(abs(radius - 6) < 1e-6 && simd_length(pos(s, center) - SIMD2(6, 6)) < 1e-6)
    }

    // MARK: polygons

    @Test func aCircumscribedPolygonHasTheClickedDistanceAsItsApothem() throws {
        var s = Sketch()
        let made = s.addCircumscribedPolygon(center: SketchSnap(SIMD2(0, 0)), sideMiddle: SketchSnap(SIMD2(10, 0)), sides: 6)
        #expect(made.lines.count == 6)
        #expect(SketchSolver.solve(&s, dimensionValues: [:]).status == .solved)
        let first = try #require(s.lineEnds(made.lines[0]))
        let mid = (first.0 + first.1) / 2
        #expect(abs(simd_length(mid) - 10) < 1e-6, "the side's middle is the apothem from the center")
        #expect(abs(mid.y) < 1e-6 && mid.x > 0, "and the first side faces the click")
        let side = simd_length(first.1 - first.0)
        #expect(abs(side - 2 * 10 * tan(.pi / 6)) < 1e-6)
    }

    @Test func anEdgePolygonSitsOnItsEdgeToTheLeft() throws {
        var s = Sketch()
        let madeMade = s.addEdgePolygon(from: SketchSnap(SIMD2(0, 0)), to: SketchSnap(SIMD2(10, 0)), sides: 4)
        let made = try #require(madeMade)
        #expect(made.lines.count == 4)
        #expect(SketchSolver.solve(&s, dimensionValues: [:]).status == .solved)
        let first = try #require(s.lineEnds(made.lines[0]))
        #expect(simd_length(first.0 - SIMD2(0, 0)) < 1e-6 && simd_length(first.1 - SIMD2(10, 0)) < 1e-6, "the first side is the clicked edge")
        let ys = made.lines.compactMap { s.lineEnds($0)?.0.y }
        #expect(ys.max()! > 9.9, "the square rises above the edge")
    }

    // MARK: slots

    @Test func aCenterPointSlotIsCenteredOnItsFirstClick() throws {
        var s = Sketch()
        let slotMade = s.addCenterPointSlot(center: SketchSnap(SIMD2(0, 0)), end: SketchSnap(SIMD2(15, 0)), width: 8)
        let slot = try #require(slotMade)
        #expect(simd_length(pos(s, slot.centers[0]) - SIMD2(-15, 0)) < 1e-9 && simd_length(pos(s, slot.centers[1]) - SIMD2(15, 0)) < 1e-9)
        s.dimension(.distance(slot.centers[0], slot.centers[1]), "50", id: "l")
        #expect(SketchSolver.solve(&s, dimensionValues: ["l": 50]).status == .solved)
        let mid = (pos(s, slot.centers[0]) + pos(s, slot.centers[1])) / 2
        #expect(simd_length(mid) < 1e-6, "still centered after resizing")
    }

    @Test func anArcSlotFollowsItsArc() throws {
        var s = Sketch()
        // A quarter turn round the origin at radius 20, 6 wide.
        let slotMade = s.addArcSlot(center: SketchSnap(SIMD2(0, 0)), start: SketchSnap(SIMD2(20, 0)), end: SketchSnap(SIMD2(0, 30)), width: 6)
        let slot = try #require(slotMade)
        s.dimension(.diameter(slot.ends[0]), "6", id: "w")
        let result = SketchSolver.solve(&s, dimensionValues: ["w": 6])
        #expect(result.status == .solved)
        let radii = slot.sides.compactMap { id in s.curve(id).flatMap { s.radius(of: $0) } }.sorted()
        #expect(radii.count == 2 && abs(radii[0] - 17) < 1e-6 && abs(radii[1] - 23) < 1e-6, "the long sides are half a width in and out")
        for end in slot.ends { #expect(abs((s.curve(end).flatMap { s.radius(of: $0) } ?? 0) - 3) < 1e-6) }
        // Widening the slot keeps the ends round and tangent to both long sides.
        #expect(SketchSolver.solve(&s, dimensionValues: ["w": 10]).status == .solved)
        let wider = slot.sides.compactMap { id in s.curve(id).flatMap { s.radius(of: $0) } }.sorted()
        #expect(abs(wider[0] - 15) < 1e-6 && abs(wider[1] - 25) < 1e-6)
        #expect(result.degreesOfFreedom > 0)
    }

    @Test func anArcSlotNeedsRoomForItsWidth() {
        var s = Sketch()
        #expect(s.addArcSlot(center: SketchSnap(SIMD2(0, 0)), start: SketchSnap(SIMD2(2, 0)), end: SketchSnap(SIMD2(0, 2)), width: 6) == nil)
    }

    // MARK: splines

    @Test func aControlPointSplineStartsAndEndsAtItsEndPoints() throws {
        let controls = [SIMD2(0.0, 0), SIMD2(10, 20), SIMD2(20, -20), SIMD2(30, 20), SIMD2(40, 0)]
        let pieces = try #require(Sketch.controlPointSpline(controls))
        #expect(pieces.count == 2)
        #expect(simd_length(pieces[0][0] - controls[0]) < 1e-9 && simd_length(pieces[1][3] - controls[4]) < 1e-9)
        #expect(simd_length(pieces[0][3] - pieces[1][0]) < 1e-9, "the pieces meet")
        // Slope continuity at the join.
        let inSlope = pieces[0][3] - pieces[0][2], outSlope = pieces[1][1] - pieces[1][0]
        #expect(abs(simd_normalize(inSlope).x - simd_normalize(outSlope).x) < 1e-6 && abs(simd_normalize(inSlope).y - simd_normalize(outSlope).y) < 1e-6)
    }

    @Test func fourControlPointsMakeOneBezierWithTheControlsAsItsHandles() throws {
        let controls = [SIMD2(0.0, 0), SIMD2(0, 10), SIMD2(10, 10), SIMD2(10, 0)]
        let pieces = try #require(Sketch.controlPointSpline(controls))
        #expect(pieces == [controls])
    }

    @Test func aControlPointSplineIsDrawnAsBezierCurves() throws {
        var s = Sketch()
        let snaps = [SIMD2(0.0, 0), SIMD2(10, 20), SIMD2(20, -20), SIMD2(30, 20), SIMD2(40, 0)].map { SketchSnap($0) }
        let madeMade = s.addControlPointSpline(snaps)
        let made = try #require(madeMade)
        #expect(made.count == 2)
        #expect(Sketch.controlPointSpline([SIMD2(0, 0), SIMD2(1, 1)]) == nil)
    }

    @Test func aTangentCircleBetweenParallelLinesFillsTheGapAndSlidesAlong() throws {
        let a = CurveGeometry.line(SIMD2(-20, 0), SIMD2(20, 0)), b = CurveGeometry.line(SIMD2(-20, 10), SIMD2(20, 10))
        let r = try #require(TangentCircle.solve(a, b, near: SIMD2(7, 30)))
        #expect(abs(r.radius - 5) < 1e-9 && simd_length(r.center - SIMD2(7, 5)) < 1e-9, "half the gap, under the pointer")
        #expect(TangentCircle.solve(a, b, near: SIMD2(7, 30), radius: 5) != nil)
        #expect(TangentCircle.solve(a, b, near: SIMD2(7, 30), radius: 3) == nil, "no other size touches both")
        #expect(TangentCircle.solve(a, a, near: SIMD2(0, 0)) == nil, "the same line twice has no gap to fill")
    }
}
