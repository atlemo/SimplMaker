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
    /// The name in the top bar, what its back button does, and what its title menu's Rename does (nil: the part cannot be renamed).
    var title = ""
    var onClose: () -> Void = {}
    var onRename: (() -> Void)?
    @Environment(\.undoManager) private var undoManager
    @AppStorage(Preferences.showGrid) private var showGrid = true
    @AppStorage(Preferences.showAxes) private var showAxes = true

    private var model: DocumentModel { file.model }
    /// The size of the window the part is in (the whole screen on an iPad, the folded or open screens of an iPhone Duo, a Split View column).
    @State private var windowSize = CGSize(width: 1024, height: 768)
    /// A narrow window has room for the viewport or the panels, not both.
    private var narrow: Bool { windowSize.width < 1200 }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// Too small to design in (a phone, the folded iPhone Duo, a window squeezed beside another app): the part is only looked at there.
    /// Unfolded or made bigger, the full tools come back.
    private var viewer: Bool { horizontalSizeClass == .compact || verticalSizeClass == .compact }
    /// The panels as they were before the viewer mode closed them, to put them back.
    @State private var beforeViewer: (sidebar: Bool, inspector: Bool, timeline: Bool)?
    /// The iPhone Duo's vertical bar is there (see `PadDuoBar`): the way back, the workspace switcher, help, settings and share are in it.
    @State private var duoBar = false
    /// The system's vertical bar is there, as the environment says (see `PadDuoBar`).
    @State private var systemBar = false
    /// The safe area's inset at each side: a vertical bar shows as a big inset on one side only (a phone's notch gives both sides the same).
    @State private var insetLeading: CGFloat = 0
    /// Whether the inset pattern is a bar's. Where the environment does not report the bar, this still finds it.
    private var barByInsets: Bool { (barInset >= 40 && insetLeading < 1) || (insetLeading >= 40 && barInset < 1) }
    /// The width of the Duo's vertical bar on the right (the safe area's trailing inset: the picture and its overlays reach under it).
    @State private var barInset: CGFloat = 0
    /// What the panels and the picture leave free at the right: the inspector when it is open, and the Duo's bar.
    private var rightInset: CGFloat { (model.showInspector ? Panel.inspectorWidth + Panel.margin : 0) + barInset }
    /// What the panels and the picture leave free at the left: the browser when it is open.
    private var leftInset: CGFloat { (model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0) + (insetLeading >= 40 && barInset < 1 ? insetLeading : 0) }
    /// What the top bar takes: just its title beside the Duo's vertical bar.
    private var topBarHeight: CGFloat { duoBar ? PadTopBar.compactHeight : PadTopBar.height }
    /// What the tool bar takes at the top: nothing in the viewer.
    private var barHeight: CGFloat { viewer ? 0 : toolBarHeight }
    /// The picture stored in the file: the part as the viewport shows it, shrunk.
    private func storeThumbnail() async {
        try? await Task.sleep(for: .seconds(1.5))
        // The picture is the part as Design shows it: not a mold's halves or a split's tinted pieces.
        guard !Task.isCancelled, model.sketchSession == nil, model.workspace == .design else { return }
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
    @State private var navButtonsFrame = CGRect.zero
    /// The Inspector was opened by the number pad (not by the user): it closes when the pad does.
    @State private var inspectorOpenedForPad = false

    var body: some View {
        let model = model
        let guide = file.guide
        // (The tutorial's card is drawn at the very end of this chain, so that nothing floats above it.)
        return DocumentPanels(model: model, guide: guide, viewport: viewport(model), chrome:
            // The bar is drawn here, under the side panels, so its shadow never falls on them (all the glass is at one level);
            // the empty inset below keeps the room it needs. Offset up by that room: this layer sits under the inset.
            ZStack {
                if !viewer {
                    PadToolBar(model: model, height: $toolBarHeight, keepsOpen: guide.isActive)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .offset(y: -toolBarHeight)
                }
                PadTopGlass(frame: navButtonsFrame)
            })
            .withoutTutorialCard()
            .startCard(!viewer)
            .onGeometryChange(for: [CGFloat].self) { [$0.safeAreaInsets.leading, $0.safeAreaInsets.trailing] } action: { insetLeading = $0[0]; barInset = $0[1] }
            .onChange(of: systemBar || barByInsets, initial: true) { duoBar = systemBar || barByInsets }
            // The keyboard covers the bottom of the screen instead of squeezing the view above it: the fields that are typed in move up by themselves.
            .ignoresSafeArea(.keyboard)
            // The size fields and the OK / Cancel bar of a feature float above the panels, never under them.
            .overlay {
                PadHandleFields(model: model, state: viewState, insets: (leftInset,
                                                                         rightInset,
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
                    .padding(.leading, leftInset)
                    .padding(.trailing, rightInset)
                    .padding(.bottom, Panel.bottomInset(timeline: model.showTimeline) + 8)
                    .ignoresSafeArea()
            }
            // The number pad that stands in for the keyboard when a size is typed, beside the Inspector, which opens so that every
            // size the feature needs is in view.
            .overlay(alignment: .bottom) {
                PadNumpadPanel(model: model)
                    .padding(.leading, leftInset)
                    .padding(.trailing, rightInset)
                    .padding(.bottom, Panel.bottomInset(timeline: model.showTimeline) + 8)
                    .ignoresSafeArea()
            }
            // The Inspector opens for a feature's sizes only when it was not open already, and closes again with the pad: it is wide, and
            // the part needs the room. The tutorial keeps it shut (its steps type in the boxes beside the arrows).
            .onChange(of: PadNumpad.shared.isActive) {
                if PadNumpad.shared.isActive {
                    guard !guide.isActive, !PadNumpad.shared.inOverlayWindow, model.selectedFeature != nil || model.newFeature != nil,
                          !model.showInspector else { return }
                    model.showInspector = true
                    inspectorOpenedForPad = true
                } else if inspectorOpenedForPad {
                    inspectorOpenedForPad = false
                    model.showInspector = false
                }
            }
            // Each side panel's show/hide button sits in the panel's top corner and stays there when the panel is closed
            // (then it floats on its own), as in Apple Notes.
            // The Render view has no browser or inspector: its two buttons give way to the ones that belong to it.
            .overlay(alignment: .topLeading) {
                if !model.renderView, !viewer {
                    PadPanelToggle(open: model.showSidebar, systemImage: "sidebar.left", label: "Browser") { model.showSidebar.toggle() }
                        .padding(.leading, Panel.inset + 2).padding(.top, Panel.inset + 4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewer {
                    EmptyView()
                } else if model.renderView {
                    PadRenderButtons(model: model)
                        .padding(.trailing, Panel.inset + 2).padding(.top, Panel.inset + 4)
                } else {
                    PadPanelToggle(open: model.showInspector, systemImage: "sidebar.right", label: "Inspector") { model.showInspector.toggle() }
                        .padding(.trailing, Panel.inset + 2).padding(.top, Panel.inset + 4)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: barHeight).allowsHitTesting(false) }
            // Undo, Render, View, Help, Settings and Export live in the navigation bar as a view of our own, not as items of the
            // system bar: those kept disappearing (after another app, or a dialog) and took the way out of the Render view with them.
            .scrollEdgeEffectHidden(true, for: .top)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)  // the bar's own backdrop would wash out the glass under it
            // The bar's room at the top, as the system's navigation bar took it before: the panels start below it.
            .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: topBarHeight).allowsHitTesting(false) }
            .overlay(alignment: .top) {
                PadTopBar(model: model, guide: guide, undoManager: undoManager, title: title, viewer: viewer, duoBar: duoBar, onClose: onClose, onRename: onRename, frame: $navButtonsFrame)
            }
            // The tutorial's card is above everything else: the bars, the panel buttons, the number pad and the size fields.
            .overlay { TutorialCardLayer(model: model, guide: guide).ignoresSafeArea(.keyboard) }
            .overlay(alignment: .bottom) {
                // An empty part has nothing to look at: say where the tools are.
                if viewer, model.document.features.isEmpty, !model.isImporting {
                    Text("Nothing to look at yet. Open the Duo, or make the window wider, to start designing.")
                        .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        .padding(16).frame(maxWidth: 360)
                        .panelMaterial(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .padding(.bottom, 40)
                }
            }
            .modifier(PadDuoBar(model: model, guide: guide, undoManager: undoManager, viewer: viewer, onClose: onClose, active: $systemBar))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
            .environment(\.windowHeight, windowSize.height)
            .onChange(of: viewer, initial: true) { applyViewer() }
            .modifier(PadDialogs(model: model))
            .modifier(AccentScope(sketching: model.sketchSession != nil))
            .environment(\.completionModel, model)
            .environment(\.tutorialSpotlight, guide.spotlight)
            .focusedSceneValue(\.documentModel, model)
            .onAppear {
                _ = KeyboardWatcher.shared  // watching from the start, so a keyboard raised later is seen
                PadNumpad.shared.model = model  // the number pad's parameters menu, in popovers and sheets too
                model.undoManager = undoManager
                model.fileURL = fileURL
                // A narrow screen has room for the viewport or the panels, not both: start with the viewport.
                if narrow { model.showSidebar = false; model.showInspector = false }
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
            // A narrow screen has room for one side panel beside the part: opening one closes the other.
            .onChange(of: model.showSidebar) { if model.showSidebar, narrow { model.showInspector = false } }
            .onChange(of: model.showInspector) { if model.showInspector, narrow { model.showSidebar = false } }
            // Opening the tool bar, or starting a tool, gives the part its room back.
            .onChange(of: model.pendingTool != nil) { if model.pendingTool != nil, narrow { model.showSidebar = false } }
            .onChange(of: undoManager) { model.undoManager = undoManager }
            .onChange(of: fileURL) { model.fileURL = fileURL }
    }

    /// Into or out of the viewer: what is being worked on is finished first (a sketch, a tool waiting for picks, a feature being sized),
    /// the workspace goes back to Design, and the panels are put away and brought back as they were.
    private func applyViewer() {
        model.viewerOnly = viewer
        if viewer {
            if beforeViewer == nil { beforeViewer = (model.showSidebar, model.showInspector, model.showTimeline) }
            if model.sketchSession != nil { model.finishSketch() }
            if model.isPickingSketchPlane { model.cancelSketchPlanePick() }
            if model.pendingTool != nil { model.cancelTool() }
            if model.newFeature != nil { model.finishFeatureEdit() }
            if model.workspace != .design { model.setWorkspace(.design) }
            model.clearSelection()
            model.showSidebar = false; model.showInspector = false; model.showTimeline = false
        } else if let saved = beforeViewer {
            beforeViewer = nil
            model.showTimeline = saved.timeline
            model.showSidebar = saved.sidebar && !narrow
            model.showInspector = saved.inspector && !narrow
        }
    }

    private func viewport(_ model: DocumentModel) -> some View {
        ZStack {
            padViewport(model)
            PadOverlays(model: model, state: viewState, insets: (leftInset,
                                                               rightInset,
                                                               Panel.bottomInset(timeline: model.showTimeline)))
        }
    }

    private func padViewport(_ model: DocumentModel) -> some View {
        PadViewport(model: model, sceneRevision: model.sceneRevision, overlayRevision: model.overlayRevision,
                    fitRevision: model.fitRevision, cameraRevision: model.cameraCommand?.revision ?? 0,
                    highlighted: model.highlighted, orthographic: model.orthographic, visualStyle: model.visualStyle,
                    explodeOffsets: model.explodeOffsets, sketching: model.sketchSession != nil,
                    showGrid: model.hasOwnGridSetting ? model.workspaceShowsGrid : showGrid, showAxes: showAxes && model.sketchSession == nil,
                    panelInsets: (leftInset,
                                  rightInset,
                                  Panel.bottomInset(timeline: model.showTimeline)),
                    toolbarHeight: barHeight, topBarHeight: topBarHeight, state: viewState,
                    printPreview: model.printPreview, printLayer: model.printLayer, printNozzle: model.printNozzle,
                    renderSettings: model.renderView ? model.renderSettings : nil,
                    spinning: model.renderView && model.renderSpinning && model.sketchSession == nil,
                    sectionPlane: model.sectionClip, sketchSlice: model.sketchSlicePlane)
    }
}

/// A panel's show/hide button: plain inside the open panel, on its own glass disc once the panel is closed.
/// In the Render view, always in reach: the way out, and the render options when they have been closed.
private struct PadRenderButtons: View {
    let model: DocumentModel

    var body: some View {
        HStack(spacing: 0) {
            if !model.showRenderOptions {
                Button { model.showRenderOptions = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Show render options")
            }
            Button { model.setRenderView(false) } label: {
                Label("Done", systemImage: "camera.fill").font(.system(size: 16, weight: .semibold)).frame(height: 44).padding(.horizontal, 12).contentShape(Rectangle())
            }
            .accessibilityLabel("Leave the render view")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .background { Color.clear.panelMaterial(in: Capsule()) }
    }
}

private struct PadPanelToggle: View {
    let open: Bool
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(open ? Color.secondary : Color.primary)
        .background { if !open { Color.clear.panelMaterial(in: Circle()) } }
        .accessibilityLabel(open ? "Hide \(label.lowercased())" : "Show \(label.lowercased())")
        .animation(.easeOut(duration: 0.15), value: open)
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
    /// The scale the bar's row is drawn at right now (see `layout(fitting:)`).
    @State private var barScale = PadToolBar.scale
    /// How wide the row is in each layout, measured on copies that are never shown.
    @State private var widths: [ToolbarLayout: CGFloat] = [:]
    @AppStorage(Preferences.sketchPaper) private var sketchPaper = Preferences.SketchPaper.blue
    @ObservedObject private var shortcuts = ShortcutStore.shared

    private func row(_ layout: ToolbarLayout) -> some View {
        Group {
            // Each workspace has its own row, as on the Mac; only Design's has layouts that narrow (the others scroll sideways).
            switch model.workspace {
            case .split: SplitToolbar(model: model)
            case .mold: MoldToolbar(model: model)
            case .render: RenderToolbar(model: model)
            case .design, .start:
                if let session = model.sketchSession {
                    SketchToolbar(model: model, session: session, layout: layout)
                } else {
                    DesignToolbar(model: model, layout: layout)
                }
            }
        }
        .environment(\.toolTitles, true)
        .fixedSize()
    }

    /// What the measured widths depend on: the mode, and the tools pinned in each group (the user can change them).
    private var signature: String {
        let pins = ["design.create", "design.shapes", "design.modify", "design.construct", "design.inspect",
                    "sketch.create",
                    "sketch.modify", "sketch.transform", "sketch.constraints"]
            .map { UserDefaults.standard.string(forKey: Preferences.toolbarPins($0)) ?? "-" }
        return "\(model.workspace.rawValue) \(model.sketchSession != nil) \(model.isPickingSketchPlane) \(pins.joined(separator: "|"))"
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
    /// Buttons are drawn at full size when they fit; otherwise they shrink (down to the Mac's size) before tools are moved into menus,
    /// so a narrow iPad still shows its tool row instead of only a "Tools" menu.
    private func layout(fitting room: CGFloat) -> (layout: ToolbarLayout, scale: CGFloat) {
        // The other workspaces' rows have no narrower layouts: the buttons shrink to fit (down to 80 %), then the row scrolls.
        if model.workspace != .design, let w = widths[.trimmed(0)] ?? widths[.single], w > 0 {
            return (.trimmed(0), min(Self.scale, max(0.8, room / w)))
        }
        for scale in [Self.scale, 1.15, 1.0] {
            var trim = 0
            while let w = widths[.trimmed(trim)] {
                if w * scale <= room { return (.trimmed(trim), scale) }
                trim += 1
            }
        }
        return (.single, Self.scale)
    }

    /// The user's own choice (nil: follow the tool). A tool that is being set up folds the bar away so the part is in view;
    /// when the tool ends, the bar comes back. Tapping the chevron or the pill overrides that until the next change.
    @State private var manualCollapse: Bool?
    /// The tutorial keeps the bar open: its steps say "tap Extrude", and a bar that folds away and moves the part is one more thing to learn.
    var keepsOpen = false
    private var busy: Bool { !keepsOpen && model.sketchSession == nil && (model.newFeature != nil || model.pendingTool != nil) }
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
        .onChange(of: model.workspace) { manualCollapse = nil }
        .onChange(of: model.sketchSession == nil) { manualCollapse = nil }
    }

    /// A small pill in the middle of the top edge: the tool's name and a chevron that brings the bar back.
    private var foldedBar: some View {
        HStack(spacing: 8) {
            // On the right, where the chevron that folded the bar is.
            Spacer(minLength: 0)
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
            .panelMaterial(in: Capsule())
            .accessibilityHint("Shows the tool bar")
            // A new feature being sized (a hole, an extrude…) is finished or given up here too, whatever else is on screen:
            // its own OK sits by its arrow, which may be out of reach, and until it is done the bar stays folded.
            if model.pendingTool == nil, let id = model.newFeature {
                Button { model.cancelNewFeature() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .panelMaterial(in: Circle())
                .accessibilityLabel("Cancel \(foldedTitle)")
                Button { model.finishFeatureEdit() } label: {
                    Label("Done", systemImage: "checkmark").font(.headline)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .panelMaterial(in: Capsule())
                .accessibilityLabel("Finish \(foldedTitle)")
                .id(id)
            }
            // A tool that still waits for a pick has no other Cancel on screen.
            if model.pendingTool != nil {
                Button { model.pendingTool = nil } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .panelMaterial(in: Circle())
                .accessibilityLabel("Cancel \(foldedTitle)")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var fullBar: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                let (chosen, scale) = layout(fitting: geo.size.width - 28)
                ScrollView(.horizontal, showsIndicators: false) {
                    row(chosen)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { natural = $0 }
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: natural.width * scale, height: natural.height * scale, alignment: .topLeading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .frame(minWidth: geo.size.width, alignment: .center)
                }
                .onChange(of: scale, initial: true) { barScale = scale }
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
        .frame(height: natural.height * barScale + 12)
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
            content.panelMaterial(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// The glass behind the part's action buttons, at the buttons' place, in the layer of the tool bar so that all glass is at one level.
private struct PadTopGlass: View {
    let frame: CGRect
    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            if frame.width > 0 {
                Color.clear.panelMaterial(in: Capsule())
                    // As tall as the glass buttons at the left (the system draws those 7 pt taller than their 44 pt label, each side).
                    .frame(width: frame.width, height: frame.height + 14)
                    .position(x: frame.midX - origin.x, y: frame.midY - origin.y)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The viewer's buttons: the View menu and Export, in a glass capsule at the top right (the rest is for designing).
struct PadViewerButtons: View {
    let model: DocumentModel
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 0) {
            Menu("View", systemImage: "eye") { PadViewControls(model: model) }
            Menu("Export", systemImage: "square.and.arrow.up") {
                Button("STL") { model.export(format: .stl) }
                Button("3MF") { model.export(format: .threeMF) }
                Button("STEP") { model.export(format: .step) }
            }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .foregroundStyle(accent)
        .buttonStyle(PadTopButtonStyle())
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Part actions")
    }
}

/// Undo, redo, render, view, help, settings and export, in a glass capsule at the top right.
/// The Help menu: the tutorial, the example parts, the docs and the licences.
struct PadHelpMenu: View {
    let model: DocumentModel
    let guide: TutorialGuide
    @Environment(\.openURL) private var openURL

    /// An example part replaces what is in the part (one Undo brings it back): iPadOS has no way to open a second part from inside the app.
    private func loadExample(_ title: String, _ document: CADDocument) {
        model.mutate("Load Example: \(title)") { $0 = document }
        model.regenerate(fit: true)  // the view fits the new part once it is built
    }

    var body: some View {
        Menu("Help", systemImage: "questionmark.circle") {
            Button(guide.canResume ? "Resume Tutorial: \(guide.kind.title)" : "Tutorial: Make a \(guide.kind.title)") {
                if guide.isActive { return }
                if guide.canResume || (model.document.features.isEmpty && model.document.parameters.isEmpty) { guide.start() }
                else { model.alert = AlertInfo(title: "The tutorial starts in an empty part", message: "Close this part, go back to the start screen, make a new one there, and choose Help › Tutorial there.") }
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
    }
}

/// The Export menu: the file formats, and the imports.
struct PadExportMenu: View {
    let model: DocumentModel

    var body: some View {
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

struct PadTopButtons: View {
    let model: DocumentModel
    let guide: TutorialGuide
    let undoManager: UndoManager?
    @Environment(\.accent) private var accent

    var body: some View {
        HStack(spacing: 0) {
            Button("Undo", systemImage: "arrow.uturn.backward") { undoManager?.undo() }
                .disabled(undoManager?.canUndo != true)
            Button("Redo", systemImage: "arrow.uturn.forward") { undoManager?.redo() }
                .disabled(undoManager?.canRedo != true)
            Menu("View", systemImage: "eye") { PadViewControls(model: model) }
            PadHelpMenu(model: model, guide: guide)
            Button("Settings", systemImage: "gearshape") { model.showSettings = true }
            PadExportMenu(model: model)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .foregroundStyle(accent)
        // Every control is a finger-sized square of its own.
        .buttonStyle(PadTopButtonStyle())
        .padding(.horizontal, 6)
        // The glass behind the buttons is drawn with the tool bar's (see `PadTopGlass`): the nav bar is a layer above everything.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Part actions")
    }
}

private struct PadTopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.5 : 1)
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
            .sheet(isPresented: Binding(get: { model.exportedFile != nil || !model.exportedFiles.isEmpty },
                                        set: { if !$0 { model.exportedFile = nil; model.exportedFiles = [] } })) {
                let urls = (model.exportedFile.map { [$0] } ?? []) + model.exportedFiles
                if !urls.isEmpty { ShareSheet(urls: urls).presentationDetents([.medium, .large]) }
            }
            // The pieces of a mold or a split: which format, and one file or one for each piece.
            .sheet(item: $model.piecesExport) { request in
                PiecesExportSheet(model: model, request: request).presentationDetents([.height(360)])
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
    let urls: [URL]
    init(url: URL) { urls = [url] }
    init(urls: [URL]) { self.urls = urls }
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// What to write of a mold's or a split's pieces (the Mac asks the same in an alert): the format, and one file or one for each piece.
struct PiecesExportSheet: View {
    let model: DocumentModel
    let request: PiecesExportRequest
    @State private var format = ExportFormat.stl
    @State private var individually = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        Text("STL · for slicers").tag(ExportFormat.stl)
                        Text("3MF · with units and colours").tag(ExportFormat.threeMF)
                        Text("STEP · for other CAD programs").tag(ExportFormat.step)
                    }
                    if request.bodies.count > 1 {
                        Picker("Files", selection: $individually) {
                            Text("All \(request.noun) in one file").tag(false)
                            Text("One file for each of the \(request.bodies.count)").tag(true)
                        }
                    }
                } footer: {
                    Text("The \(request.noun) are laid out for printing. Next you choose where they go: Files, AirDrop, a slicer…")
                }
            }
            .navigationTitle("Export \(request.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.piecesExport = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { model.exportPieces(request, format: format, individually: individually) }
                }
            }
        }
    }
}
