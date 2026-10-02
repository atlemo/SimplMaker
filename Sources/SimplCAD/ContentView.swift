// Main window: timeline + parameters on the left, viewport in the middle, inspector on the right.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
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
    @AppStorage(Preferences.unitSystem) private var unitSystem = Preferences.UnitSystem.system
    @AppStorage(Preferences.gridSizeMetric) private var gridSizeMetric = 0.0
    @AppStorage(Preferences.gridSizeUS) private var gridSizeUS = 0.0
    @AppStorage(Preferences.showAxes) private var showAxes = true
    @AppStorage(Preferences.showConstraints) private var showConstraints = true
    /// The window's width: below this, the Finish Sketch button drops its title so the sketch
    /// tools still fit (otherwise macOS folds the whole row into the toolbar's overflow menu).
    @State private var windowWidth: CGFloat = 1200
    static let titledSketchWidth: CGFloat = 1100

    @Environment(\.controlActiveState) private var activeState
    /// Sketch mode tints the toolbar while the window is active.
    private var sketchTint: Bool { model.sketchSession != nil && activeState != .inactive }
    /// The pointer is over the toolbar strip, which fades in a background, and how tall that strip is.
    @State private var toolbarHovered = false
    @State private var toolbarHeight: CGFloat = 65

    private var unlinkTitle: String {
        guard let p = model.unlinkPrompt else { return "" }
        return "Replace \(p.expression) with \(p.valueText)?"
    }

    var body: some View {
        // The viewport fills the window, under the toolbar too; the browser and the inspector float
        // over it as glass panels, like the sidebars of current macOS apps. The toolbar has no
        // background until the pointer is over it, when one fades in.
        ZStack {
            ViewportView(model: model, sceneRevision: model.sceneRevision, overlayRevision: model.overlayRevision,
                         highlighted: model.highlighted, fitRevision: model.fitRevision,
                         cameraRevision: model.cameraCommand?.revision ?? 0, orthographic: model.orthographic,
                         visualStyle: model.visualStyle,
                         showGrid: showGrid, gridSetting: "\(unitSystem.rawValue)/\(gridSizeMetric)/\(gridSizeUS)", showAxes: showAxes && model.sketchSession == nil, showConstraints: showConstraints,
                         panelInsets: (model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0,
                                       model.showInspector ? Panel.inspectorWidth + Panel.margin : 0,
                                       Panel.bottomInset(timeline: model.showTimeline)))
                .ignoresSafeArea()
            ToolbarFade(tint: sketchTint ? .accentColor : Color(nsColor: .windowBackgroundColor),
                        height: toolbarHeight, visible: toolbarHovered || sketchTint)
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
        // The Appearance panel floats at the top, beside the inspector.
        .overlay(alignment: .topTrailing) {
            if model.showAppearance, model.sketchSession == nil {
                AppearancePanel(model: model)
                    .padding(.top, Panel.inset)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : Panel.inset)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: DS.Duration.fast), value: model.showAppearance)
        // The status bar floats at the bottom, between the panels.
        .overlay(alignment: .bottom) {
            StatusBar(model: model)
                .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : Panel.inset)
                .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : Panel.inset)
                .padding(.bottom, model.showTimeline ? TimelineBar.height + 2 * Panel.inset : Panel.inset)
        }
        // A feature with no drag handle gets its OK and Cancel here, above the status bar.
        .overlay(alignment: .bottom) {
            FeatureDoneBar(model: model)
                .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : Panel.inset)
                .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : Panel.inset)
                .padding(.bottom, (model.showTimeline ? TimelineBar.height + 2 * Panel.inset : Panel.inset) + DS.ControlHeight.large + Panel.inset)
        }
        .animation(.easeOut(duration: DS.Duration.fast), value: model.featureWithoutHandle)
        // The cursor's prompt goes above everything, panels included.
        .overlay { CursorPrompt(model: model) }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background(ToolbarHoverMonitor(hovering: $toolbarHovered))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { if $0 > 0 { toolbarHeight = $0 } }
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
                .environment(\.toolTitles, model.sketchSession == nil || windowWidth >= Self.titledSketchWidth)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Tools")
            }
            .sharedBackgroundVisibility(.hidden)  // the tools sit on the toolbar itself, with no glass of their own
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
            Button("Use \(p.valueText)") { model.resolveUnlink(useValue: true) }
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

/// The instruction next to the cursor while the app waits for a pick ("Select a plane or planar face"),
/// just below and right of the pointer and kept inside the window.
struct CursorPrompt: View {
    let model: DocumentModel
    @State private var size = CGSize.zero

    var body: some View {
        GeometryReader { geo in
            if let text = model.cursorPrompt, let p = model.cursorPromptAt {
                Text(text)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.checkbox))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.checkbox).strokeBorder(Color(nsColor: .separatorColor)))
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
                    .offset(x: min(max(p.x + 18, 0), max(geo.size.width - size.width, 0)),
                            y: min(max(p.y + 18, 0), max(geo.size.height - size.height, 0)))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The toolbar's background: a thick glass strip over the top of the view, always there so the
/// tools read, with a colour that fades in and out over it.
struct ToolbarFade: View {
    let tint: Color
    let height: CGFloat
    let visible: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.thickMaterial).frame(height: height)
                .overlay { Rectangle().fill(tint).opacity(visible ? 1 : 0) }
            Spacer(minLength: 0)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: DS.Duration.base), value: visible)
        .animation(.easeInOut(duration: DS.Duration.base), value: tint)
        .allowsHitTesting(false)
    }
}

/// Tells whether the pointer is over the window's toolbar strip. Events over the toolbar never reach
/// the content's own tracking areas, so a local event monitor watches the pointer instead.
struct ToolbarHoverMonitor: NSViewRepresentable {
    @Binding var hovering: Bool

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        let binding = $hovering
        view.onChange = { if binding.wrappedValue != $0 { binding.wrappedValue = $0 } }
    }

    final class MonitorView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited, .leftMouseDragged]) { [weak self] event in
                MainActor.assumeIsolated { self?.check(event) }
                return event
            }
        }

        private func check(_ event: NSEvent) {
            guard let window else { return }
            let p = window.mouseLocationOutsideOfEventStream
            let top = window.contentLayoutRect.maxY
            let inside = event.window === window && p.y >= top && p.y <= window.frame.height && p.x >= 0 && p.x <= window.frame.width
            onChange(inside)
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
                if model.isImporting { Text("Reading the file…").foregroundStyle(.secondary) }
                if model.isRegenerating || model.isImporting {
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
        } else if model.holeMoveStart != nil || model.hovered == .moveHandle {
            Text(model.previewInvalid ? "The hole doesn't fit there — let go to keep it where it was"
                                      : "Drag the orange dot to move the hole · it snaps to the face's centre lines")
                .foregroundStyle(model.previewInvalid ? Color.red : Color.secondary)
        } else if let h = model.dragHandle, model.hovered == nil || model.hovered?.kind == .handle {
            Text(model.previewInvalid ? "That size doesn't fit — let go to keep the previous size"
                                      : model.selectedHole != nil
                                        ? "Drag the orange dot to move the hole, or the arrow to change its depth"
                                        : model.manipulatedFeature != nil
                                        ? "Drag an arrow, square or ring dot · or type the \(h.label.lowercased()) in the field"
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
    @State private var imagesOpen = true
    /// The body or sketch whose name is being edited in place.
    @State private var renaming: FeatureID?

    /// Body rows are tagged apart from features ("body:<id>"): a click selects the body, not the
    /// feature that made it (that one opens on double-click).
    private static let bodyTag = "body:"
    private var listSelection: Binding<FeatureID?> {
        Binding(get: { model.selectedBody.map { Self.bodyTag + $0 } ?? model.selectedFeature },
                set: { tag in
                    if let tag, tag.hasPrefix(Self.bodyTag) { model.selectBody(String(tag.dropFirst(Self.bodyTag.count))) }
                    else { model.selectedFeature = tag }
                })
    }
    private func featureID(_ tag: FeatureID) -> FeatureID {
        tag.hasPrefix(Self.bodyTag) ? String(tag.dropFirst(Self.bodyTag.count)) : tag
    }

    var body: some View {
        List(selection: listSelection) {
            Section("Browser") {
                DisclosureGroup(isExpanded: $bodiesOpen) {
                    ForEach(model.bodies) { b in
                        BrowserRow(name: b.name, hidden: model.isHidden(b.id),
                                   toggle: { model.setHidden([b.id], !model.isHidden(b.id)) },
                                   renaming: renamingBinding(b.id), rename: { model.renameBody(b.id, to: $0) }) {
                            Image(systemName: "cylinder")
                        }
                        .tag(Self.bodyTag + b.id)
                        .listRowBackground(BrowserHighlight(on: model.browserHighlights.contains(b.id) && model.selectedBody != b.id))
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
                if !model.imageFeatures.isEmpty {
                    DisclosureGroup(isExpanded: $imagesOpen) {
                        ForEach(model.imageFeatures) { f in
                            BrowserRow(name: f.name, hidden: model.isHidden(f.id),
                                       toggle: { model.setHidden([f.id], !model.isHidden(f.id)) },
                                       renaming: renamingBinding(f.id), rename: { model.renameFeature(f.id, to: $0) }) {
                                Icon("image", size: 14)
                            }
                            .tag(f.id)
                        }
                    } label: {
                        FolderRow(title: "Canvases", ids: model.imageFeatures.map(\.id), model: model)
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
            menu(for: Set(ids.map(featureID)))
        } primaryAction: { ids in
            // Double-click to edit: a sketch opens in sketch mode, other features (and the one that
            // made a body) show their handle.
            if ids.count == 1, let id = ids.first { model.editFeature(featureID(id)) }
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
                Button("Scale Sketch") { model.scale(sketches: [id]) }
                Button("Rename Sketch") { renaming = id }
            } else if case .plane = f.kind {
                Button("New Sketch on Plane") { model.beginSketch(on: .plane(id)) }
                Button(model.isHidden(id) ? "Show Plane" : "Hide Plane") { model.setHidden([id], !model.isHidden(id)) }
                Button("Rename Plane") { renaming = id }
            } else if case .image = f.kind {
                Button("Replace Image…") { model.replaceImage(id) }
                Button(model.isHidden(id) ? "Show Canvas" : "Hide Canvas") { model.setHidden([id], !model.isHidden(id)) }
                Button("Rename Canvas") { renaming = id }
            } else if model.bodies.contains(where: { $0.id == id }) {
                Button(model.isHidden(id) ? "Show Body" : "Hide Body") { model.setHidden([id], !model.isHidden(id)) }
                Button("Move Body") { model.move(bodies: [id]) }
                Button("Rename Body") { renaming = id }
                Button("Appearance…") { model.openAppearance(for: id) }
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
        .accessibilityLabel(hidden ? "Show" : "Hide")  // the eye symbol's own name is always "Show"
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
                Icon(icon, size: 18, renderedStroke: Icon.toolStroke).frame(height: 20)
                if showsTitle {
                    Text(title)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .frame(minWidth: showsTitle ? 44 : 28, minHeight: showsTitle ? 0 : 24)
            .padding(.horizontal, showsTitle ? DS.Spacing.space2 : DS.Spacing.space1)
            .padding(.vertical, showsTitle ? DS.Spacing.space1 : 0)
            .foregroundStyle(active && !onTint ? Color.accentColor : ink)
            .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : DS.opacityDisabled)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .toolTip(help ?? title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

extension EnvironmentValues {
    /// Whether toolbar tools show their title under the icon (tools in a group don't: the group's
    /// name is under them), and Finish Sketch its title (not when the window is narrow).
    @Entry var toolTitles = true
    /// Whether the tools sit on a tinted (accent-coloured) toolbar, as in Sketch mode, and so draw in white.
    @Entry var toolsOnTint = false
}

extension View {
    /// The toolbar tools' row, sitting on the toolbar's own background. macOS makes the toolbar about
    /// 52 pt tall whatever is in it: padding doesn't change that, and an accessory strip under it adds
    /// at least 36 pt.
    func toolsPanel() -> some View {
        padding(.horizontal, DS.Spacing.space3)
            .padding(.vertical, DS.Spacing.space2)
            .fixedSize()
    }
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
/// dimension and constrain · Finish. Each group shows the tools pinned to it; its name opens the rest.
struct SketchToolbar: View {
    let model: DocumentModel
    let session: SketchSession
    @State private var constrainOpen = false
    @Environment(\.toolTitles) private var showsTitles
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        HStack(spacing: DS.Spacing.space1) {
            SoloTool(tool: tool(.select))
            ToolDivider()
            // Tools in a family (rectangle, circle, arc) share one button, under the first one's name.
            ToolGroup("Draw", id: "sketch.draw", defaults: ["Line", "Rectangle", "Circle", "Spline", "Text"],
                      tools: SketchTool.draw.filter { $0.family.first == $0 }.map(tool))
            ToolDivider()
            ToolGroup("Modify", id: "sketch.modify", defaults: ["Round Corner", "Trim", "Extend", "Offset"],
                      tools: SketchTool.modify.map(tool) + [offset])
            ToolDivider()
            ToolGroup("Transform", id: "sketch.transform", defaults: SketchTransformTool.allCases.map(\.rawValue),
                      tools: SketchTransformTool.allCases.map(transform))
            ToolDivider()
            ToolGroup("Constraints", id: "sketch.constraints", defaults: ["Dimension", "Constrain", "Construction"],
                      tools: [tool(.dimension), constrain, construction])
            ToolDivider()
            Button { model.finishSketch() } label: {
                if showsTitles {
                    Label("Finish Sketch", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                } else {
                    Label("Finish Sketch", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
                }
            }
            .toolTip("Finish the sketch (Return)")
            .buttonStyle(.borderedProminent)
        }
        // Sketch mode tints the tools' glass while the window is active.
        .environment(\.toolsOnTint, activeState != .inactive)
        .toolsPanel()
    }

    /// A sketch tool's button. A shape with several ways to draw it (rectangle, circle, arc) draws
    /// it the way used last, and offers the others (the tool's key switches too).
    private func tool(_ head: SketchTool) -> GroupTool {
        let mode = session.mode(of: head)
        let modes = head.family.count < 2 ? [] : head.family.map { t in
            GroupTool(id: t.rawValue, title: t.modeTitle, icon: t.symbol, help: t.help, active: session.tool == t) {
                model.setSketchTool(t)
            }
        }
        return GroupTool(id: head.rawValue, title: head.shortTitle, icon: mode.symbol, help: mode.help, shortcut: head.key,
                         active: head.family.contains(session.tool), modes: modes) { model.setSketchTool(mode) }
    }

    private func transform(_ tool: SketchTransformTool) -> GroupTool {
        // Move and Rotate show the manipulator to drag (or type into); Scale asks for a factor.
        GroupTool(id: tool.rawValue, title: tool.rawValue, icon: tool.symbol, help: tool.help,
                  active: session.manipulating == tool || (tool == .pattern && session.isPatterning),
                  enabled: tool == .pattern ? session.canPattern : session.canTransform,
                  popover: tool != .scale ? nil : ToolPopover(isPresented: Binding(get: { session.transformRequested == tool },
                                                            set: { if $0 { session.transformRequested = tool } else if session.transformRequested == tool { session.transformRequested = nil } }),
                                       content: AnyView(TransformPopover(model: model, session: session, tool: tool)))) {
            model.beginSketchTransform(tool)
        }
    }

    private var offset: GroupTool {
        GroupTool(id: "Offset", title: "Offset", icon: "expand", help: "Offset the selected curves by a distance",
                  enabled: session.canOffset,
                  popover: ToolPopover(isPresented: Binding(get: { session.offsetRequested }, set: { session.offsetRequested = $0 }),
                                       content: AnyView(OffsetPopover(model: model, session: session)))) {
            session.beginOffset()
        }
    }

    private var constrain: GroupTool {
        GroupTool(id: "Constrain", title: "Constrain", icon: "link", help: "Constrain the selected sketch entities",
                  popover: ToolPopover(isPresented: $constrainOpen, content: AnyView(constrainChoices))) {
            constrainOpen = true
        }
    }

    private var construction: GroupTool {
        GroupTool(id: "Construction", title: "Construction", icon: "square-dashed",
                  help: "Toggle construction geometry for the selected curves", enabled: session.canToggleConstruction) {
            model.sketchCommand { $0.toggleConstruction() }
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
/// primitives · tools that change a body · planes and copies. Each group shows the tools pinned to
/// it; its name opens the rest. A tool that is waiting for picks is highlighted.
struct DesignToolbar: View {
    let model: DocumentModel

    var body: some View {
        HStack(spacing: DS.Spacing.space1) {
            if model.isPickingSketchPlane {
                SoloTool(tool: GroupTool(id: "Cancel", title: "Cancel", icon: "circle-x", help: "Stop choosing a sketch plane (Esc)",
                                         active: true) { model.cancelSketchPlanePick() })
            } else {
                SoloTool(tool: GroupTool(id: "Sketch", title: "Sketch", icon: "pen-tool",
                                         help: "Create a sketch: then click an origin plane or a flat face in the viewport") { model.startSketch() })
            }
            ToolDivider()
            group("Create", id: "design.create", DesignTool.shapes, defaults: [.extrude, .revolve, .sweep, .loft])
            ToolDivider()
            group("Shapes", id: "design.shapes", DesignTool.primitives, defaults: [.box, .cylinder, .sphere])
            ToolDivider()
            group("Modify", id: "design.modify", DesignTool.modifiers, defaults: DesignTool.modifiers)
            ToolDivider()
            group("Construct", id: "design.construct", DesignTool.construct, defaults: [.plane, .mirror, .pattern, .canvas])
        }
        .toolsPanel()
    }

    private func group(_ title: String, id: String, _ tools: [DesignTool], defaults: [DesignTool]) -> some View {
        ToolGroup(title, id: id, defaults: defaults.map(\.rawValue), tools: tools.map { tool in
            GroupTool(id: tool.rawValue, title: tool.rawValue, icon: tool.symbol, help: tool.help, shortcut: tool.key,
                      active: model.pendingTool == tool) { model.run(tool) }
        })
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

/// Asks for the factor of Scale, and applies it to the selection (or the whole sketch). Move and Rotate
/// have the manipulator in the viewport instead.
struct TransformPopover: View {
    let model: DocumentModel
    let session: SketchSession
    let tool: SketchTransformTool
    @State private var factor = "2"
    @State private var pivot = TransformPivot.selection
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.labelGap) {
            Text(tool.rawValue).font(.headline)
            field("Factor", $factor, focus: true)
            pivotPicker
            HStack {
                Text("Works on \(session.transformTargetDescription).").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tool.rawValue, action: commit).keyboardShortcut(.defaultAction)
            }
            if let message = session.message { Text(message).font(.caption).foregroundStyle(.red).frame(width: 240, alignment: .leading) }
        }
        .padding(DS.Spacing.space6)
        .onAppear { focused = true }
    }

    private func field(_ title: String, _ text: Binding<String>, focus: Bool = false) -> some View {
        LabeledContent(title) {
            let box = TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .frame(width: 140)
                .onSubmit(commit)
            if focus { box.focused($focused) } else { box }
        }
    }

    private var pivotPicker: some View {
        Picker("About", selection: $pivot) {
            ForEach(TransformPivot.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    private func commit() {
        let (factor, pivot) = (factor, pivot)
        model.sketchCommand { $0.scaleSelection(factor: factor, about: pivot) }
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
