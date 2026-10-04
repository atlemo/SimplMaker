// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// Moving and rotating bodies, and the sketch Text tool.
@Suite @MainActor struct MoveRotateTextTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func boxDoc() -> CADDocument {
        var d = CADDocument()
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "10", height: "5")))]
        return d
    }

    @Test func moveSlidesTheBodyAndKeepsItsFaces() async throws {
        let model = DocumentModel(document: boxDoc())
        try await settle(model)
        model.click(PickID(body: 0, face: 0), additive: false)
        model.run(.move)
        guard case .move(let m)? = model.document.features.last?.kind else { Issue.record("expected a move"); return }
        #expect(m.bodies == ["b"] && m.arrow == .x)
        try await settle(model)
        let h = try #require(model.dragHandle)
        #expect(h.label == "Move X" && h.allowsNegative && abs(h.base.z - 2.5) < 1e-9, "from the middle of the box")
        #expect(model.commitHandle("15"))
        model.setTransformAxis(.z, of: try #require(model.selectedFeature))
        #expect(model.commitHandle("-4"))
        try await settle(model)
        let body = try #require(model.result?.body("b"))
        let box = try #require(body.bounds)
        #expect(abs(box.min.x - 5) < 1e-6 && abs(box.min.z + 4) < 1e-6, "moved 15 along X and 4 down: \(box)")
        #expect(abs(body.volume - 1000) < 1e-6 && body.hasFace("b.top"), "same body, same face names")
    }

    @Test func rotateTurnsAboutTheMiddle() async throws {
        let model = DocumentModel(document: boxDoc())
        try await settle(model)
        model.run(.move)
        #expect(model.pendingTool == .move && model.toolPrompt == "Click the bodies or sketches to move or rotate")
        model.click(PickID(body: 0, face: 0), additive: false)
        guard case .move(let r)? = model.document.features.last?.kind else { Issue.record("expected a move"); return }
        #expect(!r.rotating && r.arrow == .x && r.bodies == ["b"] && model.document.features.last?.name == "Move1")
        try await settle(model)
        model.activateManipulatorPart(.ring(.z))  // the same tool: grabbing the Z ring makes the field an angle
        #expect(model.dragHandle?.label == "Rotate Z")
        #expect(model.commitHandle("90"))
        try await settle(model)
        let box = try #require(model.result?.body("b")?.bounds)
        #expect(abs((box.max.x - box.min.x) - 10) < 1e-6 && abs((box.max.y - box.min.y) - 20) < 1e-6, "a quarter turn swaps width and length")
        #expect(abs((box.max.x + box.min.x) / 2) < 1e-6, "about its own middle")
    }

    @Test func textToolPlacesEditsAndDeletesText() async throws {
        let model = DocumentModel(document: CADDocument())
        try await settle(model)
        model.beginSketch(on: .xy)
        let s = try #require(model.sketchSession)
        s.setTool(.text)
        _ = s.handle(SketchMouse(phase: .moved, uv: SIMD2(3, 4), pick: nil))
        _ = s.handle(SketchMouse(phase: .down, uv: SIMD2(3, 4), pick: nil))
        #expect(s.pendingText?.position == SIMD2(3, 4))
        model.sketchCommand { $0.placeText("  ") }
        #expect(s.sketch.texts.isEmpty && s.pendingText == nil, "no letters, no text")
        _ = s.handle(SketchMouse(phase: .down, uv: SIMD2(3, 4), pick: nil))
        model.sketchCommand { $0.placeText("AB") }
        let t = try #require(s.sketch.texts.first)
        #expect(t.text == "AB" && s.sketch.point(t.position)?.position == SIMD2(3, 4))
        #expect(!s.textOutlines().isEmpty && SketchOverlayBuilder.labels(s).allSatisfy { !$0.id.contains(t.id) })
        model.sketchCommand { $0.updateText(t.id) { $0.height = "20 mm" } }
        #expect(s.sketch.texts.first?.height == "20 mm")
        #expect(model.sketchSession?.updateText(t.id, { $0.height = "0" }) == nil, "a height must be positive")
        model.finishSketch()
        try await settle(model)
        #expect(model.result?.sketches.values.first?.regions.count == 5, "A and its hole, B and its two holes")
        model.editSketch(model.sketches[0].id)
        model.sketchCommand { $0.select(t.position, additive: false); return $0.deleteSelection() }
        #expect(model.sketchSession?.sketch.texts.isEmpty == true, "deleting its anchor point deletes the text")
        model.finishSketch()
        try await settle(model)
    }
}

/// A text's words can be changed where it is: double-click its dot or letters, or click it with Text.
@Suite @MainActor struct EditTextInPlaceTests {
    private func sessionWithText() -> (SketchSession, anchor: EntityID) {
        var s = Sketch()
        let p = s.addPoint(10, 10)
        s.texts = [SketchText(text: "Hello", position: p, height: "5 mm")]
        return (SketchSession(featureID: IDs.make(), frame: .xy, sketch: s, parameters: ParameterEvaluator.evaluate([])), p)
    }

    @Test func doubleClickEditsTheWords() {
        let (session, anchor) = sessionWithText()
        session.setTool(.select)
        #expect(session.beginEditingText(anchoredAt: anchor))
        #expect(session.textEntryInitial == "Hello" && session.pendingText?.point == anchor)
        #expect(session.placeText("Hello there") == "Edit Text")
        #expect(session.sketch.texts.map(\.text) == ["Hello there"], "the same text, not a second one")
        #expect(session.editingText == nil && session.pendingText == nil)
        #expect(!session.beginEditingText(anchoredAt: "origin"), "no text starts at the origin")
    }

    @Test func theTextToolClickedOnATextEditsIt() {
        let (session, anchor) = sessionWithText()
        session.setTool(.text)
        _ = session.handle(SketchMouse(phase: .moved, uv: SIMD2(10, 10), pick: nil, tolerance: 0.5))
        _ = session.handle(SketchMouse(phase: .down, uv: SIMD2(10, 10), pick: nil, tolerance: 0.5))
        #expect(session.editingText == session.sketch.texts.first?.id && session.pendingText?.point == anchor)
        session.cancelText()
        #expect(session.editingText == nil && session.sketch.texts.map(\.text) == ["Hello"], "Esc leaves it as it was")
        _ = session.handle(SketchMouse(phase: .moved, uv: SIMD2(40, 40), pick: nil, tolerance: 0.5))
        _ = session.handle(SketchMouse(phase: .down, uv: SIMD2(40, 40), pick: nil, tolerance: 0.5))
        #expect(session.editingText == nil && session.pendingText != nil, "elsewhere starts a new text")
    }
}
