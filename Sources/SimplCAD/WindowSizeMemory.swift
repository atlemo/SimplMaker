// Remembers the size of the document window between launches.
// Copyright © 2026 Atle Mo. All rights reserved.
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
            NotificationCenter.default.addObserver(self, selector: #selector(windowResized),
                                                   name: NSWindow.didEndLiveResizeNotification, object: window)
        }

        @objc private func windowResized() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            Preferences.rememberWindowSize(window.frame.size)
        }
    }
}

/// Put in a document window's content: while `dark`, the titlebar (the document title and the
/// toolbar buttons) draws in its dark appearance, so it reads white on Sketch mode's accent-coloured
/// toolbar. The content below keeps the system appearance.
struct TitlebarAppearance: NSViewRepresentable {
    let dark: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The window isn't known until the view is in it, so apply on the next turn of the run loop.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.appearance = dark ? NSAppearance(named: .darkAqua) : nil
            window.contentView?.appearance = dark ? NSApp.effectiveAppearance : nil
            // The title and subtitle labels keep their own colour whatever the appearance, so set it.
            guard let titlebar = window.contentView?.superview else { return }
            Self.recolorTitles(in: titlebar, dark: dark)
            // The subtitle ("Edited") can appear a moment after the first edit, so go over them again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak titlebar] in
                if let titlebar { Self.recolorTitles(in: titlebar, dark: dark) }
            }
        }
    }

    private static func recolorTitles(in view: NSView, dark: Bool) {
        if view.className == "NSToolbarTitleView" {
            for case let label as NSTextField in allSubviews(of: view) {
                let primary = label.className == "_NSToolbarTitleField"
                label.textColor = dark ? NSColor.white.withAlphaComponent(primary ? 1 : 0.75)
                                       : (primary ? .labelColor : .secondaryLabelColor)
            }
            return
        }
        for sub in view.subviews { recolorTitles(in: sub, dark: dark) }
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }
}
