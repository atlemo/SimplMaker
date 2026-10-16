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

    /// Typing the value places the angle on the wedge the cursor was in when typing started; moving on doesn't change it.
    @Test func typingAnAngleSetsTheWedgeTheCursorWasIn() {
        let s = session()
        s.setTool(.dimension)
        _ = click(s, 10, 0.2)                       // line X
        _ = click(s, 5, 7.5)                        // line Y
        move(s, 6, 3)                               // right of the corner: the turn from X to Y
        s.setTyped(.angle, "80")
        move(s, -8, 9)                              // the cursor moves on, but the wedge stays
        #expect(s.commitTyped() == "Dimension")
        let d = s.sketch.dimensions.last!
        #expect(d.kind == .angle("X", "Y"))
        #expect(abs((s.sketch.measure(d.kind) ?? 0) - 80 * .pi / 180) < 1e-5)
        #expect(s.anglePicks == nil)
    }

    /// A placed angle stays on the side it was placed, when its value changes and the lines move.
    @Test func aPlacedAngleKeepsItsWedgeWhenTheLinesMove() {
        let s = session()
        s.setTool(.dimension)
        _ = click(s, 10, 0.2)                       // line X
        _ = click(s, 5, 7.5)                        // line Y
        move(s, -8, 9)                              // left of the corner
        #expect(click(s, -8, 9) == "Dimension")
        let d = s.sketch.dimensions.last!
        let before = s.sketch.angleArc(of: d, size: 0.5)!.middle
        #expect(cos(before - atan2(9, -8)) > 0.9, "placed on the cursor's side")
        #expect(s.setDimension(d.id, expression: "70") == "Edit Dimension")
        let after = s.sketch.angleArc(of: s.sketch.dimensions.last!, size: 0.5)!.middle
        #expect(cos(after - atan2(9, -8)) > 0.9, "still on that side after the value changed")
    }

    /// Dragging a placed angle's value moves its arc out along the wedge, like a linear dimension's line.
    @Test func aPlacedAngleDragsOutAlongItsWedge() {
        let s = session()
        s.setTool(.dimension)
        _ = click(s, 10, 0.2)
        _ = click(s, 5, 7.5)
        move(s, 4, 3)
        #expect(click(s, 4, 3) == "Dimension")
        let d = s.sketch.dimensions.last!
        s.setTool(.select)
        let arc = s.sketch.angleArc(of: d, size: 0.5)!
        let dir = SIMD2(cos(arc.middle), sin(arc.middle))
        let on = arc.center + arc.radius * dir
        move(s, on.x, on.y)
        #expect(s.hoverDimension == d.id, "the arc is the handle")
        _ = s.handle(SketchMouse(phase: .down, uv: on, pick: nil, tolerance: 0.5, gridStep: nil))
        let far = arc.center + (arc.radius * 2) * dir
        _ = s.handle(SketchMouse(phase: .dragged, uv: far, pick: nil, tolerance: 0.5, gridStep: nil))
        _ = s.handle(SketchMouse(phase: .up, uv: far, pick: nil, tolerance: 0.5))
        let moved = s.sketch.dimensions.first { $0.id == d.id }!
        #expect(abs((moved.offset ?? 0) - arc.radius * 2) < 1e-6, "the arc ends under the cursor, at twice its radius")
        let after = s.sketch.angleArc(of: moved, size: 0.5)!
        #expect(abs(after.middle - arc.middle) < 1e-6, "same wedge")
    }

    /// Grabbing the arc off its middle line must not move the arc until the cursor does: it follows the cursor's movement.
    @Test func aPlacedAngleDoesNotJumpToTheCursorWhenGrabbedOffItsMiddle() {
        let s = session()
        s.setTool(.dimension)
        _ = click(s, 10, 0.2)
        _ = click(s, 5, 7.5)
        move(s, 4, 3)
        #expect(click(s, 4, 3) == "Dimension")
        let d = s.sketch.dimensions.last!
        s.setTool(.select)
        let arc = s.sketch.angleArc(of: d, size: 0.5)!
        let dir = SIMD2(cos(arc.middle), sin(arc.middle))
        let grab = arc.center + arc.radius * SIMD2(cos(arc.middle + 0.3), sin(arc.middle + 0.3))  // 0.3 rad off the middle, inside the sweep
        move(s, grab.x, grab.y)
        #expect(s.hoverDimension == d.id)
        let before = s.sketch.dimensions.first { $0.id == d.id }?.offset ?? 0

        func drag(to p: SIMD2<Double>) {
            _ = s.handle(SketchMouse(phase: .down, uv: grab, pick: nil, tolerance: 0.5, gridStep: nil))
            _ = s.handle(SketchMouse(phase: .dragged, uv: p, pick: nil, tolerance: 0.5, gridStep: nil))
            _ = s.handle(SketchMouse(phase: .up, uv: p, pick: nil, tolerance: 0.5))
        }
        drag(to: grab)                                        // no movement: nothing changes
        let still = s.sketch.dimensions.first { $0.id == d.id }?.offset ?? 0
        #expect(abs(still - before) < 1e-6, "the arc stays put under the cursor")

        drag(to: grab + dir)                                  // 1 mm straight out along the middle
        let out = s.sketch.dimensions.first { $0.id == d.id }?.offset ?? 0
        #expect(abs((out - before) - 1) < 1e-6, "it moves by the cursor's own 1 mm")
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
