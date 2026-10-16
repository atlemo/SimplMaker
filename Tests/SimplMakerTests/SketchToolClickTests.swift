// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// Each sketch tool, clicked with the mouse the way its hint says, makes what the hint promises. These cover the
/// tools the other suites only reach through typed input or the model: Line, Rectangle, Center Rectangle, Circle,
/// Triangle, Arc, Tangent Arc, Point, Text, Trim, Extend, Round Corner and Chamfer.
@Suite @MainActor struct SketchToolClickTests {
    private func session(_ sketch: Sketch = Sketch()) -> SketchSession {
        SketchSession(featureID: IDs.make(), frame: .xy, sketch: sketch, parameters: ParameterEvaluator.evaluate([]))
    }

    /// Moves to the spot, then presses and releases there, as a click does.
    private func click(_ s: SketchSession, _ x: Double, _ y: Double) -> String? {
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil))
        let down = s.handle(SketchMouse(phase: .down, uv: SIMD2(x, y), pick: nil))
        let up = s.handle(SketchMouse(phase: .up, uv: SIMD2(x, y), pick: nil))
        return down.commit ?? up.commit
    }

    private func lines(_ s: SketchSession) -> [SketchCurve] {
        s.sketch.curves.filter { c in
            if c.construction { return false }
            if case .line = c.geometry { return true }
            return false
        }
    }

    private func arcs(_ s: SketchSession) -> [SketchCurve] {
        s.sketch.curves.filter { if case .arc = $0.geometry { return true } else { return false } }
    }

    private func near(_ a: SIMD2<Double>?, _ b: SIMD2<Double>, _ tol: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return simdLength(a - b) < tol
    }

    @Test func aLineMadeOfTwoClicksChainsFromItsEnd() {
        let s = session()
        s.setTool(.line)
        _ = click(s, 0, 0)
        #expect(s.sketch.curves.isEmpty, "the first click only starts the line")
        _ = click(s, 10, 0)
        _ = click(s, 10, 10)
        #expect(lines(s).count == 2, "the second line starts where the first one ended")
        let ends = lines(s).compactMap { s.sketch.lineEnds($0.id) }
        #expect(ends.count == 2 && near(ends[0].1, ends[1].0), "the two lines share their joint")
    }

    @Test func aLineOfNoLengthDrawsNothing() {
        let s = session()
        s.setTool(.line)
        _ = click(s, 4, 4)
        _ = click(s, 4, 4)
        #expect(s.sketch.curves.isEmpty)
    }

    @Test func aRectangleFromTwoCornersHasFourSidesAtTheCorners() {
        let s = session()
        s.setTool(.rectangle)
        _ = click(s, 0, 0)
        _ = click(s, 20, 10)
        #expect(lines(s).count == 4)
        let xs = s.sketch.points.map(\.position.x), ys = s.sketch.points.map(\.position.y)
        #expect(xs.min() == 0 && xs.max() == 20 && ys.min() == 0 && ys.max() == 10)
    }

    @Test func aCenterRectangleIsCenteredOnTheFirstClick() {
        let s = session()
        s.setTool(.centerRectangle)
        _ = click(s, 0, 0)
        _ = click(s, 10, 5)
        #expect(lines(s).count == 4, "the diagonal is construction, so four sides")
        let xs = s.sketch.points.map(\.position.x), ys = s.sketch.points.map(\.position.y)
        #expect(xs.min() == -10 && xs.max() == 10 && ys.min() == -5 && ys.max() == 5, "the corner sets the half-size")
    }

    @Test func aCircleFromCenterAndRimHasTheRadiusToTheCursor() {
        let s = session()
        s.setTool(.circle)
        _ = click(s, 2, 3)
        _ = click(s, 5, 7)
        let c = s.sketch.curves.first { if case .circle = $0.geometry { return true } else { return false } }
        #expect(c != nil)
        #expect(c.flatMap { s.sketch.radius(of: $0) }.map { abs($0 - 5) < 1e-6 } == true, "3-4-5: the rim is 5 away")
    }

    @Test func aTwoPointCircleTakesItsDiameterFromTwoSides() {
        let s = session()
        s.setTool(.circle2Point)
        _ = click(s, 0, 0)
        _ = click(s, 10, 0)
        let c = s.sketch.curves.first { if case .circle = $0.geometry { return true } else { return false } }
        #expect(c.flatMap { s.sketch.radius(of: $0) }.map { abs($0 - 5) < 1e-6 } == true, "diameter 10")
        #expect(c.flatMap { s.sketch.center(of: $0.id) }.flatMap { s.sketch.position($0) }.map { near($0, SIMD2(5, 0)) } == true,
                "centred between the two clicks")
    }

    @Test func aTriangleHasThreeSidesAndAPolygonTheTypedNumber() {
        let tri = session()
        tri.setTool(.triangle)
        _ = click(tri, 0, 0)
        _ = click(tri, 10, 0)
        #expect(lines(tri).count == 3)

        let poly = session()
        poly.setTool(.polygon)
        poly.setTyped(.sides, "5")
        _ = click(poly, 0, 0)
        _ = click(poly, 10, 0)
        #expect(lines(poly).count == 5)
    }

    @Test func aCenterArcIsCentredOnTheFirstClickFromStartToEnd() {
        let s = session()
        s.setTool(.arc)
        _ = click(s, 0, 0)
        _ = click(s, 10, 0)
        #expect(arcs(s).isEmpty, "the centre and start alone draw nothing")
        _ = click(s, 0, 4)
        let arc = arcs(s).first
        #expect(arc != nil)
        #expect(arc.flatMap { s.sketch.radius(of: $0) }.map { abs($0 - 10) < 1e-6 } == true, "the radius runs to the start")
        #expect(arc.flatMap { s.sketch.center(of: $0.id) }.flatMap { s.sketch.position($0) }.map { near($0, .zero) } == true)
    }

    @Test func aThreePointArcPassesThroughTheThirdClick() {
        let s = session()
        s.setTool(.arc3Point)
        _ = click(s, 10, 0)
        _ = click(s, -10, 0)
        _ = click(s, 0, 10)
        let arc = arcs(s).first
        #expect(arc != nil, "the arc is drawn")
        #expect(arc.flatMap { s.sketch.radius(of: $0) }.map { abs($0 - 10) < 1e-6 } == true, "centred at the origin, radius 10")
    }

    @Test func threeClicksInALineMakeNoThreePointArc() {
        let s = session()
        s.setTool(.arc3Point)
        _ = click(s, 0, 0)
        _ = click(s, 10, 0)
        _ = click(s, 5, 0)
        #expect(arcs(s).isEmpty)
        #expect(s.message?.contains("bend") == true)
    }

    @Test func aTangentArcCarriesOnFromTheFreeEndOfALine() {
        let sketch = { () -> Sketch in
            var k = Sketch()
            let a = k.addPoint(0, 0), b = k.addPoint(10, 0)
            _ = k.addLine(a, b, id: "H")
            return k
        }()
        let s = session(sketch)
        s.setTool(.tangentArc)
        _ = click(s, 10, 0)
        _ = click(s, 14, 4)
        #expect(arcs(s).count == 1, "the arc is drawn from the line's end")
        // Tangent to the x-axis at (10, 0), so the centre is straight up at (10, 4): the arc has radius 4.
        let arc = arcs(s)[0]
        #expect(s.sketch.center(of: arc.id).flatMap { s.sketch.position($0) }.map { near($0, SIMD2(10, 4)) } == true)
    }

    @Test func aTangentArcFromAPlainPointIsRefused() {
        let s = session()
        s.setTool(.tangentArc)
        _ = click(s, 10, 0)
        _ = click(s, 14, 4)
        #expect(s.sketch.curves.isEmpty)
        #expect(s.message != nil)
    }

    @Test func aClickPlacesAPointOnceAndNotTwice() {
        let s = session()
        s.setTool(.point)
        _ = click(s, 3, 4)
        _ = click(s, 3, 4)
        let points = s.sketch.points.filter { near($0.position, SIMD2(3, 4)) }
        #expect(points.count == 1, "clicking the same spot again uses the point that is there")
    }

    @Test func aTextStartsAtTheClickAndTakesItsWordsOnReturn() {
        let s = session()
        s.setTool(.text)
        _ = click(s, 5, 5)
        #expect(s.pendingText != nil, "waiting for the words")
        _ = s.placeText("Hi")
        #expect(s.sketch.texts.count == 1 && s.sketch.texts[0].text == "Hi")
        #expect(s.pendingText == nil)
    }

    @Test func trimRemovesThePiecePastTheCrossingLine() {
        var sketch = Sketch()
        let a = sketch.addPoint(0, 0), b = sketch.addPoint(10, 0)
        _ = sketch.addLine(a, b, id: "H")
        let c = sketch.addPoint(5, -5), d = sketch.addPoint(5, 5)
        _ = sketch.addLine(c, d, id: "V")
        let s = session(sketch)
        s.setTool(.trim)
        #expect(click(s, 8, 0) != nil, "the commit names the edit")
        let horizontal = lines(s).compactMap { s.sketch.lineEnds($0.id) }.filter { $0.0.y == 0 && $0.1.y == 0 }
        #expect(!horizontal.contains { max($0.0.x, $0.1.x) > 5 + 1e-6 }, "nothing is left past the crossing at x = 5")
        #expect(horizontal.contains { min($0.0.x, $0.1.x) < 1e-6 && abs(max($0.0.x, $0.1.x) - 5) < 1e-6 }, "the piece from 0 to 5 stays")
    }

    @Test func extendNearAnEndStillExtendsThatCurve() {
        var sketch = Sketch()
        let a = sketch.addPoint(0, 0), b = sketch.addPoint(4, 0)
        _ = sketch.addLine(a, b, id: "H")
        let c = sketch.addPoint(10, -5), d = sketch.addPoint(10, 5)
        _ = sketch.addLine(c, d, id: "V")
        let s = session(sketch)
        s.setTool(.extend)
        // 0.1 mm from the end: the end point is the hover, and the line must still be the one extended.
        #expect(click(s, 3.9, 0) != nil, "no 'Click on a curve' message")
        let reach = lines(s).compactMap { s.sketch.lineEnds($0.id) }.map { max($0.0.x, $0.1.x) }.max() ?? 0
        #expect(abs(reach - 10) < 1e-6)
    }

    @Test func trimNearAnEndStillTrimsThatCurve() {
        var sketch = Sketch()
        let a = sketch.addPoint(0, 0), b = sketch.addPoint(10, 0)
        _ = sketch.addLine(a, b, id: "H")
        let c = sketch.addPoint(5, -5), d = sketch.addPoint(5, 5)
        _ = sketch.addLine(c, d, id: "V")
        let s = session(sketch)
        s.setTool(.trim)
        #expect(click(s, 9.9, 0) != nil, "the end point is the hover, and the line is still trimmed")
        let horizontal = lines(s).compactMap { s.sketch.lineEnds($0.id) }.filter { $0.0.y == 0 && $0.1.y == 0 }
        #expect(!horizontal.contains { max($0.0.x, $0.1.x) > 5 + 1e-6 })
    }

    @Test func extendReachesTheNextCurveFromTheNearEnd() {
        var sketch = Sketch()
        let a = sketch.addPoint(0, 0), b = sketch.addPoint(4, 0)
        _ = sketch.addLine(a, b, id: "H")
        let c = sketch.addPoint(10, -5), d = sketch.addPoint(10, 5)
        _ = sketch.addLine(c, d, id: "V")
        let s = session(sketch)
        s.setTool(.extend)
        let got = click(s, 2.5, 0)  // 2.5 mm from the start, 1.5 from the end: the end is the nearer one
        #expect(got != nil, "the commit names the edit")
        let reach = lines(s).compactMap { s.sketch.lineEnds($0.id) }.map { max($0.0.x, $0.1.x) }.max() ?? 0
        #expect(abs(reach - 10) < 1e-6, "the line now stops on the vertical line at x = 10")
    }

    @Test func clickingACornerRoundsIt() {
        var sketch = Sketch()
        _ = sketch.addRectangle(5, 5, 25, 15)  // off the origin, which is a point of its own
        let s = session(sketch)
        s.setTool(.fillet)
        let before = arcs(s).count
        _ = click(s, 5, 5)
        #expect(arcs(s).count == before + 1, "one corner gets one arc")
    }

    @Test func clickingACornerChamfersIt() {
        var sketch = Sketch()
        _ = sketch.addRectangle(0, 0, 20, 10)
        let s = session(sketch)
        s.setTool(.chamfer)
        let before = lines(s).count
        _ = click(s, 20, 10)
        #expect(lines(s).count == before + 1, "the cut is one more side; the two legs are construction")
    }

    @Test func roundAndChamferSayWhatToClickWhenNotOnACorner() {
        var sketch = Sketch()
        _ = sketch.addRectangle(0, 0, 20, 10)
        let s = session(sketch)
        s.setTool(.fillet)
        _ = click(s, 10, 5)
        #expect(s.sketch.curves.count == 4, "nothing changed")
        #expect(s.message?.contains("corner") == true)
    }
}
