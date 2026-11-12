// The bar along the top of a part: a back button to the start screen, the part's name (with its menu) in the middle and the part's action
// buttons (undo, redo, render, view, help, settings, export) at the right. It is a view of ours laid over the part, not the system's
// navigation bar: a navigation bar of a NavigationStack carried the part's own view away into itself in portrait, and covered the bar.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct PadTopBar: View {
    /// What the bar takes at the top of the part (the part's panels start below it).
    static let height: CGFloat = 54

    let model: DocumentModel
    let guide: TutorialGuide
    let undoManager: UndoManager?
    let title: String
    let onClose: () -> Void
    /// Renames the part; nil where the part cannot be renamed (it is not in the app's own folder).
    let onRename: (() -> Void)?
    /// Where the action buttons are, in window coordinates: the glass behind them is drawn with the rest of the glass.
    @Binding var frame: CGRect

    var body: some View {
        ZStack {
            titleView
            HStack(spacing: 0) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Parts")
                Spacer(minLength: 0)
                PadTopButtons(model: model, guide: guide, undoManager: undoManager)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { new in if new != frame { frame = new } }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: Self.height)
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
