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
        .frame(height: 460)
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
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 128, height: 128)
                    .padding(.bottom, 8)
                Text("Welcome to SimplCAD")
                    .font(.system(size: 36, weight: .regular))
                Text(Self.versionText)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 18) {
                WelcomeAction(title: "Create a new part", subtitle: "Start with an empty part and sketch on a plane.",
                              systemImage: "plus.square") { newDocument { CADFile() } }
                WelcomeAction(title: "Open the demo part", subtitle: "A plate with a hole, fillets and a chamfer to explore.",
                              systemImage: "cube") { newDocument { CADFile(document: .demo()) } }
                WelcomeAction(title: "Open an existing part…", subtitle: "Open a .simplcad file on your Mac.",
                              systemImage: "folder") { NSDocumentController.shared.openDocument(nil) }
            }
            .padding(.horizontal, 52)

            Spacer(minLength: 16)

            Toggle("Show this window when SimplCAD launches", isOn: $showWelcome)
                .toggleStyle(.checkbox)
                .font(.callout)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
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
        recents = NSDocumentController.shared.recentDocumentURLs
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
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
