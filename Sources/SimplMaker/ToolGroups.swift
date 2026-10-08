// Toolbar tool groups: each group shows the tools pinned to it as buttons, with the group's name
// underneath. The name opens the whole group, where any tool can be run, and pinned to the
// toolbar or unpinned, so the toolbar needn't grow as tools are added.
// Copyright © 2026 Atle Mo. All rights reserved.
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
        let shown = tools.filter { pins.contains($0.id) }
        let hidden = tools.filter { !pins.contains($0.id) }
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
            .popover(isPresented: $listOpen, arrowEdge: .bottom) {
                ToolGroupList(title: title, tools: tools, pins: pins, isDefault: stored == nil,
                              run: run, toggle: toggle, restore: { stored = nil })
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

/// How much room the toolbar's tools take, widest first: the groups with their pinned tools, one
/// menu per group, and last of all one menu holding everything.
enum ToolbarLayout: String {
    case full, groups, single
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

/// A group as one menu with all its tools, for a window too narrow for the pinned tools.
struct ToolGroupMenu: View {
    let group: ToolGroupSpec
    @Environment(\.toolsOnTint) private var onTint

    var body: some View {
        Menu(group.title) { ToolMenuRows(tools: group.tools) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .tint(onTint ? Color.white : Color.primary)  // not the accent colour
            .fixedSize()
            .toolPopovers(group.tools)
            .help("All \(group.title) tools")
            .accessibilityLabel("\(group.title) tools")
    }
}

/// A tool that stands alone, as a text button next to the group menus.
struct SoloToolButton: View {
    let tool: GroupTool
    @Environment(\.toolsOnTint) private var onTint
    @Environment(\.accent) private var accent

    var body: some View {
        Button(action: tool.action) {
            Text(tool.title).font(.system(size: 13))
                .foregroundStyle(tool.active && !onTint ? accent : onTint ? Color.white : Color.primary)
                .padding(.horizontal, DS.Spacing.space3)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tool.enabled)
        .help(tool.help)
    }
}

/// The whole toolbar as one menu, for a window too narrow even for the group menus: every tool of
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
    @State private var hovering = false

    private var ink: Color { onTint ? .white : .primary }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.space1) {
                Text(title).font(.system(size: 11)).lineLimit(1).fixedSize()
                if chevron { Icon("chevron-down", size: 9, weight: .medium) }
            }
            .padding(.horizontal, DS.Spacing.space2)
            .frame(minHeight: 14)
            .foregroundStyle(highlighted && !onTint ? accent : ink.opacity(highlighted ? 1 : 0.8))
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
            .contentShape(Rectangle())
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if highlighted { return onTint ? Color.white.opacity(0.24) : accent.opacity(0.16) }
        return hovering ? ink.opacity(onTint ? 0.14 : 0.07) : .clear
    }
}

/// A tool's button in the toolbar; a tool with several ways of working gets a small arrow beside
/// it to choose the way.
private struct PinnedTool: View {
    let tool: GroupTool
    @State private var modesOpen = false
    @Environment(\.toolsOnTint) private var onTint

    var body: some View {
        if tool.modes.isEmpty {
            button
        } else {
            HStack(spacing: 0) {
                button
                Button { modesOpen = true } label: {
                    Icon("chevron-down", size: 10)
                        .frame(width: 12, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(onTint ? Color.white : Color.primary)
                .toolTip("Choose how to draw the \(tool.title.lowercased())")
                .accessibilityLabel("\(tool.title) options")
                .popover(isPresented: $modesOpen, arrowEdge: .bottom) {
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
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(isDefault)
            }
            .padding(.horizontal, DS.Spacing.space3)
        }
        .padding(DS.Spacing.space3)
        .frame(width: 290)
        .focusEffectDisabled()  // no focus ring on the first row as the list opens
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) tools")
    }
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
                        .frame(width: 22, height: 22)
                        .background(mode.active ? accent.opacity(0.16) : Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                        .foregroundStyle(mode.active ? accent : .primary)
                        .contentShape(Rectangle())
                        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
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
                    .frame(width: 22, height: 22)
                    .foregroundStyle(pinned ? accent : .secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pinned ? "Remove from the toolbar" : "Show in the toolbar")
            .accessibilityLabel(pinned ? "Unpin \(tool.title)" : "Pin \(tool.title)")
        }
        .padding(.horizontal, DS.Spacing.space3)
        .frame(height: 28)
        .background(hovering ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.menuItem, style: .continuous))
        .onHover { hovering = $0 }
    }
}

private extension View {
    /// Shows a tool's popover on this view, if it has one.
    @ViewBuilder func toolPopover(_ popover: ToolPopover?) -> some View {
        if let popover {
            self.popover(isPresented: popover.isPresented, arrowEdge: .bottom) { popover.content }
        } else {
            self
        }
    }
}
