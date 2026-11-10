import AppKit
import SwiftUI
import Testing
@testable import SimplMaker

/// The Parameters list's text fields once showed white text on a white fill (a selected row turns
/// inherited text white), so typing looked broken. Each state's text colour is tied to its fill.
@Suite struct RowFieldStyleTests {
    @Test func aFocusedFieldWinsOverASelectedRow() {
        #expect(RowFieldStyle.mode(focused: true, rowSelected: true) == .focused)
        #expect(RowFieldStyle.mode(focused: true, rowSelected: false) == .focused)
        #expect(RowFieldStyle.mode(focused: false, rowSelected: true) == .selected)
        #expect(RowFieldStyle.mode(focused: false, rowSelected: false) == .regular)
    }

    @Test func lightFillsGetDarkTextAndTheDarkFillGetsWhite() {
        for mode in [RowFieldStyle.Mode.regular, .focused] {
            let p = RowFieldStyle.palette(mode)
            #expect(!p.darkFill)
            #expect(p.text == .textColor && p.fill == .textBackgroundColor)
        }
        let selected = RowFieldStyle.palette(.selected)
        #expect(selected.darkFill)
        #expect(selected.text == .white)
    }
}

extension KeyWindowTests {
    /// The caret and the selection highlight of a focused row field are set explicitly: inside a selected list row
    /// the text view's own came out white on the white field, so neither could be seen.
    @Suite(.serialized) @MainActor struct RowFieldEditorColorTests {
        struct Host: View {
            @State private var text = "10 mm"
            @FocusState private var focused: Bool
            var body: some View {
                TextField("x", text: $text).rowFieldStyle(focused: focused).focused($focused)
                    .onAppear { focused = true }
            }
        }

        @Test func aFocusedRowFieldShowsItsCaretAndSelection() async throws {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Host())
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(400))
            let editor = try #require(window.firstResponder as? NSTextView)
            #expect(editor.insertionPointColor == .textColor)
            // White on the accent in the active window, the dark text on the quiet gray in one that isn't.
            let expected: NSColor = window.isKeyWindow ? .white : .textColor
            #expect(editor.selectedTextAttributes[.foregroundColor] as? NSColor == expected)
            window.makeFirstResponder(nil)
            try await Task.sleep(for: .milliseconds(400))
            window.close()
        }
    }
}
