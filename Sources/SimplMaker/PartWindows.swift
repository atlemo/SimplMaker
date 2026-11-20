// Part windows and their tabs. Parts open as tabs of one window (the system's own tab group, so Move Tab to New Window and Merge All
// Windows keep working). The system's tab bar is kept hidden and a flat strip of our own hangs from the title bar instead, only while
// the window has two parts or more.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import os
import SwiftUI

/// The parts that are only a Start page (empty, on the Start workspace), by window number. Such a part is a launcher, not a part: it is not
/// a tab, a part made from it takes its place, and a part opened from it closes it.
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

/// What a part window tells the system about itself (whether it is only a Start page), and the tabs of its window's tab group, kept up
/// to date for the strip that hangs from the title bar.
@MainActor @Observable final class WindowChrome {
    struct Tab: Identifiable, Equatable {
        let id: Int  // the window's number
        let title: String
        let selected: Bool
    }

    /// The strip's height: a row of tabs with the same room above and below.
    static let stripHeight: CGFloat = 34

    private(set) var tabs: [Tab] = []
    /// This window's part is only a Start page (see `StartPageWindows`); kept here until the window is known.
    @ObservationIgnored private var isStartPage = false
    @ObservationIgnored private var pendingIcon: NSImage?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private weak var accessory: NSTitlebarAccessoryViewController?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []

    /// Starts following the tab group of `window`, and hangs the strip from its title bar.
    func attach(to window: NSWindow) {
        guard self.window !== window else { return refresh() }
        self.window = window
        PartWindows.adopt(window)
        StartPageWindows.set(window.windowNumber, isStartPage)
        TabIcons.shared.images[window.windowNumber] = pendingIcon
        installStrip(in: window)
        // A Start page opens in the middle of the screen it is on. Next turn of the run loop: the window's remembered size is applied
        // while it is being set up (see `WindowSizeMemory`), and the centre is the centre of that size.
        if isStartPage {
            DispatchQueue.main.async { [weak window] in
                if let window, !window.styleMask.contains(.fullScreen) { WindowControls.centre(window) }
            }
        }
        observers.forEach(NotificationCenter.default.removeObserver)
        // The group changes when a window joins or leaves it, and a window's tab group is a different object after that.
        observers = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification, .startPagesChanged].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
            }
        }
        refresh()
    }

    /// The strip is a titlebar accessory: it is part of the title bar, and the content starts below it.
    private func installStrip(in window: NSWindow) {
        let host = NSHostingView(rootView: WindowTabStrip(chrome: self))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: Self.stripHeight)
        let controller = NSTitlebarAccessoryViewController()
        controller.view = host
        controller.layoutAttribute = .bottom
        controller.isHidden = true  // until the window has a second part
        window.addTitlebarAccessoryViewController(controller)
        accessory = controller
    }

    /// Reads the group again and watches it: its windows, which is selected, and each window's title (a part gets its name when it
    /// is saved). The system's tab bar is hidden each time (see `SystemTabBar`).
    func refresh() {
        guard let window else { return }
        let group = window.tabGroup
        // A Start page is not a tab. (Unless nothing else is there.)
        let all = (group?.windows ?? [window]).filter { $0.isVisible || $0 === window }
        let parts = all.filter { !StartPageWindows.contains($0.windowNumber) }
        let windows = parts.isEmpty ? all : parts
        let selected = group?.selectedWindow ?? window
        let next = windows.map { Tab(id: $0.windowNumber, title: $0.title, selected: $0 === selected) }
        if next != tabs { tabs = next }
        // One part, one window: no tab bar.
        accessory?.isHidden = next.count < 2
        watches = []
        if let group {
            watches.append(group.observe(\.windows) { [weak self] _, _ in Task { @MainActor in self?.refresh() } })
            watches.append(group.observe(\.selectedWindow) { [weak self] _, _ in Task { @MainActor in self?.refresh() } })
        }
        for w in windows { watches.append(w.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }) }
        SystemTabBar.hideSoon()
    }

    /// The part's picture for its tab (nil: none yet, an empty part).
    func setIcon(_ png: Data?) {
        pendingIcon = png.flatMap { NSImage(data: $0) }
        if let window { TabIcons.shared.images[window.windowNumber] = pendingIcon }
    }

    /// This window's part is only a Start page, or is not any more.
    func setStartPage(_ on: Bool) {
        isStartPage = on
        if let window { StartPageWindows.set(window.windowNumber, on) }
    }

    private func window(_ id: Int) -> NSWindow? { window?.tabGroup?.windows.first { $0.windowNumber == id } ?? (window?.windowNumber == id ? window : nil) }

    func select(_ id: Int) {
        guard let target = window(id) else { return }
        target.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
    }

    func close(_ id: Int) { window(id)?.performClose(nil) }

    func closeOthers(than id: Int) {
        for tab in tabs where tab.id != id { window(tab.id)?.performClose(nil) }
    }

    func moveToNewWindow(_ id: Int) { window(id)?.moveTabToNewWindow(nil) }

    /// A new part, as a tab beside these (made the way File → New makes one).
    func newTab() {
        PartWindows.open(from: window) { NSDocumentController.shared.newDocument(nil) }
    }
}

/// The pictures of the open parts, by window number, for the tab strip (every window's strip shows all the tabs).
@MainActor @Observable final class TabIcons {
    static let shared = TabIcons()
    var images: [Int: NSImage] = [:]
}

/// How many part windows are open, readable from any thread: the `newDocument:` closure of the DocumentGroup runs on an operation
/// queue, where asking AppKit for its windows crashes. Counted by the windows themselves (see `WindowSizeMemory`).
enum OpenParts {
    private static let count = OSAllocatedUnfairLock(initialState: 0)
    static var any: Bool { count.withLock { $0 > 0 } }
    static func opened() { count.withLock { $0 += 1 } }
    static func closed() { count.withLock { $0 = max(0, $0 - 1) } }
}

/// Opens part windows as tabs. A part opened from a button or a menu through SwiftUI's `newDocument` or `openDocument` comes as a
/// window of its own: only File → New (the system's own) joins the front window's tabs. So the window that comes up is joined to
/// the tab group of the window the part was opened from. (The new window is not known to the caller, so it is the one that
/// appears while `create` runs and a moment after.) A Start page, which is only a launcher, is closed once the part it started has opened.
@MainActor enum PartWindows {
    /// The window whose tabs the next part window is to join. A new window joins them the moment it is set up (see `adopt`), before it
    /// is on screen; the wait in `join` is the fallback for a window that did not.
    private static weak var pendingAnchor: NSWindow?

    /// Called by a part window as it is being set up: if a part was opened from `pendingAnchor`, this window joins its tabs now, while
    /// it is still hidden, so it never shows as a window of its own first.
    static func adopt(_ window: NSWindow) {
        guard let anchor = pendingAnchor, anchor !== window, window.tabbingMode != .disallowed, !window.isVisible else { return }
        pendingAnchor = nil
        if window.tabGroup !== anchor.tabGroup { anchor.addTabbedWindow(window, ordered: .above) }
    }

    /// Runs `create`, which opens a part's window, and joins that window to `anchor`'s tabs (the front part window by default).
    static func open(from anchor: NSWindow? = nil, _ create: () -> Void) {
        let anchor = anchor ?? frontPartWindow()
        let before = Set(NSApp.windows.map(\.windowNumber))
        let closesAnchor = anchor.map { StartPageWindows.contains($0.windowNumber) } ?? false
        pendingAnchor = anchor
        create()
        join(after: before, to: anchor, closing: closesAnchor)
    }

    /// The same for something that opens the window asynchronously (opening a file).
    static func openAsync(from anchor: NSWindow? = nil, _ create: () async throws -> Void) async rethrows {
        let anchor = anchor ?? frontPartWindow()
        let before = Set(NSApp.windows.map(\.windowNumber))
        let closesAnchor = anchor.map { StartPageWindows.contains($0.windowNumber) } ?? false
        pendingAnchor = anchor
        try await create()
        join(after: before, to: anchor, closing: closesAnchor)
    }

    /// The front window that is one of the parts' (the Settings window and panels are not).
    private static func frontPartWindow() -> NSWindow? {
        // The key or main window, and failing those (the app is not the active one) the frontmost of its windows.
        ([NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows).first {
            $0.isVisible && $0.styleMask.contains(.titled) && $0.tabbingMode == .preferred && $0.tabGroup != nil
        }
    }

    /// Joins the window that came up to `anchor`'s tabs; `closing`: the anchor was a Start page, which has done its job.
    private static func join(after before: Set<Int>, to anchor: NSWindow?, closing: Bool) {
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let new = NSApp.windows.first(where: { !before.contains($0.windowNumber) && $0.styleMask.contains(.titled) && $0.tabbingMode != .disallowed }) else { continue }
                if let anchor, new.tabGroup !== anchor.tabGroup { anchor.addTabbedWindow(new, ordered: .above) }
                new.makeKeyAndOrderFront(nil)
                if closing, let anchor, new !== anchor { anchor.close() }
                pendingAnchor = nil
                return
            }
            pendingAnchor = nil
        }
    }
}

/// Keeps the system's tab bar hidden. The bar is a titlebar accessory under the toolbar; hiding the accessory takes its row away
/// too. (`toggleTabBar` does not do it for a window with several tabs, and it is one setting for all the app's windows, which
/// every window toggling at once made flip back and forth.) A window gets its accessory a moment after it opens, and the system
/// can put it back when tabs come and go, so this is run again at those times.
@MainActor enum SystemTabBar {
    static func hideSoon() {
        for delay in [0.0, 0.1, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { hideNow() }
        }
    }

    static func hideNow() {
        for window in NSApp.windows where window.styleMask.contains(.titled) {
            for accessory in window.titlebarAccessoryViewControllers where accessory.layoutAttribute == .bottom && !accessory.isHidden {
                if containsTabBar(accessory.view) { accessory.isHidden = true }
            }
        }
    }

    private static func containsTabBar(_ view: NSView) -> Bool {
        view.className.contains("TabBar") || view.subviews.contains { containsTabBar($0) }
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
/// The tab strip that hangs from the title bar: a flat row, the tabs and a new-tab button, drawn straight on the title bar's own colour
/// rather than on glass, with a hairline under it. It is in the title bar only while the window has two parts or more.
struct WindowTabStrip: View {
    let chrome: WindowChrome

    var body: some View {
        HStack(spacing: DS.Spacing.space1) {
            ForEach(chrome.tabs) { tab in
                TabButton(tab: tab, count: chrome.tabs.count, chrome: chrome)
            }
            Button { chrome.newTab() } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open a new part in a tab")
            .accessibilityLabel("New Tab")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.space3)
        .frame(maxWidth: .infinity)
        .frame(height: WindowChrome.stripHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

private struct TabButton: View {
    let tab: WindowChrome.Tab
    let count: Int
    let chrome: WindowChrome
    @State private var hovering = false

    var body: some View {
        // A tab in the background has a faint fill of its own, so it reads as a tab and not as loose text.
        let fill: Color = tab.selected ? Color.primary.opacity(0.12) : hovering ? Color.primary.opacity(0.09) : Color.primary.opacity(0.045)
        HStack(spacing: DS.Spacing.space2) {
            // The part's picture, tiny, like a favicon (a cube until the part has one).
            Group {
                if let image = TabIcons.shared.images[tab.id] {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                } else {
                    Image(systemName: "cube").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .accessibilityHidden(true)
            Text(tab.title)
                .font(.system(size: 12, weight: tab.selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The close button always has its room (only its look changes), so the tab keeps its size as the pointer comes and goes.
            let showsClose = hovering || tab.selected
            Button { chrome.close(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(showsClose ? 1 : 0)
            .allowsHitTesting(showsClose)
            .help("Close this part")
            .accessibilityLabel("Close \(tab.title)")
            .accessibilityHidden(!showsClose)
        }
        .foregroundStyle(tab.selected ? Color.primary : Color.secondary)
        .padding(.horizontal, DS.Spacing.space3)
        .frame(minWidth: 96, maxWidth: 200, minHeight: 26, maxHeight: 26)
        .background(fill, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { chrome.select(tab.id) }
        .contextMenu {
            Button("Close Tab") { chrome.close(tab.id) }
            Button("Close Other Tabs") { chrome.closeOthers(than: tab.id) }.disabled(count < 2)
            Divider()
            Button("Move Tab to New Window") { chrome.moveToNewWindow(tab.id) }.disabled(count < 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tab.selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(tab.title)
    }
}
#endif
