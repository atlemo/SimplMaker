// The iPhone Duo's vertical bar: the strip the system reserves down one edge of the open screen. Toolbar items marked vertical-preferred
// go there (iOS 27.1): the way back, the workspace switcher, undo, redo, the view, help, settings and share, so the top bar keeps only the
// title. Where the system has no such bar (an iPad, the folded Duo) the navigation bar stays hidden and the top bar keeps everything.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct PadDuoBar: ViewModifier {
    let model: DocumentModel
    let guide: TutorialGuide
    let undoManager: UndoManager?
    /// Too small to design in: only the way back and share are in the bar.
    let viewer: Bool
    let onClose: () -> Void
    /// Set to whether the system's vertical bar is there.
    @Binding var active: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(Inner(model: model, guide: guide, undoManager: undoManager, viewer: viewer, onClose: onClose, active: $active))
        } else {
            content.toolbarVisibility(.hidden, for: .navigationBar)
        }
    }

    @available(iOS 27.1, *)
    private struct Inner: ViewModifier {
        let model: DocumentModel
        let guide: TutorialGuide
        let undoManager: UndoManager?
        let viewer: Bool
        let onClose: () -> Void
        @Binding var active: Bool
        /// The edge the system's vertical bar is on; nil where it never puts one.
        @Environment(\.toolbarVerticalEdge) private var edge

        func body(content: Content) -> some View {
            content
                // The bar's items need the navigation bar to be there (it is empty and clear: our own top bar is the one drawn).
                .toolbarVisibility(edge == nil ? .hidden : .automatic, for: .navigationBar)
                .onChange(of: edge != nil, initial: true) { active = edge != nil }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Parts", systemImage: "chevron.left", action: onClose)
                            .tint(.primary)
                    }
                    .axisBehavior(.verticalPreferred)
                    if !viewer {
                        ToolbarItem(placement: .topBarLeading) { PadWorkspaceMenu(model: model) }
                            .axisBehavior(.verticalPreferred)
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Undo", systemImage: "arrow.uturn.backward") { undoManager?.undo() }
                                .disabled(undoManager?.canUndo != true)
                                .tint(.primary)
                        }
                        .axisBehavior(.verticalPreferred)
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Redo", systemImage: "arrow.uturn.forward") { undoManager?.redo() }
                                .disabled(undoManager?.canRedo != true)
                                .tint(.primary)
                        }
                        .axisBehavior(.verticalPreferred)
                    }
                    ToolbarItem(placement: .topBarTrailing) { Menu("View", systemImage: "eye") { PadViewControls(model: model) }.tint(.primary) }
                        .axisBehavior(.verticalPreferred)
                    if !viewer {
                        ToolbarItem(placement: .topBarTrailing) { PadHelpMenu(model: model, guide: guide).tint(.primary) }
                            .axisBehavior(.verticalPreferred)
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Settings", systemImage: "gearshape") { model.showSettings = true }
                                .tint(.primary)
                        }
                        .axisBehavior(.verticalPreferred)
                    }
                    if viewer {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Render", systemImage: model.renderView ? "camera.fill" : "camera") { model.setRenderView(!model.renderView) }
                                .tint(.primary)
                        }
                        .axisBehavior(.verticalPreferred)
                    }
                    ToolbarItem(placement: .topBarTrailing) { PadExportMenu(model: model, imports: !viewer).tint(.primary) }
                        .axisBehavior(.verticalPreferred)
                }
        }
    }
}

/// The workspace switcher as a menu: the current workspace's glyph and name, in its colour.
struct PadWorkspaceMenu: View {
    let model: DocumentModel

    var body: some View {
        Menu {
            Picker("Workspace", selection: Binding(get: { model.workspace }, set: { model.setWorkspace($0) })) {
                ForEach(Workspace.available) { workspace in
                    Label(workspace.rawValue, systemImage: workspace.systemImage).tag(workspace)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(model.workspace.rawValue, systemImage: model.workspace.systemImage)
        }
        .tint(model.workspace.tint)
        .accessibilityLabel("Workspace: \(model.workspace.rawValue)")
        .accessibilityHint("Switch between Design, Split, Mold and Render")
    }
}
