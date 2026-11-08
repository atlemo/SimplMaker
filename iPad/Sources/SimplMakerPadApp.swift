// The iPad app's entry point: a document app. The system's document browser opens, creates, renames and duplicates the
// .simplmaker files; CADFile (shared with the Mac) is the document.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct SimplMakerPadApp: App {
    init() {
        // A clean profile has no documents yet: make sure the folder the first new part is written to is there, so creating it
        // does not depend on the system having made it first.
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        }
    }

    var body: some Scene {
        DocumentGroup(newDocument: { CADFile() }) { configuration in
            PadDocumentView(file: configuration.document, fileURL: configuration.fileURL)
        }
        .commands { PadCommands() }

        // Our own launch screen, worded like the Mac's welcome window: icon, title, version, and a button that makes the part and
        // opens it in one step. The system draws the file browser (recent parts) and does the opening, renaming and duplicating.
        // (A demo or tutorial button doesn't work here: the system creates the file itself and ignores a prepared document.)
        DocumentGroupLaunchScene("Welcome to SimplMaker") {
            NewDocumentButton("Create a new part")
        } background: {
            Color(.systemGroupedBackground)
        } overlayAccessoryView: { geometry in
            let box = geometry.titleViewFrame
            // Landscape (and any short screen) squeezes the title and the button together, so there the icon rides higher,
            // clear of the title, and the version, which would land on the button, is left out.
            let short = geometry.frame.width > geometry.frame.height
            ZStack(alignment: .topLeading) {
                PadWelcomeIcon().position(x: box.midX, y: box.minY + (short ? 20 : 72))
                if !short { PadWelcomeVersion().position(x: box.midX, y: box.maxY - 105) }
            }
            .frame(width: geometry.frame.width, height: geometry.frame.height, alignment: .topLeading)
        }
    }
}

/// The app icon, above the title.
private struct PadWelcomeIcon: View {
    var body: some View {
        if let icon = UIImage(named: "WelcomeIcon") {
            Image(uiImage: icon).resizable().frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
    }
}

/// The version, under the buttons.
private struct PadWelcomeVersion: View {
    var body: some View {
        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
            .font(.title3).foregroundStyle(.secondary)
    }
}
