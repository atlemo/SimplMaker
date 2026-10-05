// SimplMaker — a small parametric CAD tool for macOS.
// Copyright © 2026 Atle Mo. All rights reserved.
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

        Window("SimplMaker License", id: AppWindows.licenseID) {
            LicenseWindow().modifier(AccentScope())
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView().modifier(AccentScope())
        }
    }
}

/// Launch and Dock behaviour for a document app with a welcome window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.start()
        LicenseManager.shared.start()
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
    private let license = LicenseManager.shared
    @AppStorage(Preferences.showConstraints) private var showConstraints = true
    @AppStorage(Preferences.snapToGrid) private var snapToGrid = true
    @AppStorage(Preferences.showGrid) private var showGrid = true
    @AppStorage(Preferences.showAxes) private var showAxes = true

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About SimplMaker") { AboutPanel.show() }
            if updater.isAvailable {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            if license.isEnforced {
                Divider()
                if !license.isLicensed { Button("Buy SimplMaker…") { license.buy() } }
                Button("License…") { openWindow(id: AppWindows.licenseID) }
            }
        }
        CommandGroup(replacing: .help) {
            Button(guide?.canResume == true ? "Resume Tutorial: Box with a Lid" : "Tutorial: Make a Box with a Lid") { startTutorial() }
        }
        CommandGroup(after: .newItem) {
            Button("New Demo Part") { newDocument { CADFile(document: .demo()) } }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(before: .windowList) {
            Button("Welcome to SimplMaker") { openWindow(id: AppWindows.welcomeID) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
        }
        CommandGroup(after: .importExport) {
            Button("Import STEP…") { model?.importSTEP() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Import SVG as Sketch…") { model?.importSVG() }
                .disabled(model == nil)
            Divider()
            Button("Export STEP…") { model?.export(stl: false) }.disabled(model == nil)
            Button("Export STL…") { model?.export(stl: true) }.disabled(model == nil)
        }
        CommandGroup(before: .toolbar) {
            Button("Fit All") { model?.fitView() }
                .keyboardShortcut("0")
            Menu("Standard Views") {
                ForEach(StandardView.allCases) { v in
                    Button(v.title) { model?.show(v) }.keyboardShortcut(v.shortcut)
                }
            }
            Toggle("Orthographic Projection", isOn: Binding(get: { model?.orthographic ?? false },
                                                            set: { model?.orthographic = $0 }))
                .keyboardShortcut("o", modifiers: [.command, .option])
            Picker("Visual Style", selection: Binding(get: { model?.visualStyle ?? .standard },
                                                      set: { model?.visualStyle = $0 })) {
                ForEach(VisualStyle.allCases) { style in
                    Text(style.title).tag(style)
                    if style == .shadedWithVisibleEdges { Divider() }  // shaded styles, then wireframe ones
                }
            }
            .disabled(model == nil)
            Divider()
            Toggle("Show Grid", isOn: $showGrid)
                .keyboardShortcut("g", modifiers: [.command, .option])
            Toggle("Show Axes", isOn: $showAxes)
                .keyboardShortcut("a", modifiers: [.command, .option])
            Toggle("Show Constraints", isOn: $showConstraints)
            Toggle("Snap to Grid", isOn: $snapToGrid)
                .keyboardShortcut("'", modifiers: [.command])
            Divider()
            Button((model?.showSidebar ?? true) ? "Hide Browser" : "Show Browser") { model?.showSidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button((model?.showTimeline ?? true) ? "Hide Timeline" : "Show Timeline") { model?.showTimeline.toggle() }
                .keyboardShortcut("t", modifiers: [.command, .option])
            Button((model?.showInspector ?? true) ? "Hide Inspector" : "Show Inspector") { model?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button((model?.showAppearance ?? false) ? "Hide Appearance" : "Show Appearance") {
                LetterShortcut.perform(model) { model?.toggleAppearance() }
            }
            .keyboardShortcut("a", modifiers: [])
            .disabled(model == nil || model?.sketchSession != nil)  // sketching, A draws an arc
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
                        .disabled(!((tool == .pattern ? model?.sketchSession?.canPattern : model?.sketchSession?.canTransform) ?? false))
                }
                Divider()
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
            Button("Rebuild") { model?.regenerate() }
                .keyboardShortcut("r", modifiers: [.command])
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

    /// A Create or Modify tool, with its single-letter shortcut (E for Extrude, F for Fillet...).
    private func toolItem(_ tool: DesignTool, title: String? = nil) -> some View {
        Button(title ?? tool.rawValue) { LetterShortcut.perform(model) { model?.run(tool) } }
            .keyboardShortcut(KeyEquivalent(tool.key), modifiers: [])
            .disabled(model == nil)
    }
}

/// Menu items with single-letter shortcuts, the way CAD tools work (E extrude, A appearance).
/// A menu shortcut sees the key before the view with focus does, so the letter is handed back
/// where it belongs instead: to a text field being typed in, to a sheet or alert, and while
/// sketching to the sketch, whose tools use the same letters (A arc, E extend, F round corner).
@MainActor
enum LetterShortcut {
    static func perform(_ model: DocumentModel?, _ action: () -> Void) {
        if let event = NSApp.currentEvent, event.type == .keyDown,
           let window = NSApp.keyWindow, let responder = window.firstResponder,
           responder is NSText || model?.sketchSession != nil || window.sheetParent != nil || window.attachedSheet != nil {
            responder.keyDown(with: event)
            return
        }
        action()
    }
}
