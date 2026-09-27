// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import CADKernel
import Foundation
import Testing
@testable import SimplCAD

/// The drag handle's size field, driven with real key events through a window.
@Suite @MainActor struct HandleFieldKeyTests {
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

    @Test func returnCommitsTheSizeAndFinishesTheFeature() async throws {
        let model = DocumentModel(document: CADDocument())
        try await settle(model)
        model.clickRay = (SIMD3(0, 0, 50), SIMD3(0, 0, -1))
        model.run(.box)
        model.click(OriginPlane.xy.pickID, additive: false)
        try await settle(model)

        let view = ViewportMTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: nil)
        let renderer = try #require(Renderer())
        view.device = renderer.device
        view.renderer = renderer
        view.model = model
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.draw(view.bounds)  // lays out the handle field
        try await Task.sleep(for: .milliseconds(100))  // lets the new feature focus its field (queued on the main queue)
        let field = try #require(view.subviews.compactMap { $0 as? ValueField }.first { $0.input == nil })
        #expect(field.currentEditor() != nil, "a new feature's size field has the focus")

        key(window, "3", code: 20)
        key(window, "0", code: 29)
        #expect(field.stringValue == "30")
        key(window, "\r", code: 36)
        #expect(field.currentEditor() == nil, "Return leaves the field")
        guard case .primitive(let p)? = model.document.features.last?.kind else { Issue.record("expected a box"); return }
        #expect(p.height == "30 mm")
        #expect(model.selectedFeature == nil && model.dragHandle == nil, "Return finishes the feature: the handle goes away")
        try await settle(model)
    }
}

/// A typed size that can't be used says why, next to the field.
@Suite @MainActor struct HandleProblemTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func refusedSizesExplainThemselves() async throws {
        var d = CADDocument()
        d.parameters = [Parameter("p1", "13 mm")]
        d.features = [Feature(id: "c", name: "Cylinder1", .primitive(PrimitiveFeature(kind: .cylinder, plane: .xy, height: "5", diameter: "40")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.click(PickID(body: 0, face: 0), additive: false)
        model.run(.rotate)
        try await settle(model)
        #expect(!model.previewHandle("p1"))
        #expect(model.handleProblem == "That's a length (13 mm), but this needs an angle")
        #expect(!model.commitHandle("p2"))
        #expect(model.handleProblem?.contains("p2") == true, "\(model.handleProblem ?? "")")
        #expect(model.previewHandle("30"))
        #expect(model.handleProblem == nil)

        model.finishFeatureEdit()
        model.selection = []
        model.click(PickID(body: 0, edge: 0), additive: false)
        model.run(.fillet)
        model.confirmTool()
        try await settle(model)
        #expect(model.previewHandle("p1"), "13 mm is a fine length…")
        try await settle(model)
        #expect(model.handleProblem?.hasPrefix("Can't build it at that size: fillet failed") == true, "\(model.handleProblem ?? "")")
    }
}

/// Clicking OK (or away) closes the handle before its field hands over what was typed; the size
/// still goes to the feature the field was for, and a parameter there keeps driving it.
@Suite @MainActor struct HandleCommitAfterCloseTests {
    private func settle(_ model: DocumentModel) async throws {
        try await Task.sleep(for: .milliseconds(5))
        for _ in 0..<1000 where model.isRegenerating || model.result == nil { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func okKeepsATypedParameter() async throws {
        var d = CADDocument()
        d.parameters = [Parameter("p2", "1 mm")]
        d.features = [Feature(id: "b", name: "Box1", .primitive(PrimitiveFeature(kind: .box, plane: .xy, width: "20", length: "20", height: "10")))]
        let model = DocumentModel(document: d)
        try await settle(model)
        model.click(PickID(body: 0, edge: 0), additive: false)
        model.run(.fillet)
        model.confirmTool()
        try await settle(model)
        let fillet = try #require(model.document.features.last?.id)
        #expect(model.previewHandle("p2"))  // typing
        model.finishFeatureEdit()           // OK: the handle goes…
        #expect(model.dragHandle == nil)
        #expect(model.commitHandle("p2", for: fillet))  // …then the field ends editing
        guard case .fillet(let f)? = model.document.features.last?.kind else { Issue.record("expected a fillet"); return }
        #expect(f.size == "p2")
        try await settle(model)
        let v1 = try #require(model.result?.body("b")).volume
        model.setParameter("p2", expression: "3 mm")
        try await settle(model)
        let v2 = try #require(model.result?.body("b")).volume
        #expect(v2 < v1 - 1e-6, "a bigger fillet takes more material off: \(v1) → \(v2)")
    }
}
