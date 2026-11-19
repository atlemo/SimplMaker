// Part windows. Every part opens in a window of its own (the app has no tabs: see `PartWindows` and `WindowChrome`).
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import os
import SwiftUI

/// The parts that are only a Start page (empty, on the Start workspace), by window number. Such a part is a launcher, not a part: it is not
/// a part to keep, a part made from it takes its place, and a part opened from it closes it.
@MainActor enum StartPageWindows {
    private(set) static var numbers: Set<Int> = []

    static func contains(_ number: Int) -> Bool { numbers.contains(number) }

    static func set(_ number: Int, _ isStartPage: Bool) {
        let changed = isStartPage ? numbers.insert(number).inserted : numbers.remove(number) != nil
        if changed { NotificationCenter.default.post(name: .startPagesChanged, object: nil) }
    }
}

extension Notification.Name {
    /// A part became a Start page, or stopped being one.
    static let startPagesChanged = Notification.Name("simplmaker.startPagesChanged")
}

/// What a part window tells the system about itself: whether it is only a Start page, and where the ribbon's middle is (the traffic
/// lights are centred on it).
@MainActor @Observable final class WindowChrome {
    /// This window's part is only a Start page (see `StartPageWindows`); kept here until the window is known.
    @ObservationIgnored private var isStartPage = false
    /// The ribbon's height as last reported (0: none), kept until the window is known.
    @ObservationIgnored private var ribbonHeight: CGFloat = 0
    @ObservationIgnored private weak var window: NSWindow?

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        StartPageWindows.set(window.windowNumber, isStartPage)
        // A window that opens as the Start page comes up in the middle of the screen it is on. Next turn of the run loop: the window's
        // remembered size is applied while it is being set up (see `WindowSizeMemory`), and the centre is the centre of that size.
        if isStartPage {
            DispatchQueue.main.async { [weak window] in
                if let window, !window.styleMask.contains(.fullScreen) { WindowControls.centre(window) }
            }
        }
        if ribbonHeight > 0 { WindowControls.setAxis(ribbonHeight / 2, for: window) }
    }

    /// The ribbon's height: the traffic lights are centred on its middle, the same line as undo and redo.
    /// With no ribbon (the Start page, or the UI hidden) the lights are where a titlebar has them.
    func setRibbonHeight(_ height: CGFloat) {
        ribbonHeight = height
        if let window { WindowControls.setAxis(height > 0 ? height / 2 : WindowControls.titlebarAxis, for: window) }
    }

    /// This window's part is only a Start page, or is not any more.
    func setStartPage(_ on: Bool) {
        isStartPage = on
        if let window { StartPageWindows.set(window.windowNumber, on) }
    }
}

/// How many part windows are open, readable from any thread: the `newDocument:` closure of the DocumentGroup runs on an operation
/// queue, where asking AppKit for its windows crashes. Counted by the windows themselves (see `WindowSizeMemory`).
enum OpenParts {
    private static let count = OSAllocatedUnfairLock(initialState: 0)
    static var any: Bool { count.withLock { $0 > 0 } }
    static func opened() { count.withLock { $0 += 1 } }
    static func closed() { count.withLock { $0 = max(0, $0 - 1) } }
}

/// Opens part windows. Every part comes up as a window of its own; the one thing done here is that a Start page, which is only a
/// launcher, is closed once the part it started has opened.
@MainActor enum PartWindows {
    /// Runs `create`, which opens a part's window; if it was made from a Start page (`anchor`, the front part window by default) that page closes.
    static func open(from anchor: NSWindow? = nil, _ create: () -> Void) {
        let anchor = anchor ?? frontPartWindow()
        let before = Set(NSApp.windows.map(\.windowNumber))
        let closesAnchor = anchor.map { StartPageWindows.contains($0.windowNumber) } ?? false
        create()
        if closesAnchor, let anchor { closeAnchor(anchor, after: before) }
    }

    /// The same for something that opens the window asynchronously (opening a file).
    static func openAsync(from anchor: NSWindow? = nil, _ create: () async throws -> Void) async rethrows {
        let anchor = anchor ?? frontPartWindow()
        let before = Set(NSApp.windows.map(\.windowNumber))
        let closesAnchor = anchor.map { StartPageWindows.contains($0.windowNumber) } ?? false
        try await create()
        if closesAnchor, let anchor { closeAnchor(anchor, after: before) }
    }

    /// The front window that is one of the parts' (the Settings window and panels are not).
    private static func frontPartWindow() -> NSWindow? {
        // The key or main window, and failing those (the app is not the active one) the frontmost of its windows.
        ([NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows).first {
            $0.isVisible && $0.styleMask.contains(.titled) && $0.tabbingMode == .disallowed
        }
    }

    /// Waits for the window that came up (it appears a moment after `create` runs), brings it forward and closes the Start page.
    private static func closeAnchor(_ anchor: NSWindow, after before: Set<Int>) {
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let new = NSApp.windows.first(where: { !before.contains($0.windowNumber) && $0.styleMask.contains(.titled) }) else { continue }
                new.makeKeyAndOrderFront(nil)
                if new !== anchor { anchor.close() }
                return
            }
        }
    }
}

/// Put in a document window's content: tells `chrome` which window it is in.
struct WindowChromeAttach: NSViewRepresentable {
    let chrome: WindowChrome

    func makeNSView(context: Context) -> NSView { Finder(chrome: chrome) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Finder: NSView {
        let chrome: WindowChrome
        init(chrome: WindowChrome) { self.chrome = chrome; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            guard let window else { return }
            chrome.attach(to: window)
        }
    }
}
#endif
