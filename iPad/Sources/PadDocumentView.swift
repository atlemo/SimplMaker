// One open document on the iPad: the same panels as the Mac window (browser, inspector, timeline, status bar, tool panels),
// the Mac's tool rows in a bar along the top, and the system's dialogs and pickers in place of the Mac's panels.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import SwiftUI
import UniformTypeIdentifiers

struct PadDocumentView: View {
    let file: CADFile
    let fileURL: URL?
    @Environment(\.undoManager) private var undoManager
    @AppStorage(Preferences.showGrid) private var showGrid = true
    @AppStorage(Preferences.showAxes) private var showAxes = true

    private var model: DocumentModel { file.model }
    @State private var viewState = PadViewState()

    var body: some View {
        let model = model
        let guide = file.guide
        return DocumentPanels(model: model, guide: guide, viewport: viewport(model), chrome: EmptyView())
            .safeAreaInset(edge: .top, spacing: 0) { PadToolBar(model: model) }
            .toolbar { PadToolbar(model: model, undoManager: undoManager) }
            .modifier(PadDialogs(model: model))
            .modifier(AccentScope(sketching: model.sketchSession != nil))
            .environment(\.completionModel, model)
            .environment(\.tutorialSpotlight, guide.spotlight)
            .focusedSceneValue(\.documentModel, model)
            .onAppear {
                model.undoManager = undoManager
                model.fileURL = fileURL
                // A narrow screen has room for the viewport or the panels, not both: start with the viewport.
                if UIScreen.main.bounds.width < 1200 { model.showSidebar = false; model.showInspector = false }
            }
            .onChange(of: model.showImageExport) {
                guard model.showImageExport else { return }
                model.showImageExport = false
                viewState.capture? { data in
                    guard let data else { return }
                    Task { @MainActor in
                        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let url = folder.appendingPathComponent("\(model.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled").png")
                        if (try? data.write(to: url)) != nil { model.exportedFile = url }
                    }
                }
            }
            .onChange(of: undoManager) { model.undoManager = undoManager }
            .onChange(of: fileURL) { model.fileURL = fileURL }
    }

    private func viewport(_ model: DocumentModel) -> some View {
        ZStack {
            padViewport(model)
            PadOverlays(model: model, state: viewState, insets: (model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0,
                                                               model.showInspector ? Panel.inspectorWidth + Panel.margin : 0,
                                                               Panel.bottomInset(timeline: model.showTimeline)))
        }
    }

    private func padViewport(_ model: DocumentModel) -> some View {
        PadViewport(model: model, sceneRevision: model.sceneRevision, overlayRevision: model.overlayRevision,
                    fitRevision: model.fitRevision, cameraRevision: model.cameraCommand?.revision ?? 0,
                    highlighted: model.highlighted, orthographic: model.orthographic, visualStyle: model.visualStyle,
                    explodeOffsets: model.explodeOffsets, sketching: model.sketchSession != nil,
                    showGrid: showGrid, showAxes: showAxes && model.sketchSession == nil,
                    panelInsets: (model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0,
                                  model.showInspector ? Panel.inspectorWidth + Panel.margin : 0,
                                  Panel.bottomInset(timeline: model.showTimeline)),
                    toolbarHeight: PadToolBar.height, state: viewState,
                    printPreview: model.printPreview, printLayer: model.printLayer, printNozzle: model.printNozzle,
                    renderSettings: model.renderView ? model.renderSettings : nil,
                    spinning: model.renderView && model.renderSpinning && model.sketchSession == nil,
                    sectionPlane: model.sectionClip, sketchSlice: model.sketchSlicePlane)
    }
}

/// The Mac's two tool rows (design tools, or sketch tools while a sketch is open), in a bar across the whole width, with the buttons
/// scaled up for a finger. The row is centred while it fits and scrolls sideways when it does not.
struct PadToolBar: View {
    let model: DocumentModel
    /// How much bigger than on the Mac the buttons are drawn.
    static let scale: CGFloat = 1.3
    /// How much of the top the bar takes (its height and the gaps around it), for centring the view in what is left.
    static let height: CGFloat = 96
    @State private var natural = CGSize(width: 800, height: 56)
    @AppStorage(Preferences.sketchPaper) private var sketchPaper = Preferences.SketchPaper.blue

    private var row: some View {
        Group {
            if let session = model.sketchSession {
                SketchToolbar(model: model, session: session, layout: .full)
            } else {
                DesignToolbar(model: model, layout: .full)
            }
        }
        .environment(\.toolTitles, true)
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                row
                    .scaleEffect(Self.scale, anchor: .topLeading)
                    .frame(width: natural.width * Self.scale, height: natural.height * Self.scale, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(minWidth: geo.size.width, alignment: .center)
            }
        }
        .frame(height: natural.height * Self.scale + 12)
        .modifier(BarBackground(tint: model.sketchSession != nil ? sketchPaper.toolbarTint : nil))
        .padding(.top, 6)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
    }
}

/// The bar's background: glass, or in a sketch the sketch paper's deeper tint, which the sketch tools' white symbols are drawn for.
private struct BarBackground: ViewModifier {
    let tint: Color?
    func body(content: Content) -> some View {
        if let tint {
            content.background(tint, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            content.panelGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// The navigation bar: panels on and off at the leading side; undo, redo, view and export at the trailing side.
struct PadToolbar: ToolbarContent {
    let model: DocumentModel
    let undoManager: UndoManager?

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            Button("Browser", systemImage: "sidebar.left") { model.showSidebar.toggle() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Undo", systemImage: "arrow.uturn.backward") { undoManager?.undo() }
                .disabled(undoManager?.canUndo != true)
            Button("Redo", systemImage: "arrow.uturn.forward") { undoManager?.redo() }
                .disabled(undoManager?.canRedo != true)
            Button("Render", systemImage: model.renderView ? "camera.fill" : "camera") { model.setRenderView(!model.renderView) }
                .disabled(model.sketchSession != nil)
            Button("Inspector", systemImage: "sidebar.right") { model.showInspector.toggle() }
            Menu("View", systemImage: "eye") { PadViewControls(model: model) }
            Menu("Export", systemImage: "square.and.arrow.up") {
                Button("STL") { model.export(format: .stl) }
                Button("3MF") { model.export(format: .threeMF) }
                Button("STEP") { model.export(format: .step) }
                Divider()
                Button("Import STEP…") { model.importSTEP() }
                Button("Import STL…") { model.importSTL() }
                Button("Import SVG as sketch…") { model.importSVG() }
                Button("Import DXF as sketch…") { model.importDXF() }
            }
        }
    }
}

/// Alerts, the unlink question, the file picker the model asks for, the export chooser and the share sheet.
struct PadDialogs: ViewModifier {
    @Bindable var model: DocumentModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(unlinkTitle, isPresented: unlinkShown, presenting: model.unlinkPrompt) { p in
                Button("Use \(p.valueText)") { model.resolveUnlink(useValue: true) }
                Button("Keep \(p.expression)", role: .cancel) { model.resolveUnlink(useValue: false) }
            } message: { p in
                Text("This size comes from the expression “\(p.expression)”. Using the dragged value replaces it with a fixed number, so it will no longer follow your parameters.")
            }
            .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
                   presenting: model.alert) { _ in
                Button("OK") { model.alert = nil }
            } message: { info in Text(info.message) }
            .fileImporter(isPresented: Binding(get: { model.fileRequest != nil }, set: { if !$0 { model.fileRequest = nil } }),
                          allowedContentTypes: model.fileRequest?.contentTypes ?? [.data]) { result in
                guard let request = model.fileRequest else { return }
                model.fileRequest = nil
                if case .success(let url) = result { model.fileChosen(url, for: request) }
            }
            .confirmationDialog("Export", isPresented: $model.showExportChooser) {
                Button("STL") { model.export(format: .stl) }
                Button("3MF") { model.export(format: .threeMF) }
                Button("STEP") { model.export(format: .step) }
            }
            .sheet(isPresented: Binding(get: { model.exportedFile != nil }, set: { if !$0 { model.exportedFile = nil } })) {
                if let url = model.exportedFile { ShareSheet(url: url).presentationDetents([.medium, .large]) }
            }
    }

    private var unlinkTitle: String {
        guard let p = model.unlinkPrompt else { return "" }
        return "Replace \(p.expression) with \(p.valueText)?"
    }

    private var unlinkShown: Binding<Bool> {
        Binding(get: { model.unlinkPrompt != nil }, set: { if !$0 { model.resolveUnlink(useValue: false) } })
    }
}

/// The system share sheet for a file (Save to Files, AirDrop, Messages, …).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
