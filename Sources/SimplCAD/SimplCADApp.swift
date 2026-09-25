// SimplCAD — a small parametric CAD tool for macOS.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import SwiftUI

@main
struct SimplCADApp: App {
    @State private var model = DocumentModel()

    init() {
        // Lets `swift run SimplCAD` show a normal, focusable app window without an .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("SimplCAD", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { NSApplication.shared.activate() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { model.newDocument(demo: false) }.keyboardShortcut("n")
                Button("New Demo Part") { model.newDocument(demo: true) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open…") { model.open() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }.keyboardShortcut("s")
                Button("Save As…") { model.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Export STEP…") { model.export(stl: false) }.keyboardShortcut("e")
                Button("Export STL…") { model.export(stl: true) }
            }
            CommandMenu("Model") {
                Button("Fillet Selected Edges") { model.addEdgeFeature(fillet: true) }.keyboardShortcut("f", modifiers: [.command, .option])
                Button("Chamfer Selected Edges") { model.addEdgeFeature(fillet: false) }
                Divider()
                Button("Rebuild") { model.regenerate() }.keyboardShortcut("r")
                Button("Fit View") { model.fitView() }.keyboardShortcut("0")
            }
        }
    }
}
