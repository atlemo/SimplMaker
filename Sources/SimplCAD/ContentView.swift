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
        // The viewport fills the window, under the toolbar too; the browser and the inspector float
        // over it as glass panels, like the sidebars of current macOS apps.
        ZStack {
            ViewportView(model: model, sceneRevision: model.sceneRevision, overlayRevision: model.overlayRevision,
                         highlighted: model.highlighted, fitRevision: model.fitRevision,
                         cameraRevision: model.cameraCommand?.revision ?? 0, orthographic: model.orthographic,
                         showGrid: showGrid, showConstraints: showConstraints,
                         panelInsets: (model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0,
                                       model.showInspector ? Panel.inspectorWidth + Panel.margin : 0))
                .ignoresSafeArea()
            HStack(alignment: .top, spacing: 0) {
                if model.showSidebar {
                    Sidebar(model: model)
                        .floatingPanel(width: Panel.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)  // empty: clicks go through to the viewport
                if model.showInspector {
                    InspectorView(model: model)
                        .floatingPanel(width: Panel.inspectorWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(Panel.inset)
            .animation(.easeOut(duration: DS.Duration.base), value: model.showSidebar)
            .animation(.easeOut(duration: DS.Duration.base), value: model.showInspector)
        }
        // An empty part says how to begin, in the middle of the free space.
        .overlay {
            if model.document.features.isEmpty, model.sketchSession == nil, model.pendingTool == nil,
               !model.isPickingSketchPlane {
                StartCard(model: model)
                    .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : 0)
                    .transition(.opacity)
            }
        }
        // The status bar floats at the bottom, between the panels.
        .overlay(alignment: .bottom) {
            StatusBar(model: model)
                .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : Panel.inset)
                .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : Panel.inset)
                .padding(.bottom, Panel.inset)
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            // The tools sit in the middle of the toolbar, in Design and in Sketch mode.
            ToolbarItem(placement: .principal) {
                if let session = model.sketchSession {
                    SketchToolbar(model: model, session: session)
                } else {
                    DesignToolbar(model: model)
                }
            }
            ToolbarItem(placement: .navigation) {
                Button { model.showSidebar.toggle() } label: { Label("Browser", systemImage: "sidebar.left") }
                    .help("Show or hide the browser (⌃⌘S)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.fitView() } label: { toolLabel("Fit", "focus") }
                    .help("Fit the model in view (⌘0)")
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help("Show or hide the inspector (⌥⌘I)")
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

/// Shown on an empty part: the two ways to begin.
struct StartCard: View {
    let model: DocumentModel

    var body: some View {
        VStack(spacing: DS.Spacing.space5) {
            Text("Start your part").font(.title2.weight(.semibold))
            Text("Draw a sketch on a plane and extrude it, or place a shape and change it from there.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            HStack(spacing: DS.Spacing.space4) {
                Button { model.startSketch() } label: { Label("Sketch", systemImage: "pencil.and.outline") }
                    .buttonStyle(.borderedProminent)
                Button { model.run(.box) } label: { Label("Box", systemImage: "cube") }
                Button { model.run(.cylinder) } label: { Label("Cylinder", systemImage: "cylinder") }
            }
            .controlSize(.large)
            Text("Right-click in the view for more · File › New Demo Part for an example")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(DS.Spacing.space8)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.window))
    }
}

/// Sizes of the floating panels.
enum Panel {
    static let sidebarWidth: CGFloat = 280
    static let inspectorWidth: CGFloat = 290
    /// Gap between a panel and the window edge.
    static let inset: CGFloat = DS.Spacing.space4
    /// A panel's width plus its gaps: how much of the viewport it covers.
    static let margin: CGFloat = 2 * DS.Spacing.space4
}

extension View {
    /// A floating glass panel: rounded, inset from the window edge, full height.
    func floatingPanel(width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous)
        return self
            .scrollContentBackground(.hidden)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
    }
}

struct StatusBar: View {
    let model: DocumentModel

    var body: some View {
        HStack(spacing: DS.Spacing.space5) {
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
        .padding(.horizontal, DS.Spacing.space5)
        .frame(height: DS.ControlHeight.large)
        .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder private var message: some View {
        if let session = model.sketchSession {
            Text(session.statusText)
                .foregroundStyle(session.message != nil || session.solve?.status == .failed ? Color.red : Color.secondary)
        } else if model.isPickingSketchPlane {
            Text("Select a plane or planar face to sketch on · Esc to cancel")
        } else if let tool = model.pendingTool, let prompt = model.toolPrompt {
            Text("\(tool.rawValue): \(prompt) · Esc to cancel")
        } else if let h = model.dragHandle, model.hovered == nil || model.hovered?.kind == .handle {
            Text(model.previewInvalid ? "That size doesn't fit — let go to keep the previous size"
                                      : "Drag the orange arrow to change the \(h.label.lowercased()), or type it in the field next to it")
                .foregroundStyle(model.previewInvalid ? Color.red : Color.secondary)
        } else if !model.selectedProfiles.isEmpty, model.hovered == nil {
            Text("Press E to extrude the selected profile\(model.selectedProfiles.count == 1 ? "" : "s"), or pick another tool")
                .foregroundStyle(.secondary)
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
    @State private var bodiesOpen = true
    @State private var sketchesOpen = true

    var body: some View {
        List(selection: $model.selectedFeature) {
            Section("Browser") {
                DisclosureGroup(isExpanded: $bodiesOpen) {
                    ForEach(model.bodies) { b in
                        BrowserRow(name: b.name, hidden: model.isHidden(b.id),
                                   toggle: { model.setHidden([b.id], !model.isHidden(b.id)) }) {
                            Image(systemName: "cylinder")
                        }
                        .tag(b.id)
                    }
                } label: {
                    FolderRow(title: "Bodies", ids: model.bodies.map(\.id), model: model)
                }
                DisclosureGroup(isExpanded: $sketchesOpen) {
                    ForEach(model.sketches) { f in
                        BrowserRow(name: f.name, hidden: model.isHidden(f.id),
                                   toggle: { model.setHidden([f.id], !model.isHidden(f.id)) }) {
                            SketchIcon(editing: model.sketchSession?.featureID == f.id,
                                       locked: model.result?.sketches[f.id]?.solve.degreesOfFreedom == 0,
                                       failed: model.result?.errors[f.id] != nil)
                        }
                        .tag(f.id)
                    }
                } label: {
                    FolderRow(title: "Sketches", ids: model.sketches.map(\.id), model: model)
                }
            }
            Section("Timeline") {
                ForEach(model.document.features) { f in
                    FeatureRow(feature: f, error: model.result?.errors[f.id])
                        .tag(f.id)
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
        .contextMenu(forSelectionType: FeatureID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            // Double-click to edit: a sketch opens in sketch mode, other features show their handle.
            if ids.count == 1, let id = ids.first { model.editFeature(id) }
        }
    }

    private func isSketch(_ id: FeatureID) -> Bool {
        if case .sketch? = model.document.features.first(where: { $0.id == id })?.kind { return true }
        return false
    }

    @ViewBuilder private func menu(for ids: Set<FeatureID>) -> some View {
        if ids.count == 1, let id = ids.first, let f = model.document.features.first(where: { $0.id == id }) {
            if isSketch(id) {
                Button(model.sketchSession?.featureID == id ? "Finish Sketch" : "Edit Sketch") {
                    if model.sketchSession?.featureID == id { model.finishSketch() } else { model.editSketch(id) }
                }
                Button(model.isHidden(id) ? "Show Sketch" : "Hide Sketch") { model.setHidden([id], !model.isHidden(id)) }
            } else if model.bodies.contains(where: { $0.id == id }) {
                Button(model.isHidden(id) ? "Show Body" : "Hide Body") { model.setHidden([id], !model.isHidden(id)) }
            }
            Divider()
            Button(f.suppressed ? "Unsuppress" : "Suppress") {
                model.updateFeature(id, f.suppressed ? "Unsuppress" : "Suppress") { $0.suppressed.toggle() }
            }
            Button("Delete \(f.name)", role: .destructive) { model.deleteFeature(id) }
        } else if !ids.isEmpty {
            Button("Hide") { model.setHidden(Array(ids), true) }
            Button("Show") { model.setHidden(Array(ids), false) }
        }
    }
}

/// A body or sketch in the browser: eye toggle, icon, name.
struct BrowserRow<Icon: View>: View {
    let name: String
    let hidden: Bool
    let toggle: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: DS.Spacing.labelGap) {
            EyeButton(hidden: hidden, toggle: toggle)
            icon().frame(width: 18)
            Text(name)
        }
        .foregroundStyle(hidden ? .secondary : .primary)
    }
}

/// A browser folder ("Bodies", "Sketches"): its eye shows or hides everything in it.
struct FolderRow: View {
    let title: String
    let ids: [FeatureID]
    let model: DocumentModel

    var body: some View {
        let allHidden = !ids.isEmpty && ids.allSatisfy { model.isHidden($0) }
        HStack(spacing: DS.Spacing.labelGap) {
            EyeButton(hidden: allHidden) { model.setHidden(ids, !allHidden) }
                .disabled(ids.isEmpty)
            Image(systemName: "folder").frame(width: 18)
            Text(title)
        }
    }
}

struct EyeButton: View {
    let hidden: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: hidden ? "eye.slash" : "eye")
                .frame(width: 18)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(hidden ? "Show" : "Hide")
    }
}

/// A sketch's browser icon: a pencil while it's being edited, a lock when fully constrained.
struct SketchIcon: View {
    let editing: Bool
    let locked: Bool
    let failed: Bool

    var body: some View {
        Image(systemName: "square.dashed")
            .overlay(alignment: .bottomTrailing) {
                if failed {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundStyle(.red)
                } else if editing {
                    Image(systemName: "pencil").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                } else if locked {
                    Image(systemName: "lock.fill").font(.system(size: 7)).foregroundStyle(.red)
                }
            }
            .help(failed ? "This sketch has an error" : editing ? "Being edited" : locked ? "Fully constrained" : "Sketch")
    }
}

struct FeatureRow: View {
    let feature: Feature
    let error: String?

    var icon: String {
        switch feature.kind {
        case .sketch: return "pen-tool"
        case .extrude: return DesignTool.extrude.symbol
        case .fillet: return DesignTool.fillet.symbol
        case .chamfer: return DesignTool.chamfer.symbol
        case .revolve: return DesignTool.revolve.symbol
        case .sweep: return DesignTool.sweep.symbol
        case .loft: return DesignTool.loft.symbol
        case .rib: return DesignTool.rib.symbol
        case .hole: return DesignTool.hole.symbol
        case .pipe: return DesignTool.pipe.symbol
        case .primitive(let p):
            switch p.kind {
            case .box: return DesignTool.box.symbol
            case .cylinder: return DesignTool.cylinder.symbol
            case .sphere: return DesignTool.sphere.symbol
            case .torus: return DesignTool.torus.symbol
            case .coil: return DesignTool.coil.symbol
            }
        }
    }

    var body: some View {
        HStack {
            Icon(icon).frame(width: 18)
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
        .padding(.vertical, DS.Spacing.space2)
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
            .labelsHidden()  // in a Form row the label beside the field would read "expression"
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

/// Sketch mode's tools, in the middle of the toolbar, in groups: Select · draw · change curves ·
/// dimension and constrain · Finish.
struct SketchToolbar: View {
    let model: DocumentModel
    let session: SketchSession

    var body: some View {
        HStack(spacing: 14) {
            tools([.select])
            tools(SketchTool.draw)
            ControlGroup {
                toolToggles(SketchTool.modify)
                Button { session.beginOffset() } label: { toolLabel("Offset", "expand") }
                    .help("Offset the selected curves by a distance")
                    .disabled(!session.canOffset)
                    .popover(isPresented: Binding(get: { session.offsetRequested }, set: { session.offsetRequested = $0 }),
                             arrowEdge: .bottom) {
                        OffsetPopover(model: model, session: session)
                    }
            }
            ControlGroup {
                toolToggles([.dimension])
                Menu {
                    ForEach(ConstraintTool.allCases, id: \.self) { c in
                        Button(c.rawValue) { model.sketchCommand { $0.apply(c) } }
                            .disabled(!session.canApply(c))
                    }
                } label: { toolLabel("Constrain", "link") }
                    .help("Constrain the selected sketch entities")
                Button { model.sketchCommand { $0.toggleConstruction() } } label: {
                    toolLabel("Construction", "square-dashed")
                }
                .help("Toggle construction geometry for the selected curves")
                .disabled(!session.canToggleConstruction)
            }
            Button { model.finishSketch() } label: { Label("Finish Sketch", systemImage: "checkmark.circle.fill") }
                .help("Finish the sketch (Return)")
                .buttonStyle(.borderedProminent)
                .labelStyle(.titleAndIcon)
        }
        .labelStyle(.iconOnly)
        .toggleStyle(.button)
        .fixedSize()
    }

    private func tools(_ list: [SketchTool]) -> some View {
        ControlGroup { toolToggles(list) }
    }

    @ViewBuilder private func toolToggles(_ list: [SketchTool]) -> some View {
        ForEach(list) { tool in
            Toggle(isOn: Binding(get: { session.tool == tool }, set: { _ in model.setSketchTool(tool) })) {
                toolLabel(tool.rawValue, tool.symbol)
            }
            .help("\(tool.rawValue) (\(String(tool.key).uppercased()))")
        }
    }
}

/// Design mode's tools, in the middle of the toolbar, in groups: Sketch · shapes from sketches ·
/// primitives · tools that change a body. A tool that is waiting for picks is highlighted.
struct DesignToolbar: View {
    let model: DocumentModel

    var body: some View {
        HStack(spacing: 14) {
            if model.isPickingSketchPlane {
                Button { model.cancelSketchPlanePick() } label: { toolLabel("Cancel Sketch", "circle-x") }
                    .help("Stop choosing a sketch plane (Esc)")
            } else {
                Button { model.startSketch() } label: { toolLabel("Sketch", "pen-tool") }
                    .help("Create a sketch: then click an origin plane or a flat face in the viewport")
            }
            group(DesignTool.shapes)
            group(DesignTool.primitives)
            group(DesignTool.modifiers)
        }
        .labelStyle(.iconOnly)
        .fixedSize()
    }

    private func group(_ tools: [DesignTool]) -> some View {
        ControlGroup {
            ForEach(tools) { tool in
                Toggle(isOn: Binding(get: { model.pendingTool == tool }, set: { _ in model.run(tool) })) {
                    toolLabel(tool.rawValue, tool.symbol)
                }
                .help(tool.help)
            }
        }
        .toggleStyle(.button)
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
        VStack(alignment: .leading, spacing: DS.Spacing.labelGap) {
            HStack(spacing: DS.Spacing.controlGap) {
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
        .padding(DS.Spacing.space5)
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
        VStack(alignment: .leading, spacing: DS.Spacing.labelGap) {
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
        .padding(DS.Spacing.space6)
        .onAppear { focused = true }
    }

    private func commit() {
        let text = draft
        model.sketchCommand { $0.offsetSelection(expression: text) }
    }
}
