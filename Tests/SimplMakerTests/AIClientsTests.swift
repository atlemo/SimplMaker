// Finding the assistants a user has, the command for Claude Code, and showing that an assistant has connected.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AIClientsTests {
    @Test func clientsAreNamedTheWayAPersonWouldName() {
        #expect(AIClients.displayName(for: "claude-ai") == "Claude Desktop")
        #expect(AIClients.displayName(for: "Claude Desktop") == "Claude Desktop")
        #expect(AIClients.displayName(for: "local-agent-mode-SimplMaker") == "Claude Desktop", "Claude Desktop's agent mode")
        #expect(AIClients.displayName(for: "claude-code") == "Claude Code")
        #expect(AIClients.displayName(for: "claude-code-vscode") == "Claude Code")
        #expect(AIClients.displayName(for: "mcp-inspector") == "mcp-inspector", "an unknown client keeps its own name")
    }

    @Test func claudeCodeIsFoundWhereTheInstallersPutIt() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(AIClients.claudeCodePath(home: home, isExecutable: { $0 == "/Users/test/.local/bin/claude" }) == "/Users/test/.local/bin/claude")
        #expect(AIClients.claudeCodePath(home: home, isExecutable: { $0 == "/opt/homebrew/bin/claude" }) == "/opt/homebrew/bin/claude")
        #expect(AIClients.claudeCodePath(home: home, isExecutable: { $0 == "/Users/test/.npm-global/bin/claude" }) != nil)
        #expect(AIClients.claudeCodePath(home: home, isExecutable: { _ in false }) == nil)
        // The first place wins when it is in several.
        #expect(AIClients.claudeCodePath(home: home, isExecutable: { _ in true }) == "/Users/test/.local/bin/claude")
    }

    @Test func pathsWithSpacesAndQuotesSurviveTheShell() {
        #expect(AIClients.shellQuoted("/Applications/SimplMaker.app/Contents/Helpers/simplmaker-mcp") == "'/Applications/SimplMaker.app/Contents/Helpers/simplmaker-mcp'")
        #expect(AIClients.shellQuoted("/Users/a b/it's here") == "'/Users/a b/it'\\''s here'")
        // And a real shell reads it back as one word.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s " + AIClients.shellQuoted("/Users/a b/it's \"here\"")]
        let out = Pipe()
        process.standardOutput = out
        try? process.run()
        process.waitUntilExit()
        #expect(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == "/Users/a b/it's \"here\"")
    }

    @Test func theClaudeCodeCommandHasNoSecretWhenTheRelayIsThere() {
        let withRelay = AIClients.claudeCodeCommand(relay: "/Applications/SimplMaker.app/Contents/Helpers/simplmaker-mcp", endpoint: "http://127.0.0.1:1/mcp", token: "SECRET")
        #expect(withRelay == "claude mcp add --scope user SimplMaker -- '/Applications/SimplMaker.app/Contents/Helpers/simplmaker-mcp'")
        #expect(withRelay?.contains("SECRET") == false)
        let network = AIClients.claudeCodeCommand(relay: nil, endpoint: "http://127.0.0.1:47821/mcp", token: "SECRET")
        #expect(network == "claude mcp add --scope user --transport http SimplMaker http://127.0.0.1:47821/mcp --header \"Authorization: Bearer SECRET\"")
        #expect(AIClients.claudeCodeCommand(relay: nil, endpoint: nil, token: "SECRET") == nil, "nothing to point at while it is off")
    }

    @Test func anAssistantThatConnectsIsShownAsConnected() async throws {
        let s = AIConnectionTests.Setup(); defer { s.cleanUp() }
        let ai = s.connection()
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        defer { ai.stop() }
        #expect(ai.clients.isEmpty && ai.lastConnected("Claude Desktop") == nil)
        var request = URLRequest(url: URL(string: ai.endpoint!)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(ai.token)", forHTTPHeaderField: "Authorization")
        let hello: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-ai", "version": "0.1.0"]]]
        request.httpBody = Data(hello.text().utf8)
        _ = try await URLSession.shared.data(for: request)
        for _ in 0..<100 where ai.clients.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ai.clients.map(\.displayName) == ["Claude Desktop"] && ai.clients.first?.version == "0.1.0")
        #expect(ai.lastConnected("Claude Desktop") != nil && ai.lastConnected("Claude Code") == nil)
        // Saying hello again moves it to the top and updates the time, without a second entry.
        ai.noteClient(name: "claude-code", version: "2")
        ai.noteClient(name: "claude-ai", version: "0.2.0", at: Date().addingTimeInterval(60))
        #expect(ai.clients.map(\.rawName) == ["claude-ai", "claude-code"] && ai.clients.first?.version == "0.2.0")
    }

    @Test func anAnonymousClientIsNotRecordedAsSomethingItIsNot() async throws {
        let s = AIConnectionTests.Setup(); defer { s.cleanUp() }
        let ai = s.connection()
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        defer { ai.stop() }
        var request = URLRequest(url: URL(string: ai.endpoint!)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(ai.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(JSONValue.object(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]).text().utf8)
        _ = try await URLSession.shared.data(for: request)
        try await Task.sleep(for: .milliseconds(100))
        #expect(ai.clients.isEmpty, "a client that gives no name is not shown")
    }

    // MARK: Claude Code's own list

    private func claudeJSON(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString).json")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func anEntryInClaudeCodesListIsFoundByNameAndByProgram() throws {
        let relay = "/Applications/SimplMaker.app/Contents/Helpers/simplmaker-mcp"
        let file = try claudeJSON(#"{"numStartups": 9, "mcpServers": {"other": {"command": "x"}, "SimplMaker": {"type": "stdio", "command": "\#(relay)", "args": []}}}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        let found = ClaudeCodeConfig.registration(at: file)
        #expect(found == ClaudeCodeConfig.Registration(command: relay))
        #expect(ClaudeCodeConfig.isCurrent(found, relay: relay))
        #expect(!ClaudeCodeConfig.isCurrent(found, relay: "/Volumes/Other/SimplMaker.app/Contents/Helpers/simplmaker-mcp"), "an app that moved would fail")
        #expect(!ClaudeCodeConfig.isCurrent(nil, relay: relay))
    }

    @Test func noFileAnOldNameOrNoEntryIsNotRegistered() throws {
        #expect(ClaudeCodeConfig.registration(at: URL(fileURLWithPath: "/nonexistent/.claude.json")) == nil)
        for text in [#"{"mcpServers": {"simplmaker": {"command": "x"}}}"#, #"{"projects": {}}"#, "not json", #"{"mcpServers": 5}"#] {
            let file = try claudeJSON(text)
            defer { try? FileManager.default.removeItem(at: file) }
            #expect(ClaudeCodeConfig.registration(at: file) == nil, "\(text)")
        }
    }

    @Test func aNetworkEntryCountsAndAStaleOneIsRemovedBeforeAdding() throws {
        let file = try claudeJSON(#"{"mcpServers": {"SimplMaker": {"type": "http", "url": "http://127.0.0.1:1/mcp"}}}"#)
        defer { try? FileManager.default.removeItem(at: file) }
        let http = ClaudeCodeConfig.registration(at: file)
        #expect(http?.command == nil && ClaudeCodeConfig.isCurrent(http, relay: "/x"))
        let add = "claude mcp add --scope user SimplMaker -- '/x'"
        #expect(ClaudeCodeConfig.command(add: add, replacing: nil) == add)
        let stale = ClaudeCodeConfig.Registration(command: "/old")
        #expect(ClaudeCodeConfig.command(add: add, replacing: stale) == "claude mcp remove --scope user SimplMaker; " + add)
    }
}
