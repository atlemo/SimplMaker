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
    /// The picture stored in the file: the part as the viewport shows it, shrunk.
    private func storeThumbnail() async {
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled, model.sketchSession == nil else { return }
        await model.rebuilt()
        guard !Task.isCancelled else { return }
        let png: Data? = model.visibleMeshes.isEmpty ? nil : await withCheckedContinuation { continuation in
            guard let capture = viewState.capture else { continuation.resume(returning: nil); return }
            capture { data in continuation.resume(returning: data.flatMap(Self.shrunk)) }
        }
        file.updateThumbnail(png)
    }

    /// A PNG at most 512 points across.
    private static func shrunk(_ data: Data) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0 else { return nil }
        let scale = min(512 / max(image.size.width, image.size.height), 1)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
    @State private var viewState = PadViewState()
    /// How much of the top the tool bar takes: it grows when the layout has fewer, bigger buttons.
    @State private var toolBarHeight = PadToolBar.height

    var body: some View {
        let model = model
        let guide = file.guide
        return DocumentPanels(model: model, guide: guide, viewport: viewport(model), chrome: EmptyView())
            // The keyboard covers the bottom of the screen instead of squeezing the view above it: the fields that are typed in move up by themselves.
            .ignoresSafeArea(.keyboard)
            // The size fields and the OK / Cancel bar of a feature float above the panels, never under them.
            .overlay {
                PadHandleFields(model: model, state: viewState, insets: (model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0,
                                                                         model.showInspector ? Panel.inspectorWidth + Panel.margin : 0,
                                                                         Panel.bottomInset(timeline: model.showTimeline)))
                    .ignoresSafeArea()
            }
            // A tapped sketch offers Edit and Delete, above the timeline and between the side panels.
            .overlay(alignment: .bottom) {
                ZStack {
                    PadSketchActions(model: model)
                    PadToolActions(model: model)
                    PadSketchBar(model: model)
                }
                    .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : 0)
                    .padding(.bottom, Panel.bottomInset(timeline: model.showTimeline) + 8)
                    .ignoresSafeArea()
            }
            .safeAreaInset(edge: .top, spacing: 0) { PadToolBar(model: model, height: $toolBarHeight) }
            .toolbar { PadToolbar(model: model, guide: guide, undoManager: undoManager) }
            .modifier(PadDialogs(model: model))
            .modifier(AccentScope(sketching: model.sketchSession != nil))
            .environment(\.completionModel, model)
            .environment(\.tutorialSpotlight, guide.spotlight)
            .focusedSceneValue(\.documentModel, model)
            .onAppear {
                _ = KeyboardWatcher.shared  // watching from the start, so a keyboard raised later is seen
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
            .task(id: model.documentRevision) { await storeThumbnail() }
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
                    toolbarHeight: toolBarHeight, state: viewState,
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
    /// Set to the room the bar takes, gaps included.
    @Binding var height: CGFloat
    /// How much bigger than on the Mac the buttons are drawn.
    static let scale: CGFloat = 1.3
    /// How much of the top the bar takes (its height and the gaps around it), for centring the view in what is left.
    static let height: CGFloat = 96
    @State private var natural = CGSize(width: 800, height: 56)
    /// How wide the row is in each layout, measured on copies that are never shown.
    @State private var widths: [ToolbarLayout: CGFloat] = [:]
    @AppStorage(Preferences.sketchPaper) private var sketchPaper = Preferences.SketchPaper.blue
    @ObservedObject private var shortcuts = ShortcutStore.shared

    private func row(_ layout: ToolbarLayout) -> some View {
        Group {
            if let session = model.sketchSession {
                SketchToolbar(model: model, session: session, layout: layout)
            } else {
                DesignToolbar(model: model, layout: layout)
            }
        }
        .environment(\.toolTitles, true)
        .fixedSize()
    }

    /// What the measured widths depend on: the mode, and the tools pinned in each group (the user can change them).
    private var signature: String {
        let pins = ["design.create", "design.shapes", "design.modify", "design.construct", "design.inspect",
                    "sketch.draw", "sketch.modify", "sketch.transform", "sketch.constraints"]
            .map { UserDefaults.standard.string(forKey: Preferences.toolbarPins($0)) ?? "-" }
        return "\(model.sketchSession != nil) \(model.isPickingSketchPlane) \(pins.joined(separator: "|"))"
    }

    /// Every layout from the widest (each group's pinned tools) down to one menu of everything.
    private func measure() {
        func width(_ layout: ToolbarLayout) -> CGFloat {
            UIHostingController(rootView: row(layout)).sizeThatFits(in: CGSize(width: 10_000, height: 400)).width
        }
        var result: [ToolbarLayout: CGFloat] = [.single: width(.single)]
        var previous = CGFloat.infinity
        for trim in 0..<32 {
            let w = width(.trimmed(trim))
            if w >= previous - 0.5 { break }
            result[.trimmed(trim)] = w
            previous = w
        }
        widths = result
    }

    /// The widest layout that fits the room: a small iPad starts with fewer pinned tools, the rest are in each group's menu.
    private func layout(fitting room: CGFloat) -> ToolbarLayout {
        var trim = 0
        while let w = widths[.trimmed(trim)] {
            if w * Self.scale <= room { return .trimmed(trim) }
            trim += 1
        }
        return .single
    }

    /// The user's own choice (nil: follow the tool). A tool that is being set up folds the bar away so the part is in view;
    /// when the tool ends, the bar comes back. Tapping the chevron or the pill overrides that until the next change.
    @State private var manualCollapse: Bool?
    private var busy: Bool { model.sketchSession == nil && (model.newFeature != nil || model.pendingTool != nil) }
    private var collapsed: Bool { manualCollapse ?? busy }

    /// What the folded bar says: the tool that is running, or just "Tools".
    private var foldedTitle: String {
        if let tool = model.pendingTool { return tool.rawValue }
        if let id = model.newFeature, let f = model.document.features.first(where: { $0.id == id }) { return f.name }
        return model.sketchSession != nil ? "Sketch tools" : "Tools"
    }

    private func setCollapsed(_ value: Bool) {
        withAnimation(.snappy(duration: 0.25)) { manualCollapse = value }
    }

    var body: some View {
        Group {
            if collapsed { foldedBar } else { fullBar }
        }
        .animation(.snappy(duration: 0.25), value: collapsed)
        .padding(.top, 6)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tools")
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .task(id: signature) { measure() }
        .onChange(of: busy) { manualCollapse = nil }
        .onChange(of: model.sketchSession == nil) { manualCollapse = nil }
    }

    /// A small pill in the middle of the top edge: the tool's name and a chevron that brings the bar back.
    private var foldedBar: some View {
        HStack(spacing: 8) {
            Button { setCollapsed(false) } label: {
                HStack(spacing: 8) {
                    Text(foldedTitle).font(.headline).lineLimit(1)
                    Image(systemName: "chevron.down").font(.body.weight(.semibold))
                }
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .panelGlass(in: Capsule())
            .accessibilityHint("Shows the tool bar")
            // A tool that still waits for a pick has no other Cancel on screen.
            if model.pendingTool != nil {
                Button { model.pendingTool = nil } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .panelGlass(in: Circle())
                .accessibilityLabel("Cancel \(foldedTitle)")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var fullBar: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                let chosen = layout(fitting: geo.size.width - 28)
                ScrollView(.horizontal, showsIndicators: false) {
                    row(chosen)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
                        .scaleEffect(Self.scale, anchor: .topLeading)
                        .frame(width: natural.width * Self.scale, height: natural.height * Self.scale, alignment: .topLeading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(minWidth: geo.size.width, alignment: .center)
                }
            }
            Button { setCollapsed(true) } label: {
                Image(systemName: "chevron.up").font(.body.weight(.semibold))
                    .foregroundStyle(model.sketchSession != nil ? Color.white : Color.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide tool bar")
        }
        .frame(height: natural.height * Self.scale + 12)
        .modifier(BarBackground(tint: model.sketchSession != nil ? sketchPaper.toolbarTint : nil))
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
    let guide: TutorialGuide
    @Environment(\.openURL) private var openURL
    let undoManager: UndoManager?

    /// An example part replaces what is in the part (one Undo brings it back): iPadOS has no way to open a second part from inside the app.
    private func loadExample(_ title: String, _ document: CADDocument) {
        model.mutate("Load Example: \(title)") { $0 = document }
        model.regenerate(fit: true)  // the view fits the new part once it is built
    }

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
            Menu("Help", systemImage: "questionmark.circle") {
                Button(guide.canResume ? "Resume Tutorial: Desk Organizer" : "Tutorial: Make a Desk Organizer") {
                    if guide.isActive { return }
                    if guide.canResume || (model.document.features.isEmpty && model.document.parameters.isEmpty) { guide.start() }
                    else { model.alert = AlertInfo(title: "The tutorial starts in an empty part", message: "Close this part, create a new one from the document browser, and choose Help › Tutorial there.") }
                }
                Menu("Load Example Part") {
                    Button("Plate with Holes, Fillets and a Chamfer") { loadExample("Plate with Holes, Fillets and a Chamfer", CADDocument.demo()) }
                    Button("Bracket Profile (try the sketch solver)") { loadExample("Bracket Profile", CADDocument.bracketProfileDemo()) }
                    Button("Bracket with Ribs") { loadExample("Bracket with Ribs", CADDocument.ribDemo()) }
                    Button("Flanged Pipe on a Manifold (advanced)") { loadExample("Flanged Pipe on a Manifold", CADDocument.manifoldDemo()) }
                }
                Divider()
                Button("SimplMaker Docs") { openURL(URL(string: "https://simplmaker.com/docs/")!) }
                Button("About SimplMaker and Licences") { model.showAbout = true }
            }
            Button("Settings", systemImage: "gearshape") { model.showSettings = true }
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
            .sheet(isPresented: $model.showAbout) {
                NavigationStack {
                    PadAbout().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showAbout = false } } }
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $model.showSettings) {
                NavigationStack {
                    SettingsView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showSettings = false } } }
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.large])
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
