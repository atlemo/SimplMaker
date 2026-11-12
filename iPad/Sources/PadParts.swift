// The parts on this iPad: the ones in the app's Documents folder (the "On My iPad" list) and the ones opened lately from anywhere
// (Recents, kept as bookmarks so a part in iCloud Drive or on a USB drive is found again). The start screen shows them; the editor
// reports every part it opens. The file browser of the system is no longer in the way, so creating, renaming, duplicating and
// deleting are done here.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import SwiftUI
import UniformTypeIdentifiers

/// One part in a list: where it is, when it last changed and the picture stored in it.
struct PadPart: Identifiable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    let modified: Date
    let thumbnail: UIImage?
    /// In the app's own Documents folder, where it can be renamed, duplicated and deleted.
    var isLocal: Bool { url.deletingLastPathComponent().standardizedFileURL.path == PadParts.documentsURL.standardizedFileURL.path }
}

@MainActor @Observable
final class PadParts {
    static let shared = PadParts()
    private(set) var recents: [PadPart] = []
    private(set) var local: [PadPart] = []
    /// False until the first look at the disk has finished, so an empty list is not shown for a moment first.
    private(set) var loaded = false

    private static let recentsKey = "padRecentPartBookmarks"
    private static let recentsLimit = 30

    nonisolated static var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    // MARK: Listing

    /// Looks at the disk again: the Documents folder and every bookmarked recent part. Reading the pictures is done off the main thread.
    func refresh() async {
        let bookmarks = UserDefaults.standard.array(forKey: Self.recentsKey) as? [Data] ?? []
        let result = await Task.detached(priority: .userInitiated) { () -> ([PadPart], [PadPart], [Data]) in
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: Self.documentsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            let local = files.filter { $0.pathExtension == "simplmaker" }.compactMap { Self.read($0, scoped: false) }
                .sorted { $0.modified > $1.modified }
            var recents: [PadPart] = []
            var kept: [Data] = []
            for data in bookmarks {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
                      let part = Self.read(url, scoped: true) else { continue }  // gone (deleted, or its drive is not there): forgotten
                if recents.contains(where: { $0.url.standardizedFileURL == part.url.standardizedFileURL }) { continue }
                recents.append(part)
                kept.append(stale ? ((try? url.bookmarkData()) ?? data) : data)
            }
            return (local, recents, kept)
        }.value
        local = result.0
        recents = result.1
        if result.2.count != bookmarks.count { UserDefaults.standard.set(result.2, forKey: Self.recentsKey) }
        loaded = true
    }

    nonisolated private static func read(_ url: URL, scoped: Bool) -> PadPart? {
        let access = scoped && url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let image = (try? Data(contentsOf: url, options: .mappedIfSafe)).flatMap { CADDocument.thumbnail(in: $0) }.flatMap { UIImage(data: $0) }
        return PadPart(url: url, modified: modified, thumbnail: image)
    }

    // MARK: Recents

    /// A part was opened: it goes to the top of Recents.
    func noteOpened(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData() else { return }
        var list = UserDefaults.standard.array(forKey: Self.recentsKey) as? [Data] ?? []
        list.removeAll { data in
            var stale = false
            guard let other = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return true }
            return other.standardizedFileURL == url.standardizedFileURL
        }
        list.insert(bookmark, at: 0)
        UserDefaults.standard.set(Array(list.prefix(Self.recentsLimit)), forKey: Self.recentsKey)
    }

    /// Takes a part out of Recents (the file stays where it is).
    func forget(_ url: URL) {
        var list = UserDefaults.standard.array(forKey: Self.recentsKey) as? [Data] ?? []
        list.removeAll { data in
            var stale = false
            guard let other = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return true }
            return other.standardizedFileURL == url.standardizedFileURL
        }
        UserDefaults.standard.set(list, forKey: Self.recentsKey)
        recents.removeAll { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    // MARK: Files

    /// A name in the Documents folder that is not taken: "Untitled", then "Untitled 2", "Untitled 3"…
    static func freeURL(named base: String, in folder: URL = documentsURL) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent(base).appendingPathExtension("simplmaker")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("simplmaker")
            n += 1
        }
        return url
    }

    /// Writes an empty part to the Documents folder.
    func createPart(named base: String = "Untitled") throws -> URL {
        let url = Self.freeURL(named: base)
        try CADDocument().encoded().write(to: url, options: .atomic)
        return url
    }

    func duplicate(_ part: PadPart) throws {
        let copy = Self.freeURL(named: "\(part.name) copy")
        try FileManager.default.copyItem(at: part.url, to: copy)
    }

    /// Gives a part in the Documents folder another name; returns the new place. The name is cleaned of what a file name cannot hold.
    @discardableResult
    func rename(_ url: URL, to name: String) throws -> URL {
        let clean = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != url.deletingPathExtension().lastPathComponent else { return url }
        let target = url.deletingLastPathComponent().appendingPathComponent(clean).appendingPathExtension("simplmaker")
        guard !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.moveItem(at: url, to: target)
        noteOpened(target)
        return target
    }

    func delete(_ part: PadPart) throws {
        try FileManager.default.removeItem(at: part.url)
        forget(part.url)
        local.removeAll { $0.url == part.url }
    }
}
