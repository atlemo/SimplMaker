// The document type for SwiftUI's DocumentGroup. It wraps the window's DocumentModel, so
// macOS provides New/Open/Open Recent/Save/Duplicate/Rename/Revert, autosave, versions and the
// "unsaved changes" prompt. The document is marked edited whenever the model registers undo.
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let simplCAD = UTType(exportedAs: "org.simplcad.document", conformingTo: .json)
}

final class CADFile: ReferenceFileDocument, @unchecked Sendable {
    typealias Snapshot = CADDocument

    static var readableContentTypes: [UTType] { [.simplCAD] }

    /// The document as read from disk (or the template for a new document).
    private let initial: CADDocument
    @MainActor private var modelStorage: DocumentModel?

    init(document: CADDocument = CADDocument()) {
        initial = document
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        initial = try CADDocument.decode(data)
    }

    /// The live model for this document's window, created on first use.
    @MainActor var model: DocumentModel {
        if let m = modelStorage { return m }
        let m = DocumentModel(document: initial)
        modelStorage = m
        return m
    }

    // SwiftUI calls snapshot on the main thread, then writes the snapshot in the background.
    func snapshot(contentType: UTType) throws -> CADDocument {
        MainActor.assumeIsolated { modelStorage?.document ?? initial }
    }

    func fileWrapper(snapshot: CADDocument, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.encoded())
    }
}

extension FocusedValues {
    /// The model of the frontmost document window, for menu commands.
    @Entry var documentModel: DocumentModel?
}
