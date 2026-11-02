// Where SimplMaker tells a connecting program how to reach it: the port and the secret. The relay that Claude Desktop
// launches (a separate small program) reads it, because it can't ask the running app anything before it has the
// secret. The file lives in the user's Application Support folder, readable by this user only (0600), the same
// trust as the user's own files; the token also keeps other websites and other users out. A file left behind by an app
// that quit says `running: false`, and the relay confirms by trying to connect.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

struct MCPConnectionInfo: Codable, Equatable {
    var port: Int
    var token: String
    var pid: Int32
    var running: Bool
    var version: String
}

struct MCPConnectionFile {
    let url: URL

    /// ~/Library/Application Support/SimplMaker/mcp-connection.json
    static var standard: MCPConnectionFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return MCPConnectionFile(url: base.appendingPathComponent("SimplMaker", isDirectory: true).appendingPathComponent("mcp-connection.json"))
    }

    func read() -> MCPConnectionInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MCPConnectionInfo.self, from: data)
    }

    /// Replaces the file in one step, created readable by the owner alone (never briefly by anyone else).
    func write(_ info: MCPConnectionInfo) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = directory.appendingPathComponent(".mcp-connection.\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: try encoder.encode(info),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The app is no longer listening; the token stays so the next start keeps the connection a user set up.
    func markStopped() {
        guard var info = read() else { return }
        info.running = false
        try? write(info)
    }

    /// 32 random bytes as URL-safe text.
    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess, "no randomness")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
