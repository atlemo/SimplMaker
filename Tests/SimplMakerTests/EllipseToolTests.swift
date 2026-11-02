// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// The Ellipse sketch tool: a center, the end of one axis, and how far the other axis reaches.
@Suite @MainActor struct EllipseToolTests {
    private func session() -> SketchSession {
        SketchSession(featureID: IDs.make(), frame: .xy, sketch: Sketch(), parameters: ParameterEvaluator.evaluate([]))
    }

    private func click(_ s: SketchSession, _ x: Double, _ y: Double) -> String? {
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil))
        let down = s.handle(SketchMouse(phase: .down, uv: SIMD2(x, y), pick: nil))
        let up = s.handle(SketchMouse(phase: .up, uv: SIMD2(x, y), pick: nil))
        return down.commit ?? up.commit
    }

    @Test func threeClicksDrawAnEllipseAndItsMajorDimensionIsEditable() {
        let s = session()
        s.setTool(.ellipse)
        _ = click(s, 0, 0)
        _ = click(s, 10, 0)
        #expect(s.sketch.curves.isEmpty, "two clicks are not yet an ellipse")
        _ = click(s, 3, 5)
        #expect(s.sketch.curves.contains { if case .ellipse = $0.geometry { return true } else { return false } })
        #expect(s.editingDimension != nil, "the major axis is ready to type")
    }

    @Test func thePreviewShowsTheEllipseBeforeTheLastClick() {
        let s = session()
        s.setTool(.ellipse)
        _ = click(s, 0, 0)
        _ = click(s, 10, 0)
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(0, 5), pick: nil))
        let points = s.previewPolylines().flatMap { $0 }
        #expect(abs((points.map(\.y).max() ?? 0) - 5) < 1e-6, "the other axis reaches 5 mm to the cursor")
        #expect(abs((points.map(\.x).max() ?? 0) - 10) < 1e-6)
    }

    @Test func aMinorAxisOnTheMajorAxisDrawsNothing() {
        let s = session()
        s.setTool(.ellipse)
        _ = click(s, 0, 0)
        _ = click(s, 10, 0)
        _ = click(s, 5, 0)
        #expect(s.sketch.curves.isEmpty)
        #expect(s.message != nil)
    }
}
