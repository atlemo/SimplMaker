// SPDX-License-Identifier: GPL-3.0-or-later
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
}
