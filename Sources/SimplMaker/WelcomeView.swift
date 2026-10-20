// The welcome window shown at launch, in the style of Xcode's: the app icon and the ways to start
// on the left, recently opened parts on the right.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import CADCore
import SwiftUI

/// Lets AppKit code (the app delegate) open SwiftUI windows once a view has captured the action.
@MainActor
enum AppWindows {
    static let welcomeID = "welcome"
    static let licenseID = "license"
    static let settingsID = "settings"
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
    @AppStorage(Preferences.tutorialCompleted) private var tutorialCompleted = false
    @State private var recents: [URL] = []
    @State private var selected: URL?
    /// The part being opened, which shows a spinner.
    @State private var opening: URL?
    /// The recent list has the keyboard from the start (for ↑ ↓ Return), not the first button.
    @FocusState private var listFocused: Bool
    @State private var error: String?

    var body: some View {
        HStack(spacing: 0) {
            actions
                .frame(width: 520)
                .frame(maxHeight: .infinity)
                .background(DS.windowBackground)
            recentList
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(DS.underPageBackground)
        }
        .frame(height: 580)
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
                Text("Welcome to SimplMaker")
                    .font(.system(size: 32, weight: .regular))
                Text(Self.versionText)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, DS.Spacing.space9)
            .padding(.bottom, DS.Spacing.space8)

            VStack(alignment: .leading, spacing: 18) {
                // New users see the tutorial first; once it's been finished it moves down the list.
                if !tutorialCompleted { tutorialAction }
                WelcomeAction(title: "Create a new part", subtitle: "Start with an empty part and sketch on a plane.",
                              systemImage: "plus.square") { newDocument { CADFile() } }
                WelcomeAction(title: "Open the demo part", subtitle: "A plate with a hole, fillets and a chamfer to poke at.",
                              systemImage: "cube") { newDocument { CADFile(document: .demo()) } }
                WelcomeAction(title: "Open an existing part…", subtitle: "Open a .simplmaker file on your Mac.",
                              systemImage: "folder") { NSDocumentController.shared.openDocument(nil) }
                if tutorialCompleted { tutorialAction }
            }
            .padding(.horizontal, 52)

            Spacer(minLength: DS.Spacing.space6)

            LicenseNotice(license: .shared)
                .frame(maxWidth: .infinity)
                .padding(.bottom, DS.Spacing.space3)

            Toggle("Show this window when SimplMaker launches", isOn: $showWelcome)
                .toggleStyle(.checkbox)
                .font(.callout)
                .padding(.horizontal, DS.Spacing.windowMargin)
                .padding(.bottom, DS.Spacing.windowMargin)
        }
    }

    private var tutorialAction: some View {
        WelcomeAction(title: tutorialCompleted ? "Do the tutorial again" : "Make your first part",
                      subtitle: "A guided tutorial: make a desk organizer, step by step.",
                      systemImage: "graduationcap") { newDocument { CADFile(tutorial: true) } }
    }

    static var versionText: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return "Development build" }
        return "Version \(version)"
    }

    // MARK: right: recent parts

    @ViewBuilder private var recentList: some View {
        if recents.isEmpty {
            VStack(spacing: 6) {
                Text("No Recent Parts").font(.title3).foregroundStyle(.secondary)
                Text("Parts you open or save will show up here. For now it is very quiet.").font(.callout).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Drawn here rather than with List: a List shows its selection in grey until it has
            // keyboard focus, and its table doesn't take the click that brings the window forward,
            // so a double-click could select without opening. Here a click selects at once, the
            // second click of a double-click opens, and ↑ ↓ Return work as in a list.
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(recents, id: \.self) { url in
                        RecentRow(url: url, selected: selected == url, opening: opening == url)
                            .onTapGesture { click(url) }
                            .contextMenu {
                                Button("Open") { open(url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Divider()
                                Button("Remove from Recent Parts") {
                                    RecentParts.remove(url)
                                    reloadRecents()
                                }
                            }
                            .accessibilityAction { open(url) }
                    }
                }
                .padding(DS.Spacing.space3)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onAppear { listFocused = true }
            .onKeyPress(.upArrow) { step(-1) }
            .onKeyPress(.downArrow) { step(1) }
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

    private func reloadRecents() {
        recents = RecentParts.urls
    }

    private func open(_ url: URL) {
        guard opening == nil else { return }
        opening = url
        Task {
            defer { opening = nil }
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

/// A recent part: file icon, name, and where it lives; blue when selected, as in a source list.
private struct RecentRow: View {
    @Environment(\.accent) private var accent
    let url: URL
    let selected: Bool
    let opening: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                Text(Self.abbreviated(url.deletingLastPathComponent())).font(.callout)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if opening { ProgressView().controlSize(.small).tint(selected ? .white : nil) }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, DS.Spacing.space3)
        .padding(.vertical, 5)
        .background(selected ? accent : hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(url.path)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
