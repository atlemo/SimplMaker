// The status bar's hints are written for a mouse and a keyboard. On the iPad they are reworded for a finger.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum Hint {
    /// The hint as it should read on this device: unchanged on the Mac.
    static func text(_ s: String) -> String {
#if os(macOS)
        return s
#else
        // Parts that only a keyboard can act on go; the tool bar has Cancel and Done.
        let parts = s.components(separatedBy: " · ").filter {
            !$0.contains("⇧-") && !$0.hasPrefix("Esc to") && !$0.hasPrefix("Tab ") && !$0.contains("Tab moves")
        }
        var out = parts.isEmpty ? s : parts.joined(separator: " · ")
        for (from, to) in [("Press E to extrude", "Tap Extrude to extrude"), ("and press Return", "and tap Done"),
                           ("double-click", "double-tap"), ("Double-click", "Double-tap"),
                           ("click", "tap"), ("Click", "Tap"),
                           ("let go to keep", "lift to keep")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
#endif
    }
}

/// A hint line, reworded for the device.
func hintText(_ s: String) -> Text { Text(verbatim: Hint.text(s)) }

extension View {
    /// The small controls of a floating bar on the Mac; on the iPad big bordered buttons, so a finger hits them.
    @ViewBuilder func touchControls() -> some View {
#if os(macOS)
        controlSize(.small)
#else
        controlSize(.large).buttonStyle(.bordered).frame(minHeight: 48)
#endif
    }
}

extension View {
    /// A field for a size: the iPad shows numbers and symbols (digits, a point, a minus and the operators of an expression) first, not letters
    /// (the keyboard's own "ABC" key still reaches a parameter's name). The Mac types as it always did.
    @ViewBuilder func numericEntry() -> some View {
#if os(macOS)
        self
#else
        keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
#endif
    }
}
