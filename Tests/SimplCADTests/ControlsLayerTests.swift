// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI
import Testing
@testable import SimplCAD

/// The viewport's controls sit in a layer on top of the window's SwiftUI content (over the
/// floating panels): clicks on them reach them, and clicks beside them reach the content.
@Suite @MainActor struct ControlsLayerTests {
    @Test func clicksReachTheControlsOverSwiftUIContent() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let content = NSHostingView(rootView: Color.gray.frame(maxWidth: .infinity, maxHeight: .infinity))
        window.contentView = content
        content.layoutSubtreeIfNeeded()

        // Beside the hosting view, in the window's frame view, not inside it.
        let frameView = try #require(content.superview)
        let layer = ControlsLayer(frame: frameView.convert(NSRect(x: 100, y: 100, width: 120, height: 40), from: content))
        let button = NSButton(title: "OK", target: nil, action: nil)
        button.frame = layer.bounds
        layer.addSubview(button)
        frameView.addSubview(layer, positioned: .above, relativeTo: nil)

        let onButton = content.convert(NSPoint(x: 160, y: 120), to: nil)
        #expect(frameView.hitTest(onButton) === button)
        let beside = content.convert(NSPoint(x: 20, y: 20), to: nil)
        let other = frameView.hitTest(beside)
        #expect(other !== button && other !== layer, "a click beside the controls reaches the content")
    }
}
