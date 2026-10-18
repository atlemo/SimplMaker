// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

/// The sketch toolbar's Move (which also rotates) and Scale.
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
        #expect(session.inputFields == [.moveX, .moveY, .turn], "one tool slides and turns")
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
        #expect(session.beginManipulatorDrag(.axis(.x)))
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
        session.beginTransform(.move)
        #expect(session.beginManipulatorDrag(.axis(.x)))
        model.endManipulatorDrag()
        #expect(committed(model) == before && session.sketch == before)
    }

    @Test func aDragTheConstraintsForbidGoesBackWithAReason() async throws {
        let (model, session, _) = try await editing()
        let before = try #require(committed(model))
        session.beginTransform(.move)
        #expect(session.beginManipulatorDrag(.axis(.x)))
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
        session.beginTransform(.move)
        #expect(session.inputFields == [.moveX, .moveY, .turn])
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
        session.beginTransform(.move)
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
        session.beginTransform(.move)
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
        session.beginTransform(.move)
        session.setTool(.line)
        #expect(session.manipulating == nil)
        session.beginTransform(.scale)
        #expect(session.transformRequested == .scale && session.manipulating == nil, "Scale still asks for a factor")
    }
}

/// The sketch toolbar's Pattern: copies in a grid or round a point, shown live and kept on Return.
@Suite @MainActor struct SketchPatternToolTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func editing() async throws -> (DocumentModel, SketchSession, [EntityID]) {
        var s = Sketch()
        let (lines, _) = s.addRectangle(20, 20, 30, 24)
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

    @Test func startsWithAGridShownLiveAndSizedToTheShape() async throws {
        let (model, session, _) = try await editing()
        let before = try #require(committed(model))
        session.beginTransform(.pattern)
        let setup = try #require(session.patternSetup)
        #expect(setup.kind == .rectangular && setup.countX == "3" && setup.countY == "2")
        #expect(setup.spacingX == "15 mm" && setup.spacingY == "6 mm", "one and a half times the rectangle")
        #expect(session.sketch.curves.count == 4 * 6, "five copies are shown")
        #expect(committed(model) == before, "but nothing is stored yet")
        #expect(session.inputFields == [.countX, .spacingX, .countY, .spacingY])
        #expect(session.manipulatorMiddle == SIMD2(25, 22))
    }

    @Test func draggingAnArrowSetsTheSpacingLive() async throws {
        let (model, session, _) = try await editing()
        session.beginTransform(.pattern)
        let start = try #require(model.manipulatorDragStart)
        #expect(start.move.x == 15 && start.move.y == 6)
        #expect(model.beginManipulatorDrag(.axis(.x)) != nil)
        var v = start
        v.move.x = 40
        model.previewManipulator(v)
        #expect(session.patternSetup?.spacingX == "40 mm")
        #expect(session.sketch.points.contains { $0.position == SIMD2(100, 20) }, "the third column is 80 mm over")
        model.endManipulatorDrag()
        #expect(session.isPatterning, "letting go keeps the pattern open")
        #expect(session.patternSetup?.spacingY == "6 mm")
    }

    @Test func typedCountsAndSpacingsMakeTheCopiesAndReturnKeepsThem() async throws {
        let (model, session, _) = try await editing()
        let undo = UndoManager()
        model.undoManager = undo
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let before = try #require(committed(model))
        session.beginTransform(.pattern)
        session.setTyped(.countX, "2")
        session.setTyped(.countY, "1")
        session.setTyped(.spacingX, "20 mm")
        #expect(session.sketch.curves.count == 8)
        model.commitSketchTyped()
        undo.endUndoGrouping()
        #expect(!session.isPatterning)
        let s = try #require(committed(model))
        #expect(s.curves.count == 8 && s.points.contains { $0.position == SIMD2(50, 24) })
        undo.undo()
        #expect(committed(model) == before)
    }

    @Test func aBadValueSaysWhyAndKeepsThePatternOpen() async throws {
        let (model, session, _) = try await editing()
        session.beginTransform(.pattern)
        session.setTyped(.countX, "1")
        session.setTyped(.countY, "1")
        #expect(session.patternProblem != nil)
        model.commitSketchTyped()
        #expect(session.isPatterning && session.message != nil)
        session.setTyped(.countX, "2.5")
        #expect(session.typedIsInvalid(.countX))
        session.setTyped(.countX, "1000")
        #expect(session.typedIsInvalid(.countX))
    }

    @Test func circularSpreadsAboutAClickedPointAndEscapeTakesTheCopiesAway() async throws {
        let (model, session, _) = try await editing()
        let before = try #require(committed(model))
        session.beginTransform(.pattern)
        session.setPatternKind(.circular)
        #expect(session.inputFields == [.copies, .spread])
        #expect(session.patternSetup?.center == "origin" && session.manipulatorMiddle == .zero)
        #expect(model.manipulatorDragStart?.turn.z == 2 * .pi)
        session.setTyped(.copies, "4")
        #expect(session.sketch.curves.count == 16)
        var v = try #require(model.manipulatorDragStart)
        v.turn.z = .pi
        model.beginManipulatorDrag(.ring(.z))
        model.previewManipulator(v)
        #expect(session.patternSetup?.angle == "180 deg")
        session.escape()
        #expect(!session.isPatterning && session.sketch == before, "back to the original")
    }

    @Test func otherCommandsWorkOnTheSketchWithoutTheCopies() async throws {
        let (model, session, lines) = try await editing()
        session.selection = [lines[0]]
        session.beginTransform(.pattern)
        #expect(session.sketch.curves.count == 4 + 5, "only the selected line is copied")
        model.sketchCommand { $0.deleteSelection() }
        #expect(!session.isPatterning)
        #expect(committed(model)?.curves.count == 3, "the one selected line is gone, and no copies were stored")
    }

    @Test func theCopiesStayLinkedToTheOriginalAndTheParameters() async throws {
        var s = Sketch()
        let (lines, corners) = s.addRectangle(20, 20, 30, 24)
        s.patterns = [SketchPatternDef(id: "p", sources: lines, countX: "n", spacingX: "gap", countY: "1")]
        var d = CADDocument()
        d.parameters = [Parameter("n", "2", unit: .none), Parameter("gap", "15 mm")]
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        #expect(model.result?.errors["sk"] == nil)
        #expect(model.result?.sketches["sk"]?.solved.curves.count == 8, "the stored sketch had no copies; the rebuild made them")
        model.setParameter("n", expression: "3")
        try await settle(model)
        #expect(model.result?.sketches["sk"]?.solved.curves.count == 12, "a parameter drives the count")

        model.editSketch("sk")
        let session = try #require(model.sketchSession)
        #expect(session.sketch.curves.count == 12)
        let corner = try #require(session.sketch.point(corners[2]))
        #expect(session.sketch.point("p~2~\(corners[2])")?.position == corner.position + SIMD2(30, 0))
        // Drag the original's corner: the copies follow while it is dragged.
        let uv = corner.position + SIMD2(2, 0)
        session.select(corners[2], additive: false)
        _ = session.handle(SketchMouse(phase: .down, uv: corner.position, pick: session.pickID(for: corners[2])))
        _ = session.handle(SketchMouse(phase: .dragged, uv: uv))
        #expect(session.sketch.point("p~2~\(corners[2])")!.position.x == session.sketch.point(corners[2])!.position.x + 30)
    }

    @Test func theGlyphOpensThePatternAndClickingACopyOnlyPicksIt() async throws {
        let (model, session, lines) = try await editing()
        session.beginTransform(.pattern)
        model.commitSketchTyped()
        #expect(!session.isPatterning)
        let id = try #require(session.sketch.patterns.first?.id)
        let copy = try #require(session.sketch.curves.first { Sketch.isGenerated($0.id) })
        _ = session.handle(SketchMouse(phase: .down, uv: .zero, pick: session.pickID(for: copy.id)))
        #expect(!session.isPatterning && session.selection == [copy.id], "a click on a copy only selects it")
        let glyph = try #require(SketchOverlayBuilder.patternGlyphs(session).first)
        #expect(glyph.pattern == id && glyph.id == "pattern:\(id)")
        model.beginSketchPattern(editing: id)  // what the glyph's click does
        #expect(session.isPatterning && !session.patternIsNew && session.patternSetup?.id == id)
        #expect(SketchOverlayBuilder.patternGlyphs(session).isEmpty, "no glyph while the pattern is open")
        session.setTyped(.countX, "2")
        model.commitSketchTyped()
        #expect(committed(model)?.patterns.first?.countX == "2")
        #expect(committed(model)?.curves.count == 4 * 4, "2 × 2 cells, three copies")

        model.beginSketchPattern(editing: id)
        model.commitSketch(session.deletePattern())
        #expect(committed(model)?.patterns.isEmpty == true && committed(model)?.curves.count == lines.count)
    }

    @Test func copiesCantBeDrawnOnOrPickedByTheOtherTools() async throws {
        let (model, session, _) = try await editing()
        session.beginTransform(.pattern)
        model.commitSketchTyped()
        let copy = try #require(session.sketch.points.first { Sketch.isGenerated($0.id) })
        session.setTool(.line)
        let r = session.handle(SketchMouse(phase: .moved, uv: copy.position, pick: session.pickID(for: copy.id), tolerance: 1))
        _ = r
        #expect(session.hover == nil, "a copy is not there to draw from")
        let snap = session.snap(copy.position)
        #expect(snap.point == nil || !Sketch.isGenerated(snap.point!))
    }
}
