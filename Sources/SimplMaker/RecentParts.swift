// The recent parts: the list the Start page shows, its rows, and the record of parts opened and saved.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
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
        .task(id: url) {
            picture = await RecentPictures.image(for: url)
            loaded = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// "~/Desktop" rather than "/Users/name/Desktop".
    static func abbreviated(_ folder: URL) -> String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }
}

/// The pictures stored in the recent parts' files, read once per version of the file.
@MainActor enum RecentPictures {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for url: URL) async -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let png = await Task.detached(priority: .utility) { () -> Data? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return CADDocument.thumbnail(in: data)
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
    static let limit = 12

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
        return all.filter { url in
            FileManager.default.fileExists(atPath: url.path) && seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    private static var stored: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    private static var removed: [String] { UserDefaults.standard.stringArray(forKey: removedKey) ?? [] }
}
