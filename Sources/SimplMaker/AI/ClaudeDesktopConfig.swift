// Claude Desktop starts MCP servers listed in its own config file. This adds SimplMaker's relay to that list, only
// when the user asks (Settings ▸ AI ▸ Add to Claude Desktop), and without disturbing what else is in the file: the other
// servers and settings are kept, and the original is copied aside the first time. A file that isn't valid JSON is left alone.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

enum ClaudeDesktopConfig {
    struct Failure: Error, CustomStringConvertible { var description: String }

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude_desktop_config.json")
    }

    /// The entry itself, as JSON text a user can paste by hand.
    static func snippet(command: String) -> String {
        let object: [String: Any] = ["mcpServers": ["simplmaker": ["command": command]]]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
    }

    /// `existing` (nil when there is no file yet) with the SimplMaker server added or updated.
    static func merging(command: String, into existing: Data?) throws -> Data {
        var root: [String: Any] = [:]
        if let existing, !existing.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw Failure(description: "Claude Desktop's configuration file isn't valid JSON, so SimplMaker left it alone.")
            }
            root = parsed
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if root["mcpServers"] != nil, root["mcpServers"] as? [String: Any] == nil {
            throw Failure(description: "\"mcpServers\" in Claude Desktop's configuration file isn't a list of servers, so SimplMaker left it alone.")
        }
        servers["simplmaker"] = ["command": command]
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Adds the server to the file on disk (made if needed). The original is kept as `<name>.simplmaker-backup`, once.
    static func install(command: String, at file: URL = url) throws {
        let existing = try? Data(contentsOf: file)
        let merged = try merging(command: command, into: existing)
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if existing != nil {
            let backup = file.appendingPathExtension("simplmaker-backup")
            if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: file, to: backup) }
        }
        try merged.write(to: file, options: .atomic)
    }

    /// Whether the file already lists SimplMaker.
    static func isInstalled(at file: URL = url) -> Bool {
        guard let data = try? Data(contentsOf: file), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (root["mcpServers"] as? [String: Any])?["simplmaker"] != nil
    }
}

extension AIConnection {
    /// The relay program: inside the installed app, or next to the executable in a build run from the command line.
    /// Nil when there is none (a build from Xcode makes only the app).
    static var relayPath: String? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/simplmaker-mcp"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("simplmaker-mcp"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }
}
