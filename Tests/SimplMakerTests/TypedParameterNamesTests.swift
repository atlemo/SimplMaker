// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// A parameter name typed in a sketch field is what the sketch keeps, not the number it stands for now: the
/// drawing tools are covered in TypedInputTests, the Offset, Pattern and Gear tools here.
@Suite @MainActor struct TypedParameterNamesTests {
    private let params = ParameterEvaluator.evaluate([
        Parameter("gap", "7 mm"), Parameter("n", "4", unit: .none), Parameter("sweep", "180 deg", unit: .angle),
        Parameter("tooth", "2 mm"), Parameter("press", "25 deg", unit: .angle)])

    private func square() -> SketchSession {
        var s = Sketch()
        s.addRectangle(0, 0, 10, 10, lineIDs: ["B", "R", "T", "L"])
        return SketchSession(featureID: "sk", frame: .xy, sketch: s, parameters: params)
    }

    @Test func offsetKeepsTheTypedParameter() {
        let s = square()
        s.selection = ["B", "R", "T", "L"]
        s.beginOffset()
        s.setTyped(.offsetDistance, "gap")
        #expect(s.commitTyped() != nil)
        let offsets = s.sketch.dimensions.map(\.expression)
        #expect(!offsets.isEmpty && offsets.allSatisfy { $0.contains("gap") }, "offset dimensions are \(offsets)")
    }

    @Test func rectangularPatternKeepsTheTypedParameters() {
        let s = square()
        s.selection = ["B", "R", "T", "L"]
        s.beginPattern()
        s.setTyped(.countX, "n")
        s.setTyped(.spacingX, "gap")
        s.setTyped(.countY, "n")
        s.setTyped(.spacingY, "gap * 2")
        #expect(s.commitTyped() != nil)
        let p = s.sketch.patterns.first
        #expect(p?.countX == "n" && p?.countY == "n" && p?.spacingX == "gap" && p?.spacingY == "gap * 2", "pattern is \(String(describing: p))")
    }

    @Test func gearKeepsTheTypedParameters() {
        let s = SketchSession(featureID: "sk", frame: .xy, sketch: Sketch(), parameters: params)
        s.setTool(.gear)
        s.setTyped(.module, "tooth")
        s.setTyped(.pressureAngle, "press")
        s.setTyped(.teeth, "n * 4")
        _ = s.commitTyped()
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(10, 5), pick: nil))
        _ = s.handle(SketchMouse(phase: .down, uv: SIMD2(10, 5), pick: nil))
        _ = s.handle(SketchMouse(phase: .up, uv: SIMD2(10, 5), pick: nil))
        let g = s.activeGear
        #expect(g?.module == "tooth" && g?.pressureAngle == "press" && g?.teeth == "n * 4", "gear is \(String(describing: g))")
    }
}
