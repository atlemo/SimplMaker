// Remembers the size of the document window between launches.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

extension Preferences {
    static let windowSize = "documentWindowSize"

    /// The last size a document window was left at, if any.
    static var rememberedWindowSize: NSSize? {
        guard let s = UserDefaults.standard.string(forKey: windowSize) else { return nil }
        let size = NSSizeFromString(s)
        return size.width >= 200 && size.height >= 200 ? size : nil
    }

    static func rememberWindowSize(_ size: NSSize) {
        UserDefaults.standard.set(NSStringFromSize(size), forKey: windowSize)
    }
}

/// Put in a document window's content: opens the window at the size the last one was left at, and
/// keeps that size up to date as the window is resized.
struct WindowSizeMemory: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Tracker() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Tracker: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            guard let window, observer == nil else { return }
            if let size = Preferences.rememberedWindowSize, !window.styleMask.contains(.fullScreen) {
                let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? size
                let fitted = NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
                var frame = window.frame
                frame.origin.y += frame.height - fitted.height  // keep the top edge where it is
                frame.size = fitted
                window.setFrame(frame, display: true)
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { note in
                    guard let w = note.object as? NSWindow, !w.styleMask.contains(.fullScreen) else { return }
                    Preferences.rememberWindowSize(w.frame.size)
            }
        }
    }
}
