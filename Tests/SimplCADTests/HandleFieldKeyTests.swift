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
