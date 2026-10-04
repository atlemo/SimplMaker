// The document type for SwiftUI's DocumentGroup. It wraps the window's DocumentModel, so
// macOS provides New/Open/Open Recent/Save/Duplicate/Rename/Revert, autosave, versions and the
// "unsaved changes" prompt. The document is marked edited whenever the model registers undo.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import os
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let simplMaker = UTType(exportedAs: "com.simplmaker.document", conformingTo: .json)
}

final class CADFile: ReferenceFileDocument, @unchecked Sendable {
    typealias Snapshot = CADDocument

    static var readableContentTypes: [UTType] { [.simplMaker] }

    /// The document as read from disk (or the template for a new document).
    private let initial: CADDocument
    @MainActor private var modelStorage: DocumentModel?
    /// The model's latest document, readable from any thread. SwiftUI takes snapshots on a
    /// background thread, where touching the main-actor model would crash.
    private let latest: OSAllocatedUnfairLock<CADDocument>

    init(document: CADDocument = CADDocument()) {
        initial = document
        latest = OSAllocatedUnfairLock(initialState: document)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        initial = try CADDocument.decode(data)
        latest = OSAllocatedUnfairLock(initialState: initial)
    }

    /// The live model for this document's window, created on first use.
    @MainActor var model: DocumentModel {
        if let m = modelStorage { return m }
        let m = DocumentModel(document: initial)
        m.onDocumentChange = { [latest] doc in latest.withLock { $0 = doc } }
        modelStorage = m
        return m
    }

    // SwiftUI calls snapshot on a background thread (autosave, Save), so it reads the locked copy.
    func snapshot(contentType: UTType) throws -> CADDocument {
        latest.withLock { $0 }
    }

    func fileWrapper(snapshot: CADDocument, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.encoded())
    }
}

extension FocusedValues {
    /// The model of the frontmost document window, for menu commands.
    @Entry var documentModel: DocumentModel?
}
