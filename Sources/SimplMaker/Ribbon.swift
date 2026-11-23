// The window's top bar: the ribbon, at the very top of the window and as wide as it. The window's controls (the traffic lights) are at
// its left, then the big workspace button, which opens the list of workspaces, then the workspace's tool groups, divided by thin
// lines, each with its name under its tools, and at the far right undo and redo. There is no system toolbar: the window's titlebar
// is transparent and the ribbon is drawn under it. In Sketch mode the ribbon sits on the tinted band (see ToolbarFade) and draws in the contrast ink.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import SwiftUI

/// The big button at the left of the ribbon: the current workspace's glyph and name, and a small "Workspace" under it. It opens the
/// list of workspaces.
struct WorkspaceButton: View {
    @Bindable var model: DocumentModel
    let ink: Color?
    /// Whether the list of workspaces is showing: it is drawn by the window, in a panel under the ribbon.
    @Binding var open: Bool
    static let width: CGFloat = 88
    @State private var hovering = false

    var body: some View {
        let workspace = model.workspace
        let colour: Color = ink ?? workspace.tint
        Button { open.toggle() } label: {
            VStack(spacing: DS.Spacing.space0) {
                Icon(workspace.symbol, size: 22, renderedStroke: Icon.toolStroke)
                Text(workspace.rawValue).font(.system(size: 13, weight: .semibold))
                HStack(spacing: DS.Spacing.space1) {
                    Text("Workspace").font(.system(size: 10))
                    Icon("chevron-down", size: 8, weight: .medium)
                }
                .opacity(0.7)
            }
            .foregroundStyle(colour)
            .frame(width: Self.width)
            .padding(.vertical, DS.Spacing.space3)
            .background(colour.opacity(hovering || open ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .toolTip("Change workspace: \(Workspace.available.map(\.rawValue).joined(separator: ", "))")
        .accessibilityLabel("Workspace: \(workspace.rawValue)")
    }
}

/// The list the workspace button opens, as a panel of glass under the ribbon: a tile with the glyph, the name, what it is for and what is in it, for each workspace.
struct WorkspaceList: View {
    @Bindable var model: DocumentModel
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WORKSPACE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Spacing.space5)
                .padding(.vertical, DS.Spacing.space4)
            // 1 pt between the rows, so the hover and current tints read as separate bars.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Workspace.available) { workspace in
                    WorkspaceRow(workspace: workspace, current: model.workspace == workspace) {
                        dismiss()
                        model.setWorkspace(workspace)
                    }
                }
            }
            Divider().padding(.top, DS.Spacing.space3)
            Text("Every workspace works on the same part and its history; only the tools and panels change. A sketch you are drawing is finished when you switch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DS.Spacing.space5)
        }
        .frame(width: 400)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous))
        .panelMaterial(in: RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous))
    }
}

private struct WorkspaceRow: View {
    let workspace: Workspace
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.space5) {
                Icon(workspace.symbol, size: 26, renderedStroke: Icon.toolStroke)
                    .foregroundStyle(workspace.tint)
                    .frame(width: 52, height: 52)
                    .background(workspace.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: DS.Radius.xl2, style: .continuous))
                VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                    HStack(spacing: DS.Spacing.space3) {
                        Text(workspace.rawValue).font(.headline)
                        if current { Badge(text: "Current", tint: workspace.tint) }
                        if workspace == .mold { Badge(text: "Experimental", tint: .secondary) }
                    }
                    Text(workspace.summary).font(.callout)
                    Text(workspace.contents).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.space5)
            .padding(.vertical, DS.Spacing.space4)
            .background(current ? workspace.tint.opacity(0.10) : hovering ? Color.primary.opacity(0.05) : .clear)
            .overlay(alignment: .leading) { Rectangle().fill(current ? workspace.tint : .clear).frame(width: 3) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(workspace.rawValue). \(workspace.summary)")
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

private struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, DS.Spacing.space3)
            .padding(.vertical, DS.Spacing.space1)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: The ribbon

/// Drags the window from the empty parts of the ribbon, and zooms it on a double click, as a titlebar does (the ribbon is drawn in the
/// titlebar's place).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class DragView: NSView {
        // AppKit drags the window itself from a view that says so; calling `performDrag` as well made it log "Window move completed
        // without beginning". A double click zooms, as on a titlebar.
        override var mouseDownCanMoveWindow: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(zoom))
            doubleClick.numberOfClicksRequired = 2
            addGestureRecognizer(doubleClick)
        }

        required init?(coder: NSCoder) { nil }

        @objc private func zoom() { window?.performZoom(nil) }
    }
}

/// The ribbon: one floating glass capsule under the window's title bar, like the panels. The workspace button, then (where the workspace has
/// tools) the tool row, which the window builds so it can measure it for the room it has, then undo and redo at the far right. `ink` is the
/// contrast ink on Sketch mode's tint, nil on the plain glass.
struct RibbonBar<Tools: View>: View {
    @Bindable var model: DocumentModel
    let ink: Color?
    let tint: Color
    @Binding var listOpen: Bool
    @ViewBuilder let tools: Tools

    /// What the ribbon keeps clear at each side of the tool row: the tools are centred in the window, so each side has to be as wide as the
    /// wider cluster, which is the left one (the workspace button; undo and redo are narrower), with the padding and a gap.
    static var sideRoom: CGFloat { Panel.inset + WorkspaceButton.width + 3 * DS.Spacing.space3 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous)
        ZStack {
            HStack(spacing: DS.Spacing.space3) {
                WorkspaceButton(model: model, ink: ink, open: $listOpen)
                Spacer(minLength: 0)
                UndoRedoButtons(model: model, ink: ink)
            }
            // The tools sit in the middle of the window, not next to the workspace button.
            if model.workspace.hasTools { tools }
        }
        .padding(.horizontal, DS.Spacing.space3)
        .padding(.vertical, DS.Spacing.space3)
        .environment(\.toolsOnTint, ink != nil)
        .environment(\.toolsInk, ink ?? .white)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Color.clear.panelMaterial(in: shape)
                shape.fill(tint).opacity(ink != nil ? 1 : 0)
            }
            .animation(.easeInOut(duration: DS.Duration.base), value: ink != nil)
        }
        .padding(.horizontal, Panel.inset)
        .padding(.top, Panel.inset)
    }
}

// MARK: Undo and redo

/// Undo and redo, at the far right of the ribbon.
struct UndoRedoButtons: View {
    @Bindable var model: DocumentModel
    /// The ink the buttons draw in on the tinted sketch band; nil on the plain view.
    let ink: Color?
    static let buttonWidth: CGFloat = 34
    @Environment(\.undoManager) private var undoManager
    /// Bumped when the undo history changes, so the buttons are read again.
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
        // Not the checkpoint notification: reading `canUndo` posts it, which would draw the buttons again, and so on.
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { _ in undoTick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { _ in undoTick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { _ in undoTick += 1 }
    }
}
#endif
