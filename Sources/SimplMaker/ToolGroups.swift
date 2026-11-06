// Toolbar tool groups: each group shows the tools pinned to it as buttons, with the group's name
// underneath. The name opens the whole group, where any tool can be run, and pinned to the
// toolbar or unpinned, so the toolbar needn't grow as tools are added.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Which of a group's tools show as toolbar buttons (the rest are in the group's list), saved per
/// group as comma-separated tool ids. Nothing saved means the group's defaults.
struct ToolPins: Equatable {
    private(set) var ids: [String]

    /// The saved pins, keeping only tools the group still has.
    init(stored: String?, available: [String], defaults: [String]) {
        let saved = stored.map { $0.split(separator: ",").map(String.init) } ?? defaults
        var ids: [String] = []
        for id in saved where available.contains(id) && !ids.contains(id) { ids.append(id) }
        self.ids = ids
    }

    var stored: String { ids.joined(separator: ",") }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Pins the tool, or unpins it.
    mutating func toggle(_ id: String) {
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
    }
}

/// A tool in a toolbar group: its button when pinned, and its row in the group's list.
struct GroupTool: Identifiable {
    let id: String
    let title: String
    let icon: String
    var help: String
    var shortcut: String?
    /// A small label after the name in the group's list ("Experimental").
    var badge: String?
    var active = false
    var enabled = true
    /// Ways of doing it (a rectangle from two corners, or from its center). The button does the
    /// one used last; a small arrow beside it, or the chips in the group's list, pick another.
    var modes: [GroupTool] = []
    /// A popover the tool asks for (the offset distance, the list of constraints). It opens on the
    /// tool's button, or on the group's name while the tool isn't in the toolbar.
    var popover: ToolPopover?
    let action: () -> Void
}

struct ToolPopover {
    let isPresented: Binding<Bool>
    let content: AnyView
}

/// A group of tools: the pinned ones as buttons, and the group's name underneath, which opens
/// the whole group.
struct ToolGroup: View {
    let title: String
    let tools: [GroupTool]
    private let defaults: [String]
    @AppStorage private var stored: String?
    @State private var listOpen = false
    /// How many of the pinned buttons the window has no room for, taken from the end. The group keeps
    /// at least one; the tools taken out are in the group's list, like any tool that isn't pinned.
    @Environment(\.toolTrim) private var trim

    init(_ title: String, id: String, defaults: [String], tools: [GroupTool]) {
        self.title = title
        self.tools = tools
        self.defaults = defaults
        _stored = AppStorage(Preferences.toolbarPins(id))
    }

    init(_ spec: ToolGroupSpec) { self.init(spec.title, id: spec.id, defaults: spec.defaults, tools: spec.tools) }

    private var pins: ToolPins { ToolPins(stored: stored, available: tools.map(\.id), defaults: defaults) }

    var body: some View {
        let pins = pins
        let pinned = tools.filter { pins.contains($0.id) }
        let shown = Array(pinned.dropLast(min(trim, max(pinned.count - 1, 0))))
        let hidden = tools.filter { tool in !shown.contains { $0.id == tool.id } }
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.space1) {
                ForEach(shown) { tool in
                    PinnedTool(tool: tool)
                        .contextMenu {
                            Button("Remove from Toolbar") { toggle(tool.id) }
                            Button("Show All \(title) Tools") { listOpen = true }
                        }
                }
            }
            .environment(\.toolTitles, false)
            groupButton(hidden: hidden)
        }
    }

    /// The group's name: opens the whole group. It also carries the popovers of tools that aren't
    /// in the toolbar.
    private func groupButton(hidden: [GroupTool]) -> some View {
        GroupLabel(title: title, chevron: true,
                   highlighted: hidden.contains { $0.active }) { listOpen.toggle() }
            .toolTip("All \(title) tools. Pin the ones you use to the toolbar.")
            .tutorialSpot(anyOf: hidden.map(\.title), cornerRadius: DS.Radius.sm, outset: 1)  // a tool the tutorial wants, not pinned: its group
            .accessibilityLabel("\(title) tools")
            .popover(isPresented: $listOpen, arrowEdge: ToolListMetrics.arrowEdge) {
                ScrollingList {
                    ToolGroupList(title: title, tools: tools, pins: pins, isDefault: stored == nil,
                                  run: run, toggle: toggle, restore: { stored = nil })
                }
                .environment(\.toolsOnTint, false)
                .environment(\.toolTitles, true)
            }
            .background {
                ForEach(hidden.filter { $0.popover != nil }) { tool in
                    Color.clear.toolPopover(tool.popover)
                }
            }
    }

    private func toggle(_ id: String) {
        var pins = pins
        pins.toggle(id)
        stored = pins.stored
    }

    /// Runs a tool from the list. The list closes first, so a popover the tool asks for can open
    /// in its place.
    private func run(_ tool: GroupTool) {
        listOpen = false
        if tool.popover != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                tool.action()
            }
        } else {
            tool.action()
        }
    }
}

/// What a toolbar group is made of, so the toolbar and its compact forms list the same tools.
struct ToolGroupSpec: Identifiable {
    let title: String
    let id: String
    let defaults: [String]
    let tools: [GroupTool]
}

/// How much room the toolbar's tools take, widest first: the groups with their pinned tools, then
/// with one pinned tool fewer in each group at a time (down to one in each), and last of all one menu
/// holding everything.
enum ToolbarLayout: Hashable {
    case trimmed(Int)
    case single

    static let full = ToolbarLayout.trimmed(0)
}

extension EnvironmentValues {
    /// How many pinned tools each toolbar group leaves out for want of room.
    @Entry var toolTrim = 0
}

/// The rows of a tool menu: every tool, pinned or not. A tool with several ways of working
/// (a rectangle from corners or from its center) is a submenu of them.
private struct ToolMenuRows: View {
    let tools: [GroupTool]

    var body: some View {
        ForEach(tools) { tool in
            if tool.modes.isEmpty {
                Toggle(tool.title, isOn: Binding(get: { tool.active }, set: { _ in run(tool) }))
                    .disabled(!tool.enabled)
            } else {
                Menu(tool.title) {
                    ForEach(tool.modes) { mode in
                        Toggle(mode.title, isOn: Binding(get: { mode.active }, set: { _ in mode.action() }))
                    }
                }
                .disabled(!tool.enabled)
            }
        }
    }

    /// Runs a tool. The menu closes first, so a popover the tool asks for can open in its place.
    private func run(_ tool: GroupTool) {
        guard tool.popover != nil else { return tool.action() }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            tool.action()
        }
    }
}

private extension View {
    /// The popovers of tools that sit in a menu, which open on the menu's button.
    func toolPopovers(_ tools: [GroupTool]) -> some View {
        background {
            ForEach(tools.filter { $0.popover != nil }) { tool in
                Color.clear.toolPopover(tool.popover)
            }
        }
    }
}

/// The whole toolbar as one menu, for a window too narrow even for one tool in each group: every tool of
/// every group. A tool that asks for a popover gets it on the menu's button.
struct ToolsMenu: View {
    let solo: GroupTool
    let groups: [ToolGroupSpec]
    /// What comes after the groups (Finish Sketch).
    var trailing: GroupTool?

    var body: some View {
        Menu {
            ToolMenuRows(tools: [solo])
            ForEach(groups) { group in
                Section(group.title) { ToolMenuRows(tools: group.tools) }
            }
            if let trailing {
                Divider()
                ToolMenuRows(tools: [trailing])
            }
        } label: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
        .menuIndicator(.visible)
        .help("All the tools")
        .accessibilityLabel("Tools")
        .toolPopovers([solo] + groups.flatMap(\.tools))
    }
}

/// A tool that stands alone (Select, Sketch), laid out like a group so its icon lines up with
/// theirs: the icon, and its name underneath, which runs it too.
struct SoloTool: View {
    let tool: GroupTool

    var body: some View {
        VStack(spacing: 0) {
            PinnedTool(tool: tool).environment(\.toolTitles, false)
            GroupLabel(title: tool.title, chevron: false, highlighted: tool.active, action: tool.action)
                .toolTip(tool.help)
                .accessibilityHidden(true)  // the button above says the same
        }
    }
}

/// A group's name under its tools, with an arrow when it opens the group.
private struct GroupLabel: View {
    @Environment(\.accent) private var accent
    let title: String
    let chevron: Bool
    let highlighted: Bool
    let action: () -> Void
    @Environment(\.toolsOnTint) private var onTint
    @Environment(\.toolsInk) private var toolsInk
    @State private var hovering = false

    private var ink: Color { onTint ? toolsInk : .primary }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.space1) {
                Text(title).font(.system(size: 11)).lineLimit(1).fixedSize()
                if chevron { Icon("chevron-down", size: 9, weight: .medium) }
            }
            .padding(.horizontal, ToolListMetrics.labelPadding)
            .frame(minHeight: ToolListMetrics.labelMinHeight)
            .foregroundStyle(highlighted && !onTint ? accent : ink.opacity(highlighted ? 1 : 0.8))
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .contentShape(Rectangle())
            .platformFocusShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if highlighted { return onTint ? toolsInk.opacity(0.24) : accent.opacity(0.16) }
        return hovering ? ink.opacity(onTint ? 0.14 : 0.07) : .clear
    }
}

/// A tool's button in the toolbar; a tool with several ways of working gets a small arrow beside
/// it to choose the way.
private struct PinnedTool: View {
    let tool: GroupTool
    @State private var modesOpen = false
    @Environment(\.toolsOnTint) private var onTint
    @Environment(\.toolsInk) private var toolsInk

    var body: some View {
        if tool.modes.isEmpty {
            button
        } else {
            HStack(spacing: 0) {
                button
                Button { modesOpen = true } label: {
                    Icon("chevron-down", size: 10)
                        .frame(width: ToolListMetrics.arrowSize.width, height: ToolListMetrics.arrowSize.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(onTint ? toolsInk : Color.primary)
                .toolTip("Choose how to draw the \(tool.title.lowercased())")
                .accessibilityLabel("\(tool.title) options")
                .popover(isPresented: $modesOpen, arrowEdge: ToolListMetrics.arrowEdge) {
                    HStack(spacing: DS.Spacing.space1) {
                        ForEach(tool.modes) { mode in
                            ToolButton(title: mode.title, icon: mode.icon, active: mode.active, help: mode.help) {
                                modesOpen = false
                                mode.action()
                            }
                        }
                    }
                    .environment(\.toolTitles, true)
                    .environment(\.toolsOnTint, false)
                    .padding(DS.Spacing.space3)
                }
            }
        }
    }

    private var button: some View {
        ToolButton(title: tool.title, icon: tool.icon, active: tool.active, help: tool.help, action: tool.action)
            .disabled(!tool.enabled)
            .toolPopover(tool.popover)
    }
}

/// Everything in a group, opened from its name: click a tool to use it, or its pin to show it in
/// the toolbar or take it out.
private struct ToolGroupList: View {
    let title: String
    let tools: [GroupTool]
    let pins: ToolPins
    let isDefault: Bool
    let run: (GroupTool) -> Void
    let toggle: (String) -> Void
    let restore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tools) { tool in
                ToolGroupRow(tool: tool, pinned: pins.contains(tool.id), run: run, toggle: { toggle(tool.id) })
            }
            Divider().padding(.vertical, DS.Spacing.space3)
            HStack(alignment: .firstTextBaseline) {
                Text("Pinned tools show in the toolbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.space4)
                Button("Restore Defaults", action: restore)
                    .buttonStyle(.platformLink)
                    .font(.caption)
                    .disabled(isDefault)
            }
            .padding(.horizontal, DS.Spacing.space3)
        }
        .padding(DS.Spacing.space3)
        .frame(width: ToolListMetrics.listWidth)
        .focusEffectDisabled()  // no focus ring on the first row as the list opens
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) tools")
    }
}

/// A popover's content that scrolls when it is taller than the room (the iPad's long Modify list); on the Mac it is just the content.
private struct ScrollingList<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var height: CGFloat = 400

    var body: some View {
#if os(macOS)
        content
#else
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        // Never taller than the room the popover has below the toolbar: a taller one is cropped at the top and the bottom alike, and the
        // first tool cannot be reached. The rest scrolls.
        .frame(height: min(height, max(min(560, UIScreen.main.bounds.height - 270), 240)))
        .scrollBounceBehavior(.basedOnSize)
#endif
    }
}

/// Sizes of the lists the toolbar opens: roomy on the iPad, where a finger taps them.
enum ToolListMetrics {
#if os(macOS)
    /// The edge of the popover that carries its arrow: on the Mac `.bottom` opens it below the toolbar.
    static let arrowEdge = Edge.bottom
    static let rowHeight: CGFloat = 28
    static let smallButton: CGFloat = 22
    static let listWidth: CGFloat = 290
    static let labelMinHeight: CGFloat = 14
    static let toolMinWidth: CGFloat = 28
    static let toolMinHeight: CGFloat = 24
    static let titledToolPadding: CGFloat = DS.Spacing.space1
    static let labelPadding: CGFloat = DS.Spacing.space2
    static let arrowSize = CGSize(width: 12, height: 24)
#else
    /// On the iPad the edge names where the arrow sits on the popover, so `.top` opens it below the button.
    static let arrowEdge = Edge.top
    static let rowHeight: CGFloat = 52
    static let smallButton: CGFloat = 44
    static let listWidth: CGFloat = 360
    /// The group names and the arrows beside tools sit in a bar drawn 1.3 times bigger: 34 points here is 44 on the screen.
    static let labelMinHeight: CGFloat = 34
    static let toolMinWidth: CGFloat = 38
    static let toolMinHeight: CGFloat = 36
    static let titledToolPadding: CGFloat = 8
    static let labelPadding: CGFloat = 14
    static let arrowSize = CGSize(width: 24, height: 36)
#endif
}

private struct ToolGroupRow: View {
    @Environment(\.accent) private var accent
    let tool: GroupTool
    let pinned: Bool
    let run: (GroupTool) -> Void
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Spacing.space2) {
            Button { run(tool) } label: {
                HStack(spacing: DS.Spacing.space4) {
                    Icon(tool.icon, size: 16, renderedStroke: Icon.toolStroke).frame(width: 20)
                    Text(tool.title).lineLimit(1)
                    if let badge = tool.badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.85), in: Capsule())
                    }
                    Spacer(minLength: DS.Spacing.space4)
                }
                .foregroundStyle(tool.active ? accent : .primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!tool.enabled)
            .opacity(tool.enabled ? 1 : DS.opacityDisabled)
            .help(tool.help)
            ForEach(tool.modes) { mode in
                Button { run(mode) } label: {
                    Icon(mode.icon, size: 14, renderedStroke: Icon.toolStroke)
                        .frame(width: ToolListMetrics.smallButton, height: ToolListMetrics.smallButton)
                        .background(mode.active ? accent.opacity(0.16) : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                        .foregroundStyle(mode.active ? accent : .primary)
                        .contentShape(Rectangle())
                        .platformFocusShape(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode.help)
                .accessibilityLabel("\(tool.title), \(mode.title)")
            }
            Text(tool.shortcut ?? "")
                .foregroundStyle(.secondary)
                .frame(minWidth: 16)
                .accessibilityHidden(true)
            Button(action: toggle) {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .frame(width: ToolListMetrics.smallButton, height: ToolListMetrics.smallButton)
                    .foregroundStyle(pinned ? accent : .secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pinned ? "Remove from the toolbar" : "Show in the toolbar")
            .accessibilityLabel(pinned ? "Unpin \(tool.title)" : "Pin \(tool.title)")
        }
        .padding(.horizontal, DS.Spacing.space3)
        .frame(height: ToolListMetrics.rowHeight)
        .background(hovering ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.menuItem, style: .continuous))
        .onHover { hovering = $0 }
    }
}

private extension View {
    /// Shows a tool's popover on this view, if it has one.
    @ViewBuilder func toolPopover(_ popover: ToolPopover?) -> some View {
        if let popover {
            self.popover(isPresented: popover.isPresented, arrowEdge: ToolListMetrics.arrowEdge) { popover.content }
        } else {
            self
        }
    }
}

extension View {
    /// The shape of the keyboard focus ring: the Mac draws one for a plain button; on the iPad it is left to the system.
    @ViewBuilder func platformFocusShape<S: Shape>(_ shape: S) -> some View {
        #if os(macOS)
        contentShape(.focusEffect, shape)
        #else
        self
        #endif
    }
}

extension PrimitiveButtonStyle where Self == PlainButtonStyle {
    /// A link-looking button: the Mac's `.link`, and a plain one on the iPad.
    static var platformLink: PlainButtonStyle { PlainButtonStyle() }
}

extension View {
    /// A tick box on the Mac; the iPad's own switch.
    @ViewBuilder func platformCheckbox() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        self
        #endif
    }
}
