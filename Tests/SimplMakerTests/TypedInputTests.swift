// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

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

    @Test func twoPointCircleSpansItsDiameter() throws {
        let c = session()
        c.setTool(.circle2Point)
        click(c, 0, 0)
        click(c, 10, 0)
        let circle = try #require(c.sketch.curves.first)
        guard case .circle(let center, _) = circle.geometry else { Issue.record("expected a circle"); return }
        #expect(c.sketch.position(center).map { simdLength($0 - SIMD2(5, 0)) < 1e-6 } == true)
        #expect(c.sketch.radius(of: circle).map { abs($0 - 5) < 1e-6 } == true)

        let typed = session()
        typed.setTool(.circle2Point)
        click(typed, 0, 0)
        move(typed, 0, 1)
        #expect(typed.liveValue(.diameter).map { abs($0 - 1) < 1e-6 } == true, "the distance between the two points")
        typed.setTyped(.diameter, "12")
        #expect(typed.commitTyped() == "Circle")
        let d = try #require(typed.sketch.curves.first)
        #expect(typed.sketch.radius(of: d).map { abs($0 - 6) < 1e-6 } == true)

        #expect(SketchTool.forKey("c", current: .circle) == .circle2Point)
        #expect(SketchTool.forKey("c", current: .circle2Point) == .circle)
        #expect(SketchTool.forKey("c", current: .line) == .circle)
    }

    @Test func drawingSnapsToTheMiddleOfARectangle() throws {
        let c = session()
        c.setTool(.rectangle)
        click(c, 0, 0)
        click(c, 30, 20)
        c.setTool(.circle)
        move(c, 15.2, 9.9)
        #expect(c.lastSnap?.kind == .center && c.lastSnap.map { simdLength($0.position - SIMD2(15, 10)) < 1e-9 } == true)
        click(c, 15.2, 9.9)
        click(c, 20, 10)
        let circle = try #require(c.sketch.curves.first { if case .circle = $0.geometry { return true }; return false })
        let center = try #require(c.sketch.center(of: circle.id).flatMap { c.sketch.position($0) })
        #expect(simdLength(center - SIMD2(15, 10)) < 1e-6)
    }

    @Test func centerRectangleStaysCentred() throws {
        let c = session()
        c.setTool(.centerRectangle)
        click(c, 10, 10)
        move(c, 15, 12)
        #expect(c.liveValue(.width).map { abs($0 - 10) < 1e-6 } == true, "the whole width, twice the cursor's reach")
        c.setTyped(.width, "30")
        c.setTyped(.height, "20")
        #expect(c.commitTyped() == "Rectangle")
        let lines = c.sketch.curves.filter { !$0.construction }
        #expect(lines.count == 4 && c.sketch.curves.filter(\.construction).count == 1, "four sides and the diagonal")
        let xs = lines.compactMap { c.sketch.lineEnds($0.id) }.flatMap { [$0.0.x, $0.1.x] }
        #expect(abs((xs.min() ?? 0) + (xs.max() ?? 0) - 20) < 1e-6 && abs((xs.max() ?? 0) - (xs.min() ?? 0) - 30) < 1e-6)
        #expect(c.sketch.dimensions.map(\.expression).sorted() == ["20 mm", "30 mm"])
        #expect(SketchTool.forKey("r", current: .rectangle) == .centerRectangle && SketchTool.forKey("r", current: .line) == .rectangle)
    }

    @Test func threePointArcPassesThroughAllThree() throws {
        for (end, through) in [(SIMD2(20.0, 0), SIMD2(10.0, 10)), (SIMD2(20.0, 0), SIMD2(10.0, -10))] {
            let c = session()
            c.setTool(.arc3Point)
            click(c, 0, 0)
            click(c, end.x, end.y)
            move(c, through.x, through.y)
            #expect(c.previewPolylines().first.map { $0.count > 10 } == true)
            click(c, through.x, through.y)
            let arc = try #require(c.sketch.curves.first)
            let g = try #require(c.sketch.geometry(of: arc.id))
            let ends = [g.point(0), g.point(1)]
            #expect(ends.contains { simdLength($0) < 1e-6 } && ends.contains { simdLength($0 - end) < 1e-6 })
            #expect(simdLength(g.point(0.5) - through) < 1e-6, "the arc bends the way of the third click")
        }
        #expect(SketchTool.forKey("a", current: .arc) == .arc3Point)
    }

    /// Presses at (x, y), drags to (toX, toY) and lets go.
    private func drag(_ s: SketchSession, _ x: Double, _ y: Double, to toX: Double, _ toY: Double) {
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(x, y), pick: nil))
        _ = s.handle(SketchMouse(phase: .down, uv: SIMD2(x, y), pick: nil))
        _ = s.handle(SketchMouse(phase: .dragged, uv: SIMD2(toX, toY), pick: nil))
        _ = s.handle(SketchMouse(phase: .up, uv: SIMD2(toX, toY), pick: nil))
    }

    @Test func splineIsItsOwnToolWithItsOwnKey() {
        #expect(SketchTool.bezier.family == [.bezier] && SketchTool.line.family == [.line])
        #expect(SketchTool.forKey("b", current: .select) == .bezier && SketchTool.forKey("l", current: .bezier) == .line)
        #expect(SketchTool.bezier.shortTitle == "Spline" && SketchTool.draw.contains(.bezier))
    }

    @Test func curveToolChainsSmoothCurvesPointByPoint() throws {
        let c = session()
        c.setTool(.bezier)
        click(c, 0, 0)
        #expect(c.sketch.curves.isEmpty, "the first point only starts the run")
        click(c, 10, 8)
        #expect(c.sketch.curves.count == 1 && c.clicks.count == 1)
        move(c, 20, -4)
        #expect(c.previewPolylines().count >= 6, "the last curve turning to meet the cursor, and the new one, with handles")
        #expect(c.redrawnCurves.count == 1, "the committed curve it redraws isn't drawn twice")
        click(c, 20, -4)
        click(c, 30, 6)
        #expect(c.sketch.curves.count == 3)
        let ends = c.sketch.curves.compactMap { c.sketch.geometry(of: $0.id) }
        #expect(ends.count == 3)
        let pass = [SIMD2(10.0, 8), SIMD2(20, -4)]
        for p in pass { #expect(ends.contains { simdLength($0.point(1) - p) < 1e-9 }, "passes through each point clicked") }
        c.escape()
        #expect(c.curveChain == nil && c.clicks.isEmpty && c.sketch.curves.count == 3, "Esc ends the run and keeps the curves")
    }

    @Test func draggingOnAPointPullsOutItsHandle() throws {
        let c = session()
        c.setTool(.bezier)
        click(c, 0, 0)
        drag(c, 20, 0, to: 20, 6)
        let curve = try #require(c.sketch.curves.first)
        guard case .bezier(_, _, let c2, let end) = curve.geometry else { Issue.record("expected a Bézier"); return }
        let handle = try #require(c.sketch.position(c2)), anchor = try #require(c.sketch.position(end))
        #expect(simdLength(anchor - SIMD2(20, 0)) < 1e-9)
        #expect(simdLength(handle - SIMD2(20, -6)) < 1e-9, "the curve arrives along the pulled handle's mirror")
        // The pulled handle goes on being the way out of that point.
        click(c, 40, 0)
        let second = try #require(c.sketch.curves.last)
        guard case .bezier(_, let out, _, _) = second.geometry else { Issue.record("expected a Bézier"); return }
        #expect(try simdLength(#require(c.sketch.position(out)) - SIMD2(20, 6)) < 1e-9)
    }

    @Test func aTinyDragIsJustAClick() throws {
        let c = session()
        c.setTool(.bezier)
        click(c, 0, 0)
        drag(c, 20, 0, to: 20.0001, 0.0001)
        #expect(c.curveChain?.pulled.isEmpty == true)
    }

    @Test func clickingTheFirstPointClosesTheShape() throws {
        let c = session()
        c.setTool(.bezier)
        for p in [(0.0, 0.0), (20, 0), (20, 20), (0, 20)] { click(c, p.0, p.1) }
        #expect(c.sketch.curves.count == 3)
        click(c, 0.2, 0.1)  // near the first point: snaps to it
        #expect(c.sketch.curves.count == 4 && c.curveChain == nil && c.clicks.isEmpty)
        let starts = c.sketch.curves.compactMap { cu -> EntityID? in
            if case .bezier(let a, _, _, _) = cu.geometry { return a }
            return nil
        }
        let ends = c.sketch.curves.compactMap { cu -> EntityID? in
            if case .bezier(_, _, _, let b) = cu.geometry { return b }
            return nil
        }
        #expect(Set(starts) == Set(ends), "a closed loop: every point is the end of one curve and the start of the next")
    }

    @Test func theCurveDoesNotSnapToItsOwnHandles() throws {
        let c = session()
        c.setTool(.bezier)
        click(c, 0, 0)
        click(c, 30, 0)
        let handle = try #require(c.curveChain?.segments.first?.control1)
        let at = try #require(c.sketch.position(handle))
        move(c, at.x, at.y)
        #expect(c.snap(at).point == nil, "a click there is a new point, not a handle")
    }

    @Test func undoingMidCurveStartsOver() throws {
        let c = session()
        c.setTool(.bezier)
        click(c, 0, 0)
        click(c, 10, 5)
        #expect(c.curveChain != nil)
        c.reload(Sketch(), parameters: ParameterEvaluator.evaluate([]))
        #expect(c.curveChain == nil && c.clicks.isEmpty)
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
        case .throughAll, .toFace: Issue.record("expected a distance")
        }
        // Let the last rebuild finish: a kernel call still running when the test process exits crashes it.
        for _ in 0..<500 where model.isRegenerating { try await Task.sleep(for: .milliseconds(10)) }
    }
}
