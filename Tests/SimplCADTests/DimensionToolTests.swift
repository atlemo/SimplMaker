// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// The Dimension tool, picking within a few pixels, and the measured sizes shown for every curve.
@Suite @MainActor struct DimensionToolTests {
    /// A 20 × 10 rectangle from the origin, and a circle of radius 3 at (40, 5).
    private func session() -> SketchSession {
        var s = Sketch()
        s.addRectangle(0, 0, 20, 10, lineIDs: ["B", "R", "T", "L"])
        let c = s.addPoint(40, 5)
        s.addCircle(center: c, radius: 3, id: "C")
        return SketchSession(featureID: "sk", frame: .xy, sketch: s, parameters: ParameterValues())
    }

    /// A click near (not exactly on) a point on the plane, as a real click with a few pixels of tolerance.
    private func click(_ s: SketchSession, _ x: Double, _ y: Double) -> String? {
        for phase in [SketchMouse.Phase.moved, .down] {
            let r = s.handle(SketchMouse(phase: phase, uv: SIMD2(x, y), pick: nil, tolerance: 0.5, gridStep: nil))
            if phase == .down { _ = s.handle(SketchMouse(phase: .up, uv: SIMD2(x, y), pick: nil, tolerance: 0.5)); return r.commit }
        }
        return nil
    }

    @Test func clickingALineTwiceSetsItsLength() {
        let s = session()
        s.setTool(.dimension)
        #expect(click(s, 10, 0.3) == nil, "near the bottom line: picked, waiting")
        #expect(s.pendingLineLength == 20)
        #expect(SketchOverlayBuilder.labels(s).contains { $0.id == DimensionLabel.pendingID })
        #expect(click(s, 10, -0.2) == "Dimension", "the same line again places its length")
        let d = s.sketch.dimensions.last
        #expect(d?.kind == .length("B") && d?.expression == "20 mm")
        #expect(s.editingDimension == d?.id, "and opens it for typing")
        #expect(s.setDimension(d!.id, expression: "25") == "Edit Dimension")
        #expect(s.sketch.lineEnds("B").map { simdLength($0.1 - $0.0) }.map { abs($0 - 25) < 1e-6 } == true,
                "the sketch follows the new value")
    }

    @Test func emptySpaceAlsoPlacesTheLengthAndTwoLinesGiveAnAngleOrDistance() {
        let s = session()
        s.setTool(.dimension)
        _ = click(s, 20.2, 5)               // the right line
        #expect(click(s, 30, 30) == "Dimension")
        #expect(s.sketch.dimensions.last?.kind == .length("R"))
        _ = click(s, 10, 0.2)               // bottom
        #expect(click(s, 10, 9.8) == "Dimension", "bottom and top are parallel: their distance")
        if case .pointLineDistance? = s.sketch.dimensions.last?.kind {} else { Issue.record("expected a distance") }
        #expect(click(s, 43.2, 5) == "Dimension", "a circle takes one click")
        #expect(s.sketch.dimensions.last?.kind == .diameter("C"))
    }

    @Test func everyUndimensionedCurveShowsItsSizeAndAClickMakesItADimension() throws {
        let s = session()
        let refs = SketchOverlayBuilder.labels(s).filter(\.reference)
        #expect(refs.count == 5, "four lines and the circle")
        #expect(refs.contains { $0.text == "⌀ 6 mm" } && refs.contains { $0.text == "20 mm" })
        #expect(s.dimensionReference("T") == "Dimension")
        #expect(s.sketch.dimensions.last?.kind == .length("T") && s.editingDimension != nil)
        let after = SketchOverlayBuilder.labels(s)
        #expect(after.filter(\.reference).count == 4, "the top line now has a real dimension instead")
        #expect(after.contains { !$0.reference && $0.text == "20 mm" })
    }

    @Test func selectPicksCurvesNearTheCursor() {
        let s = session()
        s.setTool(.select)
        _ = click(s, 5, 10.3)
        #expect(s.selection == ["T"], "0.3 mm off the top line still picks it")
        _ = click(s, 0.2, 0.2)
        #expect(s.selection.count == 1 && s.sketch.point(s.selection[0]) != nil, "near a corner: the point wins")
    }

    /// A fixed 20 × 10 rectangle (lines B, R, T, L; corners returned) and a circle "C" of radius 2 centered at (8, 5).
    private func fixedSession() -> (session: SketchSession, corners: [EntityID]) {
        var s = Sketch()
        let r = s.addRectangle(0, 0, 20, 10, lineIDs: ["B", "R", "T", "L"])
        for p in r.corners { s.constrain(.fix(p, x: s.position(p)!.x, y: s.position(p)!.y)) }
        let c = s.addPoint(8, 5)
        s.addCircle(center: c, radius: 2, id: "C")
        return (SketchSession(featureID: "sk", frame: .xy, sketch: s, parameters: ParameterValues()), r.corners)
    }

    @Test func distanceToolPutsACircleAGivenGapFromAnEdge() {
        let (s, _) = fixedSession()
        s.setTool(.distance)
        #expect(click(s, 10, 5) == nil, "the circle's rim: picked, waiting for the second item")
        #expect(s.dimensionPicks == ["C"])
        #expect(click(s, 0.2, 5) == "Dimension", "the left edge: the distance opens for typing")
        let d = s.sketch.dimensions.last
        #expect(d?.kind == .gap("C", "L") && d?.expression == "6 mm", "8 - 2 from the edge")
        #expect(s.editingDimension == d?.id)
        #expect(s.setDimension(d!.id, expression: "4") == "Edit Dimension")
        let center = s.sketch.curve("C").flatMap { s.sketch.center(of: $0.id) }.flatMap { s.sketch.position($0) }
        #expect(center.map { abs($0.x - 6) < 1e-6 && abs($0.y - 5) < 1e-6 } == true, "the circle moved 2 mm toward the edge")
        #expect(s.sketch.radius(of: s.sketch.curve("C")!).map { abs($0 - 2) < 1e-9 } == true, "and kept its size")
        #expect(SketchOverlayBuilder.labels(s).contains { !$0.reference && $0.text == "4 mm" })
    }

    @Test func distanceToolMeasuresACentrePointFromTheMiddle() {
        let (s, _) = fixedSession()
        s.setTool(.distance)
        _ = click(s, 8, 5.1)                  // the circle's center point wins over its rim
        #expect(click(s, 0.2, 5) == "Dimension")
        if case .pointLineDistance? = s.sketch.dimensions.last?.kind {} else { Issue.record("expected a point-to-line distance") }
        #expect(s.sketch.dimensions.last?.expression == "8 mm")
    }

    @Test func distanceToolExplainsWhenThereIsNoSingleDistance() {
        let (s, _) = fixedSession()
        s.setTool(.distance)
        _ = click(s, 10, 0.2)                 // bottom
        #expect(click(s, 19.8, 5) == nil)      // right
        #expect(s.message?.contains("parallel") == true)
        #expect(s.sketch.dimensions.isEmpty && s.dimensionPicks.isEmpty, "nothing added, ready for the next pair")
        _ = click(s, 10, 0.2)
        #expect(click(s, 10, 9.8) == "Dimension", "bottom and top are parallel: their distance")
        #expect(s.sketch.dimensions.last?.expression == "10 mm")
    }

    @Test func aPointDistanceCanBeTakenAcrossOrUp() {
        var sketch = Sketch()
        let corners = sketch.addRectangle(10, 10, 30, 20, lineIDs: ["B", "R", "T", "L"]).corners  // free to move
        let s = SketchSession(featureID: "sk", frame: .xy, sketch: sketch, parameters: ParameterValues())
        s.setTool(.distance)
        _ = click(s, 10.1, 20.1)              // top-left corner
        #expect(click(s, 29.9, 9.9) == "Dimension", "bottom-right corner")
        let id = s.sketch.dimensions.last!.id
        #expect(s.sketch.dimensions.last?.kind == .distance(corners[3], corners[1]))
        #expect(s.distanceDirection(of: id) == .aligned)
        #expect(s.setDistanceDirection(id, .horizontal) == "Edit Dimension")
        #expect(s.sketch.dimensions.last?.kind == .horizontalDistance(corners[3], corners[1]))
        #expect(s.sketch.dimensions.last?.expression == "20 mm")
        #expect(s.setDistanceDirection(id, .vertical) == "Edit Dimension")
        #expect(s.sketch.dimensions.last?.expression == "10 mm")
        #expect(s.setDistanceDirection(id, .vertical) == nil, "already measured that way")
    }

    /// The rectangle (corners free to move, only horizontal and vertical lines) and the circle "C" of radius 2 at (8, 5).
    private func freeSession() -> SketchSession {
        var s = Sketch()
        s.addRectangle(0, 0, 20, 10, lineIDs: ["B", "R", "T", "L"])
        let c = s.addPoint(8, 5)
        s.addCircle(center: c, radius: 2, id: "C")
        return SketchSession(featureID: "sk", frame: .xy, sketch: s, parameters: ParameterValues())
    }

    private func positions(_ s: SketchSession) -> [SIMD2<Double>] { s.sketch.points.map(\.position) }

    @Test func settingADistanceMovesTheCircleAndNeverTheRectangle() {
        let s = freeSession()
        s.setTool(.distance)
        _ = click(s, 10, 5)
        _ = click(s, 0.2, 5)
        let d = s.sketch.dimensions.last!
        let before = s.sketch.points.filter { $0.id != s.sketch.curve("C").flatMap { s.sketch.center(of: $0.id) } }.map(\.position)
        #expect(s.setDimension(d.id, expression: "4") == "Edit Dimension")
        let after = s.sketch.points.filter { $0.id != s.sketch.curve("C").flatMap { s.sketch.center(of: $0.id) } }.map(\.position)
        #expect(before == after, "the rectangle stays exactly where it was")
        #expect(s.sketch.measure(.gap("C", "L")).map { abs($0 - 4) < 1e-6 } == true)
        // Measured to the right edge instead (picked in the other order): still the circle that moves.
        s.setTool(.distance)
        _ = click(s, 20.1, 5)
        _ = click(s, 6, 3.05)
        let r = s.sketch.dimensions.last!
        #expect(r.kind == .gap("C", "R"))
        #expect(s.setDimension(r.id, expression: "3") == "Edit Dimension")
        #expect(s.sketch.lineEnds("R").map { $0.0.x == 20 && $0.1.x == 20 } == true)
    }

    @Test func aDistanceIsDrawnAndItsLineCanBeDragged() {
        let s = freeSession()
        s.setTool(.distance)
        _ = click(s, 10, 5)
        _ = click(s, 0.2, 5)
        let id = s.sketch.dimensions.last!.id
        let line = s.sketch.dimensionLine(of: s.sketch.dimensions.last!)!
        #expect(s.sketch.dimensions.last?.offset != nil, "a new dimension's line stands clear of what it measures")
        #expect(abs(simdLength(line.q2 - line.q1) - 6) < 1e-9 && abs(simdLength(line.p2 - line.p1) - 6) < 1e-9)
        var o = SketchOverlay()
        SketchOverlayBuilder.editing(s, into: &o)
        #expect(o.preview.count == 1 + 2 + 2 * 3, "dimension line, two extension lines and two three-sided arrowheads")

        s.setTool(.select)
        let mid = (line.q1 + line.q2) / 2
        func mouse(_ phase: SketchMouse.Phase, _ uv: SIMD2<Double>) -> (handled: Bool, commit: String?) {
            s.handle(SketchMouse(phase: phase, uv: uv, pick: nil, tolerance: 0.5, gridStep: nil))
        }
        _ = mouse(.moved, mid)
        #expect(s.hoverDimension == id && s.hoverIsDraggable)
        let corners = positions(s)
        #expect(mouse(.down, mid).handled)
        let target = mid + line.normal * 3
        #expect(mouse(.dragged, target).handled)
        #expect(mouse(.up, target).commit == "Move Dimension")
        let moved = s.sketch.dimensionLine(of: s.sketch.dimensions.last!)!
        #expect(abs(moved.offset - (line.offset + 3)) < 1e-9, "the line followed the cursor")
        #expect(positions(s) == corners && s.sketch.measure(.gap("C", "L")).map { abs($0 - 6) < 1e-9 } == true, "the geometry and the value didn't change")
        #expect(SketchOverlayBuilder.labels(s).contains { $0.id == id && $0.text == "6 mm" })
        _ = mouse(.moved, SIMD2(5, 2))
        #expect(s.hoverDimension == nil, "away from any dimension line")
    }
}
