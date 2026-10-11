// The documents that are open, with an id for each that an AI client can use to say which one it means. The ids
// are made up when a document's model is created and last until it is closed; a document that has been closed
// has no id any more (a new one opened later gets a new id, never an old one).
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

@MainActor
final class DocumentRegistry {
    static let shared = DocumentRegistry()

    private struct Entry {
        let id: String
        weak var model: DocumentModel?
    }

    private var entries: [Entry] = []
    private var counter = 0
    private weak var active: DocumentModel?

    init() {}

    /// Gives the model an id (the one it already has, if it is known).
    @discardableResult
    func register(_ model: DocumentModel) -> String {
        prune()
        if let known = id(of: model) { return known }
        counter += 1
        let id = "doc_\(counter)"
        entries.append(Entry(id: id, model: model))
        return id
    }

    func id(of model: DocumentModel) -> String? {
        entries.first { $0.model === model }?.id
    }

    func model(withID id: String) -> DocumentModel? {
        entries.first { $0.id == id }?.model
    }

    /// The open documents, in the order they were opened.
    var documents: [(id: String, model: DocumentModel)] {
        prune()
        return entries.compactMap { e in e.model.map { (e.id, $0) } }
    }

    /// The document in the front window was last told to us by its window; with no window in front, the only
    /// one that is open. Nil when it can't be told (several open, none in front).
    var frontmost: (id: String, model: DocumentModel)? {
        prune()
        if let model = active, let id = id(of: model) { return (id, model) }
        let all = documents
        return all.count == 1 ? all[0] : nil
    }

    /// A document window came to the front.
    func activate(_ model: DocumentModel) {
        register(model)
        active = model
    }

    private func prune() {
        entries.removeAll { $0.model == nil }
    }
}
