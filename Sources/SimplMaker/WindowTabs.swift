// The window's tabs, drawn under the ribbon. Parts open as tabs of one window, and the system's own tab bar would take a row of its
// own, so it is kept hidden and a strip under the ribbon carries the tabs instead.
// The tabs are still the system's (an NSWindowTabGroup), so Window → Move Tab to New Window and Merge All Windows keep working.
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

/// The tabs of the window's tab group, kept up to date, with what the strip can do to them.
@MainActor @Observable final class WindowTabs {
    struct Tab: Identifiable, Equatable {
        let id: Int  // the window's number
        let title: String
        let selected: Bool
    }

    private(set) var tabs: [Tab] = []
    /// This window's part is only a Start page (see `StartPageWindows`); kept here until the window is known.
    @ObservationIgnored private var isStartPage = false
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []

    /// Starts following the tab group of `window`, in whichever window it is in now.
    func attach(to window: NSWindow) {
        guard self.window !== window else { return refresh() }
        self.window = window
        StartPageWindows.set(window.windowNumber, isStartPage)
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
        watches = []
        if let group {
            watches.append(group.observe(\.windows) { [weak self] _, _ in Task { @MainActor in self?.refresh() } })
            watches.append(group.observe(\.selectedWindow) { [weak self] _, _ in Task { @MainActor in self?.refresh() } })
        }
        for w in windows { watches.append(w.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }) }
        SystemTabBar.hideSoon()
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
/// appears while `create` runs and a moment after.)
@MainActor enum PartWindows {
    /// Runs `create`, which opens a part's window, and joins that window to `anchor`'s tabs (the front part window by default).
    static func open(from anchor: NSWindow? = nil, _ create: () -> Void) {
        let anchor = anchor ?? frontPartWindow()
        let before = Set(NSApp.windows.map(\.windowNumber))
        let closesAnchor = anchor.map { StartPageWindows.contains($0.windowNumber) } ?? false
        create()
        join(after: before, to: anchor, closing: closesAnchor)
    }

    /// The same for something that opens the window asynchronously (opening a file).
    static func openAsync(from anchor: NSWindow? = nil, _ create: () async throws -> Void) async rethrows {
        let anchor = anchor ?? frontPartWindow()
        let before = Set(NSApp.windows.map(\.windowNumber))
        let closesAnchor = anchor.map { StartPageWindows.contains($0.windowNumber) } ?? false
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
        guard let anchor else { return }
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let new = NSApp.windows.first(where: { !before.contains($0.windowNumber) && $0.styleMask.contains(.titled) && $0.tabbingMode != .disallowed }) else { continue }
                if new.tabGroup !== anchor.tabGroup { anchor.addTabbedWindow(new, ordered: .above) }
                new.makeKeyAndOrderFront(nil)
                if closing, new !== anchor { anchor.close() }
                return
            }
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

/// Put in a document window's content: tells `tabs` which window it is in.
struct WindowTabsAttach: NSViewRepresentable {
    let tabs: WindowTabs

    func makeNSView(context: Context) -> NSView { Finder(tabs: tabs) }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Finder: NSView {
        let tabs: WindowTabs
        init(tabs: WindowTabs) { self.tabs = tabs; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            guard let window else { return }
            // The window is not in its tab group yet while it is being made; look again on the next turn too.
            tabs.attach(to: window)
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.tabs.refresh() } }
        }
    }
}

/// The tab strip: the window's tabs and a new-tab button in one capsule, a row of its own under the ribbon.
struct WindowTabStrip: View {
    let tabs: WindowTabs
    /// The ink the pills draw in on the tinted sketch band; nil on the plain view.
    let ink: Color?
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: DS.Spacing.space2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.space1) {
                    ForEach(tabs.tabs) { tab in
                        TabButton(tab: tab, count: tabs.tabs.count, ink: ink, tabs: tabs)
                    }
                }
            }
            .scrollClipDisabled(false)
            PanelToggle(title: "New Tab", systemImage: "plus", ink: ink, help: "Open a new part in a tab") { tabs.newTab() }
        }
        .frame(maxWidth: .infinity)
        .toolbarGlass(ink: ink)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }
}

private struct TabButton: View {
    let tab: WindowTabs.Tab
    let count: Int
    let ink: Color?
    let tabs: WindowTabs
    @Environment(\.accent) private var accent
    @State private var hovering = false

    var body: some View {
        let text: Color = ink ?? (tab.selected ? accent : .primary)
        let fill: Color = tab.selected ? (ink?.opacity(0.24) ?? accent.opacity(0.16)) : hovering ? (ink ?? .primary).opacity(0.08) : .clear
        HStack(spacing: DS.Spacing.space2) {
            Text(tab.title)
                .font(.system(size: 13, weight: tab.selected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            // The close button always has its room (only its look changes), so the tab keeps its size as the pointer comes and goes.
            let showsClose = count > 1 && (hovering || tab.selected)
            Button { tabs.close(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(showsClose ? 1 : 0)
            .allowsHitTesting(showsClose)
            .help("Close this part")
            .accessibilityLabel("Close \(tab.title)")
            .accessibilityHidden(!showsClose)
        }
        .foregroundStyle(text)
        .padding(.horizontal, DS.Spacing.space5)
        .frame(minWidth: 72, maxWidth: 220, minHeight: 28)
        .background(fill, in: Capsule())
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture { tabs.select(tab.id) }
        .contextMenu {
            Button("Close Tab") { tabs.close(tab.id) }
            Button("Close Other Tabs") { tabs.closeOthers(than: tab.id) }.disabled(count < 2)
            Divider()
            Button("Move Tab to New Window") { tabs.moveToNewWindow(tab.id) }.disabled(count < 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tab.selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(tab.title)
    }
}
#endif
