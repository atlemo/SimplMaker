// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// The sketch Offset tool: it shows the offset with an arrow to drag and a field to type in, and keeps it on Return.
@Suite @MainActor struct OffsetToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A model editing a sketch with a 10 × 4 rectangle (counter-clockwise lines) and a spline run (two Béziers
    /// that bend smoothly), and the ids of each.
    private func editing() async throws -> (model: DocumentModel, session: SketchSession, rect: [EntityID], spline: [EntityID]) {
        var s = Sketch()
        let (lines, _) = s.addRectangle(0, 0, 10, 4)
        let a = s.addPoint(0, 20), b = s.addPoint(20, 20), c = s.addPoint(30, 30)
        let first = s.addBezier(start: a, control1: s.addPoint(8, 20), control2: s.addPoint(12, 20), end: b)
        let second = s.addBezier(start: b, control1: s.addPoint(24, 20), control2: s.addPoint(30, 24), end: c)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        return (model, try #require(model.sketchSession), lines, [first, second])
    }

    private func committed(_ model: DocumentModel) -> Sketch? {
        if case .sketch(let sf)? = model.document.features.first?.kind { return sf.sketch }
        return nil
    }

    private func lineCount(_ s: Sketch) -> Int { s.curves.filter { if case .line = $0.geometry { return true }; return false }.count }
    private func bezierCount(_ s: Sketch) -> Int { s.curves.filter { if case .bezier = $0.geometry { return true }; return false }.count }

    /// The x extent of a sketch's lines.
    private func xRange(_ s: Sketch) -> ClosedRange<Double> {
        let xs = s.curves.compactMap { c -> [Double]? in
            guard case .line = c.geometry, case .line(let a, let b)? = s.geometry(of: c.id) else { return nil }
            return [a.x, b.x]
        }.flatMap { $0 }
        return xs.min()!...xs.max()!
    }

    @Test func theButtonShowsAnOffsetWithAnArrowAndAField() async throws {
        let (model, session, rect, _) = try await editing()
        let before = try #require(committed(model))
        session.selection = rect
        model.beginSketchOffset()
        #expect(session.isOffsetting && session.offsetDistance == 2)
        #expect(session.inputFields == [.offsetDistance])
        #expect(lineCount(session.sketch) == 8, "the offset is shown over the original")
        #expect(committed(model) == before, "but nothing is stored yet")
        let place = try #require(model.manipulatorPlacement)
        #expect(place.frame.arrows == [.x] && place.frame.rings.isEmpty && place.frame.squares.isEmpty, "one arrow")
        // The arrow stands on the offset curve and points outward from a counter-clockwise rectangle.
        let handle = try #require(session.offsetHandle)
        let middle = try #require(session.manipulatorMiddle)
        #expect(simdLength(middle - (handle.origin + handle.direction * 2)) < 1e-9)
        #expect(abs(simdLength(handle.direction) - 1) < 1e-9)
    }

    @Test func draggingTheArrowChangesTheDistanceLiveAndReleaseKeepsItOpen() async throws {
        let (model, session, rect, _) = try await editing()
        session.selection = rect
        model.beginSketchOffset()
        #expect(model.manipulatorDragStart?.move.x == 2)
        #expect(session.beginManipulatorDrag(.axis(.x)))
        var v = TransformValues()
        v.move = SIMD3(5, 0, 0)
        model.previewManipulator(v)
        #expect(xRange(session.sketch) == -5...15, "five millimetres out on every side: \(xRange(session.sketch))")
        #expect(session.offsetDistance == 5)
        model.endManipulatorDrag()
        #expect(session.isOffsetting, "letting go leaves the offset open for more changes")
        #expect(committed(model).map(lineCount) == 4, "and stores nothing")
    }

    @Test func draggingBackThroughTheCurveGoesTheOtherWay() async throws {
        let (model, session, rect, _) = try await editing()
        session.selection = rect
        model.beginSketchOffset()
        #expect(session.beginManipulatorDrag(.axis(.x)))
        var v = TransformValues()
        v.move = SIMD3(-1, 0, 0)
        model.previewManipulator(v)
        #expect(xRange(session.sketch) == 0...10, "the original is 0…10; the offset (inside) is 1…9")
        #expect(lineCount(session.sketch) == 8)
        let inner = session.sketch.curves.compactMap { c -> Double? in
            guard case .line(let a, _)? = session.sketch.geometry(of: c.id), abs(a.x - 1) < 1e-6 else { return nil }
            return a.x
        }
        #expect(!inner.isEmpty, "a side at x = 1")
        #expect(session.offsetProblem == nil)
    }

    @Test func returnKeepsTheOffsetAsOneUndoStepAndSelectsIt() async throws {
        let (model, session, rect, _) = try await editing()
        let before = try #require(committed(model))
        let undo = UndoManager()
        model.undoManager = undo
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        session.selection = rect
        model.beginSketchOffset()
        session.setTyped(.offsetDistance, "3")
        #expect(session.offsetDistance == 3)
        model.commitSketchTyped()
        undo.endUndoGrouping()
        #expect(!session.isOffsetting)
        let s = try #require(committed(model))
        #expect(lineCount(s) == 8 && xRange(s) == -3...13)
        #expect(Set(session.selection) == Set(s.curves.map(\.id)).subtracting(rect).filter { s.kind(of: $0) == .line }, "the new curves are selected")
        undo.undo()
        #expect(committed(model) == before, "one undo step")
    }

    @Test func escapeTakesTheOffsetBack() async throws {
        let (model, session, rect, _) = try await editing()
        let before = session.sketch
        session.selection = rect
        model.beginSketchOffset()
        #expect(session.sketch != before)
        session.escape()
        #expect(!session.isOffsetting && session.sketch == before)
        #expect(session.selection == rect, "what was selected stays selected")
    }

    @Test func buttonPressedAgainStopsIt() async throws {
        let (model, session, rect, _) = try await editing()
        let before = session.sketch
        session.selection = rect
        model.beginSketchOffset()
        model.beginSketchOffset()
        #expect(!session.isOffsetting && session.sketch == before)
    }

    @Test func zeroAndNonsenseAreRefusedAndTheToolStaysOpen() async throws {
        let (model, session, rect, _) = try await editing()
        session.selection = rect
        model.beginSketchOffset()
        session.setTyped(.offsetDistance, "0")
        model.commitSketchTyped()
        #expect(session.isOffsetting && session.message?.contains("zero") == true, "\(String(describing: session.message))")
        session.setTyped(.offsetDistance, "abc")
        #expect(session.typedIsInvalid(.offsetDistance))
        #expect(session.offsetDistance == 0, "the last good distance stays")
    }

    @Test func aSplineRunOffsetsOnTheSideTheArrowPoints() async throws {
        let (model, session, _, spline) = try await editing()
        #expect(!session.canOffset)
        session.selection = spline
        #expect(session.canOffset)
        model.beginSketchOffset()
        #expect(session.isOffsetting && session.offsetProblem == nil, "\(String(describing: session.offsetProblem))")
        #expect(bezierCount(session.sketch) > 2, "the spline's offset is drawn beside it")
        let handle = try #require(session.offsetHandle)
        #expect(handle.direction.y > 0.5 || handle.direction.y < -0.5, "across the run, not along it: \(handle.direction)")
        model.commitSketchTyped()
        let s = try #require(committed(model))
        #expect(bezierCount(s) > 2 && !session.isOffsetting)
    }

    @Test func noSelectionSaysSo() async throws {
        let (model, session, _, _) = try await editing()
        model.beginSketchOffset()
        #expect(!session.isOffsetting && session.message != nil)
    }

    @Test func aSketchCommandWhileOpenTakesThePreviewBackFirst() async throws {
        let (model, session, rect, _) = try await editing()
        session.selection = rect
        model.beginSketchOffset()
        model.sketchCommand { $0.deleteSelection() }
        #expect(!session.isOffsetting)
        #expect(lineCount(session.sketch) == 0, "the rectangle went, and the offset's copies weren't left behind")
    }
}
