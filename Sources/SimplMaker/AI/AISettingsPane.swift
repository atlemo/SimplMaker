// Settings ▸ AI: turn the interface on, see whether it is running, and copy what a client needs to connect.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import SwiftUI

struct AISettingsPane: View {
    let ai: AIConnection
    @State private var showToken = false
    @State private var confirmNewToken = false
    @State private var copied: String?
    @State private var desktopMessage: String?

    init(ai: AIConnection = .shared) { self.ai = ai }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {  // one row, so no divider between them
                    Toggle("Let AI assistants connect to SimplMaker", isOn: Binding(get: { ai.isEnabled }, set: { ai.setEnabled($0) }))
                    Text("An assistant you connect, such as Claude, can see the parts you have open in SimplMaker and change them while you watch. Each change is one step in Undo, and the status bar says when an assistant is working. It can't see anything else on your Mac. Only programs on this Mac can connect, and only with the secret below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                statusRow
            }
            if let command = ai.claudeCodeCommand {
                Section("Claude Code") {
                    Text("Paste this into a terminal once:")
                        .font(.caption).foregroundStyle(.secondary)
                    // The secret stays hidden here as in the Secret section below; the button copies the whole command.
                    codeBox(showToken ? command : command.replacingOccurrences(of: ai.token, with: "<secret>"))
                    copyButton("Copy command", text: command, id: "command")
                }
            }
            if ai.isEnabled, let relay = AIConnection.relayPath {
                Section("Claude Desktop") {
                    Text("Claude Desktop starts SimplMaker's helper program itself. Add it once, then restart Claude Desktop:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(ClaudeDesktopConfig.isInstalled() ? "Update Claude Desktop" : "Add to Claude Desktop") { addToDesktop(relay) }
                        copyButton("Copy configuration", text: ClaudeDesktopConfig.snippet(command: relay), id: "desktop")
                    }
                    if let desktopMessage { Text(desktopMessage).font(.caption).foregroundStyle(.secondary) }
                    Text("This edits Claude Desktop's own settings file; the original is kept next to it as a backup. The helper needs SimplMaker to be running with this switch on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if ai.isEnabled {
                Section("Secret") {
                    HStack {
                        Text(showToken ? ai.token : String(repeating: "•", count: 24))
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                    }
                    HStack {
                        copyButton("Copy secret", text: ai.token, id: "token")
                        Button("Make a New Secret…") { confirmNewToken = true }
                    }
                    Text("Anyone who has the secret and is on this Mac can read and change your open parts, so keep it to yourself. A new secret locks out every connection made with the old one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await ai.refresh() }  // the license may have changed since the window was last open
        .confirmationDialog("Make a new secret?", isPresented: $confirmNewToken) {
            Button("Make a New Secret", role: .destructive) { ai.regenerateToken(); copied = nil }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connections made with the old secret stop working until you give them the new one.")
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch ai.status {
        case .off:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .running(let port):
            Label("On, listening on 127.0.0.1:\(String(port))", systemImage: "circle.fill").foregroundStyle(.green)
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

    private func addToDesktop(_ relay: String) {
        do {
            try ClaudeDesktopConfig.install(command: relay)
            desktopMessage = "Added. Quit and reopen Claude Desktop to use it."
        } catch {
            desktopMessage = "\(error) Copy the configuration and add it by hand instead."
        }
    }

    private func codeBox(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private func copyButton(_ title: String, text: String, id: String) -> some View {
        Button(copied == id ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = id
        }
    }
}
