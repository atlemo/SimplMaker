// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import SimplMaker

@Suite struct ClaudeDesktopConfigTests {
    private let relay = "/Applications/SimplMaker.app/Contents/Helpers/simplmaker-mcp"

    private func parse(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func command(_ root: [String: Any]) -> String? {
        ((root["mcpServers"] as? [String: Any])?["simplmaker"] as? [String: Any])?["command"] as? String
    }

    @Test func aNewFileGetsJustOurServer() throws {
        let root = try parse(ClaudeDesktopConfig.merging(command: relay, into: nil))
        #expect(command(root) == relay)
        #expect(root.keys.sorted() == ["mcpServers"])
        let empty = try parse(ClaudeDesktopConfig.merging(command: relay, into: Data("  \n".utf8)))
        #expect(command(empty) == relay, "a blank file counts as none")
    }

    @Test func everythingElseInTheFileIsKept() throws {
        let existing = #"{"theme":"dark","mcpServers":{"other":{"command":"npx","args":["x","y"],"env":{"A":"1"}}},"count":3}"#
        let root = try parse(ClaudeDesktopConfig.merging(command: relay, into: Data(existing.utf8)))
        #expect(command(root) == relay && root["theme"] as? String == "dark" && root["count"] as? Int == 3)
        let other = try #require((root["mcpServers"] as? [String: Any])?["other"] as? [String: Any])
        #expect(other["command"] as? String == "npx" && other["args"] as? [String] == ["x", "y"] && (other["env"] as? [String: String]) == ["A": "1"])
    }

    @Test func anOldEntryOfOursIsUpdatedNotDuplicated() throws {
        let existing = #"{"mcpServers":{"simplmaker":{"command":"/old/path","args":["--x"]}}}"#
        let root = try parse(ClaudeDesktopConfig.merging(command: relay, into: Data(existing.utf8)))
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers.count == 1 && command(root) == relay)
        #expect((servers["simplmaker"] as? [String: Any])?["args"] == nil, "the entry is ours, so it is replaced whole")
    }

    @Test func aFileThatIsNotWhatWeExpectIsNotTouched() {
        for bad in ["{not json", "[1,2]", #"{"mcpServers": 5}"#, #"{"mcpServers": ["a"]}"#] {
            #expect(throws: ClaudeDesktopConfig.Failure.self, "\(bad)") { try ClaudeDesktopConfig.merging(command: relay, into: Data(bad.utf8)) }
        }
    }

    @Test func slashesInThePathAreNotEscaped() throws {
        let text = String(decoding: try ClaudeDesktopConfig.merging(command: relay, into: nil), as: UTF8.self)
        #expect(text.contains("\"/Applications/SimplMaker.app/Contents/Helpers/simplmaker-mcp\""))
        #expect(ClaudeDesktopConfig.snippet(command: relay).contains(relay))
    }

    @Test func installingWritesTheFileAndKeepsTheOriginalAsideOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Claude/claude_desktop_config.json")
        #expect(!ClaudeDesktopConfig.isInstalled(at: file))
        try ClaudeDesktopConfig.install(command: relay, at: file)  // no file yet: made, and the folder with it
        #expect(ClaudeDesktopConfig.isInstalled(at: file))
        let backup = file.appendingPathExtension("simplmaker-backup")
        #expect(!FileManager.default.fileExists(atPath: backup.path), "nothing to back up")

        let original = #"{"theme":"dark"}"#
        try Data(original.utf8).write(to: file)
        try ClaudeDesktopConfig.install(command: relay, at: file)
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        try ClaudeDesktopConfig.install(command: "/new/path", at: file)  // again: the first backup stays
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        #expect(command(try parse(Data(contentsOf: file))) == "/new/path")
        #expect(try parse(Data(contentsOf: file))["theme"] as? String == "dark")
    }
}
