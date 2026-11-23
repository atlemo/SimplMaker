// The bar along the top of a part: a back button to the start screen, the part's name (with its menu) in the middle and the part's action
// buttons (undo, redo, render, view, help, settings, export) at the right. It is a view of ours laid over the part, not the system's
// navigation bar: a navigation bar of a NavigationStack carried the part's own view away into itself in portrait, and covered the bar.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct PadTopBar: View {
    /// What the bar takes at the top of the part (the part's panels start below it).
    static let height: CGFloat = contentHeight + gap
    /// The row of buttons and the title.
    static let contentHeight: CGFloat = 54
    /// The room between that row and the tool bar under it.
    static let gap: CGFloat = 14
    /// What it takes beside the Duo's vertical bar, where only the title is left: a line of text and a small gap.
    static let compactHeight: CGFloat = 36

    let model: DocumentModel
    let guide: TutorialGuide
    let undoManager: UndoManager?
    let title: String
    /// The window is too small to design in: the part is only looked at (see `PadDocumentView`).
    let viewer: Bool
    /// The iPhone Duo's vertical bar holds every button (see `PadDuoBar`).
    let duoBar: Bool
    let onClose: () -> Void
    /// Renames the part; nil where the part cannot be renamed (it is not in the app's own folder).
    let onRename: (() -> Void)?
    /// Where the action buttons are, in window coordinates: the glass behind them is drawn with the rest of the glass.
    @Binding var frame: CGRect

    var body: some View {
        ZStack {
            titleView
            HStack(spacing: 0) {
                if !duoBar {
                    Button(action: onClose) {
                        Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Parts")
                    if !viewer { workspaceMenu.padding(.leading, 8) }
                }
                Spacer(minLength: 0)
                // With the Duo's vertical bar every button is in it (see `PadDuoBar`), and only the title is left here.
                if !duoBar {
                    Group {
                        if viewer { PadViewerButtons(model: model) } else { PadTopButtons(model: model, guide: guide, undoManager: undoManager) }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { new in if new != frame { frame = new } }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: duoBar ? Self.compactHeight - 6 : Self.contentHeight)
        .onChange(of: duoBar, initial: true) { if duoBar { frame = .zero } }  // no glass behind buttons that are not here
        // A phone's screen can have no safe area at the top (the Duo's status is at its side): the buttons keep off the edge.
        .padding(.top, viewer ? 6 : 0)
        .frame(height: duoBar ? Self.compactHeight : Self.height, alignment: .top)
    }

    /// The workspace switcher, next to the back button: the current workspace's glyph and name, in its colour.
    private var workspaceMenu: some View {
        Menu {
            Picker("Workspace", selection: Binding(get: { model.workspace }, set: { model.setWorkspace($0) })) {
                ForEach(Workspace.available) { workspace in
                    Label(workspace.rawValue, systemImage: workspace.systemImage).tag(workspace)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.workspace.systemImage).font(.title3.weight(.semibold))
                Text(model.workspace.rawValue).font(.headline)
                Image(systemName: "chevron.down").font(.footnote.weight(.bold)).opacity(0.7)
            }
            .foregroundStyle(model.workspace.tint)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Workspace: \(model.workspace.rawValue)")
        .accessibilityHint("Switch between Design, Split, Mold and Render")
    }

    @ViewBuilder private var titleView: some View {
        let label = Text(title).font(.headline).lineLimit(1)
        if let onRename {
            Menu {
                Button("Rename…", systemImage: "pencil", action: onRename)
            } label: {
                HStack(spacing: 4) {
                    label
                    Image(systemName: "chevron.down.circle.fill").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
        } else {
            label
        }
    }
}
