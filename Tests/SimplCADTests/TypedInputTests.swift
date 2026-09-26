// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// Typing sizes while drawing, and typing a feature's size next to its drag handle.
@Suite @MainActor struct TypedInputTests {
    private func session(_ params: [Parameter] = []) -> SketchSession {
        SketchSession(featureID: IDs.make(), frame: .xy, sketch: Sketch(), parameters: ParameterEvaluator.evaluate(params))
    }

    private func click(_ s: SketchSession, _ x: Double, _ y: Double) {
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil))
        _ = s.handle(SketchMouse(phase: .down, uv: SIMD2(x, y), pick: nil))
        _ = s.handle(SketchMouse(phase: .up, uv: SIMD2(x, y), pick: nil))
    }

    private func move(_ s: SketchSession, _ x: Double, _ y: Double) {
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil))
    }

    @Test func lineTakesTypedLengthAndAngle() throws {
        let s = session()
        s.setTool(.line)
        #expect(s.inputFields.isEmpty)
        click(s, 0, 0)
        #expect(s.inputFields == [.length, .angle])
        move(s, 10, 1)
        #expect(abs((s.liveValue(.length) ?? 0) - (101.0).squareRoot()) < 1e-9)

        s.setTyped(.length, "25")
        s.setTyped(.angle, "30")
        let end = try #require(s.target()).position
        #expect(abs(end.x - 25 * cos(.pi / 6)) < 1e-9 && abs(end.y - 12.5) < 1e-9)

        #expect(s.commitTyped() == "Line")
        #expect(s.typed.isEmpty)
        #expect(s.inputFields == [.length, .angle])  // the chain continues from the new end
        let line = try #require(s.sketch.curves.first)
        #expect(s.sketch.dimensions.map(\.expression) == ["25 mm"])
        #expect(s.sketch.dimensions.first?.kind == .length(line.id))
        let ends = try #require(s.sketch.lineEnds(line.id))
        #expect(abs(simdLength(ends.1 - ends.0) - 25) < 1e-6)
    }

    @Test func rectangleKeepsTheCursorsQuadrantAndParameters() throws {
        let s = session([Parameter("h", "20 mm")])
        s.setTool(.rectangle)
        click(s, 0, 0)
        move(s, -5, -3)
        s.setTyped(.width, "40")
        s.setTyped(.height, "h")
        #expect(s.liveValue(.height) == 20)
        #expect(s.commitTyped() == "Rectangle")
        #expect(Set(s.sketch.dimensions.map(\.expression)) == ["40 mm", "h"])
        #expect(s.solve?.status == .solved)
        let xs = s.sketch.points.map(\.position.x), ys = s.sketch.points.map(\.position.y)
        #expect(abs((xs.min() ?? 0) + 40) < 1e-6 && abs((ys.min() ?? 0) + 20) < 1e-6)
    }

    @Test func circleDiameterAndArcRadiusBecomeDimensions() throws {
        let c = session()
        c.setTool(.circle)
        click(c, 0, 0)
        move(c, 1, 1)
        c.setTyped(.diameter, "10")
        #expect(c.commitTyped() == "Circle")
        let circle = try #require(c.sketch.curves.first)
        #expect(c.sketch.radius(of: circle).map { abs($0 - 5) < 1e-9 } == true)
        #expect(c.sketch.dimensions.first?.kind == .diameter(circle.id))

        let a = session()
        a.setTool(.arc)
        click(a, 0, 0)
        move(a, 0, 3)
        a.setTyped(.radius, "8")
        #expect(a.commitTyped() == nil)  // the start point; the arc isn't done yet
        #expect(a.inputFields == [.sweep])
        a.setTyped(.sweep, "90")
        #expect(a.commitTyped() == "Arc")
        let arc = try #require(a.sketch.curves.first)
        #expect(a.sketch.radius(of: arc).map { abs($0 - 8) < 1e-6 } == true)
        #expect(a.sketch.dimensions.map(\.expression) == ["8 mm"])
    }

    @Test func unusableTextIsIgnoredAndEscapeClearsIt() throws {
        let s = session()
        s.setTool(.line)
        click(s, 0, 0)
        move(s, 3, 4)
        s.setTyped(.length, "abc")
        #expect(s.typedIsInvalid(.length))
        #expect(s.target()?.position == SIMD2(3, 4))  // still follows the cursor
        s.setTyped(.length, "-2")
        #expect(s.typedIsInvalid(.length))
        s.setTyped(.length, "")
        #expect(s.typed.isEmpty)
        s.setTyped(.length, "7")
        s.escape()
        #expect(s.typed.isEmpty && s.inputFields.isEmpty)
    }

    @Test func handleFieldPreviewsAndCommitsTypedSizes() async throws {
        let model = DocumentModel(document: .demo())
        for _ in 0..<500 where model.result == nil { try await Task.sleep(for: .milliseconds(10)) }
        let extrude = try #require(model.document.features.first { if case .extrude = $0.kind { true } else { false } })
        model.selectedFeature = extrude.id
        let h = try #require(model.dragHandle)
        #expect(model.handleFieldText == h.expression)

        #expect(!model.commitHandle("abc"))
        #expect(!model.commitHandle("0"), "zero is not a distance (negative ones are: they extrude the other way)")
        #expect(model.previewHandle("30"))
        model.cancelHandleEdit()
        #expect(model.commitHandle("30"))
        let f = try #require(model.document.features.first { $0.id == extrude.id })
        guard case .extrude(let e) = f.kind else { Issue.record("expected an extrude"); return }
        switch e.extent {
        case .distance(let d), .twoSides(let d, _): #expect(d == "30 mm")
        case .symmetric(let d): #expect(d == "30 mm")
        }
        // Let the last rebuild finish: a kernel call still running when the test process exits crashes it.
        for _ in 0..<500 where model.isRegenerating { try await Task.sleep(for: .milliseconds(10)) }
    }
}
