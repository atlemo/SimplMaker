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

        // Our own launch screen, worded like the Mac's welcome window: icon, title, button and version, with the button making the
        // part and opening it in one step. The system draws the file browser (recent parts) and does the opening, renaming and
        // duplicating. (A demo or tutorial button doesn't work here: the system creates the file itself and ignores a prepared
        // document.) The system's own title is left empty: it is set left-aligned in a size we cannot change, so the title, like
        // the icon and the version, is drawn here, centred on the button.
        DocumentGroupLaunchScene("") {
            NewDocumentButton("Create a new part")
        } background: {
            Color(.systemGroupedBackground)
        } overlayAccessoryView: { geometry in
            // With no title, the button sits in the middle of this box (the box is tight around it on a roomy screen, and taller on
            // the short folded phone): everything else is placed around the button.
            let box = geometry.titleViewFrame
            GeometryReader { proxy in
                // The overlay is not always laid out from the screen's top left corner: place things relative to where it is.
                let origin = proxy.frame(in: .global).origin
                let x = box.midX - origin.x
                let buttonTop = box.midY - 26 - origin.y
                ZStack(alignment: .topLeading) {
                    // The icon where it fits above the title: full size on a roomy screen, smaller when the browser takes the room
                    // (landscape), and left out on the short folded phone.
                    if buttonTop >= 150 {
                        let size: CGFloat = buttonTop >= 212 ? 96 : 56
                        PadWelcomeIcon(size: size).position(x: x, y: buttonTop - 80 - size / 2)
                    }
                    PadWelcomeTitle(size: min(40, max(26, box.width * 0.06))).frame(width: max(box.width - 32, 100)).position(x: x, y: buttonTop - 40)
                    PadWelcomeVersion().position(x: x, y: box.midY + 26 + 36 - origin.y)
                }
            }
            .ignoresSafeArea()
        }
    }
}

/// The title, above the button.
private struct PadWelcomeTitle: View {
    let size: CGFloat
    var body: some View {
        Text("Welcome to SimplMaker")
            .font(.system(size: size, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .multilineTextAlignment(.center)
    }
}

/// The app icon, above the title.
private struct PadWelcomeIcon: View {
    let size: CGFloat
    var body: some View {
        if let icon = UIImage(named: "WelcomeIcon") {
            Image(uiImage: icon).resizable().frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
    }
}

/// The version, under the button.
private struct PadWelcomeVersion: View {
    var body: some View {
        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
            .font(.title3).foregroundStyle(.secondary)
    }
}
