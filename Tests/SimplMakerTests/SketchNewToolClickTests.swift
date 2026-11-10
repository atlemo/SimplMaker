// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// The newer ways to draw (Midpoint Line, 3-Point Rectangle, Center Rounded Rectangle, 3-Point / 2-Tangent / 3-Tangent
/// Circle, Circumscribed and Edge Polygon, the three slots and the Control Point Spline), clicked the way their hints say.
@Suite @MainActor struct SketchNewToolClickTests {
    private func session(_ sketch: Sketch = Sketch()) -> SketchSession {
        SketchSession(featureID: IDs.make(), frame: .xy, sketch: sketch, parameters: ParameterEvaluator.evaluate([]))
    }

    private func click(_ s: SketchSession, _ x: Double, _ y: Double) -> String? {
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil))
        let down = s.handle(SketchMouse(phase: .down, uv: SIMD2(x, y), pick: nil))
        let up = s.handle(SketchMouse(phase: .up, uv: SIMD2(x, y), pick: nil))
        return down.commit ?? up.commit
    }

    private func drawn(_ s: SketchSession) -> [SketchCurve] { s.sketch.curves.filter { !$0.construction } }
    private func lines(_ s: SketchSession) -> [SketchCurve] { drawn(s).filter { if case .line = $0.geometry { return true } else { return false } } }
    private func arcs(_ s: SketchSession) -> [SketchCurve] { drawn(s).filter { if case .arc = $0.geometry { return true } else { return false } } }
    private func circles(_ s: SketchSession) -> [SketchCurve] { drawn(s).filter { if case .circle = $0.geometry { return true } else { return false } } }

    /// The box around every drawn point (control points and arc centers excluded: only line ends and curve ends count).
    private func lineBox(_ s: SketchSession) -> (min: SIMD2<Double>, max: SIMD2<Double>) {
        let ends = lines(s).compactMap { s.sketch.lineEnds($0.id) }.flatMap { [$0.0, $0.1] }
        return (SIMD2(ends.map(\.x).min() ?? 0, ends.map(\.y).min() ?? 0), SIMD2(ends.map(\.x).max() ?? 0, ends.map(\.y).max() ?? 0))
    }

    private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) < tol }

    // MARK: lines and rectangles

    @Test func aMidpointLineGrowsEquallyBothWaysFromTheFirstClick() {
        let s = session()
        s.setTool(.midpointLine)
        _ = click(s, 5, 0)
        #expect(drawn(s).isEmpty, "the middle alone draws nothing")
        let commit = click(s, 8, 0)
        #expect(commit == "Midpoint Line")
        let ends = lines(s).first.flatMap { s.sketch.lineEnds($0.id) }
        #expect(ends.map { near($0.0.x, 2) && near($0.1.x, 8) } == true, "from 2 to 8, around the middle at 5")
    }

    @Test func aThreePointRectangleTakesItsHeightFromTheThirdClick() {
        let s = session()
        s.setTool(.rectangle3Point)
        _ = click(s, 0, 0)
        _ = click(s, 10, 0)
        #expect(lines(s).isEmpty, "two clicks fix one side only")
        let commit = click(s, 10, 4)
        #expect(commit == "3-Point Rectangle")
        #expect(lines(s).count == 4)
        let box = lineBox(s)
        #expect(near(box.min.x, 0) && near(box.max.x, 10) && near(box.min.y, 0) && near(box.max.y, 4))
    }

    @Test func aThreePointRectangleNeedsTheThirdClickOffTheFirstSide() {
        let s = session()
        s.setTool(.rectangle3Point)
        _ = click(s, 0, 0)
        _ = click(s, 10, 0)
        _ = click(s, 4, 0)
        #expect(lines(s).isEmpty)
        #expect(s.message?.contains("height") == true)
    }

    @Test func aCenterRoundedRectangleHasFourSidesAndFourRoundCorners() {
        let s = session()
        s.setTool(.centerRoundedRectangle)
        s.setTyped(.radius, "2")
        _ = click(s, 0, 0)
        let commit = click(s, 10, 6)
        #expect(commit == "Center Rounded Rectangle")
        #expect(lines(s).count == 4 && arcs(s).count == 4)
        for a in arcs(s) { #expect(near(s.sketch.radius(of: a) ?? 0, 2)) }
        let box = lineBox(s)
        #expect(near(box.min.x, -10) && near(box.max.x, 10) && near(box.min.y, -6) && near(box.max.y, 6), "the sides reach the box; each stops a radius short of the corner")
    }

    // MARK: circles

    @Test func aThreePointCircleGoesThroughTheThreeClicks() {
        let s = session()
        s.setTool(.circle3Point)
        _ = click(s, 10, 0)
        _ = click(s, -10, 0)
        #expect(circles(s).isEmpty)
        let commit = click(s, 0, 10)
        #expect(commit == "Circle")
        let c = circles(s).first
        #expect(c.flatMap { s.sketch.radius(of: $0) }.map { near($0, 10) } == true)
    }

    @Test func threePointsInALineMakeNoCircle() {
        let s = session()
        s.setTool(.circle3Point)
        _ = click(s, 0, 0)
        _ = click(s, 5, 0)
        _ = click(s, 10, 0)
        #expect(circles(s).isEmpty)
        #expect(s.message?.contains("bend") == true)
    }

    @Test func aTwoTangentCircleBetweenTwoParallelLinesFillsTheGap() {
        var k = Sketch()
        let a = k.addPoint(-20, 0), b = k.addPoint(20, 0), c = k.addPoint(-20, 10), d = k.addPoint(20, 10)
        _ = k.addLine(a, b, id: "lo")
        _ = k.addLine(c, d, id: "hi")
        let s = session(k)
        s.setTool(.circle2Tangent)
        _ = click(s, 3, 0)
        _ = click(s, 3, 10)
        #expect(circles(s).isEmpty, "the two lines are picked; the circle is placed by the next click")
        #expect(s.tangentPicks.count == 2)
        let commit = click(s, 3, 5)
        #expect(commit != nil)
        let made = circles(s).first
        #expect(made.flatMap { s.sketch.radius(of: $0) }.map { near($0, 5, 1e-4) } == true, "half the gap")
    }

    @Test func aThreeTangentCircleTouchesAllThreeLines() {
        var k = Sketch()
        let o = k.addPoint(0, 0), x = k.addPoint(12, 0), y = k.addPoint(0, 12)
        _ = k.addLine(o, x, id: "a")
        _ = k.addLine(x, y, id: "b")
        _ = k.addLine(y, o, id: "c")
        let s = session(k)
        s.setTool(.circle3Tangent)
        _ = click(s, 6, 0)
        _ = click(s, 6, 6)
        #expect(circles(s).isEmpty)
        _ = click(s, 0, 6)
        let made = circles(s).first
        #expect(made != nil, "three lines of a triangle have a circle that touches them all")
        guard let made, let r = s.sketch.radius(of: made), let center = s.sketch.center(of: made.id).flatMap({ s.sketch.position($0) }) else { return }
        for id in ["a", "b", "c"] {
            guard let g = s.sketch.geometry(of: id), case .line(let p, let q) = g else { Issue.record("line \(id) lost"); continue }
            let dir = q - p
            let dist = abs(dir.x * (center.y - p.y) - dir.y * (center.x - p.x)) / simdLength(dir)
            #expect(near(dist, r, 1e-4), "tangent to \(id)")
        }
    }

    @Test func aTangentToolIgnoresAClickOnNothing() {
        let s = session()
        s.setTool(.circle2Tangent)
        _ = click(s, 50, 50)
        #expect(s.tangentPicks.isEmpty)
        #expect(s.message?.contains("Click a line") == true)
    }

    // MARK: polygons

    @Test func aCircumscribedPolygonHasItsSidesTouchingTheCircle() {
        let s = session()
        s.setTool(.circumscribedPolygon)
        s.setTyped(.sides, "4")
        _ = click(s, 0, 0)
        let commit = click(s, 10, 0)
        #expect(commit == "Circumscribed Polygon")
        #expect(lines(s).count == 4)
        let box = lineBox(s)
        #expect(near(box.max.x, 10) && near(box.min.x, -10) && near(box.max.y, 10) && near(box.min.y, -10), "a square with its sides 10 from the center")
    }

    @Test func anInscribedPolygonHasItsCornersOnTheCircle() {
        let s = session()
        s.setTool(.polygon)
        s.setTyped(.sides, "4")
        _ = click(s, 0, 0)
        _ = click(s, 10, 0)
        let box = lineBox(s)
        #expect(near(box.max.x, 10) && near(box.min.x, -10), "the corner clicked is 10 from the center")
        // Circumscribed with the same clicks is a bigger shape: its corners lie outside the circle.
        let outer = session()
        outer.setTool(.circumscribedPolygon)
        outer.setTyped(.sides, "4")
        _ = click(outer, 0, 0)
        _ = click(outer, 10, 0)
        let farthest = lines(outer).compactMap { outer.sketch.lineEnds($0.id)?.0 }.map { simdLength($0) }.max() ?? 0
        #expect(farthest > 10 * 1.4, "its corners are 10 / cos(45 degrees) away")
    }

    @Test func anEdgePolygonGrowsToTheLeftOfItsFirstSide() {
        let s = session()
        s.setTool(.edgePolygon)
        s.setTyped(.sides, "4")
        _ = click(s, 0, 0)
        let commit = click(s, 10, 0)
        #expect(commit == "Edge Polygon")
        #expect(lines(s).count == 4)
        let box = lineBox(s)
        #expect(near(box.min.x, 0) && near(box.max.x, 10) && near(box.min.y, 0) && near(box.max.y, 10), "a square standing on the side, going up")
    }

    // MARK: slots and splines

    @Test func aCenterPointSlotReachesAWidthPastItsEndCenter() {
        let s = session()
        s.setTool(.slotCenterPoint)
        s.setTyped(.width, "4")
        _ = click(s, 0, 0)
        #expect(drawn(s).isEmpty)
        _ = click(s, 10, 0)
        #expect(lines(s).count == 2 && arcs(s).count == 2)
        let box = lineBox(s)
        #expect(near(box.min.x, -10) && near(box.max.x, 10) && near(box.min.y, -2) && near(box.max.y, 2), "end centers at +-10, sides 2 off the axis")
        for a in arcs(s) { #expect(near(s.sketch.radius(of: a) ?? 0, 2)) }
    }

    @Test func anArcSlotThroughThreePointsFollowsTheArc() {
        let s = session()
        s.setTool(.arcSlot3Point)
        s.setTyped(.width, "2")
        _ = click(s, 10, 0)
        _ = click(s, -10, 0)
        #expect(drawn(s).isEmpty)
        _ = click(s, 0, 10)
        #expect(arcs(s).count == 4, "two long sides and two round ends")
        let radii = arcs(s).compactMap { s.sketch.radius(of: $0) }.sorted()
        #expect(radii.count == 4 && near(radii[0], 1) && near(radii[1], 1) && near(radii[2], 9) && near(radii[3], 11), "ends of radius 1; sides 1 inside and 1 outside radius 10")
    }

    @Test func aCenterArcSlotRunsFromTheFirstEndToTheSecond() {
        let s = session()
        s.setTool(.arcSlotCenter)
        s.setTyped(.width, "2")
        _ = click(s, 0, 0)
        _ = click(s, 10, 0)
        #expect(drawn(s).isEmpty)
        _ = click(s, 0, 10)
        #expect(arcs(s).count == 4)
        let radii = arcs(s).compactMap { s.sketch.radius(of: $0) }.sorted()
        #expect(near(radii[0], 1) && near(radii[3], 11))
    }

    @Test func aControlPointSplineEndsOnItsLastClickAndIsFinishedByDoubleClick() {
        let s = session()
        s.setTool(.splineControl)
        _ = click(s, 0, 0)
        _ = click(s, 5, 10)
        _ = click(s, 10, 0)
        #expect(drawn(s).isEmpty, "still being drawn")
        let commit = click(s, 10, 0)  // the same spot again: a double-click
        #expect(commit != nil)
        #expect(!drawn(s).isEmpty)
        let points = drawn(s).flatMap { s.sketch.pointIDs(of: $0) }.compactMap { s.sketch.position($0) }
        #expect(points.contains { simdLength($0 - SIMD2(0, 0)) < 1e-9 } && points.contains { simdLength($0 - SIMD2(10, 0)) < 1e-9 }, "it starts at the first click and ends at the last")
    }

    @Test func escapeCancelsAControlPointSpline() {
        let s = session()
        s.setTool(.splineControl)
        _ = click(s, 0, 0)
        _ = click(s, 5, 10)
        s.escape()
        #expect(drawn(s).isEmpty)
    }

    // MARK: families

    @Test func theKeyCyclesThroughTheNewWaysToDraw() {
        #expect(SketchTool.line.family.contains(.midpointLine))
        #expect(SketchTool.rectangle.family.contains(.rectangle3Point) && SketchTool.rectangle.family.contains(.centerRoundedRectangle))
        #expect(SketchTool.circle.family.contains(.circle3Tangent))
        #expect(SketchTool.polygon.family.contains(.circumscribedPolygon) && SketchTool.polygon.family.contains(.edgePolygon))
        #expect(SketchTool.slot.family.contains(.arcSlotCenter))
        #expect(SketchTool.bezier.family.contains(.splineControl))
    }

    // MARK: tidying projections

    @Test func cleanUpProjectionsRemovesTheUnusedOnesAndSaysSo() {
        var k = Sketch()
        k.project(ModelSnap(edge: EdgeRef(body: "b", edge: "e"), start: SIMD2(0, 0), end: SIMD2(10, 0)))
        let s = session(k)
        #expect(s.canCleanUpProjections)
        #expect(s.cleanUpProjections() == "Clean Up Projections")
        #expect(s.sketch.projections.isEmpty && s.message?.contains("1 unused") == true)
        #expect(s.cleanUpProjections() == nil, "nothing left to clean")
        #expect(!s.canCleanUpProjections)
    }

    @Test func cleanUpStaleProjectionsDoesNothingWhenNothingIsStale() {
        var k = Sketch()
        k.project(ModelSnap(edge: EdgeRef(body: "b", edge: "e"), start: SIMD2(0, 0), end: SIMD2(10, 0)))
        let s = session(k)
        #expect(!s.canCleanUpStaleProjections)
        #expect(s.cleanUpStaleProjections() == nil)
        #expect(s.sketch.projections.count == 1)
    }
}
