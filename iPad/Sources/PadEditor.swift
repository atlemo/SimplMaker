// Opens one part from its file and keeps it saved. With no DocumentGroup to read and write the file, this does it: the file is read
// when the part opens, written a moment after every change (and when the app leaves the screen or the part is closed), and the
// title in the top bar renames it.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Where the editor goes: a part's file, and whether the tutorial's card shows when it opens.
struct PadRoute: Hashable {
    let url: URL
    var tutorial = false
}

struct PadEditor: View {
    let route: PadRoute
    /// Goes back to the start screen.
    let close: () -> Void
    @State private var url: URL
    @State private var file: CADFile?
    @State private var failure: String?
    @State private var scoped = false
    @State private var saver = PadSaver()
    @State private var renaming = false
    @State private var newName = ""
    @State private var renameFailure: String?
    @Environment(\.scenePhase) private var scenePhase

    init(route: PadRoute, close: @escaping () -> Void) {
        self.route = route
        self.close = close
        _url = State(initialValue: route.url)
    }

    private var name: String { url.deletingPathExtension().lastPathComponent }
    private var canRename: Bool { PadPart(url: url, modified: .now, thumbnail: nil).isLocal }

    var body: some View {
        Group {
            if let file {
                PadDocumentView(file: file, fileURL: url, title: name, onClose: { saver.flush(file, to: url); close() },
                                onRename: canRename ? { newName = name; renaming = true } : nil)
                    .background(PadAutosave(file: file, url: url, saver: saver))
                    .onChange(of: scenePhase) { if scenePhase != .active { saver.flush(file, to: url) } }
                    .onDisappear { saver.flush(file, to: url) }
            } else if let failure {
                ContentUnavailableView {
                    Label("This part could not be opened", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Back to Parts", action: close).buttonStyle(.borderedProminent)
                }
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .onDisappear { if scoped { url.stopAccessingSecurityScopedResource(); scoped = false } }
        .alert("Rename Part", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename() }
        }
        .alert("The part could not be renamed", isPresented: Binding(get: { renameFailure != nil }, set: { if !$0 { renameFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(renameFailure ?? "") }
    }

    private func load() async {
        guard file == nil else { return }
        scoped = url.startAccessingSecurityScopedResource()
        let target = url, tutorial = route.tutorial
        do {
            let data = try await Task.detached { try PadAutosave.read(target) }.value
            let opened = try CADFile(data: data, tutorial: tutorial)
            saver.saved = opened.model.documentRevision  // as read: nothing to write until it changes
            file = opened
            PadParts.shared.noteOpened(url)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func rename() {
        guard let file else { return }
        saver.flush(file, to: url)  // the bytes first, then the new name
        do { url = try PadParts.shared.rename(url, to: newName) } catch { renameFailure = error.localizedDescription }
    }
}

/// Remembers which state of the part is in the file.
@MainActor final class PadSaver {
    /// The part's change count when the file was read or last written.
    var saved = -1

    /// Writes the file if the part has changed since it was last written (coordinated, as the system's own file handling would, so
    /// iCloud and Files see one clean update).
    func flush(_ file: CADFile, to url: URL) {
        let revision = file.model.documentRevision
        guard revision != saved, let data = try? file.encodedData() else { return }
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
            try? data.write(to: target, options: .atomic)
        }
        saved = revision
    }
}

/// Writes the part a moment after it changes. A view of no size: its task restarts with every change, so the write comes once the
/// part has been left alone.
private struct PadAutosave: View {
    let file: CADFile
    let url: URL
    let saver: PadSaver

    var body: some View {
        let revision = file.model.documentRevision
        Color.clear.frame(width: 0, height: 0)
            .task(id: revision) {
                guard saver.saved != revision else { return }
                // Long enough for the picture stored in the file to be redrawn first.
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                saver.flush(file, to: url)
            }
    }

    nonisolated static func read(_ url: URL) throws -> Data {
        var error: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { source in
            result = Result { try Data(contentsOf: source) }
        }
        if let error { throw error }
        return try result.get()
    }
}
