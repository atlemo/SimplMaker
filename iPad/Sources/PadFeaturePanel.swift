// The size of the feature just made, in a small panel at the top: an extrude's distance, with Done and Cancel.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import SwiftUI

struct PadFeaturePanel: View {
    let model: DocumentModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let id = model.newFeature, let feature = model.document.features.first(where: { $0.id == id }) {
            HStack(spacing: 12) {
                Text(feature.name).font(.headline)
                if let distance = distanceText(feature) {
                    TextField("Distance", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .frame(width: 110)
                        .onSubmit { commit(id) }
                        .onAppear { text = distance }
                        .onChange(of: distance) { if !focused { text = distance } }
                        .accessibilityIdentifier("distance")
                }
                Button("Cancel", role: .cancel) { model.cancelNewFeature() }
                Button("Done") { commit(id); model.finishFeatureEdit() }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("feature-done")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 8)
        }
    }

    private func distanceText(_ f: Feature) -> String? {
        guard case .extrude(let e) = f.kind else { return nil }
        switch e.extent {
        case .distance(let d), .symmetric(let d), .twoSides(let d, _): return d
        default: return nil
        }
    }

    private func commit(_ id: FeatureID) {
        model.updateFeature(id, "Change Distance") { f in
            guard case .extrude(var e) = f.kind else { return }
            switch e.extent {
            case .distance: e.extent = .distance(text)
            case .symmetric: e.extent = .symmetric(text)
            case .twoSides(_, let back): e.extent = .twoSides(text, back: back)
            default: return
            }
            f.kind = .extrude(e)
        }
    }
}
