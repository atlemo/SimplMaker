// The window's top bar: the ribbon, at the very top of the window and as wide as it. The window's controls (the traffic lights) are at
// its left, then the big workspace button, which opens the list of workspaces, then the workspace's tool groups, divided by thin
// lines, each with its name under its tools, and at the far right undo and redo. There is no system toolbar: the window's titlebar
// is transparent and the ribbon is drawn under it. With more than one part open the tabs make a row of their own under the ribbon. In
// Sketch mode the ribbon sits on the tinted band (see ToolbarFade) and draws in the contrast ink.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
import SwiftUI

// MARK: Workspaces, as the switcher shows them

extension Workspace {
    /// The glyph that stands for the workspace.
    var symbol: String {
        switch self {
        case .start: "house"
        case .design: "pen-tool"
        case .mold: "split-body"
        case .render: "camera"
        }
    }

    /// What it is for, in a line.
    var summary: String {
        switch self {
        case .start: "New and recent parts, and the ways to begin"
        case .design: "Sketch, model and change the part, step by step"
        case .mold: "Make a printable mold of a body, to cast copies of it"
        case .render: "Show the part on a floor with a light you set"
        }
    }

    /// What is in it.
    var contents: String {
        switch self {
        case .start: "New Part · Open · Tutorial · Recent parts"
        case .design: "Sketch · Create · Shapes · Modify · Construct · Inspect"
        case .mold: "Parting · Gate and vents · Keys · Export"
        case .render: "Floor · Light · Materials · Export image"
        }
    }

    /// The colour of its tile.
    var tint: Color {
        switch self {
        case .start: DS.brand
        case .design: Color(red: 0.22, green: 0.47, blue: 0.93)
        case .mold: Color(red: 0.09, green: 0.60, blue: 0.55)
        case .render: Color(red: 0.80, green: 0.27, blue: 0.55)
        }
    }
}

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
            ForEach(Workspace.available) { workspace in
                WorkspaceRow(workspace: workspace, current: model.workspace == workspace) {
                    dismiss()
                    model.setWorkspace(workspace)
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
        .panelGlass(in: RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous))
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

/// A thin line between the workspace button and the tools, and between tool groups.
struct RibbonDivider: View {
    @Environment(\.toolsOnTint) private var onTint
    @Environment(\.toolsInk) private var ink

    var body: some View {
        Rectangle()
            .fill((onTint ? ink : Color.primary).opacity(onTint ? 0.35 : 0.14))
            .frame(width: 1, height: 44)
    }
}

/// Drags the window from the empty parts of the ribbon, and zooms it on a double click, as a titlebar does (the ribbon is drawn in the
/// titlebar's place).
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
}

/// Measures of the ribbon that other code needs (a generic type cannot hold them).
enum RibbonMetrics {
    /// How far below the top of the window the middle of the ribbon is before it has been measured: the line the traffic lights follow.
    static let defaultAxis: CGFloat = 37
}

/// The ribbon: the window's controls' room, the workspace button and, where the workspace has tools, the tool row (which the window
/// builds, so it can measure it for the room it has), then undo and redo at the far right. `ink` is the contrast ink on the tinted
/// sketch band, nil on the plain view.
struct RibbonBar<Tools: View>: View {
    @Bindable var model: DocumentModel
    let ink: Color?
    @Binding var listOpen: Bool
    @ViewBuilder let tools: Tools

    /// The room the traffic lights take at the left.
    static var windowControls: CGFloat { 72 + WindowControls.inset }
    /// What the ribbon takes besides the tool row: the window controls, the workspace button, its divider, undo and redo, the gaps
    /// between them and the padding.
    static var chrome: CGFloat {
        windowControls + WorkspaceButton.width + 1 + 2 * UndoRedoButtons.buttonWidth + 5 * DS.Spacing.space3 + 2 * DS.Spacing.space3
    }

    var body: some View {
        HStack(spacing: DS.Spacing.space3) {
            Color.clear.frame(width: Self.windowControls, height: 1)
            WorkspaceButton(model: model, ink: ink, open: $listOpen)
            if model.workspace.hasTools {
                RibbonDivider()
                tools
            }
            Spacer(minLength: 0)
            UndoRedoButtons(model: model, ink: ink)
        }
        .padding(.horizontal, DS.Spacing.space3)
        .padding(.vertical, DS.Spacing.space3)
        .environment(\.toolsOnTint, ink != nil)
        .environment(\.toolsInk, ink ?? .white)
        .frame(maxWidth: .infinity)
        .background { WindowDragArea() }
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

/// The Mold workspace's tool row. Only a stand-in so far: the studio's steps will be tool groups here, as in Design.
struct MoldToolbar: View {
    @Bindable var model: DocumentModel

    var body: some View {
        HStack(spacing: DS.Spacing.space5) {
            Text("The mold's steps will be here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Back to Design") { model.setWorkspace(.design) }
                .controlSize(.small)
        }
        .frame(height: 36)
        .fixedSize()
    }
}
#endif
