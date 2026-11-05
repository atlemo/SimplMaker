// One open document: the viewport with its toolbar.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import SwiftUI

struct PadDocumentView: View {
    let file: CADFile
    let fileURL: URL?
    @Environment(\.undoManager) private var undoManager
    @State private var showParameters = false

    private var model: DocumentModel { file.model }

    var body: some View {
        let model = model
        ZStack(alignment: .bottomLeading) {
            PadViewport(model: model, sceneRevision: model.sceneRevision, fitRevision: model.fitRevision,
                        highlighted: model.highlighted, orthographic: model.orthographic, visualStyle: model.visualStyle,
                        explodeOffsets: model.explodeOffsets)
                .ignoresSafeArea()
            status(model)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Undo", systemImage: "arrow.uturn.backward") { undoManager?.undo() }
                    .disabled(undoManager?.canUndo != true)
                Button("Redo", systemImage: "arrow.uturn.forward") { undoManager?.redo() }
                    .disabled(undoManager?.canRedo != true)
                Button("Parameters", systemImage: "slider.horizontal.3") { showParameters = true }
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("STL") { model.export(format: .stl) }
                    Button("3MF") { model.export(format: .threeMF) }
                    Button("STEP") { model.export(format: .step) }
                }
            }
        }
        .sheet(isPresented: $showParameters) { PadParametersView(model: model) }
        .sheet(isPresented: Binding(get: { model.exportedFile != nil }, set: { if !$0 { model.exportedFile = nil } })) {
            if let url = model.exportedFile { ShareSheet(url: url).presentationDetents([.medium, .large]) }
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: { Text(model.alert?.message ?? "") }
        .onAppear { model.undoManager = undoManager; model.fileURL = fileURL }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .onChange(of: fileURL) { model.fileURL = fileURL }
    }

    private func status(_ model: DocumentModel) -> some View {
        let triangles = model.visibleMeshes.reduce(0) { $0 + $1.mesh.indices.count / 3 }
        let text = "\(model.visibleMeshes.count) bodies · \(triangles) triangles"
            + (model.selection.isEmpty ? "" : " · \(model.selection.count) selected")
            + (model.isRegenerating ? " · rebuilding…" : "")
        return Text(text)
            .font(.footnote.monospacedDigit())
            .padding(8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding()
            .accessibilityIdentifier("status")
    }
}

/// The system share sheet for a file (Save to Files, AirDrop, Messages, …).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
