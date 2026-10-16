// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// Placing an angle between two lines: the wedge follows the cursor, and the typed value is set afterwards.
@Suite @MainActor struct AnglePlacementTests {
    /// Two lines from the origin: along x (20 long) and up to (10, 15).
    private func session() -> SketchSession {
        var s = Sketch()
        let a = s.addPoint(0, 0), b = s.addPoint(20, 0), c = s.addPoint(10, 15)
        s.addLine(a, b, id: "X")
        s.addLine(a, c, id: "Y")
        return SketchSession(featureID: "sk", frame: .xy, sketch: s, parameters: ParameterValues())
    }

    private func move(_ s: SketchSession, _ x: Double, _ y: Double) {
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil, tolerance: 0.5, gridStep: nil))
    }

    private func click(_ s: SketchSession, _ x: Double, _ y: Double) -> String? {
        move(s, x, y)
        let r = s.handle(SketchMouse(phase: .down, uv: SIMD2(x, y), pick: nil, tolerance: 0.5, gridStep: nil))
        _ = s.handle(SketchMouse(phase: .up, uv: SIMD2(x, y), pick: nil, tolerance: 0.5))
        return r.commit
    }

    /// The wedge on the far side of the corner: the supplement of the turn from X to Y (56° turn, so 124° there).
    @Test func theCursorPicksTheSupplementWedgeOnItsSide() {
        let s = session()
        s.setTool(.dimension)
        _ = click(s, 10, 0.2)                       // line X
        _ = click(s, 5, 7.5)                        // line Y
        move(s, -8, 9)                              // up and to the left of the corner: between Y and the far side of X
        let turned = s.anglePreview
        #expect(turned?.kind == .supplementAngle("X", "Y"))
        #expect(abs((turned?.value ?? 0) - (.pi - atan2(15, 10))) < 1e-9)
        move(s, 6, 3)                               // right of the corner: the turn itself
        #expect(s.anglePreview?.kind == .angle("X", "Y"))
        move(s, -8, 9)
        #expect(click(s, -8, 9) == "Dimension")
        let d = s.sketch.dimensions.last!
        #expect(s.setDimension(d.id, expression: "80") == "Edit Dimension", "80 on the left wedge is accepted")
        #expect(abs((s.sketch.measure(d.kind) ?? 0) - 80 * .pi / 180) < 1e-5)
    }

    @Test func aPlacedAngleCanBeSetToATypedValue() {
        let s = session()
        s.setTool(.dimension)
        _ = click(s, 10, 0.2)                       // line X
        _ = click(s, 5, 7.5)                        // line Y: the angle waits for a place
        #expect(s.anglePicks != nil, "two lines wait for the placing click")
        move(s, 4, 3)                               // cursor in the small wedge (about 56°)
        #expect(s.anglePreview != nil)
        let preview = s.anglePreview!.value
        #expect(click(s, 4, 3) == "Dimension")
        let d = s.sketch.dimensions.last!
        #expect(s.anglePicks == nil)
        #expect(abs((s.sketch.measure(d.kind) ?? 0) - preview) < 1e-5, "placed at the previewed value (solver tolerance)")
        #expect(d.offset != nil, "the placed radius is kept")
        #expect(s.setDimension(d.id, expression: "80") == "Edit Dimension", "typed 80 is accepted")
        let v = s.sketch.measure(s.sketch.dimensions.last!.kind) ?? 0
        #expect(abs(v - 80 * .pi / 180) < 1e-6, "the sketch now has an 80° angle")
    }
}
