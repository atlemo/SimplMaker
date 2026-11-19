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
            // Every part has a window of its own: no tabs.
            window.tabbingMode = .disallowed
            window.titleVisibility = .hidden
            // The ribbon is the window's top bar, drawn under a transparent titlebar that keeps only the traffic lights.
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            // The traffic lights sit on the same line as the ribbon's icons. AppKit puts them back when the window resizes, is
            // activated or leaves full screen, so they are placed again then.
            for delay in [0.0, 0.1, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    if let window { WindowControls.place(in: window) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
                if let window { WindowControls.watch(window) }
            }
            // didUpdate too: AppKit moved the zoom button back to its own place on its own once (after a save, when the document's title and
            // edited state change), without a resize or an activation to hear about. A window update is the one thing that comes after
            // every such change, and placing is cheap when nothing has moved (see `WindowControls.place`).
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification, NSWindow.didUpdateNotification] {
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                    guard let window = note.object as? NSWindow else { return }
                    MainActor.assumeIsolated { WindowControls.place(in: window) }
                }
            }
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

/// Places a window's traffic lights. The ribbon is the window's top bar and taller than a titlebar, so the lights are moved down to sit
/// centred on the line through the middle of the ribbon, which is the line through undo and redo: the titlebar view is made twice that
/// far tall and the three buttons are centred in it. The ribbon reports its height (`setAxis`); until it does the lights use
/// `RibbonMetrics.defaultAxis`.
@MainActor enum WindowControls {
    private static var axes: [Int: CGFloat] = [:]
    /// Where AppKit puts each window's three buttons (their x), noted before they are first moved.
    private static var standardX: [Int: [CGFloat]] = [:]
    /// How far in from AppKit's own place the lights sit: where Finder and other windows with a toolbar have them.
    static let inset: CGFloat = 7
    /// Where a titlebar has the lights: the middle of its 28 pt.
    static let titlebarAxis: CGFloat = 14
    private static var placing = false

    /// Puts the window in the exact middle of its screen's usable area (NSWindow.center() sits a little above the middle).
    static func centre(_ window: NSWindow) {
        guard let area = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let origin = NSPoint(x: (area.midX - window.frame.width / 2).rounded(), y: (area.midY - window.frame.height / 2).rounded())
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    /// The line the lights are centred on, in points below the top of the window, for this window.
    static func setAxis(_ axis: CGFloat, for window: NSWindow) {
        guard axes[window.windowNumber] != axis else { return }
        axes[window.windowNumber] = axis
        place(in: window)
    }

    static func place(in window: NSWindow) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SIMPLMAKER_NO_LIGHTS"] == "1" { return }  // an experiment: leave the lights where AppKit has them
        #endif
        guard !placing, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let miniaturize = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let bar = close.superview, let container = bar.superview, let frameView = container.superview else { return }
        placing = true
        defer { placing = false }
        let height = (axes[window.windowNumber] ?? RibbonMetrics.defaultAxis) * 2
        // Already in place (the usual case on a window update): nothing to do.
        if let xs = standardX[window.windowNumber], container.frame.height == height, bar.frame == container.bounds,
           zip([close, miniaturize, zoom], xs).allSatisfy({ button, x in
               button.frame.origin == NSPoint(x: x + inset, y: ((height - button.frame.height) / 2).rounded()) }) { return }
        let frame = NSRect(x: 0, y: frameView.bounds.height - height, width: frameView.bounds.width, height: height)
        if container.frame != frame { container.frame = frame }
        if bar.frame != container.bounds { bar.frame = container.bounds }
        let buttons = [close, miniaturize, zoom]
        // AppKit's own x is noted the first time and kept: a placement made now is not mistaken for AppKit's later.
        if standardX[window.windowNumber] == nil { standardX[window.windowNumber] = buttons.map(\.frame.origin.x) }
        let xs = standardX[window.windowNumber] ?? buttons.map(\.frame.origin.x)
        for (button, x) in zip(buttons, xs) {
            let origin = NSPoint(x: x + inset, y: ((height - button.frame.height) / 2).rounded())
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    /// Places them again whenever AppKit moves them: it does when the window's appearance changes (Sketch mode flips it), as well as on
    /// resizes and activation.
    static func watch(_ window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton),
              let miniaturize = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let bar = close.superview, let container = bar.superview else { return }
        for view in [close, miniaturize, zoom, bar, container] {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak window] _ in
                guard let window else { return }
                MainActor.assumeIsolated { place(in: window) }
            }
        }
    }
}
