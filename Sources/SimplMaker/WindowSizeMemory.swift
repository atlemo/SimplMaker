// Remembers the size of the document window between launches, and sets how document windows tab.
// Copyright © 2026 Atle Mo
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
        private var observed = false

        override func viewDidMoveToWindow() {
            guard let window, !observed else { return }
            if let size = Preferences.rememberedWindowSize, !window.styleMask.contains(.fullScreen) {
                let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? size
                let fitted = NSSize(width: min(size.width, visible.width), height: min(size.height, visible.height))
                var frame = window.frame
                frame.origin.y += frame.height - fitted.height  // keep the top edge where it is
                frame.size = fitted
                window.setFrame(frame, display: true)
            }
            observed = true
            OpenParts.opened()
            let number = window.windowNumber
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                OpenParts.closed()
                MainActor.assumeIsolated { StartPageWindows.set(number, false) }
            }
            // Parts open as tabs of one window; the system's tab bar is hidden and our own strip hangs from the title bar (see `WindowChrome`).
            window.tabbingMode = .preferred
            // A standard title bar: the traffic lights and the document's title are the system's. The ribbon floats in the content below.
            NotificationCenter.default.addObserver(self, selector: #selector(windowResized),
                                                   name: NSWindow.didEndLiveResizeNotification, object: window)
        }

        @objc private func windowResized() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            Preferences.rememberWindowSize(window.frame.size)
        }
    }
}

/// Put in a document window's content: while the toolbar is filled with `tint` (Sketch mode's colour),
/// the titlebar (the document title and the toolbar buttons) draws in whichever appearance contrasts
/// with it, white symbols on a deep tint and black on a pale one. The content below keeps the system
/// appearance; nil leaves both as the system draws them.
struct TitlebarAppearance: NSViewRepresentable {
    var tint: NSColor?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let tint = tint
        // The window isn't known until the view is in it, so apply on the next turn of the run loop.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            // The tint is judged as the content draws it (the system appearance), since that is what fills the toolbar.
            let system = NSApp.effectiveAppearance
            window.appearance = tint.flatMap { ContrastColor.appearance(for: $0, in: system) }
            window.contentView?.appearance = tint == nil ? nil : system
            // The title and subtitle labels keep their own colour whatever the appearance, so set it.
            guard let titlebar = window.contentView?.superview else { return }
            Self.recolorTitles(in: titlebar, on: tint, appearance: system)
            // The subtitle ("Edited") can appear a moment after the first edit, so go over them again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak titlebar] in
                if let titlebar { Self.recolorTitles(in: titlebar, on: tint, appearance: system) }
            }
        }
    }

    /// Colours the title and subtitle for `tint` behind them: whichever of black and white contrasts, the
    /// subtitle a little softer where that still passes. With no tint they go back to the system's colours.
    private static func recolorTitles(in view: NSView, on tint: NSColor?, appearance: NSAppearance) {
        if view.className == "NSToolbarTitleView" {
            for case let label as NSTextField in allSubviews(of: view) {
                let primary = label.className == "_NSToolbarTitleField"
                if let tint {
                    label.textColor = ContrastColor.foreground(on: tint, alpha: primary ? 1 : 0.75, in: appearance)
                } else {
                    label.textColor = primary ? .labelColor : .secondaryLabelColor
                }
            }
            return
        }
        for sub in view.subviews { recolorTitles(in: sub, on: tint, appearance: appearance) }
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }
}

@MainActor enum WindowControls {
    /// Puts the window in the exact middle of its screen's usable area (NSWindow.center() sits a little above the middle).
    static func centre(_ window: NSWindow) {
        guard let area = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let origin = NSPoint(x: (area.midX - window.frame.width / 2).rounded(), y: (area.midY - window.frame.height / 2).rounded())
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }
}
