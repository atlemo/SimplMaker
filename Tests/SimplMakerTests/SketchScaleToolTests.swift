// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import SimplMaker

/// A sketch of hundreds of curves (an imported drawing, a perforated plate): the work done on every cursor move and
/// every frame while sketching must not grow with the square of that. These limits are far above what it takes (in a
/// debug build, a few milliseconds each) and far below what it took when it did.
@Suite @MainActor struct SketchScaleToolTests {
    private func busy() -> SketchSession {
        var sketch = Sketch()
        for i in 0..<150 {
            _ = sketch.addRectangle(Double(i % 25) * 4, Double(i / 25) * 4, Double(i % 25) * 4 + 2.5, Double(i / 25) * 4 + 2.5)
        }
        for k in 0..<100 {
            let c = sketch.addPoint(200 + Double(k % 10) * 5, Double(k / 10) * 5)
            _ = sketch.addCircle(center: c, radius: 1.5)
        }
        return SketchSession(featureID: IDs.make(), frame: .xy, sketch: sketch, parameters: ParameterEvaluator.evaluate([]))
    }

    private func seconds(_ body: () -> Void) -> Double {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    @Test(arguments: [SketchTool.line, .circle, .rectangle, .point, .trim, .dimension])
    func cursorMovesStayQuickOnABusySketch(tool: SketchTool) {
        let s = busy()
        #expect(s.sketch.curves.count >= 700)
        s.setTool(tool)
        let took = seconds {
            for k in 0..<20 {
                _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(Double(k) * 1.7 + 0.31, Double(k % 7) * 3.3 + 0.17), pick: nil,
                                         tolerance: 0.3, gridStep: 1))
            }
        }
        #expect(took < 1.5, "20 moves with the \(tool.rawValue) tool took \(took) s")
    }

    @Test func theOverlayLabelsAndGlyphsStayQuickOnABusySketch() {
        let s = busy()
        s.setTool(.line)
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(3, 3), pick: nil, tolerance: 0.3, gridStep: 1))
        var labels = 0
        let took = seconds {
            for _ in 0..<10 {
                var o = SketchOverlay()
                SketchOverlayBuilder.editing(s, into: &o)
                labels = SketchOverlayBuilder.labels(s).count
                _ = SketchOverlayBuilder.glyphs(s)
            }
        }
        #expect(labels > 500, "every undimensioned curve still shows its size")
        #expect(took < 3, "10 frames took \(took) s")
    }

    @Test func theMeasuredSizesAreWorkedOutAgainOnlyWhenTheSketchChanges() {
        let s = busy()
        let first = s.referenceMeasurements
        let again = seconds { for _ in 0..<200 { _ = s.referenceMeasurements } }
        #expect(again < 0.5, "200 lookups of an unchanged sketch took \(again) s")
        #expect(s.referenceMeasurements.count == first.count)
        s.setTool(.line)
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(300, 300), pick: nil, tolerance: 0.3, gridStep: 1))
        _ = s.handle(SketchMouse(phase: .down, uv: SIMD2(300, 300), pick: nil, tolerance: 0.3, gridStep: 1))
        _ = s.handle(SketchMouse(phase: .up, uv: SIMD2(300, 300), pick: nil, tolerance: 0.3, gridStep: 1))
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(310, 300), pick: nil, tolerance: 0.3, gridStep: 1))
        _ = s.handle(SketchMouse(phase: .down, uv: SIMD2(310, 300), pick: nil, tolerance: 0.3, gridStep: 1))
        _ = s.handle(SketchMouse(phase: .up, uv: SIMD2(310, 300), pick: nil, tolerance: 0.3, gridStep: 1))
        #expect(s.referenceMeasurements.count == first.count + 1, "the new line's length shows")
    }
}
