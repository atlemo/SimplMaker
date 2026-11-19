// The window's top bar. The system toolbar (which keeps the traffic lights and the tabs) holds the browser toggle, undo and
// redo, the workspace selector (Design, Mold) and the panel toggles as pills; under it the tools of the workspace float over the
// view, each group on an island of its own. The islands sit on the same glass as the panels; in Sketch mode they sit on the
// tinted band instead (see ToolbarFade) and draw in the contrast ink.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// One island of the tool row: a rounded plate of glass, or on the tinted sketch band a soft plate of the contrast ink
    /// (the system's glass would pick its own brightness there).
    func island() -> some View { modifier(IslandStyle()) }
}

private struct IslandStyle: ViewModifier {
    @Environment(\.toolsOnTint) private var onTint
    @Environment(\.toolsInk) private var ink

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.xl3, style: .continuous)
        let padded = content
            .padding(.horizontal, DS.Spacing.space3)
            .padding(.vertical, DS.Spacing.space2)
        if onTint {
            padded.background(ink.opacity(0.16), in: shape)
        } else {
            padded.panelGlass(in: shape)
        }
    }
}

/// The row of tool islands under the window's toolbar. `tools` is the row the window builds, so it can measure it for the room it has.
struct IslandBar<Tools: View>: View {
    @ViewBuilder let tools: Tools

    var body: some View {
        tools
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Panel.inset)
            .padding(.top, Panel.inset)
    }
}

/// The toolbar's browser pill. The leading pills are items of their own in the window's toolbar (which keeps the traffic lights and
/// the tabs): in one item the system names every button after the first.
struct ToolbarBrowserPill: View {
    @Bindable var model: DocumentModel
    /// The ink the pills draw in on the tinted sketch band; nil on the plain view.
    let ink: Color?

    var body: some View {
        PanelToggle(title: "Browser", systemImage: "sidebar.left", ink: ink,
                    help: shortcutHelp("Show or hide the browser", .browser)) { model.showSidebar.toggle() }
            .disabled(model.workspace == .start)
            .toolbarGlass(ink: ink)
    }
}

/// Undo and redo.
struct ToolbarUndoRedoPill: View {
    @Bindable var model: DocumentModel
    let ink: Color?
    @Environment(\.undoManager) private var undoManager
    /// Bumped when the undo history changes, so the undo and redo buttons are read again.
    @State private var undoTick = 0

    var body: some View {
        _ = undoTick  // read, so a change to the history draws the buttons again
        let manager = undoManager ?? model.undoManager
        return HStack(spacing: 0) {
            PanelToggle(title: "Undo", systemImage: "arrow.uturn.backward", ink: ink, help: "Undo the last change") { manager?.undo() }
                .disabled(!(manager?.canUndo ?? false))
            PanelToggle(title: "Redo", systemImage: "arrow.uturn.forward", ink: ink, help: "Redo what was undone") { manager?.redo() }
                .disabled(!(manager?.canRedo ?? false))
        }
        .toolbarGlass(ink: ink)
        // Not the checkpoint notification: reading `canUndo` posts it, which would draw the buttons again, and so on.
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in undoTick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in undoTick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in undoTick += 1 }
    }
}

/// The toolbar's trailing pill: Hide UI and the inspector.
struct ToolbarTrailingPills: View {
    @Bindable var model: DocumentModel
    let ink: Color?

    var body: some View {
        HStack(spacing: 0) {
            PanelToggle(title: "Hide UI", systemImage: "rectangle.on.rectangle.slash", ink: ink,
                        help: shortcutHelp("Hide the panels and toolbar, leaving only the view", .hideUI)) { model.toggleUIHidden() }
                .disabled(model.workspace == .start)
            PanelToggle(title: "Inspector", systemImage: "sidebar.right", ink: ink,
                        help: shortcutHelp("Show or hide the inspector", .inspector)) { model.showInspector.toggle() }
                .disabled(model.workspace == .start)
        }
        .toolbarGlass(ink: ink)
    }
}

/// The workspace selector: one segment for each workspace, the current one lit.
struct WorkspaceSwitcher: View {
    @Bindable var model: DocumentModel
    let ink: Color?
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Workspace.available) { workspace in
                segment(workspace)
            }
        }
        .toolbarGlass(ink: ink)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace")
    }

    private func segment(_ workspace: Workspace) -> some View {
        let selected = model.workspace == workspace
        let text: Color = ink ?? (selected ? accent : .primary)
        let fill: Color = selected ? (ink?.opacity(0.24) ?? accent.opacity(0.16)) : .clear
        return Button { model.setWorkspace(workspace) } label: {
            Text(workspace.rawValue)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(text)
                .padding(.horizontal, DS.Spacing.space5)
                .frame(height: 28)
                .background(fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(workspace.help)
        .accessibilityLabel(workspace.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The Mold workspace's tool row. Only a stand-in so far: the studio's steps will be islands here, as the groups are in Design.
struct MoldToolbar: View {
    @Bindable var model: DocumentModel

    var body: some View {
        HStack(spacing: DS.Spacing.space4) {
            Label("Mold studio", systemImage: "cube.transparent")
                .font(.system(size: 13, weight: .semibold))
            Text("The mold's steps will be here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Back to Design") { model.setWorkspace(.design) }
                .controlSize(.small)
        }
        .padding(.horizontal, DS.Spacing.space3)
        .frame(height: 36)
        .island()
        .fixedSize()
    }
}
#endif
