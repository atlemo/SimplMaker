// The iPad app's entry point: a document app. The system's document browser opens, creates, renames and duplicates the
// .simplmaker files; CADFile (shared with the Mac) is the document.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct SimplMakerPadApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { CADFile() }) { configuration in
            PadDocumentView(file: configuration.document, fileURL: configuration.fileURL)
        }
        .commands { PadCommands() }
    }
}
