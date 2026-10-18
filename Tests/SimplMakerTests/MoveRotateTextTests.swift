// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplMaker

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

/// The Text tool's typing box in the viewport: the letters appear in the sketch as they are typed.
@Suite @MainActor struct LiveTextFieldTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func key(_ window: NSWindow, _ chars: String, code: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            window.sendEvent(e)
        }
    }

    private func allSubviews(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + allSubviews(of: $0) } }

    @Test func theLettersShowAsTheyAreTypedAndStayOnReturn() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: Sketch())))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        let session = try #require(model.sketchSession)
        session.setTool(.text)
        _ = model.sketchMouse(SketchMouse(phase: .moved, uv: SIMD2(5, 5), pick: nil, tolerance: 0.5))
        _ = model.sketchMouse(SketchMouse(phase: .down, uv: SIMD2(5, 5), pick: nil, tolerance: 0.5))
        #expect(session.pendingText != nil)

        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.draw(view.bounds)  // lays out the typing box
        try await Task.sleep(for: .milliseconds(100))  // lets it take the focus (queued on the main queue)
        let frameView = try #require(window.contentView?.superview)
        let field = try #require(allSubviews(of: frameView).compactMap { $0 as? ValueField }.first { $0.placeholderString?.contains("Type the text") == true })
        #expect(field.currentEditor() != nil, "the box has the focus, ready to type")

        let none = model.sketchOverlay().curves.count
        key(window, "H", code: 4)
        #expect(session.textDraft == "H", "the session hears every keystroke")
        let one = model.sketchOverlay().curves.count
        key(window, "I", code: 34)
        #expect(session.textDraft == "HI")
        let two = model.sketchOverlay().curves.count
        #expect(one > none && two > one, "each letter adds its outline to the sketch before Return: \(none), \(one), \(two)")
        #expect(session.sketch.texts.isEmpty, "nothing is stored until Return")

        key(window, "\r", code: 36)
        try await settle(model)
        #expect(session.sketch.texts.map(\.text) == ["HI"] && session.textDraft.isEmpty)
        #expect(model.sketchOverlay().curves.count == two, "the same letters, now the sketch's own")
    }

    @Test func theSizeFieldSitsBesideTheWordsAndResizesTheLettersAsItIsTyped() async throws {
        var d = CADDocument()
        d.features = [Feature(id: "sk", name: "Sketch1", .sketch(SketchFeature(plane: .xy, sketch: Sketch())))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.editSketch("sk")
        let session = try #require(model.sketchSession)
        session.setTool(.text)
        _ = model.sketchMouse(SketchMouse(phase: .moved, uv: SIMD2(5, 5), pick: nil, tolerance: 0.5))
        _ = model.sketchMouse(SketchMouse(phase: .down, uv: SIMD2(5, 5), pick: nil, tolerance: 0.5))

        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.draw(view.bounds)
        try await Task.sleep(for: .milliseconds(100))
        let frameView = try #require(window.contentView?.superview)
        let fields = allSubviews(of: frameView).compactMap { $0 as? ValueField }
        let words = try #require(fields.first { $0.placeholderString?.contains("Type the text") == true })
        let size = try #require(fields.first { $0.placeholderString == "Size" })
        #expect(size.stringValue == "10 mm" && words.frame.maxX < size.frame.minX && words.frame.minY == size.frame.minY,
                "the size is in the same place as the words, to their right")
        #expect(words.currentEditor() != nil, "the words have the focus first")

        key(window, "H", code: 4)
        func tall() -> Double {
            let ys = model.sketchOverlay().curves.flatMap { [Double($0.ay), Double($0.by)] }
            return (ys.max() ?? 0) - (ys.min() ?? 0)
        }
        #expect(abs(tall() - 10) < 1e-3)
        key(window, "\t", code: 48)
        #expect(size.currentEditor() != nil && words.currentEditor() == nil, "Tab moves on to the size")
        key(window, "2", code: 19)
        key(window, "0", code: 29)
        #expect(session.textHeightDraft == "20" && abs(tall() - 20) < 1e-3, "typing over the old size redraws the letters: \(tall())")
        #expect(size.textColor == .labelColor)

        key(window, "x", code: 7)  // 20x: no length
        #expect(size.textColor == .systemRed && abs(tall() - 20) < 1e-3, "a wrong size shows red and the letters stay")
        key(window, "\r", code: 36)
        #expect(session.pendingText != nil && session.sketch.texts.isEmpty && size.currentEditor() != nil, "Return does not place it, and stays to fix it")
        key(window, "1", code: 18)  // the refused size is selected: typing replaces it
        key(window, "2", code: 19)
        #expect(session.textHeightDraft == "12" && size.textColor == .labelColor && abs(tall() - 12) < 1e-3)
        key(window, "\u{19}", code: 48)  // back-tab: to the words
        #expect(words.currentEditor() != nil, "⇧Tab goes back")
        key(window, "\r", code: 36)
        try await settle(model)
        #expect(session.sketch.texts.map(\.text) == ["H"] && session.sketch.texts.first?.height == "12 mm", "\(session.sketch.texts)")
        #expect(allSubviews(of: frameView).compactMap { $0 as? ValueField }.allSatisfy { $0.placeholderString != "Size" }, "both boxes go away")
    }
}
