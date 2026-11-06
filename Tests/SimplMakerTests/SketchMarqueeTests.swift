// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// Dragging a box over a sketch selects what it covers: wholly inside from left to right, also what it touches
/// from right to left.
@Suite @MainActor struct SketchMarqueeTests {
    private func session() -> SketchSession {
        let s = SketchSession(featureID: IDs.make(), frame: .xy, sketch: Sketch(), parameters: ParameterEvaluator.evaluate([]))
        s.setTool(.line)
        for (x, y) in [(0.0, 0.0), (10, 0), (10, 10), (0, 10), (0, 0)] {
            _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil))
            _ = s.handle(SketchMouse(phase: .down, uv: SIMD2(x, y), pick: nil))
            _ = s.handle(SketchMouse(phase: .up, uv: SIMD2(x, y), pick: nil))
        }
        s.setTool(.select)
        s.selection = []
        return s
    }

    private func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [SIMD2<Double>] {
        [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)]
    }

    @Test func aBoxAroundEverythingTakesEveryCurve() {
        let s = session()
        let lines = s.sketch.curves.count
        #expect(lines >= 4)
        s.marqueeSelect(box(-5, -5, 15, 15), crossing: false, additive: false)
        #expect(s.selection.count == lines)
    }

    @Test func aBoxThatOnlyTouchesTakesNothingUnlessCrossing() {
        let s = session()
        s.marqueeSelect(box(4, -3, 6, 3), crossing: false, additive: false)
        #expect(s.selection.isEmpty)
        s.marqueeSelect(box(4, -3, 6, 3), crossing: true, additive: false)
        #expect(s.selection.count == 1, "only the bottom side crosses it")
    }

    @Test func additiveKeepsWhatWasSelected() {
        let s = session()
        s.marqueeSelect(box(4, -3, 6, 3), crossing: true, additive: false)
        s.marqueeSelect(box(4, 7, 6, 13), crossing: true, additive: true)
        #expect(s.selection.count == 2)
    }
}
