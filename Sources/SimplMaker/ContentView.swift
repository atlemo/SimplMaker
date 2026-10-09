// Main window: timeline + parameters on the left, viewport in the middle, inspector on the right.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import CADKernel
import SwiftUI

/// One document window.
struct ContentView: View {
    let file: CADFile
    let fileURL: URL?

    var body: some View {
        DocumentWindow(model: file.model, guide: file.guide, fileURL: fileURL)
    }
}

struct DocumentWindow: View {
    @Bindable var model: DocumentModel
    let guide: TutorialGuide
    let fileURL: URL?
    @ObservedObject private var shortcuts = ShortcutStore.shared  // tooltips name the shortcuts, which the user can change
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(Preferences.showGrid) private var showGrid = true
    @AppStorage(Preferences.unitSystem) private var unitSystem = Preferences.UnitSystem.system
    @AppStorage(Preferences.gridSizeMetric) private var gridSizeMetric = 0.0
    @AppStorage(Preferences.gridSizeUS) private var gridSizeUS = 0.0
    @AppStorage(Preferences.sketchPaper) private var sketchPaper = Preferences.SketchPaper.blue
    @AppStorage(Preferences.showAxes) private var showAxes = true
    @AppStorage(Preferences.showConstraints) private var showConstraints = true
    /// The window's width: below this, the Finish Sketch button drops its title so the sketch
    /// tools still fit, and below the width they need, they become a menu per group, then one Tools menu (otherwise
    /// macOS folds the whole row away into the toolbar's overflow menu, which can't show it).
    @State private var windowWidth: CGFloat = 1200
    static let titledSketchWidth: CGFloat = 1100
    /// How wide the tool groups last laid out, by mode and title setting. Below this width plus the
    /// room the other toolbar items take, the groups give way to one menu holding every tool.
    @State private var toolRowWidths: [String: CGFloat] = [:]
    /// Where the title and subtitle in the toolbar end, measured from the window's left edge.
    @State private var titleEdge: CGFloat?
    static let toolbarGap: CGFloat = 16

    private func toolRowKey(_ layout: ToolbarLayout) -> String {
        "\(layout.rawValue)-\(model.sketchSession != nil)-\(model.sketchSession == nil || windowWidth >= Self.titledSketchWidth)"
    }
    /// The widest layout that fits. The tools are centred, so each side needs as much room as the
    /// title takes on the left. A layout not shown yet has no width to go by, so it is tried.
    private var toolbarLayout: ToolbarLayout {
        guard let titleEdge else { return .full }
        let room = windowWidth - 2 * (titleEdge + Self.toolbarGap)
        for layout in [ToolbarLayout.full, .groups] {
            if let width = toolRowWidths[toolRowKey(layout)] { if room >= width { return layout } } else { return layout }
        }
        return .single
    }

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

    /// A toolbar button's tooltip with its shortcut: "Show or hide the browser (⌃⌘S)".
    private func helpWithShortcut(_ text: String, _ command: ShortcutCommand) -> String {
        Shortcuts.label(command).map { "\(text) (\($0))" } ?? text
    }

    @ToolbarContentBuilder private var toolsItem: some ToolbarContent {
            ToolbarItem(placement: .principal) {
                Group {
                    if let session = model.sketchSession {
                        SketchToolbar(model: model, session: session, layout: toolbarLayout)
                    } else {
                        DesignToolbar(model: model, layout: toolbarLayout)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if toolbarLayout != .single { toolRowWidths[toolRowKey(toolbarLayout)] = width }
                }
                .environment(\.toolTitles, model.sketchSession == nil || windowWidth >= Self.titledSketchWidth)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Tools")
            }
            .sharedBackgroundVisibility(.hidden)  // the tools sit on the toolbar itself, with no glass of their own
    }

    var body: some View {
        // The viewport fills the window, under the toolbar too; the browser and the inspector float
        // over it as glass panels, like the sidebars of current macOS apps. The toolbar has no
        // background until the pointer is over it, when one fades in.
        ZStack {
            ViewportView(model: model, sceneRevision: model.sceneRevision, overlayRevision: model.overlayRevision,
                         highlighted: model.highlighted, fitRevision: model.fitRevision,
                         cameraRevision: model.cameraCommand?.revision ?? 0, orthographic: model.orthographic,
                         visualStyle: model.visualStyle, printPreview: model.printPreview,
                         printLayer: model.printLayer, printNozzle: model.printNozzle,
                         sectionPlane: model.sectionClip,
                         showGrid: showGrid, gridSetting: "\(unitSystem.rawValue)/\(gridSizeMetric)/\(gridSizeUS)", sketchPaper: sketchPaper, showAxes: showAxes && model.sketchSession == nil, showConstraints: showConstraints,
                         panelInsets: (model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0,
                                       model.showInspector ? Panel.inspectorWidth + Panel.margin : 0,
                                       Panel.bottomInset(timeline: model.showTimeline)))
                .ignoresSafeArea()
            ToolbarFade(tint: sketchTint ? sketchPaper.toolbarTint : Color(nsColor: .windowBackgroundColor),
                        height: toolbarHeight, visible: toolbarHovered || sketchTint)
            VStack(spacing: Panel.inset) {
            HStack(alignment: .top, spacing: 0) {
                if model.showSidebar {
                    Sidebar(model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer(minLength: 0)  // empty: clicks go through to the viewport
                if model.showInspector {
                    InspectorView(model: model)
                        .floatingPanel(width: Panel.inspectorWidth)
                        .tutorialSpot("inspector", cornerRadius: DS.Radius.window, outset: 0, filled: false)
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
               !model.isPickingSketchPlane, !guide.isActive {
                StartCard(model: model, guide: guide)
                    .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : 0)
                    .transition(.opacity)
            }
        }
        // A part that takes a while to open says what it is building, until the first model is on screen.
        .overlay {
            if model.result == nil, let progress = model.regenProgress {
                LoadingCard(progress: progress)
                    .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : 0)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: DS.Duration.fast), value: model.regenProgress != nil)
        // The tutorial's card floats at the bottom of the free space, above the status bar and the OK bar, where it
        // stays clear of what is built at the middle of the view and of the size fields that appear beside it.
        .overlay(alignment: .bottom) {
            TutorialCard(model: model, guide: guide)
                .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : 0)
                .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : 0)
                .padding(.bottom, (model.showTimeline ? TimelineBar.height + 2 * Panel.inset : Panel.inset)
                    + 2 * (DS.ControlHeight.large + Panel.inset) + Panel.inset)
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
        // The print preview's options float at the top left of the view.
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: Panel.inset) {
                if model.printPreview, model.showPrintOptions, model.visualStyle.isShaded, model.sketchSession == nil {
                    PrintPreviewPanel(model: model)
                        .transition(.opacity)
                }
                // The Section Analysis tool's options go under it.
                if model.section != nil, model.sketchSession == nil {
                    SectionPanel(model: model)
                        .transition(.opacity)
                }
            }
            .padding(.top, Panel.inset)
            .padding(.leading, model.showSidebar ? Panel.sidebarWidth + Panel.margin : Panel.inset)
        }
        .animation(.easeOut(duration: DS.Duration.fast), value: model.showPrintOptions && model.printPreview)
        .animation(.easeOut(duration: DS.Duration.fast), value: model.section != nil)
        // The Measure tool's readout floats in the same corner.
        .overlay(alignment: .topTrailing) {
            if model.pendingTool == .measure, model.sketchSession == nil {
                MeasurePanel(model: model)
                    .padding(.top, Panel.inset)
                    .padding(.trailing, model.showInspector ? Panel.inspectorWidth + Panel.margin : Panel.inset)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: DS.Duration.fast), value: model.pendingTool == .measure)
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
        // Past the trial, the part can be looked at and exported, not edited.
        .overlay(alignment: .top) {
            LockedBanner(license: .shared)
                .padding(.top, toolbarHeight + Panel.inset)
        }
        // The cursor's prompt goes above everything, panels included.
        .overlay { CursorPrompt(model: model) }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background(ToolbarHoverMonitor(hovering: $toolbarHovered))
        .background(ToolbarTitleReader(edge: $titleEdge))
        .background(TitlebarAppearance(dark: sketchTint, tabTint: sketchTint ? NSColor(sketchPaper.toolbarTint) : nil))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { if $0 > 0 { toolbarHeight = $0 } }
        .toolbar {
            // The tools sit in the middle of the toolbar, in Design and in Sketch mode. Each layout is its own
            // item: once macOS has folded the tools away, it doesn't bring a narrower layout back in the same item.
            if toolbarLayout == .full {
                toolsItem
            } else if toolbarLayout == .groups {
                toolsItem
            } else {
                toolsItem
            }
            ToolbarItem(placement: .navigation) {
                Button { model.showSidebar.toggle() } label: { Label("Browser", systemImage: "sidebar.left") }
                    .help(helpWithShortcut("Show or hide the browser", .browser))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                    .help(helpWithShortcut("Show or hide the inspector", .inspector))
            }
        }
        .modifier(AccentScope(sketching: model.sketchSession != nil))
        .focusedSceneValue(\.documentModel, model)
        .focusedSceneValue(\.tutorialGuide, guide)
        .environment(\.tutorialSpotlight, guide.spotlight)
        .environment(\.completionModel, model)
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

/// Reads where the window's title and subtitle end in the toolbar, which the centred tools must
/// clear: a longer name leaves less room for them.
struct ToolbarTitleReader: NSViewRepresentable {
    @Binding var edge: CGFloat?

    func makeNSView(context: Context) -> ReaderView { ReaderView() }

    func updateNSView(_ view: ReaderView, context: Context) {
        let binding = $edge
        view.onChange = { if binding.wrappedValue != $0 { binding.wrappedValue = $0 } }
        view.measureSoon()
    }

    final class ReaderView: NSView {
        var onChange: (CGFloat?) -> Void = { _ in }
        private var observations: [NSKeyValueObservation] = []

        override func viewDidMoveToWindow() {
            observations = []
            guard let window else { return }
            observations = [window.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.measureSoon() } },
                            window.observe(\.subtitle) { [weak self] _, _ in Task { @MainActor in self?.measureSoon() } }]
            measureSoon()
        }

        /// The title view lays itself out a moment after its text changes.
        func measureSoon() {
            for delay in [0.0, 0.25] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.measure() }
            }
        }

        private func measure() {
            guard let root = window?.contentView?.superview,
                  let titleView = Self.find("NSToolbarTitleView", in: root) else { return }
            let labels = Self.labels(in: titleView).filter { !$0.stringValue.isEmpty }
            let edges = labels.map { $0.convert($0.bounds, to: nil).minX + ceil($0.attributedStringValue.size().width) }
            if let edge = edges.max() { onChange(edge) }
        }

        private static func find(_ className: String, in view: NSView) -> NSView? {
            if view.className == className { return view }
            for sub in view.subviews { if let found = find(className, in: sub) { return found } }
            return nil
        }

        private static func labels(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { sub in (sub as? NSTextField).map { [$0] } ?? labels(in: sub) }
        }
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
    let guide: TutorialGuide

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
            Button { guide.start() } label: { Label("New to CAD? Follow the tutorial: a desk organizer", systemImage: "graduationcap") }
                .buttonStyle(.link)
                .padding(.top, DS.Spacing.space5)  // a bigger gap below the three buttons
            Text("Right-click in the view for more · File › Open Example Parts to learn from")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(DS.Spacing.space8)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.window))
    }
}

/// Shown while a part opens slowly: a bar for how many features are built, and the one being built.
struct LoadingCard: View {
    let progress: RegenProgress

    var body: some View {
        VStack(spacing: DS.Spacing.space4) {
            Text("Building the model…").font(.headline)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .frame(width: 220)
            Text("\(progress.feature) · \(progress.done + 1) of \(progress.total)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 220)
        }
        .padding(DS.Spacing.space8)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.window))
        .accessibilityElement(children: .combine)
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: DS.Spacing.space5) {
            message
                .lineLimit(1)
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            Group {
                if !model.selection.isEmpty { Text("\(model.selection.count) selected") }
                if model.isImporting { Text("Reading the file…").foregroundStyle(.secondary) }
                if let step = model.regenProgress {
                    Text("Building \(step.feature) · \(step.done + 1) of \(step.total)").foregroundStyle(.secondary)
                }
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
        .background((colorScheme == .dark ? Color.black : Color.white).opacity(0.2), in: .capsule)
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
                                        ? "Drag the orange dot to move the hole, or an arrow to change its depth or diameter · Tab moves between the fields"
                                        : model.manipulatedFeature != nil
                                        ? "Drag an arrow, square or ring dot · or type the \(h.label.lowercased()) in the field"
                                        : h.dial != nil && model.selectedIsDraft
                                        ? "Drag the dot round the arc to lean the drafted faces, or click it and type the angle · positive narrows the body away from the face that stays put, negative widens it"
                                        : h.dial != nil
                                        ? "Drag the dot round the arc to taper the sides, or click it and type the angle · negative narrows, positive widens"
                                        : model.showsDial
                                        ? "Drag the orange arrow to change the \(h.label.lowercased()), or type it in the field next to it · the dot on the arc tapers the sides"
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

/// The left column: the browser and the parameters, two glass panels that each fold up to their header. The
/// panel that stays open takes the room the other gives up, and the heights animate together.
struct Sidebar: View {
    @Bindable var model: DocumentModel
    /// The share of the room the browser gets while both panels are open; dragging the gap between them changes it.
    @State private var split: CGFloat = 0.5
    /// The browser's height when the current drag began.
    @State private var dragStart: CGFloat?

    /// The least a panel can be dragged down to: its header and a few rows.
    private static let minimumHeight = SidebarPanel<EmptyView, EmptyView>.headerHeight + 80

    /// A panel's height: the header alone when it is closed, else the share `split` gives it when both are open,
    /// or everything the closed one leaves.
    static func heights(total: CGFloat, browserOpen: Bool, parametersOpen: Bool, split: CGFloat = 0.5) -> (browser: CGFloat, parameters: CGFloat) {
        let head = SidebarPanel<EmptyView, EmptyView>.headerHeight
        let room = max(total - Panel.inset, 2 * head)
        switch (browserOpen, parametersOpen) {
        case (true, true):
            let least = min(minimumHeight, room / 2)
            let browser = min(max(room * split, least), room - least)
            return (browser, room - browser)
        case (true, false): return (room - head, head)
        case (false, true): return (head, room - head)
        case (false, false): return (head, head)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let h = Self.heights(total: geo.size.height, browserOpen: model.browserOpen, parametersOpen: model.parametersOpen, split: split)
            VStack(spacing: 0) {
                SidebarPanel(title: "Browser", open: $model.browserOpen, accessory: { EmptyView() }) {
                    BrowserList(model: model)
                }
                .frame(height: h.browser)
                .tutorialSpot("browser", cornerRadius: DS.Radius.window, outset: 0, filled: false)
                divider(room: max(geo.size.height - Panel.inset, 1), browserHeight: h.browser)
                SidebarPanel(title: "Parameters", open: $model.parametersOpen, accessory: {
                    HeaderIconButton(systemImage: "plus", help: "Add a parameter") {
                        model.parametersOpen = true  // show the new one
                        model.addParameter()
                    }
                }) {
                    ParametersList(model: model)
                }
                .frame(height: h.parameters)
                .tutorialSpot("parameters", cornerRadius: DS.Radius.window, outset: 0, filled: false)
                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: DS.Duration.base), value: model.browserOpen)
            .animation(.easeInOut(duration: DS.Duration.base), value: model.parametersOpen)
        }
        .frame(width: Panel.sidebarWidth)
        .frame(maxHeight: .infinity)
    }

    /// The gap between the panels, which drags to give one panel more room than the other (double-click to even them out).
    private func divider(room: CGFloat, browserHeight: CGFloat) -> some View {
        let resizable = model.browserOpen && model.parametersOpen
        return Color.clear
            .frame(height: Panel.inset)
            .contentShape(Rectangle())
            .pointerStyle(resizable ? .rowResize : nil)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    guard resizable else { return }
                    let start = dragStart ?? browserHeight
                    dragStart = start
                    let least = min(Self.minimumHeight, room / 2)  // stay inside the range, so the drag can turn back at once
                    split = min(max(start + drag.translation.height, least), room - least) / room
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { if resizable { withAnimation(.easeInOut(duration: DS.Duration.base)) { split = 0.5 } } }
            .accessibilityHidden(true)
    }
}

/// A floating glass panel with a header that folds its content away.
struct SidebarPanel<Accessory: View, Content: View>: View {
    static var headerHeight: CGFloat { 40 }
    let title: String
    @Binding var open: Bool
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.space1) {
                Button { open.toggle() } label: {
                    HStack(spacing: DS.Spacing.space1) {
                        Text(title)
                            .font(.headline.weight(.semibold))  // as the group titles in Settings ▸ Shortcuts
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityValue(open ? "expanded" : "collapsed")
                accessory()
                HeaderIconButton(systemImage: "chevron.down", rotation: open ? 0 : -90,
                                 help: open ? "Hide the \(title.lowercased())" : "Show the \(title.lowercased())") {
                    open.toggle()
                }
            }
            .padding(.leading, DS.Spacing.space5)
            .padding(.trailing, DS.Spacing.space4)
            .frame(height: Self.headerHeight)
            content()
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
                .opacity(open ? 1 : 0)
                .allowsHitTesting(open)
                .accessibilityHidden(!open)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
    }
}

/// The parameters: a name and a value each, with the name editable in place.
struct ParametersList: View {
    @Bindable var model: DocumentModel
    /// The parameter whose name is being edited in place.
    @State private var renaming: String?
    @State private var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(model.document.parameters) { p in
                ParameterRow(model: model, parameter: p, renaming: renamingBinding(p.name))
                    .tutorialSpot("parameter-\(p.name)", cornerRadius: DS.Radius.lg, outset: 2)
                    .tag(p.name)
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: String.self) { names in
            if names.count == 1, let name = names.first {
                Button("Rename") { renaming = name }
                Button("Delete", role: .destructive) { model.removeParameter(name) }
            }
        }
    }

    private func renamingBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { renaming == name }, set: { if !$0, renaming == name { renaming = nil } else if $0 { renaming = name } })
    }
}

/// The browser's list: bodies, sketches, planes and canvases, in folders.
struct BrowserList: View {
    @Bindable var model: DocumentModel
    @State private var bodiesOpen = true
    @State private var sketchesOpen = true
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
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: FeatureID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            // Double-click to edit: a sketch opens in sketch mode, other features (and the one that
            // made a body) show their handle.
            if ids.count == 1, let id = ids.first { model.editFeature(featureID(id)) }
        }
    }

    /// Whether a row is being renamed; ending the edit clears it.
    private func renamingBinding(_ id: FeatureID) -> Binding<Bool> {
        Binding(get: { renaming == id }, set: { if !$0, renaming == id { renaming = nil } })
    }

    private func isSketch(_ id: FeatureID) -> Bool {
        if case .sketch? = model.document.features.first(where: { $0.id == id })?.kind { return true }
        return false
    }

    @ViewBuilder private func menu(for tags: Set<FeatureID>) -> some View {
        let ids = Set(tags.map(featureID))
        if ids.count == 1, let id = ids.first, let f = model.document.features.first(where: { $0.id == id }) {
            if isSketch(id) {
                Button(model.sketchSession?.featureID == id ? "Finish Sketch" : "Edit Sketch") {
                    if model.sketchSession?.featureID == id { model.finishSketch() } else { model.editSketch(id) }
                }
                Button(model.isHidden(id) ? "Show Sketch" : "Hide Sketch") { model.setHidden([id], !model.isHidden(id)) }
                Button("Move or Rotate Sketch") { model.move(sketches: [id]) }
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
                Button("Move or Rotate Body") { model.move(bodies: [id]) }
                Button("Scale Body") { model.scale(bodies: [id]) }
                Button("Rename Body") { renaming = id }
                Button("Appearance…") { model.openAppearance(for: id) }
                Menu("Export Body") {
                    Button("STEP…") { model.export(bodies: [id], stl: false) }
                    Button("STL…") { model.export(bodies: [id], stl: true) }
                }
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

/// Colours of a text field inside a list row, one set per state. Spelled out rather than inherited:
/// a selected row makes `.primary` white and the stock field draws its own light fill, which left
/// white text on white (typing looked broken). Each text colour is always chosen with its fill.
///
/// - Regular: the row isn't selected and the field isn't focused. Field fill, normal text.
/// - Selected: the row is on the accent colour. Darkened translucent fill, white text.
/// - Focused: being edited, whatever the row. Field fill, normal text, accent border and caret.
struct RowFieldStyle: ViewModifier {
    enum Mode { case regular, selected, focused }
    /// What a mode draws with. `darkFill` says whether the text must be light.
    struct Palette: Equatable {
        let text: NSColor
        let fill: NSColor
        let darkFill: Bool
    }

    static func mode(focused: Bool, rowSelected: Bool) -> Mode { focused ? .focused : rowSelected ? .selected : .regular }

    static func palette(_ mode: Mode) -> Palette {
        switch mode {
        case .selected: Palette(text: .white, fill: NSColor.black.withAlphaComponent(0.25), darkFill: true)
        case .regular, .focused: Palette(text: .textColor, fill: .textBackgroundColor, darkFill: false)
        }
    }

    @Environment(\.accent) private var accent
    @Environment(\.backgroundProminence) private var prominence
    let focused: Bool

    func body(content: Content) -> some View {
        let mode = Self.mode(focused: focused, rowSelected: prominence == .increased)
        let palette = Self.palette(mode)
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        content
            .textFieldStyle(.plain)
            .foregroundStyle(Color(nsColor: palette.text))
            .tint(mode == .selected ? Color.white : accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(shape.fill(Color(nsColor: palette.fill)))
            .background(FieldEditorColors(active: focused, accent: NSColor(accent)))
            .overlay(shape.strokeBorder(
                mode == .selected ? Color.white.opacity(0.4) : mode == .focused ? accent : Color.secondary.opacity(0.4),
                lineWidth: mode == .focused ? 2 : 1))
    }
}

/// The caret and the selection of the field being edited. The text view that edits the field draws them in
/// colours of its own, which inside a selected list row come out white on the white field (the caret and the
/// highlight vanish), so while the field is active they are set explicitly, and put back when it isn't.
private struct FieldEditorColors: NSViewRepresentable {
    let active: Bool
    let accent: NSColor

    /// Which field's colours are on the shared field editor, so a field that lost the focus doesn't undo the
    /// colours of the one that just got it.
    @MainActor final class Owner {
        static var current: ObjectIdentifier?
    }
    final class Coordinator {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        let (active, accent, id) = (active, accent, ObjectIdentifier(context.coordinator))
        // The field editor is installed a moment after the focus changes.
        for delay in [0.0, 0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let editor = view?.window?.firstResponder as? NSTextView, editor.isFieldEditor else { return }
                if active {
                    Owner.current = id
                    editor.insertionPointColor = .textColor
                    editor.selectedTextAttributes = [.backgroundColor: accent, .foregroundColor: NSColor.white]
                } else if Owner.current == nil || Owner.current == id {
                    Owner.current = nil
                    Self.restore(editor)
                }
            }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        guard Owner.current == ObjectIdentifier(coordinator) else { return }
        Owner.current = nil
        if let editor = view.window?.firstResponder as? NSTextView, editor.isFieldEditor { restore(editor) }
    }

    private static func restore(_ editor: NSTextView) {
        editor.insertionPointColor = .textInsertionPointColor
        editor.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: NSColor.selectedTextColor]
    }
}

extension View {
    func rowFieldStyle(focused: Bool) -> some View { modifier(RowFieldStyle(focused: focused)) }

    /// The stock bordered field, except in a selectable row, where it takes `rowFieldStyle`.
    @ViewBuilder func fieldAppearance(inSelectableRow: Bool, focused: Bool) -> some View {
        if inSelectableRow { rowFieldStyle(focused: focused) } else { textFieldStyle(.roundedBorder) }
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
            .labelsHidden()
            .rowFieldStyle(focused: focused)
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
    @Environment(\.accent) private var accent
    let on: Bool

    var body: some View {
        if on {
            RoundedRectangle(cornerRadius: DS.Radius.sidebarItem, style: .continuous)
                .fill(accent.opacity(0.18))
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
    @Binding var renaming: Bool
    /// Why the last rename was refused (a taken or invalid name).
    @State private var renameError: String?
    /// The drag on the name that is changing the value: nil when none is going on.
    @State private var scrub: Scrub?

    /// A value being dragged, in the units shown (mm, degrees, or a plain number).
    struct Scrub {
        var value: Double
        var unit: UnitKind
        /// What the value snaps to when shown, set by the modifier keys held at the last move.
        var grid = 1.0

        /// Units per point dragged, and the grid the value snaps to, for the modifier keys held:
        /// whole units to begin with, Shift is coarse (tens), Option is fine (tenths).
        static func step(unit: UnitKind, _ flags: NSEvent.ModifierFlags) -> Double {
            flags.contains(.shift) ? 10 : flags.contains(.option) ? 0.1 : 1
        }

        var expression: String {
            // Snapped, so a drag gives 12 mm and not 12.3456.
            let rounded = ((value / grid).rounded() * grid * 1e6).rounded() / 1e6
            return formatDimension(unit == .angle ? rounded * .pi / 180 : rounded, kind: unit)
        }
    }

    private func beginScrub() {
        let q = model.result?.parameters.values[parameter.name]?.value ?? 0
        scrub = Scrub(value: parameter.unit == .angle ? q * 180 / .pi : q, unit: parameter.unit)
    }

    private func moveScrub(by dx: CGFloat, _ flags: NSEvent.ModifierFlags) {
        guard var s = scrub else { return }
        let step = Scrub.step(unit: s.unit, flags)
        s.value += Double(dx) * step
        s.grid = step
        scrub = s
        model.previewParameter(parameter.name, expression: s.expression)
    }

    private func endScrub() {
        guard let s = scrub else { return }
        scrub = nil
        if s.expression == parameter.expression { model.cancelParameterPreview() }  // drop the preview
        else { model.setParameter(parameter.name, expression: s.expression) }
    }

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
                    // The whole stretch up to the value is the handle, not just the letters.
                    Text(parameter.name).font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .overlay(ScrubHandle(
                            began: beginScrub,
                            moved: { dx, flags in moveScrub(by: dx, flags) },
                            ended: endScrub,
                            doubleClicked: { renameError = nil; renaming = true }))
                        .pointerStyle(.columnResize)
                        .help("Drag left or right to change the value (Shift: coarse, Option: fine); double-click to rename, and every expression that uses it follows")
                }
                if renaming { Spacer() }
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
                    HStack(spacing: 2) {
                        Text(parameter.unit == .length ? "mm" : parameter.unit == .angle ? "deg" : "#")
                            .font(.caption.monospaced())
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.5)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Length, angle or plain number")
            }
            if let renameError {
                Text(renameError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ExpressionField(text: scrub?.expression ?? parameter.expression, excluding: parameter.name, inSelectableRow: true) { model.setParameter(parameter.name, expression: $0) }
            let users = model.document.features(using: parameter.name).map(\.name)
            Text(users.isEmpty ? "Not used yet · type \(parameter.name) in any size field" : "Used by \(users.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, DS.Spacing.space2)
        .onChange(of: renaming) { if renaming { renameError = nil } }
    }
}

/// Sits over a title that can be dragged to change a value. It takes the mouse itself, because a
/// list row's own tracking swallows drags that start in SwiftUI content.
private struct ScrubHandle: NSViewRepresentable {
    let began: () -> Void
    /// Points moved since the last call, with the modifier keys held.
    let moved: (CGFloat, NSEvent.ModifierFlags) -> Void
    let ended: () -> Void
    let doubleClicked: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.began = began; view.moved = moved; view.ended = ended; view.doubleClicked = doubleClicked
    }

    final class HandleView: NSView {
        var began: () -> Void = {}
        var moved: (CGFloat, NSEvent.ModifierFlags) -> Void = { _, _ in }
        var ended: () -> Void = {}
        var doubleClicked: () -> Void = {}
        private var startX: CGFloat = 0
        private var lastX: CGFloat = 0
        private var dragging = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            lastX = startX
            dragging = false
            if event.clickCount == 2 { doubleClicked() }
        }

        override func mouseDragged(with event: NSEvent) {
            let x = event.locationInWindow.x
            if !dragging {
                guard abs(x - startX) >= 3 else { return }  // a click, not a drag
                dragging = true
                lastX = startX
                began()
            }
            moved(x - lastX, event.modifierFlags)
            lastX = x
        }

        override func mouseUp(with event: NSEvent) {
            guard dragging else { return }
            dragging = false
            ended()
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
    /// Whether typing a parameter's name is completed: for values, not for names and words.
    var completes = true
    /// A parameter's own name, which its expression can't use.
    var excluding: String?
    /// The field sits in a list row that can be selected (the Parameters list), so it takes
    /// `rowFieldStyle`'s explicit per-state colours instead of the stock bordered field's.
    var inSelectableRow = false
    @Environment(\.completionModel) private var completionModel
    @State private var draft = ""
    @State private var edited = false
    @FocusState private var focused: Bool

    init(text: String, monospaced: Bool = true, completes: Bool = true, excluding: String? = nil,
         inSelectableRow: Bool = false, preview: ((String) -> Void)? = nil, commit: @escaping (String) -> Void) {
        self.text = text
        self.monospaced = monospaced
        self.completes = completes
        self.excluding = excluding
        self.inSelectableRow = inSelectableRow
        self.preview = preview
        self.commit = commit
    }

    var body: some View {
        TextField("expression", text: $draft)
            .labelsHidden()  // in a Form row the label beside the field would read "expression"
            .font(monospaced ? .body.monospaced() : .body)
            .fieldAppearance(inSelectableRow: inSelectableRow, focused: focused)
            .focused($focused)
            .completesParameters(completes ? completionModel : nil, excluding: excluding, focused: focused)
            .onSubmit {
                if ParameterCompleter.shared.complete(&draft) { focused = true; return }
                edited = false; commit(draft)
            }
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
    @Environment(\.accent) private var accent
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
    /// The hover and active fill and the focus ring, as round as the popovers and toolbar these sit in.
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: DS.Radius.xl3, style: .continuous) }
    private var background: Color {
        if active { return onTint ? Color.white.opacity(0.24) : accent.opacity(0.16) }
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
            .padding(.horizontal, showsTitle ? DS.Spacing.space4 : DS.Spacing.space1)
            .padding(.vertical, showsTitle ? DS.Spacing.space1 : 0)
            .foregroundStyle(active && !onTint ? accent : ink)
            .background(background, in: shape)
            .contentShape(Rectangle())
            // The keyboard focus ring follows the same rounded shape as the hover and active fill,
            // drawn in the app's accent (the system's own ring would use the system colour).
            .contentShape(.focusEffect, shape)
            .modifier(AccentFocusRing(shape: shape))
            .opacity(isEnabled ? 1 : DS.opacityDisabled)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .toolTip(help ?? title)
        .tutorialSpot(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Draws the keyboard focus ring in the accent colour; applied inside a button's label, where
/// `isFocused` reflects the button.
private struct AccentFocusRing<S: InsettableShape>: ViewModifier {
    @Environment(\.accent) private var accent
    @Environment(\.isFocused) private var focused
    let shape: S

    func body(content: Content) -> some View {
        content.overlay {
            if focused { shape.strokeBorder(accent.opacity(0.75), lineWidth: 3) }
        }
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
    /// How much of the toolbar the window has room for.
    var layout = ToolbarLayout.full
    @ObservedObject private var shortcuts = ShortcutStore.shared  // the tooltips and keys shown follow the user's changes
    @State private var constrainOpen = false
    @Environment(\.toolTitles) private var showsTitles
    @Environment(\.controlActiveState) private var activeState

    private var groups: [ToolGroupSpec] {
        [ToolGroupSpec(title: "Draw", id: "sketch.draw", defaults: ["Line", "Rectangle", "Circle", "Polygon", "Spline", "Text"],
                       // Tools in a family (rectangle, circle, arc) share one button, under the first one's name.
                       tools: SketchTool.draw.filter { $0.family.first == $0 }.map(tool) + [canvas]),
         ToolGroupSpec(title: "Modify", id: "sketch.modify", defaults: ["Round Corner", "Trim", "Extend", "Offset"],
                       tools: SketchTool.modify.map(tool) + [offset]),
         ToolGroupSpec(title: "Transform", id: "sketch.transform", defaults: SketchTransformTool.allCases.map(\.rawValue),
                       tools: SketchTransformTool.allCases.map(transform)),
         ToolGroupSpec(title: "Constraints", id: "sketch.constraints", defaults: ["Dimension", "Distance", "Constrain", "Construction"],
                       tools: [tool(.dimension), tool(.distance), constrain, construction])]
    }

    private var finish: GroupTool {
        GroupTool(id: "Finish Sketch", title: "Finish Sketch", icon: "check", help: "Finish the sketch (Return)") { model.finishSketch() }
    }

    private var finishButton: some View {
        Button { model.finishSketch() } label: {
            if showsTitles {
                Label("Finish Sketch", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
            } else {
                Label("Finish Sketch", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
            }
        }
        .toolTip("Finish the sketch (Return)")
        .buttonStyle(.borderedProminent)
        .tutorialSpot("Finish Sketch", cornerRadius: 10, outset: 3)
    }

    var body: some View {
        Group {
            switch layout {
            case .single:
                ToolsMenu(solo: tool(.select), groups: groups, trailing: finish)
            case .groups:
                HStack(spacing: DS.Spacing.space1) {
                    SoloToolButton(tool: tool(.select))
                    ForEach(groups) { ToolGroupMenu(group: $0) }
                    ToolDivider()
                    finishButton
                }
            case .full:
                HStack(spacing: DS.Spacing.space1) {
                    SoloTool(tool: tool(.select))
                    ForEach(groups) { group in
                        ToolDivider()
                        ToolGroup(group)
                    }
                    ToolDivider()
                    finishButton
                }
            }
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
        return GroupTool(id: head.rawValue, title: head.shortTitle, icon: mode.symbol, help: mode.help, shortcut: head.keyLabel,
                         badge: head.isExperimental ? "Experimental" : nil, active: head.family.contains(session.tool), modes: modes) { model.setSketchTool(mode) }
    }

    private func transform(_ tool: SketchTransformTool) -> GroupTool {
        // Move shows the manipulator to drag (or type into); Scale asks for a factor.
        GroupTool(id: tool.rawValue, title: tool.rawValue, icon: tool.symbol, help: tool.help,
                  active: session.manipulating == tool || (tool == .pattern && session.isPatterning),
                  enabled: tool == .pattern ? session.canPattern : session.canTransform,
                  popover: tool != .scale ? nil : ToolPopover(isPresented: Binding(get: { session.transformRequested == tool },
                                                            set: { if $0 { session.transformRequested = tool } else if session.transformRequested == tool { session.transformRequested = nil } }),
                                       content: AnyView(TransformPopover(model: model, session: session, tool: tool)))) {
            model.beginSketchTransform(tool)
        }
    }

    private var canvas: GroupTool {
        GroupTool(id: "Canvas", title: "Canvas", icon: DesignTool.canvas.symbol,
                  help: "Canvas: place a reference image on the sketch's plane, to trace over") {
            model.insertImageInSketch()
        }
    }

    private var offset: GroupTool {
        GroupTool(id: "Offset", title: "Offset", icon: "offset",
                  help: "Offset the selected curves: drag the arrow, or type the distance",
                  active: session.isOffsetting, enabled: session.canOffset) {
            model.beginSketchOffset()
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
                .tutorialSpot(c.rawValue)
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
    /// How much of the toolbar the window has room for.
    var layout = ToolbarLayout.full
    @ObservedObject private var shortcuts = ShortcutStore.shared  // the tooltips and keys shown follow the user's changes

    private var solo: GroupTool {
        if model.isPickingSketchPlane {
            GroupTool(id: "Cancel", title: "Cancel", icon: "circle-x", help: "Stop choosing a sketch plane (Esc)",
                      active: true) { model.cancelSketchPlanePick() }
        } else {
            GroupTool(id: "Sketch", title: "Sketch", icon: "pen-tool",
                      help: "Create a sketch: then click an origin plane or a flat face in the viewport") { model.startSketch() }
        }
    }

    private var groups: [ToolGroupSpec] {
        let modify = DesignTool.modifiers
        return [group("Create", id: "design.create", DesignTool.shapes, defaults: [.extrude, .revolve, .sweep, .loft]),
                group("Shapes", id: "design.shapes", DesignTool.primitives, defaults: [.box, .cylinder, .sphere]),
                group("Modify", id: "design.modify", modify, defaults: modify),
                group("Construct", id: "design.construct", DesignTool.construct, defaults: [.plane, .mirror, .pattern, .canvas]),
                group("Inspect", id: "design.inspect", DesignTool.inspect, defaults: DesignTool.inspect)]
    }

    var body: some View {
        Group {
            switch layout {
            case .single:
                ToolsMenu(solo: solo, groups: groups)
            case .groups:
                HStack(spacing: DS.Spacing.space1) {
                    SoloToolButton(tool: solo)
                    ForEach(groups) { ToolGroupMenu(group: $0) }
                }
            case .full:
                HStack(spacing: DS.Spacing.space1) {
                    SoloTool(tool: solo)
                    ForEach(groups) { group in
                        ToolDivider()
                        ToolGroup(group)
                    }
                }
            }
        }
        .toolsPanel()
    }

    private func group(_ title: String, id: String, _ tools: [DesignTool], defaults: [DesignTool]) -> ToolGroupSpec {
        ToolGroupSpec(title: title, id: id, defaults: defaults.map(\.rawValue), tools: tools.map { tool in
            // Chamfer and Extrude have three ways each: the button works the way chosen last, and the arrow beside it chooses.
            var modes: [GroupTool] = [], icon = tool.symbol, help = tool.help
            if tool == .chamfer {
                icon = model.chamferMode.symbol; help = model.chamferMode.help
                modes = ChamferMode.allCases.map { mode in
                    GroupTool(id: mode.rawValue, title: mode.shortTitle, icon: mode.symbol, help: mode.help,
                              active: model.chamferMode == mode) { model.chooseChamferMode(mode) }
                }
            } else if tool == .extrude {
                icon = model.extrudeMode.symbol; help = model.extrudeMode.help
                modes = ExtrudeMode.allCases.map { mode in
                    GroupTool(id: mode.rawValue, title: mode.shortTitle, icon: mode.symbol, help: mode.help,
                              active: model.extrudeMode == mode) { model.chooseExtrudeMode(mode) }
                }
            }
            return GroupTool(id: tool.rawValue, title: tool.rawValue, icon: icon, help: help, shortcut: Shortcuts.label(.tool(tool)),
                             active: model.pendingTool == tool, modes: modes) { model.run(tool) }
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
                    .completesParameters(model, focused: focused)
                    .onSubmit { submit() }
                    .onChange(of: draft) { session.message = nil }  // an old complaint isn't about this text
                    .onExitCommand(perform: onDone)
                Button("Set") { submit(unlessClicked: true) }
                    .keyboardShortcut(.defaultAction)
                Button { remove() } label: { Image(systemName: "trash") }
                    .help("Delete this dimension; the sketch keeps its size but can change again")
            }
            if let direction = session.distanceDirection(of: dimensionID) {
                Picker("Measured", selection: Binding(get: { direction }, set: { d in
                    model.sketchCommand { $0.setDistanceDirection(dimensionID, d) }
                })) {
                    ForEach(SketchSession.DistanceDirection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Straight between the points, or only the horizontal or vertical part of it")
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

    /// Return or Set: completes a half-typed name first, otherwise sets the dimension.
    private func submit(unlessClicked: Bool = false) {
        if ParameterCompleter.shared.complete(&draft, unlessClicked: unlessClicked) { focused = true } else { commit() }
    }

    private func remove() {
        let id = dimensionID
        model.sketchCommand { $0.deleteDimension(id) }
        onDone()
    }

    private func commit() {
        let id = dimensionID, text = draft
        model.sketchCommand { $0.setDimension(id, expression: text) }
        if session.editingDimension == nil { onDone() }
    }
}

/// Asks for the factor of Scale, and applies it to the selection (or the whole sketch). Move
/// has the manipulator in the viewport instead.
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
                Button(tool.rawValue) { submit(unlessClicked: true) }
                    .keyboardShortcut(.defaultAction)
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
                .completesParameters(model, focused: focus && focused)
                .onSubmit { submit() }
            if focus { box.focused($focused) } else { box }
        }
    }

    private var pivotPicker: some View {
        Picker("About", selection: $pivot) {
            ForEach(TransformPivot.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    /// Return or the button: completes a half-typed name first, otherwise applies the factor.
    private func submit(unlessClicked: Bool = false) {
        if ParameterCompleter.shared.complete(&factor, unlessClicked: unlessClicked) { focused = true } else { commit() }
    }

    private func commit() {
        let (factor, pivot) = (factor, pivot)
        model.sketchCommand { $0.scaleSelection(factor: factor, about: pivot) }
    }
}

