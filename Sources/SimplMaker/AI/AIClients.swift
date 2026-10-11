// The assistants a user may connect, found on this Mac, and what is known about the ones that have connected: so Settings can
// offer a "Connect" for what is installed instead of instructions for everything.
// Copyright © 2026 Atle Mo. All rights reserved.
import AppKit
import Foundation

/// An assistant that has said hello to the server.
struct AIClientActivity: Equatable, Identifiable {
    /// What the client calls itself ("claude-ai").
    var rawName: String
    var version: String
    var lastSeen: Date
    var id: String { rawName }

    /// What a person calls it.
    var displayName: String { AIClients.displayName(for: rawName) }
}

enum AIClients {
    static let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    /// "claude-ai" is how Claude Desktop (and claude.ai) introduce themselves, "claude-code" is Claude Code.
    static func displayName(for rawName: String) -> String {
        let n = rawName.lowercased()
        if n.contains("claude-code") || n.contains("claude code") { return "Claude Code" }
        // Claude Desktop's agent mode introduces itself as "local-agent-mode-<server name>".
        if n.hasPrefix("local-agent-mode") { return "Claude Desktop" }
        if n.contains("claude-ai") || n.contains("claude desktop") || n.contains("claude") { return "Claude Desktop" }
        return rawName
    }

    /// Claude Desktop, if it is installed.
    static func claudeDesktopURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeDesktopBundleID)
    }

    /// The Claude Code program, if it is where the installers put it. Several places: the native installer, Homebrew and npm.
    static func claudeCodePath(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        let candidates = [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            home.appendingPathComponent(".claude/local/claude").path,
            home.appendingPathComponent(".npm-global/bin/claude").path,
        ]
        return candidates.first(where: isExecutable)
    }

    /// Quotes a path for a shell command (single quotes; a quote inside is closed, escaped and reopened).
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command that adds SimplMaker to Claude Code. With the relay program there is nothing secret in it; without, it names the
    /// local address and the secret.
    static func claudeCodeCommand(relay: String?, endpoint: String?, token: String) -> String? {
        if let relay { return "claude mcp add --scope user \(ClaudeDesktopConfig.serverName) -- \(shellQuoted(relay))" }
        guard let endpoint else { return nil }
        return "claude mcp add --scope user --transport http \(ClaudeDesktopConfig.serverName) \(endpoint) --header \"Authorization: Bearer \(token)\""
    }

    /// What to ask an assistant first.
    static let examplePrompts = [
        "What's in my open SimplMaker part?",
        "Make a key ring with the name Jane Doe on it, about 35 mm long and 3 mm thick.",
        "Create a 60 × 40 × 20 mm box, then make it 10 mm taller.",
    ]
}

/// Quits and reopens Claude Desktop so it reads its settings again.
@MainActor
enum ClaudeDesktopApp {
    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: AIClients.claudeDesktopBundleID).isEmpty
    }

    /// Asks Claude to quit (it can say no, or ask to save), waits a few seconds, then opens it again. False if it didn't quit.
    static func restart() async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: AIClients.claudeDesktopBundleID)
        for app in running { app.terminate() }
        for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) { try? await Task.sleep(for: .milliseconds(100)) }
        guard running.allSatisfy(\.isTerminated) else { return false }
        return open()
    }

    @discardableResult
    static func open() -> Bool {
        guard let url = AIClients.claudeDesktopURL() else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        return true
    }
}

/// Claude Code keeps the servers added with `claude mcp add --scope user` in its own file. Settings only looks for SimplMaker's entry (its
/// name and the program it starts), to say "Added" instead of offering the command again; nothing else in the file is read or kept.
enum ClaudeCodeConfig {
    struct Registration: Equatable {
        /// The program it starts; nil for a server reached over the network.
        var command: String?
    }

    static var url: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }

    /// SimplMaker's entry in the user-level list, if there is one under the current name.
    static func registration(at file: URL = url) -> Registration? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (root["mcpServers"] as? [String: Any])?[ClaudeDesktopConfig.serverName] as? [String: Any] else { return nil }
        return Registration(command: entry["command"] as? String)
    }

    /// Whether the entry will start `relay` (an entry for a moved or replaced app would fail, so it doesn't count), or is the network version.
    static func isCurrent(_ registration: Registration?, relay: String?) -> Bool {
        guard let registration else { return false }
        guard let relay, let command = registration.command else { return true }
        return command == relay
    }

    /// The command to paste: when an entry for another copy of the app is there, it is removed first (`claude mcp add` refuses a name it has).
    static func command(add: String, replacing existing: Registration?) -> String {
        existing == nil ? add : "claude mcp remove --scope user \(ClaudeDesktopConfig.serverName); \(add)"
    }
}
