// The parameter table: every named size in the part, editable. Changing one rebuilds the part.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import SwiftUI

struct PadParametersView: View {
    let model: DocumentModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.document.parameters.isEmpty {
                    Text("This part has no parameters yet.").foregroundStyle(.secondary)
                }
                ForEach(model.document.parameters) { parameter in
                    ParameterRow(model: model, parameter: parameter)
                }
            }
            .navigationTitle("Parameters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Add parameter", systemImage: "plus") { model.addParameter() }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct ParameterRow: View {
    let model: DocumentModel
    let parameter: Parameter
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(parameter.name).font(.body.monospaced())
            Spacer()
            TextField("Expression", text: $text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .frame(maxWidth: 200)
                .onSubmit(commit)
                .accessibilityIdentifier("parameter-\(parameter.name)")
        }
        .onAppear { text = parameter.expression }
        .onChange(of: parameter.expression) { if !focused { text = parameter.expression } }
        .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        guard text != parameter.expression else { return }
        model.setParameter(parameter.name, expression: text)
    }
}
