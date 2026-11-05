// The document type for SwiftUI's DocumentGroup. It wraps the window's DocumentModel, so
// macOS provides New/Open/Open Recent/Save/Duplicate/Rename/Revert, autosave, versions and the
// "unsaved changes" prompt. The document is marked edited whenever the model registers undo.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
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
    /// The window opens with the tutorial's card showing (File ▸ New from the welcome window's tutorial, or Help ▸ Tutorial).
    private let startsTutorial: Bool
    @MainActor private var guideStorage: TutorialGuide?
    /// A picture of the part (PNG), stored in the file for Finder's Quick Look: the one read from the file until the part changes,
    /// then the latest drawn. Readable from any thread, like `latest`.
    private let thumbnail = OSAllocatedUnfairLock<Data?>(initialState: nil)
    @MainActor private var thumbnailTask: Task<Void, Never>?

    init(document: CADDocument = CADDocument(), tutorial: Bool = false) {
        initial = document
        startsTutorial = tutorial
        latest = OSAllocatedUnfairLock(initialState: document)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        initial = try CADDocument.decode(data)
        startsTutorial = false
        latest = OSAllocatedUnfairLock(initialState: initial)
        thumbnail.withLock { $0 = CADDocument.thumbnail(in: data) }
    }

    /// The live model for this document's window, created on first use.
    @MainActor var model: DocumentModel {
        if let m = modelStorage { return m }
        let m = DocumentModel(document: initial)
        m.onDocumentChange = { [weak self, latest] doc in
            latest.withLock { $0 = doc }
            Task { @MainActor in self?.scheduleThumbnail() }
        }
        #if os(macOS)
        if AIFeature.isAvailable { DocumentRegistry.shared.register(m) }  // the AI interface can now name this document
        #endif
        modelStorage = m
        return m
    }

    /// The tutorial's guide for this document's window (showing only when asked for).
    @MainActor var guide: TutorialGuide {
        if let g = guideStorage { return g }
        let g = TutorialGuide(active: startsTutorial)
        guideStorage = g
        return g
    }

    /// Draws a new thumbnail once the part has been left alone for a moment (drawing is not free, and every edit changes it).
    @MainActor private func scheduleThumbnail() {
        thumbnailTask?.cancel()
        thumbnailTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let model = modelStorage else { return }
            await model.rebuilt()
            guard !Task.isCancelled else { return }
            #if os(macOS)
            let image = try? await ViewportSnapshot.render(model, direction: .iso, width: 512, height: 512, axes: false)
            guard !Task.isCancelled else { return }
            thumbnail.withLock { $0 = image?.png }  // nothing to show (an empty part) means no picture
            #endif
        }
    }

    // SwiftUI calls snapshot on a background thread (autosave, Save), so it reads the locked copy.
    func snapshot(contentType: UTType) throws -> CADDocument {
        latest.withLock { $0 }
    }

    func fileWrapper(snapshot: CADDocument, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.encoded(thumbnail: thumbnail.withLock { $0 }))
    }
}

extension FocusedValues {
    /// The model of the frontmost document window, for menu commands.
    @Entry var documentModel: DocumentModel?
    /// The tutorial guide of the frontmost document window, for Help ▸ Tutorial.
    @Entry var tutorialGuide: TutorialGuide?
}
