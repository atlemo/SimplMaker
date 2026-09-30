// A tooltip that AppKit shows for one view, in place of SwiftUI's `.help` where that misbehaves.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

extension View {
    /// Shows `text` when the pointer rests on this view. Unlike `.help`, each view gets its own
    /// AppKit tooltip area: in the toolbar, `.help`'s areas all belong to the one view hosting the
    /// tools, and they're re-registered whenever a tool redraws (as it does on hover), so moving
    /// between tools could briefly show the previous tool's tooltip.
    func toolTip(_ text: String) -> some View {
        background(ToolTipArea(text: text))
    }
}

private struct ToolTipArea: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }

    /// Only carries the tooltip: clicks and hovering go to the SwiftUI view on top.
    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
