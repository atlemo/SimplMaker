// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import Foundation
import Testing
@testable import SimplMaker

/// A plain-letter menu shortcut that is handed back to the view with focus must not come round again.
@Suite @MainActor struct LetterShortcutTests {
    @Test func aKeyThatComesRoundAgainIsDroppedInsteadOfLooping() {
        _ = NSApplication.shared  // (NSApp is only set once the application exists)
        var ran = 0
        LetterShortcut.perform(nil) { ran += 1 }
        #expect(ran == 1, "with no key event in flight the command just runs")
        LetterShortcut.handingBack = true
        LetterShortcut.perform(nil) { ran += 1 }
        LetterShortcut.handingBack = false
        #expect(ran == 1, "a key being handed back, offered to the menu again, does nothing")
        LetterShortcut.perform(nil) { ran += 1 }
        #expect(ran == 2, "and the next one works as before")
    }
}
