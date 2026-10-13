// Remembers the size of the document window between launches, and sets how document windows tab.
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
            // Parts open as tabs of one window, with the tab bar showing even for one part, and the document's name
            // is in its tab rather than the toolbar.
            window.tabbingMode = .preferred
            window.titleVisibility = .hidden
            for delay in [0.0, 0.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    guard let window, let group = window.tabGroup, !group.isTabBarVisible else { return }
                    window.toggleTabBar(nil)
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
/// appearance. The window's tab bar takes the same tint; nil leaves both as the system draws them.
struct TitlebarAppearance: NSViewRepresentable {
    var tint: NSColor?

    /// Re-applies the tab tint when the window's tabs come and go or it becomes the front tab, since
    /// the system builds the tab bar's views anew then.
    @MainActor final class Coordinator {
        var observations: [NSObjectProtocol] = []
        var tabObservation: NSKeyValueObservation?
        var window: NSWindow?
        var tint: NSColor?

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            observations.forEach(NotificationCenter.default.removeObserver)
            observations = [NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification].map {
                NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reapply() } }
            }
            tabObservation = window.tabGroup?.observe(\.windows) { [weak self] _, _ in
                Task { @MainActor in self?.reapply() }
            }
        }

        func reapply() {
            guard let window else { return }
            TitlebarAppearance.applyTabTint(tint, in: window)
            // The tab bar's views can appear a moment after the tabs change.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let window = self.window else { return }
                TitlebarAppearance.applyTabTint(self.tint, in: window)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let tint = tint
        // The window isn't known until the view is in it, so apply on the next turn of the run loop.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            // The tint is judged as the content draws it (the system appearance), since that is what fills the toolbar.
            let system = NSApp.effectiveAppearance
            coordinator.tint = tint
            coordinator.attach(to: window)
            coordinator.reapply()
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

    private static let tabTintID = NSUserInterfaceItemIdentifier("simplmaker.tabTint")

    /// Colours the window's tab bar: the selected tab's glass takes the tint, and a wash of it goes
    /// under the tabs on the track. The tab bar is the system's, so this goes by its view classes and
    /// does nothing if they aren't there.
    static func applyTabTint(_ tint: NSColor?, in window: NSWindow) {
        guard let frame = window.contentView?.superview else { return }
        recolorSelectedTabTitle(in: frame, window: window, tint: tint)
        for view in allSubviews(of: frame) {
            if let glass = view as? NSGlassEffectView, glass.className == "NSGlassEffectView", isInTabBar(glass) {
                glass.tintColor = tint
            } else if view.className == "NSTabBarScrollView", let host = view.superview {
                let wash = host.subviews.first { $0.identifier == tabTintID }
                guard let tint else { wash?.removeFromSuperview(); continue }
                let layerView = wash ?? NSView()
                if wash == nil {
                    layerView.identifier = tabTintID
                    layerView.wantsLayer = true
                    layerView.autoresizingMask = [.width, .height]
                    layerView.frame = host.bounds
                    host.addSubview(layerView, positioned: .below, relativeTo: view)
                }
                layerView.layer?.backgroundColor = tint.withAlphaComponent(0.55).cgColor
                layerView.layer?.cornerRadius = host.bounds.height / 2
            }
        }
    }

    /// The selected tab's title is drawn in the system's own text colour, which can be hard to read
    /// on the tint. Whichever of white and black contrasts more with the tint wins: that tab draws
    /// in the dark or the light appearance to get it, and the others keep the system's.
    private static func recolorSelectedTabTitle(in frame: NSView, window: NSWindow, tint: NSColor?) {
        guard let bar = allSubviews(of: frame).first(where: { $0.className == "NSTabBar" }) else { return }
        let buttons = allSubviews(of: bar).filter { $0.className == "NSTabButton" }.sorted { $0.frame.minX < $1.frame.minX }
        let tabs = window.tabGroup?.windows ?? []
        let selected = window.tabGroup?.selectedWindow.flatMap { tabs.firstIndex(of: $0) }
        let appearance = tint.flatMap { ContrastColor.appearance(for: $0) }
        for (i, button) in buttons.enumerated() {
            button.appearance = i == selected ? appearance ?? nil : nil
        }
    }

    private static func isInTabBar(_ view: NSView) -> Bool {
        var v: NSView? = view.superview
        while let current = v {
            if current.className == "NSTabBar" { return true }
            v = current.superview
        }
        return false
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
