// Settings ▸ AI: connect an assistant in one click. It finds which Claude apps are installed and offers a Connect for each,
// turns the interface on by itself, and shows when an assistant has connected. Everything technical (the address, the secret,
// the command for a terminal) is under Advanced.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import SwiftUI

struct AISettingsPane: View {
    let ai: AIConnection
    @State private var showToken = false
    @State private var confirmNewToken = false
    @State private var confirmRestart = false
    @State private var copied: String?
    @State private var desktop = DesktopState.idle
    /// SimplMaker's entry in Claude Code's list, read when the pane opens and whenever the app is brought back to the front.
    @State private var codeRegistration: ClaudeCodeConfig.Registration?

    enum DesktopState: Equatable {
        case idle, working, restarting
        /// The settings file has been updated; Claude Desktop reads it when it starts.
        case added
        case failed(String)
    }

    init(ai: AIConnection = .shared) { self.ai = ai }

    private var relay: String? { AIConnection.relayPath }
    private var desktopURL: URL? { AIClients.claudeDesktopURL() }
    private var codePath: String? { AIClients.claudeCodePath() }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {  // one row, so no divider between them
                    Toggle("Let AI assistants work with SimplMaker", isOn: Binding(get: { ai.isEnabled }, set: { ai.setEnabled($0) }))
                    Text("An assistant such as Claude can see the parts you have open and change them while you watch. Each change is one step in Undo, and the status bar says when it is working. It can't see anything else on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                statusRow
            }

            if ai.isAvailable {
                Section("Connect an assistant") {
                    if desktopURL == nil && codePath == nil { nothingInstalled }
                    if desktopURL != nil { desktopRow }
                    if let codePath { codeRow(codePath) }
                }
                Section("Then try asking") {
                    ForEach(AIClients.examplePrompts, id: \.self) { prompt in
                        HStack(alignment: .firstTextBaseline) {
                            Text("“\(prompt)”").font(.callout)
                            Spacer(minLength: 8)
                            copyButton(icon: true, text: prompt, id: prompt)
                        }
                    }
                    Text("The first time an assistant changes your part it asks you for permission. Choose Always allow to stop it asking each time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    DisclosureGroup("Advanced") { advanced }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await ai.refresh()  // the license may have changed since the window was last open
            codeRegistration = await Task.detached { ClaudeCodeConfig.registration() }.value
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { codeRegistration = await Task.detached { ClaudeCodeConfig.registration() }.value }  // back from pasting the command in a terminal
        }
        .confirmationDialog("Make a new secret?", isPresented: $confirmNewToken) {
            Button("Make a New Secret", role: .destructive) { ai.regenerateToken(); copied = nil }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connections made with the old secret stop working until you give them the new one.")
        }
        .confirmationDialog("Quit and reopen Claude?", isPresented: $confirmRestart) {
            Button("Quit and Reopen Claude") { restartDesktop() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Claude keeps your conversations, but anything you were in the middle of typing may be lost.")
        }
    }

    // MARK: status

    @ViewBuilder private var statusRow: some View {
        switch ai.status {
        case .off:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .running:
            if let latest = ai.clients.first {
                Label("On · \(latest.displayName) is connected", systemImage: "circle.fill").foregroundStyle(.green)
            } else {
                Label("On, waiting for an assistant to connect", systemImage: "circle.fill").foregroundStyle(.green)
            }
        case .needsLicense:
            VStack(alignment: .leading, spacing: 4) {
                Label("Waiting for a license", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("AI connections need a valid license or a running trial. Choose SimplMaker ▸ License… to buy or enter one; this starts by itself once it is valid.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 4) {
                Label("Could not start", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: assistants

    private var nothingInstalled: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Claude app found on this Mac.").font(.callout)
            Text("Install Claude, then come back here and connect it.").font(.caption).foregroundStyle(.secondary)
            Link("Get Claude…", destination: URL(string: "https://claude.ai/download")!)
        }
    }

    private func connectedText(_ name: String) -> (text: String, connected: Bool)? {
        ai.lastConnected(name) != nil ? ("Connected", true) : nil
    }

    private var desktopRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Desktop")
                desktopSubtitle
            }
            Spacer(minLength: 8)
            if desktop == .working || desktop == .restarting { ProgressView().controlSize(.small) }
            desktopButtons
        }
    }

    @ViewBuilder private var desktopSubtitle: some View {
        if let seen = ai.lastConnected("Claude Desktop") {
            Text("Connected \(seen, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.green)
        } else if case .failed(let why) = desktop {
            Text(why).font(.caption).foregroundStyle(.red)
        } else if desktop == .added || ClaudeDesktopConfig.isInstalled(command: relay) {
            Text(ClaudeDesktopApp.isRunning ? "Added. Restart Claude to finish." : "Added. Open Claude to start using it.")
                .font(.caption).foregroundStyle(.secondary)
        } else if relay == nil {
            Text("Needs the packaged SimplMaker app.").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Not connected yet.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var desktopButtons: some View {
        if let relay {
            let connected = ai.lastConnected("Claude Desktop") != nil
            let added = desktop == .added || ClaudeDesktopConfig.isInstalled(command: relay)
            if connected {
                Button("Connected") {}.buttonStyle(.bordered).disabled(true)
            } else if added {
                Button(ClaudeDesktopApp.isRunning ? "Restart Claude" : "Open Claude") {
                    if ClaudeDesktopApp.isRunning { confirmRestart = true } else { ClaudeDesktopApp.open() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(desktop == .restarting)
            } else {
                Button("Connect") { connectDesktop(relay) }
                    .buttonStyle(.borderedProminent)
                    .disabled(desktop == .working)
            }
        }
    }

    private func codeRow(_ path: String) -> some View {
        let add = AIClients.claudeCodeCommand(relay: relay, endpoint: ai.endpoint, token: ai.token)
        let connected = ai.lastConnected("Claude Code") != nil
        let current = ClaudeCodeConfig.isCurrent(codeRegistration, relay: relay)
        let stale = codeRegistration != nil && !current
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code")
                if let seen = ai.lastConnected("Claude Code") {
                    Text("Connected \(seen, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.green)
                } else if current {
                    Text("Added. It connects when you start Claude Code.").font(.caption).foregroundStyle(.secondary)
                } else if stale {
                    Text("Set up for another copy of SimplMaker. Copy the command to update it.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Copy the command and paste it into a terminal once.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if connected {
                Button("Connected") {}.buttonStyle(.bordered).disabled(true)
            } else if current {
                Button("Added") {}.buttonStyle(.bordered).disabled(true)
            } else if let add {
                copyButton(title: "Copy Command", text: ClaudeCodeConfig.command(add: add, replacing: codeRegistration), id: "code", prominent: true,
                           preparing: { ai.setEnabled(true) })
            }
        }
    }

    // MARK: advanced

    @ViewBuilder private var advanced: some View {
        if let endpoint = ai.endpoint {
            LabeledContent("Address") { Text(endpoint).font(.system(.callout, design: .monospaced)).textSelection(.enabled) }
        }
        LabeledContent("Secret") {
            HStack {
                Text(showToken ? ai.token : String(repeating: "•", count: 16))
                    .font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Button(showToken ? "Hide" : "Show") { showToken.toggle() }
            }
        }
        HStack {
            copyButton(title: "Copy Secret", text: ai.token, id: "token")
            Button("Make a New Secret…") { confirmNewToken = true }
        }
        if let relay {
            copyButton(title: "Copy Claude Desktop Configuration", text: ClaudeDesktopConfig.snippet(command: relay), id: "desktop")
            Button("Write Claude Desktop Configuration Again") { connectDesktop(relay) }.disabled(desktop == .working)
        }
        if let http = AIClients.claudeCodeCommand(relay: nil, endpoint: ai.endpoint, token: ai.token) {
            copyButton(title: "Copy Claude Code Command (network version)", text: http, id: "http")
        }
        Text("The secret keeps other programs and websites from using the connection. Anyone who has it and is on this Mac can read and change your open parts. A new secret locks out every connection made with the old one.")
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: actions

    private func connectDesktop(_ relay: String) {
        desktop = .working
        Task {
            ai.setEnabled(true)
            await ai.refresh()
            do {
                try ClaudeDesktopConfig.install(command: relay)
                desktop = .added
            } catch {
                desktop = .failed("\(error)")
            }
        }
    }

    private func restartDesktop() {
        desktop = .restarting
        Task {
            let reopened = await ClaudeDesktopApp.restart()
            desktop = reopened ? .added : .failed("Claude didn't close. Quit it yourself (⌘Q) and open it again.")
        }
    }

    @ViewBuilder
    private func copyButton(title: String? = nil, icon: Bool = false, text: String, id: String, prominent: Bool = false,
                            preparing: (() -> Void)? = nil) -> some View {
        let copy = {
            preparing?()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = id
        }
        let label = copied == id ? "Copied" : (title ?? "Copy")
        if icon {
            Button(action: copy) { Image(systemName: copied == id ? "checkmark" : "doc.on.doc") }.buttonStyle(.borderless).help("Copy")
        } else if prominent {
            Button(label, action: copy).buttonStyle(.borderedProminent)
        } else {
            Button(label, action: copy).buttonStyle(.bordered)
        }
    }
}
