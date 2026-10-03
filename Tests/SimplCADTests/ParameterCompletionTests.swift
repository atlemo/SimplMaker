// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import Foundation
import Testing
@testable import SimplCAD

/// Typing a parameter's name in a numeric field, driven with real key events through a window.
@Suite @MainActor struct ParameterCompletionTests {
    private let words = [CompletionCandidate(name: "width", detail: "40 mm"), CompletionCandidate(name: "height", detail: "10 mm")]

    private func makeField(completing: Bool = true) throws -> (NSWindow, ValueField) {
        _ = ParameterCompleter.shared
        let field = ValueField(frame: NSRect(x: 20, y: 20, width: 110, height: 24))
        if completing { field.completions = { [words] in words } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        return (window, field)
    }

    /// Like the app: the completer's key monitor sees the event first.
    private func key(_ window: NSWindow, _ chars: String, code: UInt16, shift: Bool = false) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            if type == .keyDown, ParameterCompleter.shared.handle(e) { continue }
            window.sendEvent(e)
        }
    }

    private func type(_ window: NSWindow, _ text: String) {
        for c in text { key(window, String(c), code: 0) }
    }

    @Test func offersTheParametersWhileANameIsTyped() throws {
        let (window, field) = try makeField()
        type(window, "2 * w")
        #expect(field.stringValue == "2 * w")
        #expect(ParameterCompleter.shared.offered == ["width"])
        ParameterCompleter.shared.hide()
    }

    @Test func tabCompletesTheFirstSuggestion() throws {
        let (window, field) = try makeField()
        type(window, "2 * wi")
        key(window, "\t", code: 48)
        #expect(field.stringValue == "2 * width")
        #expect(!ParameterCompleter.shared.isShowing, "the list goes away, and a finished word doesn't bring it back")
        #expect(field.currentEditor() != nil, "the field keeps the typing")
        type(window, " + 1")
        #expect(field.stringValue == "2 * width + 1")
    }

    @Test func arrowsChooseAndReturnTakesTheChoice() throws {
        let words = [CompletionCandidate(name: "zed_a"), CompletionCandidate(name: "zed_b")]
        let (window, field) = try makeField()
        field.completions = { words }
        type(window, "ze")
        #expect(ParameterCompleter.shared.offered == ["zed_a", "zed_b"])
        key(window, "\u{F701}", code: 125)  // down
        key(window, "\r", code: 36)
        #expect(field.stringValue == "zed_b")
        #expect(field.currentEditor() != nil, "Return took the choice; it didn't end the field")
    }

    @Test func returnWithNothingChosenEndsTheFieldAsUsual() throws {
        let (window, field) = try makeField()
        var ended = false
        let handler = Handler { ended = true }
        field.delegate = handler
        type(window, "wi")
        #expect(ParameterCompleter.shared.isShowing)
        key(window, "\r", code: 36)
        #expect(ended, "the field saw Return")
        #expect(field.stringValue == "wi", "nothing was completed")
        #expect(!ParameterCompleter.shared.isShowing)
    }

    @Test func escapeClosesOnlyTheList() throws {
        let (window, field) = try makeField()
        var cancelled = false
        let handler = Handler(onCancel: { cancelled = true })
        field.delegate = handler
        type(window, "wi")
        key(window, "\u{1B}", code: 53)
        #expect(!ParameterCompleter.shared.isShowing)
        #expect(!cancelled, "the first Esc only closes the list")
        key(window, "\u{1B}", code: 53)
        #expect(cancelled)
    }

    @Test func staysQuietForUnitsNumbersAndPlainTextFields() throws {
        let (window, _) = try makeField()
        type(window, "3 w")
        #expect(!ParameterCompleter.shared.isShowing, "after a number only a unit can follow")
        let (other, _) = try makeField(completing: false)
        type(other, "2 * wi")
        #expect(!ParameterCompleter.shared.isShowing, "a field with no words to complete is left alone")
    }

    @Test func movingAwayClosesTheList() throws {
        let (window, field) = try makeField()
        type(window, "wi")
        #expect(ParameterCompleter.shared.isShowing)
        window.makeFirstResponder(nil)
        #expect(!ParameterCompleter.shared.isShowing)
        _ = field
    }

    @Test func theModelOffersItsParametersWithTheirValues() async throws {
        var d = CADDocument()
        d.parameters = [Parameter("width", "40 mm"), Parameter("turns", "3", unit: .none), Parameter("1bad", "5")]
        let model = DocumentModel(document: d)
        try await Task.sleep(for: .milliseconds(20))
        let words = model.completionCandidates()
        #expect(words.map(\.name) == ["width", "turns"], "invalid names can't be typed, so they aren't offered")
        #expect(words.map(\.detail) == ["40 mm", "3"])
        #expect(model.completionCandidates(excluding: "width").map(\.name) == ["turns"])
    }
}

/// Stands in for the viewport as the field's delegate: notes Return and Esc.
@MainActor private final class Handler: NSObject, NSTextFieldDelegate {
    var onReturn: () -> Void
    var onCancel: () -> Void
    init(onReturn: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {}) { self.onReturn = onReturn; self.onCancel = onCancel }
    convenience init(_ onReturn: @escaping () -> Void) { self.init(onReturn: onReturn) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) { onReturn(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancel(); return true }
        return false
    }
}
