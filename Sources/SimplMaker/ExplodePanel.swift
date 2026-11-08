// The exploded view's options panel (Mac). The model side is in ExplodedView.swift, which the iPad app shares.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import simd
import SwiftUI

/// The exploded view's panel: the slider, and which way the bodies go.
struct ExplodePanel: View {
    @Bindable var model: DocumentModel
    static let width: CGFloat = 270

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            HStack {
                Text("Exploded View").font(.headline)
                Spacer()
                HeaderIconButton(systemImage: "xmark", help: "Close the exploded view") { model.setExplodedView(false) }
            }
            if model.canExplode {
                HStack(spacing: DS.Spacing.space4) {
                    Slider(value: $model.explodeAmount, in: 0...1)
                        .help("Move the bodies apart")
                    Text("\(Int((model.explodeAmount * 100).rounded())) %")
                        .font(.callout)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                SegmentedPicker(selection: $model.explodeDirection) { $0.title }
                .help("All: along X, Y and Z. X, Y or Z: along that axis only")
                Text(model.sketchSession != nil || model.pendingTool != nil
                     ? "The bodies sit back in place while you sketch or use a tool."
                     : "The bodies move apart in equal steps. Nothing in the part is changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("There is only one body. Make a second one and they can be pulled apart.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.space6)
        .frame(width: Self.width)
        .panelGlass(in: .rect(cornerRadius: DS.Radius.window))
    }
}
