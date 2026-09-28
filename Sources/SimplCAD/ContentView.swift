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
    @AppStorage(Preferences.showAxes) private var showAxes = true
    @AppStorage(Preferences.showConstraints) private var showConstraints = true
    /// The window's width: below these, the toolbar tools drop their titles so the row still fits
    /// (otherwise macOS folds the whole row into the toolbar's overflow menu).
    @State private var windowWidth: CGFloat = 1200
    static let titledDesignWidth: CGFloat = 1720
    static let titledSketchWidth: CGFloat = 1540

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
                         showGrid: showGrid, showAxes: showAxes && model.sketchSession == nil, showConstraints: showConstraints,
                         panelInsets: (model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0,
                                       model.showInspector ? Panel.inspectorWidth + Panel.margin : 0,
                                       Panel.bottomInset(timeline: model.showTimeline)))
                .ignoresSafeArea()
            VStack(spacing: Panel.inset) {
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
            if model.showTimeline {
                TimelineBar(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            }
            .padding(Panel.inset)
            .animation(.easeOut(duration: DS.Duration.base), value: model.showTimeline)
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
                .padding(.bottom, model.showTimeline ? TimelineBar.height + 2 * Panel.inset : Panel.inset)
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .toolbar {
            // The tools sit in the middle of the toolbar, in Design and in Sketch mode.
            ToolbarItem(placement: .principal) {
                Group {
                    if let session = model.sketchSession {
                        SketchToolbar(model: model, session: session)
                    } else {
                        DesignToolbar(model: model)
                    }
                }
                .environment(\.toolTitles, windowWidth >= (model.sketchSession == nil ? Self.titledDesignWidth : Self.titledSketchWidth))
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
            if let fileURL { RecentParts.note(fileURL) }
            AppWindows.openWindow = openWindow
            dismissWindow(id: AppWindows.welcomeID)  // a part is open; the welcome window has done its job
        }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .onChange(of: fileURL) {
            model.fileURL = fileURL
            if let fileURL { RecentParts.note(fileURL) }  // saved for the first time, or saved as
        }
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

    /// How much the timeline and status bar cover at the bottom of the viewport.
    static func bottomInset(timeline: Bool) -> CGFloat {
        (timeline ? TimelineBar.height + inset : 0) + DS.ControlHeight.large + 2 * inset
    }
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
            Text("Click faces or edges to select · double-click an edge for its loop · ⇧-click to add · drag to orbit").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var model: DocumentModel
    @State private var bodiesOpen = true
    @State private var sketchesOpen = true
    @State private var parametersOpen = true
    @State private var planesOpen = true
    /// The body or sketch whose name is being edited in place.
    @State private var renaming: FeatureID?

    var body: some View {
        List(selection: $model.selectedFeature) {
            Section("Browser") {
                DisclosureGroup(isExpanded: $bodiesOpen) {
                    ForEach(model.bodies) { b in
                        BrowserRow(name: b.name, hidden: model.isHidden(b.id),
                                   toggle: { model.setHidden([b.id], !model.isHidden(b.id)) },
                                   renaming: renamingBinding(b.id), rename: { model.renameBody(b.id, to: $0) }) {
                            Image(systemName: "cylinder")
                        }
                        .tag(b.id)
                        .listRowBackground(BrowserHighlight(on: model.browserHighlights.contains(b.id)))
                    }
                } label: {
                    FolderRow(title: "Bodies", ids: model.bodies.map(\.id), model: model)
                }
                DisclosureGroup(isExpanded: $sketchesOpen) {
                    ForEach(model.sketches) { f in
                        BrowserRow(name: f.name, hidden: model.isHidden(f.id),
                                   toggle: { model.setHidden([f.id], !model.isHidden(f.id)) },
                                   renaming: renamingBinding(f.id), rename: { model.renameFeature(f.id, to: $0) }) {
                            SketchIcon(editing: model.sketchSession?.featureID == f.id,
                                       locked: model.result?.sketches[f.id]?.solve.degreesOfFreedom == 0,
                                       failed: model.result?.errors[f.id] != nil)
                        }
                        .tag(f.id)
                        .listRowBackground(BrowserHighlight(on: model.browserHighlights.contains(f.id)))
                    }
                } label: {
                    FolderRow(title: "Sketches", ids: model.sketches.map(\.id), model: model)
                }
                if !model.planeFeatures.isEmpty {
                    DisclosureGroup(isExpanded: $planesOpen) {
                        ForEach(model.planeFeatures) { f in
                            BrowserRow(name: f.name, hidden: model.isHidden(f.id),
                                       toggle: { model.setHidden([f.id], !model.isHidden(f.id)) },
                                       renaming: renamingBinding(f.id), rename: { model.renameFeature(f.id, to: $0) }) {
                                Icon("plane", size: 14)
                            }
                            .tag(f.id)
                        }
                    } label: {
                        FolderRow(title: "Planes", ids: model.planeFeatures.map(\.id), model: model)
                    }
                }
            }
            // A plain section with its own chevron: the sidebar's built-in one only shows on hover.
            Section {
                if parametersOpen {
                    ForEach(model.document.parameters) { p in
                        ParameterRow(model: model, parameter: p)
                    }
                }
            } header: {
                HStack(spacing: DS.Spacing.space1) {
                    Text("Parameters")
                        .contentShape(Rectangle())
                        .onTapGesture { toggleParameters() }
                    Spacer()
                    HeaderIconButton(systemImage: "plus", help: "Add a parameter") {
                        withAnimation(.easeOut(duration: 0.15)) { parametersOpen = true }  // show the new one
                        model.addParameter()
                    }
                    HeaderIconButton(systemImage: "chevron.right", rotation: parametersOpen ? 90 : 0,
                                     help: parametersOpen ? "Hide the parameters" : "Show the parameters") {
                        toggleParameters()
                    }
                }
                .padding(.trailing, DS.Spacing.space4)  // clear of the panel edge, in line with the rows below
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

    private func toggleParameters() {
        withAnimation(.easeOut(duration: 0.15)) { parametersOpen.toggle() }
    }

    /// Whether a row is being renamed; ending the edit clears it.
    private func renamingBinding(_ id: FeatureID) -> Binding<Bool> {
        Binding(get: { renaming == id }, set: { if !$0, renaming == id { renaming = nil } })
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
                Button("Move Sketch") { model.move(sketches: [id]) }
                Button("Rename Sketch") { renaming = id }
            } else if case .plane = f.kind {
                Button("New Sketch on Plane") { model.beginSketch(on: .plane(id)) }
                Button(model.isHidden(id) ? "Show Plane" : "Hide Plane") { model.setHidden([id], !model.isHidden(id)) }
                Button("Rename Plane") { renaming = id }
            } else if model.bodies.contains(where: { $0.id == id }) {
                Button(model.isHidden(id) ? "Show Body" : "Hide Body") { model.setHidden([id], !model.isHidden(id)) }
                Button("Move Body") { model.move(bodies: [id]) }
                Button("Rename Body") { renaming = id }
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

/// A small icon button in a sidebar section header (add, expand/collapse), with a hover highlight.
struct HeaderIconButton: View {
    let systemImage: String
    var rotation: Double = 0
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(rotation))
                .frame(width: 20, height: 20)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .background(hovering ? Color.primary.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: rotation)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A body or sketch in the browser: eye toggle, icon, name (edited in place while `renaming`).
struct BrowserRow<Icon: View>: View {
    let name: String
    let hidden: Bool
    let toggle: () -> Void
    @Binding var renaming: Bool
    let rename: (String) -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: DS.Spacing.labelGap) {
            EyeButton(hidden: hidden, toggle: toggle)
            icon().frame(width: 18)
            if renaming {
                InlineNameField(name: name, commit: { rename($0); renaming = false }, cancel: { renaming = false })
            } else {
                Text(name)
            }
        }
        .foregroundStyle(hidden ? .secondary : .primary)
    }
}

/// A name edited in place: focused and selected when it appears; Return or clicking away keeps
/// it, Esc puts the old name back.
struct InlineNameField: View {
    let name: String
    let commit: (String) -> Void
    let cancel: () -> Void
    @State private var draft = ""
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .focused($focused)
            .onAppear {
                draft = name
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit { finish(keep: true) }
            .onExitCommand { finish(keep: false) }
            .onChange(of: focused) { if !focused { finish(keep: true) } }
    }

    private func finish(keep: Bool) {
        guard !done else { return }
        done = true
        if keep, draft != name { commit(draft) } else { cancel() }
    }
}

/// The browser row of a body or sketch that owns something selected in the viewport.
struct BrowserHighlight: View {
    let on: Bool

    var body: some View {
        if on {
            RoundedRectangle(cornerRadius: DS.Radius.sidebarItem, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .padding(.horizontal, DS.Spacing.space2)
        }
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

struct ParameterRow: View {
    let model: DocumentModel
    let parameter: Parameter
    @State private var renaming = false
    /// Why the last rename was refused (a taken or invalid name).
    @State private var renameError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if renaming {
                    InlineNameField(name: parameter.name, commit: { new in
                        renameError = model.renameParameter(parameter.name, to: new)
                        renaming = false
                    }, cancel: { renaming = false })
                    .font(.body.monospaced())
                } else {
                    Text(parameter.name).font(.body.monospaced())
                        .onTapGesture(count: 2) { renameError = nil; renaming = true }
                        .help("Double-click to rename; every expression that uses it follows")
                }
                Spacer()
                if let error = model.result?.parameters.errors[parameter.name] {
                    Text(error).foregroundStyle(.red).font(.caption).lineLimit(1)
                } else if let q = model.result?.parameters.values[parameter.name] {
                    Text(parameter.unit.format(q.value)).foregroundStyle(.secondary).font(.caption)
                }
                // Length, angle or plain number.
                Menu {
                    ForEach([(UnitKind.length, "Length (mm)"), (.angle, "Angle (deg)"), (.none, "Number")], id: \.0) { unit, title in
                        Button {
                            model.setParameterUnit(parameter.name, unit)
                        } label: {
                            if parameter.unit == unit { Label(title, systemImage: "checkmark") } else { Text(title) }
                        }
                    }
                } label: {
                    Text(parameter.unit == .length ? "mm" : parameter.unit == .angle ? "deg" : "#")
                        .font(.caption.monospaced())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Length, angle or plain number")
            }
            if let renameError {
                Text(renameError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ExpressionField(text: parameter.expression) { model.setParameter(parameter.name, expression: $0) }
            let users = model.document.features(using: parameter.name).map(\.name)
            Text(users.isEmpty ? "Not used yet · type \(parameter.name) in any size field" : "Used by \(users.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, DS.Spacing.space2)
        .contextMenu {
            Button("Rename") { renameError = nil; renaming = true }
            Button("Delete", role: .destructive) { model.removeParameter(parameter.name) }
        }
    }
}

/// A text field that commits on Return / focus loss and follows external changes (undo).
struct ExpressionField: View {
    let text: String
    /// Called shortly after typing pauses, to preview the uncommitted value (no undo step).
    var preview: ((String) -> Void)? = nil
    let commit: (String) -> Void
    /// Expressions are monospaced; plain text (a name) isn't.
    var monospaced = true
    @State private var draft = ""
    @State private var edited = false
    @FocusState private var focused: Bool

    init(text: String, monospaced: Bool = true, preview: ((String) -> Void)? = nil, commit: @escaping (String) -> Void) {
        self.text = text
        self.monospaced = monospaced
        self.preview = preview
        self.commit = commit
    }

    var body: some View {
        TextField("expression", text: $draft)
            .labelsHidden()  // in a Form row the label beside the field would read "expression"
            .textFieldStyle(.roundedBorder)
            .font(monospaced ? .body.monospaced() : .body)
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

/// A toolbar tool: its icon with a short title underneath, so the tools are easy to learn.
/// Highlighted while `active` (the current sketch tool, or a design tool waiting for picks).
struct ToolButton: View {
    let title: String
    let icon: String
    var active = false
    var help: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.toolTitles) private var showsTitle
    @Environment(\.toolsOnTint) private var onTint
    @State private var hovering = false

    private var ink: Color { onTint ? .white : .primary }
    private var background: Color {
        if active { return onTint ? Color.white.opacity(0.24) : Color.accentColor.opacity(0.16) }
        return hovering && isEnabled ? ink.opacity(onTint ? 0.14 : 0.07) : .clear
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Spacing.space1) {
                Icon(icon, size: 18).frame(height: 20)
                if showsTitle {
                    Text(title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(minWidth: showsTitle ? 44 : 28, minHeight: showsTitle ? 0 : 28)
            .padding(.horizontal, showsTitle ? DS.Spacing.space2 : DS.Spacing.space1)
            .padding(.vertical, DS.Spacing.space1)
            .foregroundStyle(active && !onTint ? Color.accentColor : ink)
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : DS.opacityDisabled)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

extension EnvironmentValues {
    /// Whether toolbar tools show their title under the icon (they don't when the window is too
    /// narrow for the titled row; a setting can turn them off later).
    @Entry var toolTitles = true
    /// Whether the tools sit on a tinted (accent-coloured) toolbar, as in Sketch mode, and so draw in white.
    @Entry var toolsOnTint = false
}

/// Tool groups in the toolbar are separated by a thin line.
struct ToolDivider: View {
    @Environment(\.toolTitles) private var showsTitles
    @Environment(\.toolsOnTint) private var onTint
    var body: some View {
        Group {
            if onTint { Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1) } else { Divider() }
        }
        .frame(height: 30).padding(.horizontal, showsTitles ? DS.Spacing.space3 : DS.Spacing.space2)
    }
}

/// Sketch mode's tools, in the middle of the toolbar, in groups: Select · draw · change curves ·
/// dimension and constrain · Finish.
struct SketchToolbar: View {
    let model: DocumentModel
    let session: SketchSession
    @State private var constrainOpen = false
    /// The shape whose ways of drawing are showing (rectangle, circle, arc).
    @State private var modesOpen: SketchTool?
    @Environment(\.toolTitles) private var showsTitles
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        HStack(spacing: DS.Spacing.space1) {
            tools([.select])
            ToolDivider()
            tools(SketchTool.draw)
            ToolDivider()
            tools(SketchTool.modify)
            ToolButton(title: "Offset", icon: "expand", help: "Offset the selected curves by a distance") { session.beginOffset() }
                .disabled(!session.canOffset)
                .popover(isPresented: Binding(get: { session.offsetRequested }, set: { session.offsetRequested = $0 }),
                         arrowEdge: .bottom) {
                    OffsetPopover(model: model, session: session)
                }
            ToolDivider()
            tools([.dimension])
            ToolButton(title: "Constrain", icon: "link", help: "Constrain the selected sketch entities") { constrainOpen = true }
                .popover(isPresented: $constrainOpen, arrowEdge: .bottom) { constrainChoices }
            ToolButton(title: "Construction", icon: "square-dashed", help: "Toggle construction geometry for the selected curves") {
                model.sketchCommand { $0.toggleConstruction() }
            }
            .disabled(!session.canToggleConstruction)
            ToolDivider()
            Button { model.finishSketch() } label: {
                if showsTitles {
                    Label("Finish Sketch", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                } else {
                    Label("Finish Sketch", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
                }
            }
            .help("Finish the sketch (Return)")
            .buttonStyle(.borderedProminent)
        }
        // The prominent Finish button tints the whole toolbar group while the window is active.
        .environment(\.toolsOnTint, activeState != .inactive)
        .padding(.horizontal, DesignToolbar.edgePadding)
        .fixedSize()
    }

    private func tools(_ list: [SketchTool]) -> some View {
        // Tools in a family (rectangle, circle, arc) share one button: only the first shows.
        ForEach(list.filter { $0.family.first == $0 }) { tool in
            if tool.family.count > 1 {
                modeTool(tool)
            } else {
                ToolButton(title: tool.shortTitle, icon: tool.symbol, active: session.tool == tool, help: tool.help) {
                    model.setSketchTool(tool)
                }
            }
        }
    }

    /// A shape with several ways to draw it: one button, which draws it the way used last, and a
    /// small arrow beside it to choose the way (the tool's key switches too).
    private func modeTool(_ head: SketchTool) -> some View {
        let mode = session.mode(of: head)
        return HStack(spacing: 0) {
            ToolButton(title: mode.shortTitle, icon: mode.symbol, active: head.family.contains(session.tool), help: mode.help) {
                model.setSketchTool(mode)
            }
            Button { modesOpen = head } label: {
                Icon("chevron-down", size: 10)
                    .frame(width: 12, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(activeState != .inactive ? Color.white : Color.primary)
            .help("Choose how to draw the \(head.shortTitle.lowercased())")
            .accessibilityLabel("\(head.shortTitle) options")
            .popover(isPresented: Binding(get: { modesOpen == head }, set: { if !$0, modesOpen == head { modesOpen = nil } }),
                     arrowEdge: .bottom) {
                HStack(spacing: DS.Spacing.space1) {
                    ForEach(head.family) { tool in
                        ToolButton(title: tool.modeTitle, icon: tool.symbol, active: session.tool == tool, help: tool.help) {
                            modesOpen = nil
                            model.setSketchTool(tool)
                        }
                    }
                }
                .environment(\.toolTitles, true)
                .environment(\.toolsOnTint, false)
                .padding(DS.Spacing.space3)
            }
        }
    }

    /// The constraints, enabled when they fit the selection.
    private var constrainChoices: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            if session.selection.isEmpty {
                Text("Select sketch entities first").font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, DS.Spacing.space2)
            }
            ForEach(ConstraintTool.allCases, id: \.self) { c in
                Button(c.rawValue) {
                    model.sketchCommand { $0.apply(c) }
                    constrainOpen = false
                }
                .buttonStyle(.borderless)
                .disabled(!session.canApply(c))
            }
        }
        .padding(DS.Spacing.space5)
    }
}

/// Design mode's tools, in the middle of the toolbar, in groups: Sketch · shapes from sketches ·
/// primitives · tools that change a body. A tool that is waiting for picks is highlighted.
struct DesignToolbar: View {
    let model: DocumentModel
    @State private var shapesOpen = false
    @Environment(\.toolTitles) private var showsTitles
    /// Space inside the ends of the toolbar's capsule.
    static let edgePadding: CGFloat = 10

    var body: some View {
        HStack(spacing: DS.Spacing.space1) {
            if model.isPickingSketchPlane {
                ToolButton(title: "Cancel", icon: "circle-x", active: true, help: "Stop choosing a sketch plane (Esc)") {
                    model.cancelSketchPlanePick()
                }
            } else {
                ToolButton(title: "Sketch", icon: "pen-tool",
                           help: "Create a sketch: then click an origin plane or a flat face in the viewport") { model.startSketch() }
            }
            ToolDivider()
            group(DesignTool.shapes)
            ToolDivider()
            if showsTitles {
                group(DesignTool.primitives)
            } else {
                // Narrow window: the primitives share one button that opens a palette of them.
                ToolButton(title: "Shapes", icon: "cuboid", active: DesignTool.primitives.contains { model.pendingTool == $0 },
                           help: "Box, cylinder, sphere, torus or coil") { shapesOpen = true }
                    .popover(isPresented: $shapesOpen, arrowEdge: .bottom) {
                        HStack(spacing: DS.Spacing.space1) {
                            ForEach(DesignTool.primitives) { tool in
                                ToolButton(title: tool.rawValue, icon: tool.symbol, help: tool.help) {
                                    shapesOpen = false
                                    model.run(tool)
                                }
                            }
                        }
                        .environment(\.toolTitles, true)
                        .padding(DS.Spacing.space3)
                    }
            }
            ToolDivider()
            group(DesignTool.modifiers)
            ToolDivider()
            group(DesignTool.construct)
        }
        .padding(.horizontal, Self.edgePadding)  // room at the ends of the toolbar's capsule
        .fixedSize()
    }

    private func group(_ tools: [DesignTool]) -> some View {
        ForEach(tools) { tool in
            ToolButton(title: tool.rawValue, icon: tool.symbol, active: model.pendingTool == tool, help: tool.help) {
                model.run(tool)
            }
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
