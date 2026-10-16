// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// The Rounded Rectangle and Tangent Arc sketch tools, as they are drawn with the mouse.
@Suite @MainActor struct RoundedRectangleAndTangentArcTests {
    private func session() -> SketchSession {
        SketchSession(featureID: IDs.make(), frame: .xy, sketch: Sketch(), parameters: ParameterEvaluator.evaluate([]))
    }

    private func click(_ s: SketchSession, _ x: Double, _ y: Double) -> String? {
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil))
        let down = s.handle(SketchMouse(phase: .down, uv: SIMD2(x, y), pick: nil))
        let up = s.handle(SketchMouse(phase: .up, uv: SIMD2(x, y), pick: nil))
        return down.commit ?? up.commit
    }

    @Test func roundedRectangleIsAFamilyOfTheRectangleTools() {
        #expect(SketchTool.roundedRectangle.family == [.rectangle, .centerRectangle, .roundedRectangle])
        #expect(SketchTool.forKey("r", current: .centerRectangle) == .roundedRectangle)
        #expect(SketchTool.forKey("r", current: .roundedRectangle) == .rectangle)
    }

    @Test func twoCornersDrawARoundedRectangleOfTheTypedRadius() {
        let s = session()
        s.setTool(.roundedRectangle)
        s.setTyped(.radius, "2")
        _ = click(s, 0, 0)
        _ = click(s, 20, 10)
        #expect(s.sketch.curves.count == 8, "four sides and four corner arcs")
        #expect(s.sketch.dimensions.filter { if case .radius = $0.kind { return true } else { return false } }.count == 1)
        #expect(s.roundedRadius == "2 mm")
    }

    @Test func aRadiusTooBigForTheRectangleDrawsNothingAndSaysWhy() {
        let s = session()
        s.setTool(.roundedRectangle)
        s.setTyped(.radius, "9")
        _ = click(s, 0, 0)
        _ = click(s, 20, 10)
        #expect(s.sketch.curves.isEmpty)
        #expect(s.message != nil)
    }

    @Test func aTangentArcMustStartOnAFreeEnd() {
        let s = session()
        s.setTool(.tangentArc)
        _ = click(s, 50, 50)
        #expect(s.sketch.curves.isEmpty)
        #expect(s.message != nil)
    }
}
