// The Measure tool's panel (Mac). The measuring itself is in Measure.swift, which the iPad app shares.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import Foundation
import simd
import SwiftUI

/// The Measure tool's readout, floating at the top of the viewport.
struct MeasurePanel: View {
    let model: DocumentModel
    static let width: CGFloat = 270

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            HStack {
                Text("Measure").font(.headline)
                Spacer()
                HeaderIconButton(systemImage: "xmark", help: "Finish measuring (Esc)") { model.cancelTool() }
            }
            if let m = model.measurement {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.space5) {
                        ForEach(m.sections) { section in
                            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                                Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(section.rows) { row in
                                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space4) {
                                        Text(row.label).foregroundStyle(.secondary)
                                        Spacer(minLength: DS.Spacing.space4)
                                        Text(row.value)
                                            .monospacedDigit()
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                    }
                                    .font(.callout)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(m.text, forType: .string)
                }
                .controlSize(.small)
                .help("Copy these values")
            } else {
                Text(model.measurePrompt())
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
