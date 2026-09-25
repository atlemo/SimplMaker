// Main window: timeline + parameters on the left, viewport in the middle, inspector on the right.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import CADKernel
import SwiftUI

/// One document window.
struct ContentView: View {
    let file: CADFile
    let fileURL: URL?

    var body: some View {
        DocumentWindow(model: file.model, fileURL: fileURL)
    }
}

struct DocumentWindow: View {
    @Bindable var model: DocumentModel
    let fileURL: URL?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(Preferences.showGrid) private var showGrid = true
    @AppStorage(Preferences.showConstraints) private var showConstraints = true

    private var unlinkTitle: String {
        guard let p = model.unlinkPrompt else { return "" }
        return "Replace \(p.expression) with \(formatDimension(p.value, kind: .length))?"
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            ViewportView(model: model, sceneRevision: model.sceneRevision, overlayRevision: model.overlayRevision,
                         highlighted: model.highlighted, fitRevision: model.fitRevision,
                         cameraRevision: model.cameraCommand?.revision ?? 0, orthographic: model.orthographic,
                         showGrid: showGrid, showConstraints: showConstraints)
                // An overlay takes no part in the column's layout. As a sibling in a VStack, the
                // status bar's text made the detail column resize itself while the split view was
                // laying it out, a loop AppKit ends by crashing the app.
                .overlay(alignment: .bottom) { StatusBar(model: model) }
            .inspector(isPresented: $model.showInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 240, ideal: 280)
            }
        }
        .toolbar {
            if let session = model.sketchSession {
                SketchToolbar(model: model, session: session)
            } else {
                ToolbarItemGroup {
                    if model.isPickingSketchPlane {
                        Button { model.cancelSketchPlanePick() } label: { Label("Cancel Sketch", systemImage: "xmark.circle") }
                            .help("Stop choosing a sketch plane (Esc)")
                    } else {
                        Button { model.startSketch() } label: { Label("Sketch", systemImage: "pencil.and.outline") }
                            .help("Create a sketch: then click an origin plane or a flat face in the viewport")
                    }
                    Button { model.extrudeSelectedProfiles() } label: { Label("Extrude", systemImage: "square.stack.3d.up") }
                        .help("Extrude the selected profiles (select a sketch in the timeline, then click its regions)")
                        .disabled(model.selectedRegions.isEmpty)
                    Button { model.addEdgeFeature(fillet: true) } label: { Label("Fillet", systemImage: "square.fill.on.square") }
                        .help("Fillet the selected edges")
                        .disabled(model.selectedEdgeCount == 0)
                    Button { model.addEdgeFeature(fillet: false) } label: { Label("Chamfer", systemImage: "square.on.square.dashed") }
                        .help("Chamfer the selected edges")
                        .disabled(model.selectedEdgeCount == 0)
                    Button { model.fitView() } label: { Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .help("Fit the model in view")
                    Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                        .help("Show or hide the inspector (⌥⌘I)")
                }
            }
        }
        .focusedSceneValue(\.documentModel, model)
        .onAppear {
            model.undoManager = undoManager
            model.fileURL = fileURL
            AppWindows.openWindow = openWindow
            dismissWindow(id: AppWindows.welcomeID)  // a part is open; the welcome window has done its job
        }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .onChange(of: fileURL) { model.fileURL = fileURL }
        .confirmationDialog(unlinkTitle, isPresented: Binding(get: { model.unlinkPrompt != nil },
                                                             set: { if !$0 { model.resolveUnlink(useValue: false) } }),
                            presenting: model.unlinkPrompt) { p in
            Button("Use \(formatDimension(p.value, kind: .length))") { model.resolveUnlink(useValue: true) }
            Button("Keep \(p.expression)", role: .cancel) { model.resolveUnlink(useValue: false) }
        } message: { p in
            Text("This size comes from the expression “\(p.expression)”. Using the dragged value replaces it with a fixed number, so it will no longer follow your parameters.")
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button("OK") { model.alert = nil }
        } message: { info in
            Text(info.message)
        }
    }
}

struct StatusBar: View {
    let model: DocumentModel

    var body: some View {
        HStack(spacing: 12) {
            message
                .lineLimit(1)
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            Group {
                if !model.selection.isEmpty { Text("\(model.selection.count) selected") }
                if model.isRegenerating {
                    ProgressView().controlSize(.small)
                } else if let r = model.result {
                    Text(String(format: "rebuilt in %.0f ms", r.duration * 1000)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var message: some View {
        if let session = model.sketchSession {
            Text(session.statusText)
                .foregroundStyle(session.message != nil || session.solve?.status == .failed ? Color.red : Color.secondary)
        } else if model.isPickingSketchPlane {
            Text("Select a plane or planar face to sketch on · Esc to cancel")
        } else if let h = model.dragHandle, model.hovered == nil || model.hovered?.kind == .handle {
            Text(model.previewInvalid ? "That size doesn't fit the neighbouring faces — let go to keep the previous size"
                                      : "Drag the orange arrow to change the \(h.kind == .fillet ? "radius" : h.kind == .chamfer ? "chamfer size" : "distance"), or type it in the inspector")
                .foregroundStyle(model.previewInvalid ? Color.red : Color.secondary)
        } else if let hovered = model.hovered, let name = model.name(of: hovered) {
            Label(name, systemImage: hovered.isEdge ? "line.diagonal" : "square")
                .truncationMode(.middle)
        } else {
            Text("Click faces or edges to select · ⇧-click to add · drag to orbit").foregroundStyle(.secondary)
        }
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
                            if case .sketch = f.kind { Button("Edit Sketch") { model.editSketch(f.id) } }
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
    /// Called shortly after typing pauses, to preview the uncommitted value (no undo step).
    var preview: ((String) -> Void)? = nil
    let commit: (String) -> Void
    @State private var draft = ""
    @State private var edited = false
    @FocusState private var focused: Bool

    init(text: String, preview: ((String) -> Void)? = nil, commit: @escaping (String) -> Void) {
        self.text = text
        self.preview = preview
        self.commit = commit
    }

    var body: some View {
        TextField("expression", text: $draft)
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
            .focused($focused)
            .onSubmit { edited = false; commit(draft) }
            .onAppear { draft = text }
            .onChange(of: text) { draft = text; edited = false }
            .onChange(of: focused) { if !focused, draft != text { edited = false; commit(draft) } }
            .onChange(of: draft) { if focused { edited = true } }
            .task(id: draft) {
                guard edited, let preview else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, edited else { return }
                preview(draft)
            }
    }
}

// MARK: - Sketch mode

struct SketchToolbar: ToolbarContent {
    let model: DocumentModel
    let session: SketchSession

    var body: some ToolbarContent {
        ToolbarItem {
            Picker("Tool", selection: Binding(get: { session.tool }, set: { model.setSketchTool($0) })) {
                ForEach(SketchTool.allCases) { tool in
                    Label(tool.rawValue, systemImage: tool.symbol)
                        .help("\(tool.rawValue) (\(String(tool.key).uppercased()))")
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
        }
        ToolbarItemGroup {
            Menu {
                ForEach(ConstraintTool.allCases, id: \.self) { c in
                    Button(c.rawValue) { model.sketchCommand { $0.apply(c) } }
                        .disabled(!session.canApply(c))
                }
            } label: { Label("Constrain", systemImage: "link") }
                .help("Constrain the selected sketch entities")
            Button { session.beginOffset() } label: { Label("Offset", systemImage: "square.on.square.intersection.dashed") }
                .help("Offset the selected curves by a distance")
                .disabled(!session.canOffset)
                .popover(isPresented: Binding(get: { session.offsetRequested }, set: { session.offsetRequested = $0 }),
                         arrowEdge: .bottom) {
                    OffsetPopover(model: model, session: session)
                }
            Button { model.sketchCommand { $0.toggleConstruction() } } label: {
                Label("Construction", systemImage: "pencil.slash")
            }
            .help("Toggle construction geometry for the selected curves")
            .disabled(!session.canToggleConstruction)
            Button { model.finishSketch() } label: { Label("Finish Sketch", systemImage: "checkmark.circle.fill") }
                .help("Finish the sketch (Return)")
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Editor for the dimension just created or clicked, shown in a popover on its label.
struct DimensionEditor: View {
    let model: DocumentModel
    let session: SketchSession
    let dimensionID: EntityID
    var onDone: () -> Void = {}
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Value or expression", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 180)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand(perform: onDone)
                Button("Set", action: commit).keyboardShortcut(.defaultAction)
            }
            if let message = session.message {
                Text(message).font(.caption).foregroundStyle(.red)
            } else {
                Text("For example 25 mm, 1 in, 30 deg or width / 2").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .onAppear(perform: load)
        .onChange(of: dimensionID) { load() }
    }

    private func load() {
        draft = session.sketch.dimensions.first { $0.id == dimensionID }?.expression ?? ""
        focused = true
    }

    private func commit() {
        let id = dimensionID, text = draft
        model.sketchCommand { $0.setDimension(id, expression: text) }
        if session.editingDimension == nil { onDone() }
    }
}

/// Asks for the offset distance. Positive goes outward (or to the left of an open chain).
struct OffsetPopover: View {
    let model: DocumentModel
    let session: SketchSession
    @State private var draft = "2 mm"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Offset Distance").font(.headline)
            HStack {
                TextField("Distance", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 160)
                    .focused($focused)
                    .onSubmit(commit)
                Button("Offset", action: commit).keyboardShortcut(.defaultAction)
            }
            Text("Positive goes outward; use a negative value to go inward.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = session.message { Text(message).font(.caption).foregroundStyle(.red) }
        }
        .padding(12)
        .onAppear { focused = true }
    }

    private func commit() {
        let text = draft
        model.sketchCommand { $0.offsetSelection(expression: text) }
    }
}
