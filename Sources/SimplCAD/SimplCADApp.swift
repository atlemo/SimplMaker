// SimplCAD — a small parametric CAD tool for macOS.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import SwiftUI

@main
struct SimplCADApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Lets `swift run SimplCAD` show a normal, focusable app without an .app bundle.
        // (Use scripts/bundle-app.sh or Xcode for the full document experience.)
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        DocumentGroup(newDocument: { CADFile() }) { configuration in
            ContentView(file: configuration.document, fileURL: configuration.fileURL)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands { SimplCADCommands() }

        // The welcome window replaces the empty document macOS would otherwise open at launch
        // (see AppDelegate). It is never restored; launch decides whether it appears.
        Window("Welcome to SimplCAD", id: AppWindows.welcomeID) {
            WelcomeView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(Preferences.showsWelcome ? .presented : .suppressed)

        Settings {
            SettingsView()
        }
    }
}

/// Launch and Dock behaviour for a document app with a welcome window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
struct SimplCADCommands: Commands {
    @FocusedValue(\.documentModel) private var model
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Preferences.showConstraints) private var showConstraints = true

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Demo Part") { newDocument { CADFile(document: .demo()) } }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(before: .windowList) {
            Button("Welcome to SimplCAD") { openWindow(id: AppWindows.welcomeID) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
        }
        CommandGroup(after: .importExport) {
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
            Toggle("Show Constraints", isOn: $showConstraints)
            Divider()
            Button((model?.showInspector ?? true) ? "Hide Inspector" : "Show Inspector") { model?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
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
            Divider()
            ForEach(SketchTool.allCases) { tool in
                Button(tool.rawValue) { model?.setSketchTool(tool) }
                    .disabled(model?.sketchSession == nil)
            }
            Button("Offset Selection…") { model?.sketchSession?.beginOffset() }
                .disabled(!(model?.sketchSession?.canOffset ?? false))
            Divider()
            Button("Finish Sketch") { model?.finishSketch() }
                .disabled(model?.sketchSession == nil)
        }
        CommandMenu("Create") {
            ForEach(DesignTool.fromSketches) { tool in
                Button(tool.rawValue) { model?.run(tool) }
                    .keyboardShortcut(tool == .extrude ? KeyboardShortcut("e", modifiers: [.command, .shift]) : nil)
            }
            Divider()
            ForEach(DesignTool.primitives) { tool in Button(tool.rawValue) { model?.run(tool) } }
            Divider()
            Button("Rebuild") { model?.regenerate() }
        }
        CommandMenu("Modify") {
            ForEach(DesignTool.modifiers) { tool in Button(tool.rawValue) { model?.run(tool) } }
        }
    }
}
