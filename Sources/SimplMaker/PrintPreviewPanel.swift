// The options of the FDM print preview: layer height and nozzle. Opens with the preview (View ▸ FDM 3D Print Preview).
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct PrintPreviewPanel: View {
    @Bindable var model: DocumentModel
    static let width: CGFloat = 270

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            HStack {
                Text("3D Print Preview").font(.headline)
                Spacer()
                HeaderIconButton(systemImage: "xmark", help: "Close these options (the preview stays on)") { model.showPrintOptions = false }
            }
            option("Layer height", values: DocumentModel.printLayerHeights, selection: $model.printLayer)
            option("Nozzle", values: DocumentModel.printNozzles, selection: $model.printNozzle)
            Text("A look at how the bodies would print, not a slice. Turn it off in the View menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Spacing.space6)
        .frame(width: Self.width)
        .panelGlass(in: .rect(cornerRadius: DS.Radius.window))
    }

    private func option(_ title: String, values: [Double], selection: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            Text("\(title) (mm)").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            SegmentedPicker(selection: selection, options: values) { $0.formatted(.number.precision(.fractionLength(2))) }
        }
    }
}
