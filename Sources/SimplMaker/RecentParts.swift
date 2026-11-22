// The recent parts: the list the Start page shows, its rows, and the record of parts opened and saved.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import CryptoKit
import SwiftUI

/// The recent parts, as a list to open them from (the Start page's). Drawn here rather than
/// with List: a List shows its selection in grey until it has keyboard focus, and its table doesn't take the click that brings the
/// window forward, so a double-click could select without opening. Here a click selects at once, the second click of a
/// double-click opens, and the arrow keys and Return work as in a list. Each part is a card with its picture.
struct RecentPartsList: View {
    /// The list has the keyboard from the start (for ↑ ↓ Return), not the first button.
    var takesFocus = false
    @Environment(\.openDocument) private var openDocument
    @State private var recents: [URL] = []
    @State private var selected: URL?
    /// The part being opened, which shows a spinner.
    @State private var opening: URL?
    @FocusState private var listFocused: Bool
    @State private var error: String?
    /// The list's width, to know how many cards fit in a row (for ↑ ↓).
    @State private var width: CGFloat = 0

    private static let cardWidth: CGFloat = 150
    private static let gap: CGFloat = DS.Spacing.space5

    private var columns: Int {
        max(1, Int(((width - 2 * DS.Spacing.space5 + Self.gap) / (Self.cardWidth + Self.gap)).rounded(.down)))
    }

    var body: some View {
        list
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
            .alert("The part couldn't be opened", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    @ViewBuilder private var list: some View {
        if recents.isEmpty {
            VStack(spacing: 6) {
                Text("No Recent Parts").font(.title3).foregroundStyle(.secondary)
                Text("Parts you open or save will show up here. For now it is very quiet.").font(.callout).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cardWidth, maximum: Self.cardWidth + 60), spacing: Self.gap, alignment: .top)],
                          spacing: Self.gap) {
                    ForEach(recents, id: \.self) { url in
                        RecentCard(url: url, selected: selected == url, opening: opening == url)
                            .onTapGesture { click(url) }
                            .contextMenu {
                                Button("Open") { open(url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Divider()
                                Button("Remove from Recent Parts") {
                                    RecentParts.remove(url)
                                    reload()
                                }
                            }
                            .accessibilityAction { open(url) }
                    }
                }
                .padding(DS.Spacing.space5)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onAppear { listFocused = takesFocus }
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
            .onKeyPress(.upArrow) { step(-columns) }
            .onKeyPress(.downArrow) { step(columns) }
            .onKeyPress(.return) {
                guard let selected else { return .ignored }
                open(selected)
                return .handled
            }
        }
    }

    /// A click selects the part; the second click of a double-click opens it.
    private func click(_ url: URL) {
        selected = url
        if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { open(url) }
    }

    /// Moves the selection up or down the list.
    private func step(_ by: Int) -> KeyPress.Result {
        guard !recents.isEmpty else { return .ignored }
        let i = selected.flatMap { recents.firstIndex(of: $0) } ?? (by > 0 ? -1 : recents.count)
        selected = recents[min(max(i + by, 0), recents.count - 1)]
        return .handled
    }

    private func reload() {
        recents = RecentParts.urls
    }

    private func open(_ url: URL) {
        guard opening == nil else { return }
        opening = url
        Task {
            defer { opening = nil }
            do {
                try await PartWindows.openAsync { try await openDocument(at: url) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// One of the big actions of the Start page: icon, bold title and a one-line description.
struct StartAction: View {
    @Environment(\.accent) private var accent
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(accent)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.space4)
            .padding(.vertical, DS.Spacing.labelGap)
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityHint(subtitle)
    }
}

/// A recent part: the picture stored in the file (the file's icon when it has none), the name and where it lives; the picture's frame is
/// blue when selected, as in a source list.
struct RecentCard: View {
    @Environment(\.accent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    let url: URL
    let selected: Bool
    let opening: Bool
    @State private var hovering = false
    @State private var picture: NSImage?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
            // The pictures stored in the files are square: the frame is too, and takes the width the grid gives it whatever is inside.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let picture {
                        Image(nsImage: picture).resizable().interpolation(.high).scaledToFill()
                    } else if loaded {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().frame(width: 56, height: 56)
                    }
                }
                .overlay { if opening { ProgressView().controlSize(.small) } }
                .background(DS.windowBackground)
                .clipShape(shape)
                .overlay { shape.strokeBorder(selected ? accent : hovering ? Color.primary.opacity(0.18) : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 1) }
            VStack(alignment: .leading, spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                Text(Self.abbreviated(url.deletingLastPathComponent())).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, DS.Spacing.space1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(url.path)
        .task(id: PictureKey(url: url, dark: colorScheme == .dark)) {
            picture = await RecentPictures.image(for: url, dark: colorScheme == .dark)
            loaded = true
            // A part not opened since dark pictures began has only the light one: draw its dark one now, and swap it in.
            if colorScheme == .dark, await RecentPictures.makeDarkIfNeeded(for: url) {
                picture = await RecentPictures.image(for: url, dark: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private struct PictureKey: Equatable { let url: URL; let dark: Bool }

    /// "~/Desktop" rather than "/Users/name/Desktop".
    static func abbreviated(_ folder: URL) -> String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }
}

/// The pictures of the recent parts. Every time a part is opened (or saved for the first time) a new picture is drawn and kept here, in
/// the caches folder, one PNG per file: the picture inside the file is only as new as its last save, and a file saved by an older version
/// has none. The list shows the kept picture unless the file is newer and has a picture of its own.
@MainActor enum RecentPictures {
    private static let cache = NSCache<NSString, NSImage>()

    /// Keeps the new picture of the part at `url`; with none (an empty part) the old one is dropped.
    static func store(_ png: Data?, for url: URL, dark: Bool = false) {
        guard let kept = keptFile(for: url, dark: dark) else { return }
        if let png { try? png.write(to: kept, options: .atomic) } else { try? FileManager.default.removeItem(at: kept) }
    }

    private static func keptFile(for url: URL, dark: Bool = false) -> URL? {
        guard let caches = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let folder = caches.appendingPathComponent("RecentPictures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name + (dark ? "-dark" : "") + ".png")
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The part's picture. In dark mode the one drawn on the dark palette when there is one; a part not opened since dark pictures
    /// began has only the light one, which is what shows until it is opened again.
    static func image(for url: URL, dark: Bool = false) async -> NSImage? {
        if dark, let picture = await load(url, dark: true) { return picture }
        return await load(url, dark: false)
    }

    /// Parts already tried this session, so one that cannot be drawn (an empty part) is not tried at every visit of the Start page.
    private static var attempted = Set<URL>()
    /// One part at a time: each is built and drawn, which is not cheap.
    private static var busy = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    /// Draws the part's dark picture now when it has none (or the file is newer than it): a part not opened since dark pictures began.
    /// Builds the part without a window, as the part's own window would. Returns true when a new picture was kept.
    static func makeDarkIfNeeded(for url: URL) async -> Bool {
        guard let kept = keptFile(for: url, dark: true) else { return false }
        if let keptDate = modified(kept), keptDate >= (modified(url) ?? .distantPast) { return false }
        guard attempted.insert(url).inserted else { return false }
        // Unstructured, so leaving the Start page (which cancels the card's task) does not leave a half-made picture.
        return await Task { @MainActor () -> Bool in
            if busy { await withCheckedContinuation { waiting.append($0) } } else { busy = true }
            defer { if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() } }
            guard let data = try? await Task.detached(priority: .utility, operation: { try Data(contentsOf: url) }).value,
                  let document = try? CADDocument.decode(data) else { return false }
            let model = DocumentModel(document: document)
            await model.rebuilt()
            var options = SnapshotOptions()
            options.dark = true
            guard let image = try? await ViewportSnapshot.render(model, direction: .iso, width: 512, height: 512, axes: false, options: options) else { return false }
            store(image.png, for: url, dark: true)
            return true
        }.value
    }

    private static func load(_ url: URL, dark: Bool) async -> NSImage? {
        let kept = keptFile(for: url, dark: dark)
        let fileDate = modified(url)
        let keptDate = kept.flatMap(modified)
        let key = "\(url.path)|\(dark)|\(fileDate?.timeIntervalSince1970 ?? 0)|\(keptDate?.timeIntervalSince1970 ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let png = await Task.detached(priority: .utility) { () -> Data? in
            let drawn = kept.flatMap { try? Data(contentsOf: $0) }
            // The dark picture exists only as drawn at an open; the light one may also be the picture stored in the file.
            if dark { return drawn }
            let own = (try? Data(contentsOf: url)).flatMap { CADDocument.thumbnail(in: $0) }
            // The picture drawn at the last open wins, unless the file was saved after it with a picture of its own.
            if let drawn, own == nil || (keptDate ?? .distantPast) >= (fileDate ?? .distantPast) { return drawn }
            return own ?? drawn
        }.value
        guard let png, let image = NSImage(data: png) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Recently opened and saved parts. macOS's own list (File › Open Recent) is told too, but the
/// Start page keeps its own as well, so it shows recent parts even when the system list is
/// empty (recent items turned off, or a part that macOS never recorded).
enum RecentParts {
    static let key = "recentParts"
    /// Parts removed from the list by the user; macOS's list can't drop single items, so these are
    /// hidden from it until the part is opened again.
    static let removedKey = "recentPartsRemoved"
    static let limit = 20

    /// Called when a part window shows a file (opened, or saved for the first time).
    @MainActor static func note(_ url: URL) {
        guard url.isFileURL else { return }
        var paths = stored.filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(limit)), forKey: key)
        UserDefaults.standard.set(removed.filter { $0 != url.path }, forKey: removedKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    static func remove(_ url: URL) {
        UserDefaults.standard.set(stored.filter { $0 != url.path }, forKey: key)
        UserDefaults.standard.set(Array((removed + [url.path]).suffix(100)), forKey: removedKey)
    }

    /// Our list first (most recent first), then any from macOS's list not already in it; files
    /// that no longer exist are left out.
    @MainActor static var urls: [URL] {
        var seen = Set(removed)
        let all = stored.map { URL(fileURLWithPath: $0) } + NSDocumentController.shared.recentDocumentURLs
        let existing = all.filter { url in
            FileManager.default.fileExists(atPath: url.path) && seen.insert(url.standardizedFileURL.path).inserted
        }
        return Array(existing.prefix(limit))
    }

    private static var stored: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    private static var removed: [String] { UserDefaults.standard.stringArray(forKey: removedKey) ?? [] }
}
