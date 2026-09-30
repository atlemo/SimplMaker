// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// What dragging the Move/Rotate manipulator does to the model.
@Suite @MainActor struct ManipulatorModelTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func boxDoc(parameters: [Parameter] = []) -> CADDocument {
        var d = CADDocument()
        d.parameters = parameters
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "10", height: "5")))]
        return d
    }

    private func moving(_ doc: CADDocument) async throws -> (DocumentModel, UndoManager, FeatureID) {
        let model = DocumentModel(document: doc)
        let undo = UndoManager()
        model.undoManager = undo
        try await settle(model)
        model.click(PickID(body: 0, face: 0), additive: false)
        model.run(.move)
        try await settle(model)
        return (model, undo, try #require(model.selectedFeature))
    }

    private func move(_ model: DocumentModel) -> MoveFeature? {
        if case .move(let m)? = model.document.features.last?.kind { return m }
        return nil
    }

    @Test func theManipulatorShowsOnASelectedMoveAndSitsOnTheBody() async throws {
        let (model, _, _) = try await moving(boxDoc())
        #expect(model.manipulatedFeature != nil)
        let mid = try #require(model.manipulatorMiddle)
        #expect(abs(mid.x) < 1e-9 || abs(mid.x - 0) < 20, "at the middle of the box: \(mid)")
        #expect(abs(mid.z - 2.5) < 1e-9)
        #expect(model.manipulatorActivePart == .axis(.x))
        model.pendingTool = .extrude
        #expect(model.manipulatedFeature == nil, "not while a tool waits")
        model.pendingTool = nil
        model.selectedFeature = nil
        #expect(model.manipulatedFeature == nil && model.manipulatorMiddle == nil)
    }

    @Test func draggingPreviewsThenOneUndoStepKeepsIt() async throws {
        let (model, undo, id) = try await moving(boxDoc())
        let before = model.document
        undo.groupsByEvent = false  // this test groups the steps itself
        undo.beginUndoGrouping()
        let start = try #require(model.beginManipulatorDrag(.plane(.z)))
        #expect(start == TransformValues())
        model.previewManipulator(TransformValues(move: SIMD3(12, -7, 0)))
        #expect(model.document == before, "a preview doesn't touch the document")
        try await settle(model)
        let previewed = try #require(model.result?.body("b")?.bounds)
        #expect(abs((previewed.min.x + previewed.max.x) / 2 - 12) < 1e-6, "the model shows the drag")
        #expect(abs(try #require(model.manipulatorMiddle).x - 12) < 1e-9, "and so does the manipulator")
        model.endManipulatorDrag()
        undo.endUndoGrouping()
        let m = try #require(move(model))
        #expect(m.dx == "12 mm" && m.dy == "-7 mm" && m.dz == "0 mm" && model.manipulatorLive == nil)
        undo.undo()
        #expect(model.document == before, "one step takes it all back")
        _ = id
    }

    @Test func aRingTurnsAndTheFieldFollowsTheGrabbedPart() async throws {
        let (model, _, id) = try await moving(boxDoc())
        model.beginManipulatorDrag(.ring(.x))
        #expect(model.manipulatorActivePart == .ring(.x) && model.dragHandle?.label == "Rotate X" && model.dragHandle?.unit == .angle)
        model.previewManipulator(TransformValues(turn: SIMD3(.pi / 2, 0, 0)))
        #expect(model.handleFieldText == "90 deg", "\(String(describing: model.handleFieldText))")
        model.endManipulatorDrag()
        #expect(move(model)?.rx == "90 deg" && move(model)?.rotating == true)
        try await settle(model)
        let box = try #require(model.result?.body("b")?.bounds)
        #expect(abs((box.max.y - box.min.y) - 5) < 1e-6 && abs((box.max.z - box.min.z) - 10) < 1e-6, "turned about X")
        // Grabbing an arrow puts the field back on distances.
        model.beginManipulatorDrag(.axis(.y))
        model.endManipulatorDrag()
        #expect(model.dragHandle?.label == "Move Y" && model.selectedFeature == id)
    }

    @Test func switchingThePartIsNotAnUndoStep() async throws {
        let (model, undo, _) = try await moving(boxDoc())
        let before = model.document
        undo.groupsByEvent = false  // this test groups the steps itself
        undo.beginUndoGrouping()
        model.activateManipulatorPart(.ring(.y))
        model.setRotating(false, of: try #require(model.selectedFeature))
        undo.endUndoGrouping()
        #expect(!undo.canUndo || undo.undoActionName != "Change Axis", "nothing to undo but the feature itself")
        #expect(model.document != before)
        #expect(model.transformAxis(try #require(model.selectedFeature)) == .y)
    }

    @Test func aDragThatChangesNothingLeavesNothing() async throws {
        let (model, _, _) = try await moving(boxDoc())
        let before = model.document
        model.beginManipulatorDrag(.center)
        model.previewManipulator(TransformValues())
        model.endManipulatorDrag()
        #expect(model.document == before && model.manipulatorLive == nil)
    }

    @Test func aParameterAsksBeforeItIsReplaced() async throws {
        let (model, _, id) = try await moving(boxDoc(parameters: [Parameter("gap", "8 mm")]))
        model.updateFeature(id, "Edit X") { f in if case .move(var m) = f.kind { m.dx = "gap"; f.kind = .move(m) } }
        try await settle(model)
        model.beginManipulatorDrag(.axis(.x))
        model.previewManipulator(TransformValues(move: SIMD3(20, 0, 0)))
        model.endManipulatorDrag()
        let prompt = try #require(model.unlinkPrompt)
        #expect(prompt.expression == "gap" && prompt.valueText == "X 20 mm" && move(model)?.dx == "gap", "not replaced yet")
        model.resolveUnlink(useValue: true)
        #expect(move(model)?.dx == "20 mm" && model.manipulatorLive == nil)
        // And keeping it leaves the expression.
        model.updateFeature(id, "Edit X") { f in if case .move(var m) = f.kind { m.dx = "gap"; f.kind = .move(m) } }
        model.beginManipulatorDrag(.axis(.x))
        model.previewManipulator(TransformValues(move: SIMD3(30, 0, 0)))
        model.endManipulatorDrag()
        model.resolveUnlink(useValue: false)
        #expect(move(model)?.dx == "gap")
    }

    @Test func typingStillSetsTheActiveValue() async throws {
        let (model, _, _) = try await moving(boxDoc())
        #expect(model.commitHandle("15"))
        model.activateManipulatorPart(.ring(.z))
        #expect(model.commitHandle("45"))
        let m = try #require(move(model))
        #expect(m.dx == "15 mm" && m.rz == "45 deg")
    }

    @Test func aSketchTurnsToo() async throws {
        var s = Sketch()
        s.addRectangle(0, 0, 10, 4)
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: s)))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.move(sketches: ["sk"], rotating: true)
        try await settle(model)
        let mid = try #require(model.manipulatorMiddle)
        #expect(abs(mid.x - 5) < 1e-6 && abs(mid.y - 2) < 1e-6, "the sketch's own middle: \(mid)")
        model.beginManipulatorDrag(.ring(.x))
        model.previewManipulator(TransformValues(turn: SIMD3(.pi / 2, 0, 0)))
        model.endManipulatorDrag()
        try await settle(model)
        #expect(abs(try #require(model.result?.sketches["sk"]?.frame.normal).y + 1) < 1e-9)
    }
}
