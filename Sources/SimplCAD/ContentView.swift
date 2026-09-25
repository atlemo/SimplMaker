// Main window: timeline + parameters on the left, viewport in the middle, inspector on the right.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import SwiftUI

struct ContentView: View {
    @Bindable var model: DocumentModel
    @Environment(\.undoManager) private var undoManager
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                ViewportView(model: model, sceneRevision: model.sceneRevision,
                             selection: model.selection, fitRevision: model.fitRevision)
                Divider()
                StatusBar(model: model)
            }
            .inspector(isPresented: $showInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 240, ideal: 280)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.addEdgeFeature(fillet: true) } label: { Label("Fillet", systemImage: "square.fill.on.square") }
                    .help("Fillet the selected edges")
                    .disabled(model.selectedEdgeCount == 0)
                Button { model.addEdgeFeature(fillet: false) } label: { Label("Chamfer", systemImage: "square.on.square.dashed") }
                    .help("Chamfer the selected edges")
                    .disabled(model.selectedEdgeCount == 0)
                Button { model.fitView() } label: { Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("Fit the model in view")
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
        .navigationTitle(model.fileURL?.lastPathComponent ?? "SimplCAD")
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .alert("SimplCAD", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }
}

struct StatusBar: View {
    let model: DocumentModel

    var body: some View {
        HStack(spacing: 12) {
            if let hovered = model.hovered, let name = model.name(of: hovered) {
                Label(name, systemImage: hovered.isEdge ? "line.diagonal" : "square")
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Text("Click faces or edges to select · ⇧-click to add · drag to orbit").foregroundStyle(.secondary)
            }
            Spacer()
            if !model.selection.isEmpty { Text("\(model.selection.count) selected") }
            if model.isRegenerating {
                ProgressView().controlSize(.small)
            } else if let r = model.result {
                Text(String(format: "rebuilt in %.0f ms", r.duration * 1000)).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var model: DocumentModel

    var body: some View {
        List(selection: $model.selectedFeature) {
            Section("Timeline") {
                ForEach(model.document.features) { f in
                    FeatureRow(feature: f, error: model.result?.errors[f.id])
                        .tag(f.id)
                        .contextMenu {
                            Button(f.suppressed ? "Unsuppress" : "Suppress") {
                                model.updateFeature(f.id, f.suppressed ? "Unsuppress" : "Suppress") { $0.suppressed.toggle() }
                            }
                            Button("Delete", role: .destructive) { model.deleteFeature(f.id) }
                        }
                }
            }
            Section {
                ForEach(model.document.parameters) { p in
                    ParameterRow(model: model, parameter: p)
                        .contextMenu { Button("Delete", role: .destructive) { model.removeParameter(p.name) } }
                }
            } header: {
                HStack {
                    Text("Parameters")
                    Spacer()
                    Button { model.addParameter() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add a parameter")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct FeatureRow: View {
    let feature: Feature
    let error: String?

    var icon: String {
        switch feature.kind {
        case .sketch: return "pencil.and.outline"
        case .extrude: return "cube"
        case .fillet: return "circle.bottomrighthalf.pattern.checkered"
        case .chamfer: return "triangle.bottomhalf.filled"
        }
    }

    var body: some View {
        HStack {
            Image(systemName: icon).frame(width: 18)
            Text(feature.name).strikethrough(feature.suppressed)
            Spacer()
            if let error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(error)
            }
        }
        .foregroundStyle(feature.suppressed ? .secondary : .primary)
    }
}

struct ParameterRow: View {
    let model: DocumentModel
    let parameter: Parameter

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(parameter.name).font(.body.monospaced())
                Spacer()
                if let error = model.result?.parameters.errors[parameter.name] {
                    Text(error).foregroundStyle(.red).font(.caption).lineLimit(1)
                } else if let q = model.result?.parameters.values[parameter.name] {
                    Text(parameter.unit.format(q.value)).foregroundStyle(.secondary).font(.caption)
                }
            }
            ExpressionField(text: parameter.expression) { model.setParameter(parameter.name, expression: $0) }
        }
        .padding(.vertical, 2)
    }
}

/// A text field that commits on Return / focus loss and follows external changes (undo).
struct ExpressionField: View {
    let text: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("expression", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
            .focused($focused)
            .onSubmit { commit(draft) }
            .onAppear { draft = text }
            .onChange(of: text) { draft = text }
            .onChange(of: focused) { if !focused, draft != text { commit(draft) } }
    }
}
