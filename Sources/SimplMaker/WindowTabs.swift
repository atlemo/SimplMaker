// The window's tabs, drawn in the toolbar. Parts open as tabs of one window, and the system's own tab bar would take a row of its
// own under the toolbar, so it is kept hidden and the toolbar carries the tabs instead: one capsule beside the workspace selector.
// The tabs are still the system's (an NSWindowTabGroup), so Window → Move Tab to New Window and Merge All Windows keep working.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import SwiftUI

/// The tabs of the window's tab group, kept up to date, with what the strip can do to them.
@MainActor @Observable final class WindowTabs {
    struct Tab: Identifiable, Equatable {
        let id: Int  // the window's number
        let title: String
        let selected: Bool
    }

    private(set) var tabs: [Tab] = []
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []

    /// Starts following the tab group of `window`, in whichever window it is in now.
    func attach(to window: NSWindow) {
        guard self.window !== window else { return refresh() }
        self.window = window
        observers.forEach(NotificationCenter.default.removeObserver)
        // The group changes when a window joins or leaves it, and a window's tab group is a different object after that.
        observers = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.willCloseNotification].map {
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
        let windows = (group?.windows ?? [window]).filter { $0.isVisible || $0 === window }
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

    /// A new part, as a tab beside these. It is made the way File → New makes one; if the new window did not join this tab group by
    /// itself (the system only does that for a window it sees come to the front), it is added to it here.
    func newTab() {
        guard let current = window else { return NSDocumentController.shared.newDocument(nil) }
        let before = Set(NSApp.windows.map(\.windowNumber))
        NSDocumentController.shared.newDocument(nil)
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let new = NSApp.windows.first(where: { !before.contains($0.windowNumber) && $0.styleMask.contains(.titled) }) else { continue }
                if new.tabGroup !== current.tabGroup, new.tabbingMode != .disallowed {
                    current.addTabbedWindow(new, ordered: .above)
                    new.makeKeyAndOrderFront(nil)
                }
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

/// The tab strip: the window's tabs and a new-tab button in one capsule of the toolbar.
struct WindowTabStrip: View {
    let tabs: WindowTabs
    /// The ink the pills draw in on the tinted sketch band; nil on the plain view.
    let ink: Color?
    /// The window's width: the strip is as wide as the toolbar has room for between the workspace selector and the trailing pill, so it
    /// reads as a bar of its own and not as a few tabs floating in the middle. (The toolbar sizes a middle item to its content.)
    let windowWidth: CGFloat
    /// What the toolbar's other items and their gaps take: the traffic lights, the browser, undo and redo, the selector, and the trailing pill.
    static let reserved: CGFloat = 625
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
        .frame(minWidth: max(160, windowWidth - Self.reserved), maxWidth: .infinity)
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
            if hovering && count > 1 || tab.selected && count > 1 {
                Button { tabs.close(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close this part")
                .accessibilityLabel("Close \(tab.title)")
            }
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
