// SimplMaker — a small parametric CAD tool for macOS.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import SwiftUI

@main
struct SimplMakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Lets `swift run SimplMaker` show a normal, focusable app without an .app bundle.
        // (Use scripts/bundle-app.sh or Xcode for the full document experience.)
        NSApplication.shared.setActivationPolicy(.regular)
        _ = ParameterCompleter.shared  // starts listening to the number fields
    }

    var body: some Scene {
        DocumentGroup(newDocument: { CADFile() }) { configuration in
            ContentView(file: configuration.document, fileURL: configuration.fileURL)
                .frame(minWidth: 1080, minHeight: 560)  // room for the default toolbar row (every Modify tool pinned)
                .background(WindowSizeMemory())
        }
        .commands { SimplMakerCommands() }

        // The welcome window replaces the empty document macOS would otherwise open at launch
        // (see AppDelegate). It is never restored; launch decides whether it appears.
        Window("Welcome to SimplMaker", id: AppWindows.welcomeID) {
            WelcomeView().modifier(AccentScope())
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(Preferences.showsWelcome ? .presented : .suppressed)


        // An ordinary window rather than a Settings scene, whose window SwiftUI keeps from being resized.
        // The "Settings…" item (⌘,) is in SimplMakerCommands.
        Window("Settings", id: AppWindows.settingsID) {
            SettingsView().modifier(AccentScope())
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
    }
}

/// Launch and Dock behaviour for a document app with a welcome window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.start()
        RenameDocument.shared.start()
        Telemetry.start()
        if AIFeature.isAvailable { AIConnection.shared.startIfEnabled() }  // only when the user has turned it on in Settings ▸ AI
    }

    /// A rebuild still inside the geometry kernel when the process exits crashes it (the kernel's static
    /// destructors run under it), so the quit waits for the rebuild, up to a limit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard KernelActivity.shared.beginQuit() else { return .terminateNow }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(20)
            while KernelActivity.shared.isBusy, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if AIFeature.isAvailable { AIConnection.shared.stop() }  // closes the connections and marks the connection file as not running
    }

    /// No empty document at launch while the welcome window is on; the Window scene presents it.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !Preferences.showsWelcome
    }

    /// Clicking the Dock icon with no windows open brings the welcome window back, not an empty part.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, Preferences.showsWelcome else { return true }
        AppWindows.showWelcome()
        return false
    }
}

/// Menu commands. They act on the frontmost document window through a focused value.
struct SimplMakerCommands: Commands {
    @FocusedValue(\.documentModel) private var model
    @FocusedValue(\.tutorialGuide) private var guide
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var shortcuts = ShortcutStore.shared  // the menus show the user's shortcuts
    @AppStorage(Preferences.showConstraints) private var showConstraints = true
    @AppStorage(Preferences.snapToGrid) private var snapToGrid = true
    @AppStorage(Preferences.showGrid) private var showGrid = true
    @AppStorage(Preferences.showAxes) private var showAxes = true

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: AppWindows.settingsID) }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .appInfo) {
            Button("About SimplMaker") { AboutPanel.show() }
            if updater.isAvailable {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        CommandGroup(replacing: .help) {
            Button(guide?.canResume == true ? "Resume Tutorial: Desk Organizer" : "Tutorial: Make a Desk Organizer") { startTutorial() }
            Divider()
            Button("SimplMaker Docs") { NSWorkspace.shared.open(URL(string: "https://simplmaker.com/docs/")!) }
        }
        CommandGroup(before: .saveItem) {
            Menu("Open Example Parts") {
                Button("Plate with Holes, Fillets and a Chamfer") { newDocument { CADFile(document: .demo()) } }
                    .shortcut(.exampleParts)
                Button("Bracket Profile (try the sketch solver)") { newDocument { CADFile(document: .bracketProfileDemo()) } }
                Button("Bracket with Ribs") { newDocument { CADFile(document: .ribDemo()) } }
                Button("Flanged Pipe on a Manifold (advanced)") { newDocument { CADFile(document: .manifoldDemo()) } }
            }
            Divider()
        }
        CommandGroup(after: .saveItem) {
            Button("Rename…") { RenameDocument.shared.rename() }
                .disabled(model?.fileURL == nil)  // there is no file to rename until it is saved
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { EditCommands.send("cut:") }
                .keyboardShortcut("x")
            Button("Copy") { EditCommands.copy(model) }
                .keyboardShortcut("c")
            Button("Paste") { EditCommands.paste(model) }
                .keyboardShortcut("v")
            Divider()
            Button("Select All") { EditCommands.send("selectAll:") }
                .keyboardShortcut("a")
        }
        CommandGroup(before: .windowList) {
            Button("Welcome to SimplMaker") { openWindow(id: AppWindows.welcomeID) }
                .shortcut(.welcome)
        }
        CommandGroup(after: .importExport) {
            Menu("Import") {
                Button("STEP…") { model?.importSTEP() }
                    .shortcut(.importSTEP)
                Button("STL…") { model?.importSTL() }
                Button("SVG as Sketch…") { model?.importSVG() }
                Button("DXF as Sketch…") { model?.importDXF() }
            }
            .disabled(model == nil)
            Divider()
            Button("Export…") { model?.exportWithDialog() }.disabled(model == nil)
            Button("Export Image…") { model?.exportImageWithDialog() }.disabled(model == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Command Palette…") { model?.showPalette.toggle() }
                .shortcut(.palette)
                .disabled(model == nil)
            Divider()
            Button("Fit All") { LetterShortcut.perform(model) { model?.fitView() } }
                .shortcut(.fitAll)
            Menu("Standard Views") {
                ForEach(StandardView.allCases) { v in
                    Button(v.title) { LetterShortcut.perform(model) { model?.show(v) } }.shortcut(.view(v))
                }
            }
            Toggle("Orthographic Projection", isOn: Binding(get: { model?.orthographic ?? false },
                                                            set: { model?.orthographic = $0 }))
                .shortcut(.orthographic)
            Picker("Visual Style", selection: Binding(get: { model?.visualStyle ?? .standard },
                                                      set: { model?.visualStyle = $0 })) {
                ForEach(VisualStyle.allCases) { style in
                    Text(style.title).tag(style)
                    if style == .shadedWithVisibleEdges { Divider() }  // shaded styles, then wireframe ones
                }
            }
            .disabled(model == nil)
            Toggle("FDM 3D Print Preview", isOn: Binding(get: { model?.printPreview ?? false },
                                                         set: { model?.setPrintPreview($0) }))
                .disabled(model == nil || !(model?.visualStyle.isShaded ?? true))
            Toggle("Render", isOn: Binding(get: { model?.renderView ?? false },
                                           set: { model?.setRenderView($0) }))
                .disabled(model == nil)
            Toggle("Render Options", isOn: Binding(get: { model?.showRenderOptions ?? false },
                                                   set: { model?.showRenderOptions = $0 }))
                .disabled(model == nil || !(model?.renderView ?? false))
            Toggle("Section Analysis", isOn: Binding(get: { model?.sectionActive ?? false },
                                                     set: { model?.setSectionAnalysis($0) }))
                .disabled(model == nil)
            Toggle("Exploded View", isOn: Binding(get: { model?.explodeOn ?? false },
                                                  set: { model?.setExplodedView($0) }))
                .disabled(model == nil)
            Divider()
            Toggle("Show Grid", isOn: $showGrid)
                .shortcut(.showGrid)
            Toggle("Show Axes", isOn: $showAxes)
                .shortcut(.showAxes)
            Toggle("Show Constraints", isOn: $showConstraints)
            Toggle("Snap to Grid", isOn: $snapToGrid)
                .shortcut(.snapToGrid)
            Divider()
            Button((model?.showSidebar ?? true) ? "Hide Browser" : "Show Browser") { LetterShortcut.perform(model) { model?.showSidebar.toggle() } }
                .shortcut(.browser)
            Button((model?.showTimeline ?? true) ? "Hide Timeline" : "Show Timeline") { LetterShortcut.perform(model) { model?.showTimeline.toggle() } }
                .shortcut(.timeline)
            Button((model?.showInspector ?? true) ? "Hide Inspector" : "Show Inspector") { LetterShortcut.perform(model) { model?.showInspector.toggle() } }
                .shortcut(.inspector)
            Button((model?.uiHidden ?? false) ? "Show UI" : "Hide UI") { model?.toggleUIHidden() }
                .shortcut(.hideUI)
                .disabled(model == nil)
            Button((model?.showAppearance ?? false) ? "Hide Appearance" : "Show Appearance") {
                LetterShortcut.perform(model) { model?.toggleAppearance() }
            }
            .shortcut(.appearance)
            .disabled(model == nil || model?.sketchSession != nil)  // sketching, the key belongs to the sketch tools (A draws an arc)
            Divider()
        }
        CommandMenu("Sketch") {
            Button("New Sketch…") { model?.startSketch() }
                .disabled(model == nil)
            Menu("New Sketch On") {
                Button("XY Plane") { model?.beginSketch(on: .xy) }
                Button("XZ Plane") { model?.beginSketch(on: .xz) }
                Button("YZ Plane") { model?.beginSketch(on: .yz) }
                Button("Selected Face") { if let p = model?.selectedFacePlane { model?.beginSketch(on: p) } }
                    .disabled(model?.selectedFacePlane == nil)
            }
            .disabled(model == nil)
            // The drawing tools only appear while a sketch is being edited.
            if model?.sketchSession != nil {
                Divider()
                ForEach(SketchTool.allCases) { tool in
                    Button(tool.rawValue) { model?.setSketchTool(tool) }
                }
                Button("Offset Selection…") { model?.beginSketchOffset() }
                    .disabled(!(model?.sketchSession?.canOffset ?? false))
                ForEach(SketchTransformTool.allCases) { tool in
                    Button(tool == .scale ? "Scale Selection…" : tool == .pattern ? "Pattern Selection" : "\(tool.rawValue) Selection") { model?.beginSketchTransform(tool) }
                        .disabled(!((tool == .pattern ? model?.sketchSession?.canPattern : tool == .mirror ? model?.sketchSession?.canMirror : model?.sketchSession?.canTransform) ?? false))
                }
                Divider()
                Toggle("Slice View", isOn: Binding(get: { model?.sketchSlice ?? false }, set: { model?.sketchSlice = $0 }))
                Button("Finish Sketch") { model?.finishSketch() }
            }
        }
        CommandMenu("Create") {
            ForEach(DesignTool.shapes) { tool in toolItem(tool) }
            Divider()
            ForEach(DesignTool.primitives) { tool in toolItem(tool) }
            Divider()
            toolItem(.plane, title: "Construction Plane")
            toolItem(.canvas, title: "Canvas (Reference Image)…")
            Divider()
            Button("Rebuild") { LetterShortcut.perform(model) { model?.regenerate() } }
                .shortcut(.rebuild)
                .disabled(model == nil)
        }
        CommandMenu("Modify") {
            ForEach(DesignTool.modifiers) { tool in toolItem(tool) }
            Divider()
            toolItem(.mirror)
            toolItem(.pattern)
        }
        CommandMenu("Inspect") {
            ForEach(DesignTool.inspect) { tool in toolItem(tool) }
        }
    }

    /// Help ▸ Tutorial: brings back one that was closed, starts in the empty part in front, or opens a new part for it.
    private func startTutorial() {
        if let guide, let model {
            if guide.isActive { return }
            if guide.canResume || (model.document.features.isEmpty && model.document.parameters.isEmpty) {
                guide.start()
                return
            }
        }
        newDocument { CADFile(tutorial: true) }
    }

    /// A Create or Modify tool, with its shortcut (by default a single letter: E for Extrude, F for Fillet...).
    private func toolItem(_ tool: DesignTool, title: String? = nil) -> some View {
        Button(title ?? tool.rawValue) { LetterShortcut.perform(model) { model?.run(tool) } }
            .shortcut(.tool(tool))
            .disabled(model == nil)
    }
}

/// Menu items whose shortcut is a plain key, the way CAD tools work (E extrude, A appearance); the
/// user can give any command one. A menu shortcut sees the key before the view with focus does, so
/// the key is handed back where it belongs instead: to a text field being typed in, to a sheet or
/// alert, and while sketching to the sketch, whose tools use the same letters (A arc, E extend,
/// F round corner). Shortcuts with ⌘, ⌃ or ⌥ always run the command.
@MainActor
enum LetterShortcut {
    /// True while a key is being handed back to the view that had it. If nobody there wants it (a letter the sketch
    /// has no tool for, or a list that ignores it), it climbs to the window, which offers it to the menu again,
    /// which hands it back again: for ever. So a key that comes round a second time is dropped.
    static var handingBack = false

    static func perform(_ model: DocumentModel?, _ action: () -> Void) {
        if handingBack { return }
        if let event = NSApp.currentEvent, event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let window = NSApp.keyWindow, let responder = window.firstResponder,
           responder is NSText || model?.sketchSession != nil || window.sheetParent != nil || window.attachedSheet != nil {
            handingBack = true
            defer { handingBack = false }
            responder.keyDown(with: event)
            return
        }
        action()
    }
}
