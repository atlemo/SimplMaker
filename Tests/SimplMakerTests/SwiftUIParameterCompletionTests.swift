// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import Foundation
import SwiftUI
import Testing
@testable import SimplMaker

extension KeyWindowTests {
    /// The same completion, in a SwiftUI TextField (the dimension popover, the parameter list), driven with key events;
    /// the dimension popover itself is an NSPopover around a hosting controller, with events sent through the application
    /// so the completer's own key monitor sees them first.
    /// One serial suite: these share the completer and the key window, so they can't interleave.
    @Suite(.serialized) @MainActor struct SwiftUIParameterCompletionTests {
        @Observable final class Box { var text = ""; var submitted: [String] = [] }

        struct Host: View {
            let model: DocumentModel
            let box: Box
            @FocusState private var focused: Bool
            var body: some View {
                @Bindable var box = box
                VStack {
                    TextField("expression", text: $box.text)
                        .focused($focused)
                        .completesParameters(model, focused: focused)
                        .onSubmit { submit() }
                    Button("Set") { submit(unlessClicked: true) }.keyboardShortcut(.defaultAction)
                }
                .onAppear { focused = true }
            }

            private func submit(unlessClicked: Bool = false) {
                if ParameterCompleter.shared.complete(&box.text, unlessClicked: unlessClicked) { focused = true } else { box.submitted.append(box.text) }
            }
        }

        private func key(_ window: NSWindow, _ chars: String, code: UInt16, viaMonitor: Bool = true) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                if viaMonitor, type == .keyDown, ParameterCompleter.shared.handle(e) { continue }
                window.sendEvent(e)
            }
        }

        private func settle() async { try? await Task.sleep(for: .milliseconds(80)) }

        /// Even when the key monitor doesn't take the Return, the field's own submit completes the word instead
        /// of committing it half typed.
        @Test func aReturnTheMonitorMissedStillCompletesInsteadOfCommitting() async throws {
            let (window, box) = try await open()
            for c in "dep" { key(window, String(c), code: 0); await settle() }
            key(window, "\r", code: 36, viaMonitor: false)
            await settle()
            #expect(box.text == "depth")
            #expect(box.submitted.isEmpty)
            key(window, "\r", code: 36, viaMonitor: false)
            await settle()
            #expect(box.submitted == ["depth"])
            ParameterCompleter.shared.hide()
            window.close()
        }

        private func open() async throws -> (NSWindow, Box) {
            _ = ParameterCompleter.shared
            var d = CADDocument()
            d.parameters = [Parameter("depth", "50 mm")]
            let model = DocumentModel(document: d)
            let box = Box()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Host(model: model, box: box))
            window.makeKeyAndOrderFront(nil)
            await settle()
            return (window, box)
        }

        @Test func returnTakesTheSuggestionInASwiftUITextField() async throws {
            _ = ParameterCompleter.shared
            var d = CADDocument()
            d.parameters = [Parameter("depth", "50 mm")]
            let model = DocumentModel(document: d)
            let box = Box()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Host(model: model, box: box))
            window.makeKeyAndOrderFront(nil)
            await settle()
            for c in "dep" { key(window, String(c), code: 0); await settle() }
            #expect(box.text == "dep")
            #expect(ParameterCompleter.shared.offered == ["depth"])
            key(window, "\r", code: 36)
            await settle()
            #expect(box.text == "depth", "Return completed the name")
            #expect(box.submitted.isEmpty, "and didn't submit the half-typed word")
            key(window, "\r", code: 36)
            await settle()
            #expect(box.submitted.count == 1)
            ParameterCompleter.shared.hide()
            window.close()
        }

        // MARK: the dimension popover as the app builds it

        private func send(_ window: NSWindow, _ chars: String, code: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                NSApp.sendEvent(e)
            }
        }

        
        @Test func returnCompletesTheNameThenSetsTheDimension() async throws {
            _ = NSApplication.shared
            _ = ParameterCompleter.shared
            var d = CADDocument()
            d.parameters = [Parameter("depth", "50 mm")]
            var sketch = Sketch()
            sketch.addRectangle(0, 0, 20, 10, lineIDs: ["B", "R", "T", "L"])
            let feature = Feature(name: "Sketch 1", .sketch(SketchFeature(plane: .xy, sketch: sketch)))
            d.features = [feature]
            let model = DocumentModel(document: d)
            try await Task.sleep(for: .milliseconds(30))
            model.editSketch(feature.id)
            let session = try #require(model.sketchSession)
            session.setTool(.dimension)
            for phase in [SketchMouse.Phase.moved, .down, .up] { _ = session.handle(SketchMouse(phase: phase, uv: SIMD2(10, 0.3), pick: nil, tolerance: 0.5, gridStep: nil)) }
            for phase in [SketchMouse.Phase.moved, .down, .up] { _ = session.handle(SketchMouse(phase: phase, uv: SIMD2(10, -0.2), pick: nil, tolerance: 0.5, gridStep: nil)) }
            let id = try #require(session.editingDimension)

            let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            let anchor = NSView(frame: NSRect(x: 150, y: 150, width: 60, height: 20))
            host.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            host.contentView?.addSubview(anchor)
            host.makeKeyAndOrderFront(nil)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: DimensionEditor(model: model, session: session, dimensionID: id))
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            await settle()
            let window = try #require(popover.contentViewController?.view.window)
            let field = try #require(window.firstResponder as? NSTextView, "the popover's field has the keyboard")
            for c in "dep" { send(window, String(c), code: 0); await settle() }
            #expect(field.string == "dep")
            #expect(ParameterCompleter.shared.offered == ["depth"])
            send(window, "\r", code: 36)
            await settle()
            #expect(field.string == "depth", "Return completed the name")
            #expect(session.message == nil, "and didn't try to set the half-typed word")
            send(window, "\r", code: 36)
            await settle()
            #expect(session.message == nil)
            #expect(session.sketch.dimensions.first { $0.id == id }?.expression == "depth", "the next Return sets it")
            ParameterCompleter.shared.hide()
            popover.close()
            host.close()
        }
    }
}
