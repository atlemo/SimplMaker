// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// The sketch toolbar's Move, Rotate and Scale.
@Suite @MainActor struct SketchTransformToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    /// A model editing a sketch with a free 10 × 4 rectangle, and the sketch's line ids.
    private func editing(constrained: Bool = false) async throws -> (DocumentModel, SketchSession, [EntityID]) {
        var s = Sketch()
        let (lines, corners) = s.addRectangle(20, 20, 30, 24)
        if constrained { s.dimension(.horizontalDistance("origin", corners[0]), "20 mm", id: "x") }
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        return (model, try #require(model.sketchSession), lines)
    }

    private func committed(_ model: DocumentModel) -> Sketch? {
        if case .sketch(let sf)? = model.document.features.first?.kind { return sf.sketch }
        return nil
    }

    /// Types a move, a turn or both into the manipulator's fields, as the viewport does, and presses Return.
    private func type(_ model: DocumentModel, _ values: [SketchInput: String]) {
        let session = model.sketchSession!
        for (field, text) in values { session.setTyped(field, text) }
        model.sketchCommand { $0.commitTyped() }
    }

    @Test func moveSlidesTheWholeSketchWhenNothingIsSelected() async throws {
        let (model, session, _) = try await editing()
        #expect(session.canTransform && session.transformTargetDescription == "the whole sketch")
        session.beginTransform(.move)
        #expect(session.manipulating == .move && session.transformRequested == nil, "Move shows the manipulator, not a popover")
        #expect(session.inputFields == [.moveX, .moveY])
        type(model, [.moveX: "5", .moveY: "-2 mm"])
        #expect(session.message == nil)
        let s = try #require(committed(model))
        #expect(s.points.contains { $0.position == SIMD2(25, 18) } && s.points.contains { $0.position == SIMD2(35, 22) })
        #expect(session.manipulating == .move, "the manipulator stays for the next move")
    }

    @Test func draggingShowsTheMoveLiveAndKeepsItOnRelease() async throws {
        let (model, session, _) = try await editing()
        let before = try #require(committed(model))
        let undo = UndoManager()
        model.undoManager = undo
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        session.beginTransform(.move)
        let middle = try #require(session.manipulatorMiddle)
        #expect(middle == SIMD2(25, 22), "the middle of the rectangle")
        #expect(session.beginManipulatorDrag())
        var v = TransformValues()
        v.move = SIMD3(5, 3, 0)
        session.previewManipulator(v)
        #expect(session.sketch.points.contains { $0.position == SIMD2(25, 23) }, "the sketch shows the move")
        #expect(committed(model) == before, "but nothing is stored yet")
        #expect(session.manipulatorMiddle == SIMD2(30, 25), "the manipulator rides along")
        model.previewManipulator(v)
        model.endManipulatorDrag()
        undo.endUndoGrouping()
        let s = try #require(committed(model))
        #expect(s.points.contains { $0.position == SIMD2(25, 23) } && s.points.contains { $0.position == SIMD2(35, 27) })
        #expect(session.manipulatorMiddle == SIMD2(30, 25), "it sits on the new middle, at rest")
        undo.undo()
        #expect(committed(model) == before, "one undo step")
    }

    @Test func letGoWithoutMovingChangesNothing() async throws {
        let (model, session, _) = try await editing()
        let before = try #require(committed(model))
        session.beginTransform(.rotate)
        #expect(session.beginManipulatorDrag())
        model.endManipulatorDrag()
        #expect(committed(model) == before && session.sketch == before)
    }

    @Test func aDragTheConstraintsForbidGoesBackWithAReason() async throws {
        let (model, session, _) = try await editing()
        let before = try #require(committed(model))
        session.beginTransform(.rotate)
        #expect(session.beginManipulatorDrag())
        var v = TransformValues()
        v.turn = SIMD3(0, 0, 0.5)  // a tilt the rectangle's horizontal and vertical lines forbid
        session.previewManipulator(v)
        model.previewManipulator(v)
        model.endManipulatorDrag()
        #expect(session.message?.contains("horizontal, vertical") == true)
        #expect(committed(model) == before && session.sketch == before)
        #expect(session.manipulatorMiddle == SIMD2(25, 22))
    }

    @Test func typingShowsThePreviewAndEscapeTakesItBack() async throws {
        let (model, session, _) = try await editing()
        let before = try #require(committed(model))
        session.beginTransform(.move)
        session.setTyped(.moveX, "10")
        #expect(session.sketch.points.contains { $0.position == SIMD2(30, 20) }, "typed values show at once")
        #expect(committed(model) == before)
        session.setTyped(.moveX, "")
        #expect(session.sketch == before)
        session.setTyped(.moveY, "4")
        session.clearTyped()
        #expect(session.sketch == before)
        session.escape()
        #expect(session.manipulating == nil)
    }

    @Test func scaleAboutTheSelectionOrTheOrigin() async throws {
        let (model, session, lines) = try await editing()
        session.selection = lines
        #expect(session.transformTargetDescription == "4 selected")
        model.sketchCommand { $0.scaleSelection(factor: "2", about: .selection) }
        var s = try #require(committed(model))
        #expect(s.points.contains { $0.position == SIMD2(15, 18) } && s.points.contains { $0.position == SIMD2(35, 26) })
        model.sketchCommand { $0.scaleSelection(factor: "0.5", about: .origin) }
        s = try #require(committed(model))
        #expect(s.points.contains { $0.position == SIMD2(7.5, 9) })
    }

    @Test func rotateTurnsTheSelectionAboutItsMiddle() async throws {
        let (model, session, lines) = try await editing()
        session.selection = lines
        session.beginTransform(.rotate)
        #expect(session.inputFields == [.turn])
        type(model, [.turn: "90"])  // a bare number is degrees
        let s = try #require(committed(model))
        // 10 × 4 about (25, 22) becomes 4 × 10 about the same middle.
        let xs = s.points.filter { $0.id != "origin" }.map(\.x), ys = s.points.filter { $0.id != "origin" }.map(\.y)
        #expect(abs((xs.max()! - xs.min()!) - 4) < 1e-9 && abs((ys.max()! - ys.min()!) - 10) < 1e-9)
        #expect(abs((xs.max()! + xs.min()!) / 2 - 25) < 1e-9 && abs((ys.max()! + ys.min()!) / 2 - 22) < 1e-9)
    }

    @Test func aTiltThatTheRectanglesConstraintsForbidIsRefused() async throws {
        let (model, session, _) = try await editing()
        let before = try #require(committed(model))
        session.beginTransform(.rotate)
        type(model, [.turn: "30"])
        #expect(session.message?.contains("horizontal, vertical") == true)
        #expect(committed(model) == before && session.sketch == before, "the preview is taken back")
        // A quarter turn is fine: horizontal and vertical trade places.
        type(model, [.turn: "90"])
        let s = try #require(committed(model))
        let xs = s.points.filter { $0.id != "origin" }.map(\.x), ys = s.points.filter { $0.id != "origin" }.map(\.y)
        #expect(abs((xs.max()! - xs.min()!) - 4) < 1e-9 && abs((ys.max()! - ys.min()!) - 10) < 1e-9)
    }

    @Test func badValuesAreRefusedWithAReason() async throws {
        let (model, session, _) = try await editing()
        let before = try #require(committed(model))
        model.sketchCommand { $0.scaleSelection(factor: "0", about: .origin) }
        #expect(session.message?.contains("more than zero") == true)
        model.sketchCommand { $0.scaleSelection(factor: "abc", about: .origin) }
        #expect(session.message != nil)
        session.beginTransform(.move)
        type(model, [.moveX: "abc"])
        #expect(session.message != nil)
        type(model, [.moveX: "0", .moveY: "0"])
        #expect(session.message?.contains("zero") == true)
        session.beginTransform(.move)  // off
        session.beginTransform(.rotate)
        type(model, [.turn: "360"])
        #expect(session.message?.contains("zero") == true)
        #expect(committed(model) == before, "nothing changed")
    }

    @Test func aDimensionThatHoldsTheGeometryStopsTheMove() async throws {
        let (model, session, _) = try await editing(constrained: true)
        let before = try #require(committed(model))
        session.beginTransform(.move)
        type(model, [.moveX: "5", .moveY: "0"])
        #expect(session.message?.contains("Constraints or dimensions") == true)
        #expect(committed(model) == before)
        // Moving along the free direction works; the distance from the origin is only in x.
        type(model, [.moveX: "0", .moveY: "5"])
        #expect(committed(model)?.points.contains { $0.position == SIMD2(20, 25) } == true)
    }

    @Test func scalingAboutTheOriginTakesTheDimensionsAlong() async throws {
        let (model, _, _) = try await editing(constrained: true)
        model.sketchCommand { $0.scaleSelection(factor: "2", about: .origin) }
        let s = try #require(committed(model))
        #expect(s.points.contains { $0.position == SIMD2(40, 40) })
        #expect(abs(s.dimensionValues(ParameterValues())["x"]! - 40) < 1e-9)
    }

    @Test func aSketchOpensWithTheSelectTool() async throws {
        let (_, session, _) = try await editing()
        #expect(session.tool == .select)
    }

    @Test func aSketchWithNothingInItCantBeTransformed() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: Sketch())))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        let session = try #require(model.sketchSession)
        #expect(!session.canTransform)
        session.beginTransform(.move)
        #expect(session.manipulating == nil && session.transformRequested == nil)
    }

    @Test func pressingTheToolAgainOrAnotherToolTurnsTheManipulatorOff() async throws {
        let (_, session, _) = try await editing()
        session.beginTransform(.move)
        session.beginTransform(.move)
        #expect(session.manipulating == nil)
        session.beginTransform(.rotate)
        session.setTool(.line)
        #expect(session.manipulating == nil)
        session.beginTransform(.scale)
        #expect(session.transformRequested == .scale && session.manipulating == nil, "Scale still asks for a factor")
    }
}
