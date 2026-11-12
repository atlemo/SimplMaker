// The iPad app's entry point. Our own start screen (PadHome) lists and creates the .simplmaker files and opens them in the editor
// (PadEditor), which reads and saves them; CADFile (shared with the Mac) is the document. The system's document browser and launch
// screen are not used, since neither can be laid out or themed the way the start screen is.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct SimplMakerPadApp: App {
    init() {
        // A clean profile has no documents yet: make sure the folder the first new part is written to is there, so creating it
        // does not depend on the system having made it first.
        try? FileManager.default.createDirectory(at: PadParts.documentsURL, withIntermediateDirectories: true)
    }

    var body: some Scene {
        WindowGroup {
            PadRoot()
        }
        .commands { PadCommands() }
    }
}

/// The start screen, or the editor over it (with its own navigation bar, whose back button returns to the parts). The editor is
/// swapped in, not pushed: a pushed one left the screen stuck half-way when it was popped, with the start screen's bar hidden.
private struct PadRoot: View {
    @State private var route: PadRoute?

    var body: some View {
        ZStack {
            if let route {
                PadEditor(route: route) { show(nil) }
                    .id(route)
            } else {
                PadHome { url, tutorial in show(PadRoute(url: url, tutorial: tutorial)) }
            }
        }
        .tint(DS.brand)
        // A part sent to the app (Files, AirDrop, Share) opens like one chosen here.
        .onOpenURL { url in if url.pathExtension == "simplmaker" { show(PadRoute(url: url)) } }
    }

    private func show(_ new: PadRoute?) {
        route = new
    }
}
