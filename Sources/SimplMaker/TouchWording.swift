// The status bar's hints are written for a mouse and a keyboard. On the iPad they are reworded for a finger.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

extension EnvironmentValues {
    /// The height of the window the part is in, set by the iPad editor so that popovers can keep clear of the screen's edges.
    @Entry var windowHeight: CGFloat = 800
}

enum Hint {
    /// The hint as it should read on this device: unchanged on the Mac.
    static func text(_ s: String) -> String {
#if os(macOS)
        return s
#else
        // Parts that only a keyboard can act on go; the tool bar has Cancel and Done.
        let parts = s.components(separatedBy: " · ").filter {
            !$0.contains("⇧-") && !$0.hasPrefix("Esc to") && !$0.hasPrefix("Esc cancels") && !$0.hasPrefix("Tab ") && !$0.contains("Tab moves")
        }
        var out = parts.isEmpty ? s : parts.joined(separator: " · ")
        for (from, to) in [("Press E to extrude", "Tap Extrude to extrude"), ("and press Return", "and tap Done"),
                           ("Esc ends the chain", "Done ends the chain"), ("Esc ends the spline", "Done ends the spline"), ("Esc when done", "tap the tool again when done"),
                           ("Esc ends", "pick another tool to end"), ("Return keeps", "OK keeps"), ("⌫ deletes", "Delete removes the selection"),
                           ("double-click", "double-tap"), ("Double-click", "Double-tap"),
                           ("click", "tap"), ("Click", "Tap"),
                           ("let go to keep", "lift to keep")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
#endif
    }
}

extension Hint {
    /// A waiting tool's prompt: what the Mac asks of the Return key, the iPad asks of the Done button.
    static func toolText(_ s: String) -> String {
#if os(macOS)
        return s
#else
        text(s).replacingOccurrences(of: "press Return", with: "tap Done")
            .replacingOccurrences(of: "\\bReturn\\b", with: "Done", options: .regularExpression)
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
    @ViewBuilder func numericEntry(if on: Bool) -> some View {
        if on { numericEntry() } else { self }
    }

    @ViewBuilder func numericEntry() -> some View {
#if os(macOS)
        self
#else
        keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
#endif
    }
}

/// How big the small buttons of the side panels are: the Mac's pointer is precise, a finger needs about 44 pt.
enum PanelTouch {
#if os(macOS)
    static let headerButton: CGFloat = 20
    static let headerIcon: CGFloat = 11
    static let headerHeight: CGFloat = 40
    /// A row's padlock and eye sit in the same 20 pt cells as the panel header's buttons (add, collapse), so the
    /// eye is under the collapse arrow and the padlock under the add button, in every panel.
    static let rowButtonWidth: CGFloat? = headerButton
    static let rowButtonHeight: CGFloat? = nil
    /// Between neighbouring cells, in the header and in the rows.
    static let buttonSpacing: CGFloat = DS.Spacing.space1
    /// How far the list's own right inset (measured, system-drawn) falls short of the header's, which the rows' end
    /// buttons make up for; GridLayoutTests checks the columns line up.
    static let rowTrailingBleed: CGFloat = 8
    /// The header's inset from the panel's trailing edge (the cells' columns are counted from it).
    static let panelTrailing: CGFloat = DS.Spacing.space4
    static let contentLeading: CGFloat = 12
    static let panelToggleRoom: CGFloat = 0
    /// The gap between a browser row's icon and its name.
    static let rowIconGap: CGFloat = DS.Spacing.labelGap
#else
    static let headerButton: CGFloat = 44
    static let headerIcon: CGFloat = 18
    static let headerHeight: CGFloat = 52
    static let rowButtonWidth: CGFloat? = 44
    static let rowButtonHeight: CGFloat? = 44
    static let buttonSpacing: CGFloat = DS.Spacing.space1
    static let rowTrailingBleed: CGFloat = 0
    static let panelTrailing: CGFloat = DS.Spacing.space4
    static let contentLeading: CGFloat = 10
    /// The room a panel keeps at its top corner for its show/hide button (iPad).
    static let panelToggleRoom: CGFloat = 44
    static let rowIconGap: CGFloat = 8  // lands at the gap between a panel's toggle button and its title
#endif
}
