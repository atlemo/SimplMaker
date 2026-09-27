// The welcome window shown at launch, in the style of Xcode's: the app icon and the ways to start
// on the left, recently opened parts on the right.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CADCore
import SwiftUI

/// Lets AppKit code (the app delegate) open SwiftUI windows once a view has captured the action.
@MainActor
enum AppWindows {
    static let welcomeID = "welcome"
    static var openWindow: OpenWindowAction?

    /// Shows the welcome window, or a new document if no SwiftUI view has appeared yet.
    static func showWelcome() {
        if let openWindow { openWindow(id: welcomeID) } else { NSDocumentController.shared.newDocument(nil) }
    }
}

struct WelcomeView: View {
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(Preferences.showWelcome) private var showWelcome = true
    @State private var recents: [URL] = []
    @State private var selected: URL?
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            actions
                .frame(width: 520)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            recentList
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
        }
        .frame(height: 520)
        .onAppear { AppWindows.openWindow = openWindow; reloadRecents() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reloadRecents() }
        .alert("The part couldn't be opened", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: left: icon, title, actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: DS.Spacing.labelGap) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 112, height: 112)
                    .padding(.bottom, DS.Spacing.space3)
                Text("Welcome to SimplCAD")
                    .font(.system(size: 32, weight: .regular))
                Text(Self.versionText)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, DS.Spacing.space9)
            .padding(.bottom, DS.Spacing.space8)

            VStack(alignment: .leading, spacing: 18) {
                WelcomeAction(title: "Create a new part", subtitle: "Start with an empty part and sketch on a plane.",
                              systemImage: "plus.square") { newDocument { CADFile() } }
                WelcomeAction(title: "Open the demo part", subtitle: "A plate with a hole, fillets and a chamfer to explore.",
                              systemImage: "cube") { newDocument { CADFile(document: .demo()) } }
                WelcomeAction(title: "Open an existing part…", subtitle: "Open a .simplcad file on your Mac.",
                              systemImage: "folder") { NSDocumentController.shared.openDocument(nil) }
            }
            .padding(.horizontal, 52)

            Spacer(minLength: DS.Spacing.space6)

            Toggle("Show this window when SimplCAD launches", isOn: $showWelcome)
                .toggleStyle(.checkbox)
                .font(.callout)
                .padding(.horizontal, DS.Spacing.windowMargin)
                .padding(.bottom, DS.Spacing.windowMargin)
        }
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        if let build = info?["CFBundleVersion"] as? String, build != version { return "Version \(version) (\(build))" }
        return "Version \(version)"
    }

    // MARK: right: recent parts

    @ViewBuilder private var recentList: some View {
        if recents.isEmpty {
            VStack(spacing: 6) {
                Text("No Recent Parts").font(.title3).foregroundStyle(.secondary)
                Text("Parts you open or save will appear here.").font(.callout).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(recents, id: \.self, selection: $selected) { url in
                RecentRow(url: url)
                    .tag(url)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(url) }
                    .contextMenu {
                        Button("Open") { open(url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Divider()
                        Button("Remove from Recent Parts") {
                            RecentParts.remove(url)
                            reloadRecents()
                        }
                    }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onKeyPress(.return) {
                guard let selected else { return .ignored }
                open(selected)
                return .handled
            }
        }
    }

    private func reloadRecents() {
        recents = RecentParts.urls
    }

    private func open(_ url: URL) {
        Task {
            do {
                try await openDocument(at: url)
                dismissWindow(id: AppWindows.welcomeID)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// One of the big actions on the left: icon, bold title and a one-line description.
private struct WelcomeAction: View {
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
                    .foregroundStyle(Color.accentColor)
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

/// A recent part: file icon, name, and where it lives.
private struct RecentRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                Text(Self.abbreviated(url.deletingLastPathComponent())).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
        .help(url.path)
    }

    /// "~/Desktop" rather than "/Users/name/Desktop".
    static func abbreviated(_ folder: URL) -> String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Recently opened and saved parts. macOS's own list (File › Open Recent) is told too, but the
/// welcome window keeps its own as well, so it shows recent parts even when the system list is
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
