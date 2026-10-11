// The AI interface from the outside: a real server on a loopback port, spoken to over HTTP the way an MCP client does,
// serving the real tools over documents opened in a test registry.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
@testable import SimplMaker

@Suite @MainActor struct AIConnectionTests {
    /// Everything one test needs: its own defaults, connection file, documents and licence switch.
    @MainActor final class Setup {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("simplmaker-ai-\(UUID().uuidString)")
        let defaults: UserDefaults
        let suite = "simplmaker-ai-test-\(UUID().uuidString)"
        let rig = AIServiceTests.Rig()
        var licensed = true
        lazy var file = MCPConnectionFile(url: directory.appendingPathComponent("mcp-connection.json"))

        init() { defaults = UserDefaults(suiteName: suite)! }

        func connection(version: String = "test") -> AIConnection {
            AIConnection(defaults: defaults, file: file, service: CADService(registry: rig.registry, licensed: { [unowned self] in licensed }),
                         licensed: { [unowned self] in licensed }, version: version, available: true)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    /// POSTs a JSON-RPC message; the status and the JSON that came back.
    private func post(_ endpoint: String, token: String?, _ message: JSONValue) async throws -> (status: Int, json: JSONValue?) {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(message.text().utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, try? JSONDecoder().decode(JSONValue.self, from: data))
    }

    private func rpc(_ id: JSONValue, _ method: String, _ params: JSONValue = [:]) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params]
    }

    private func isRefused(_ endpoint: String) async -> Bool {
        do { _ = try await post(endpoint, token: "x", rpc(1, "ping")); return false } catch { return true }
    }

    // MARK: switching

    @Test func itIsOffUntilTheUserTurnsItOn() async throws {
        let s = Setup(); defer { s.cleanUp() }
        let ai = s.connection()
        await ai.refresh()
        #expect(ai.status == .off && ai.endpoint == nil)
        #expect(!FileManager.default.fileExists(atPath: s.file.url.path), "nothing is written while it is off")
    }

    @Test func turnedOnItListensOnLoopbackAndWritesWhereToFindIt() async throws {
        let s = Setup(); defer { s.cleanUp() }
        let ai = s.connection()
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        defer { ai.stop() }
        guard case .running(let port) = ai.status else { Issue.record("\(ai.status)"); return }
        #expect(ai.endpoint == "http://127.0.0.1:\(port)/mcp")
        let info = try #require(s.file.read())
        #expect(info.port == Int(port) && info.token == ai.token && info.running && info.pid == ProcessInfo.processInfo.processIdentifier)
        let attributes = try FileManager.default.attributesOfItem(atPath: s.file.url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600, "readable by this user only")
        let dir = try FileManager.default.attributesOfItem(atPath: s.directory.path)
        #expect((dir[.posixPermissions] as? Int) == 0o700)
        #expect(ai.claudeCodeCommand?.contains("--scope user --transport http SimplMaker http://127.0.0.1:\(port)/mcp") == true)
        #expect(ai.claudeCodeCommand?.contains("Bearer \(ai.token)") == true)
    }

    @Test func aTokenIsLongRandomAndKeptAcrossRestarts() async throws {
        let s = Setup(); defer { s.cleanUp() }
        let first = s.connection()
        #expect(first.token.count == 43, "32 random bytes")
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await first.refresh()
        first.stop()
        let second = s.connection()
        #expect(second.token == first.token, "the connection a user set up survives a restart")
        #expect(Set((0..<50).map { _ in MCPConnectionFile.makeToken() }).count == 50)
        #expect(MCPConnectionFile.makeToken().allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    @Test func turningItOffClosesTheDoorAndKeepsTheToken() async throws {
        let s = Setup(); defer { s.cleanUp() }
        let ai = s.connection()
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        let endpoint = try #require(ai.endpoint)
        #expect(try await post(endpoint, token: ai.token, rpc(1, "ping")).status == 200)
        s.defaults.set(false, forKey: AIConnection.enabledKey)
        await ai.refresh()
        #expect(ai.status == .off)
        #expect(await isRefused(endpoint))
        let info = try #require(s.file.read())
        #expect(info.running == false && info.token == ai.token)
    }

    @Test func withoutALicenseItDoesNotStartAndStartsWhenOneAppears() async throws {
        let s = Setup(); defer { s.cleanUp() }
        s.licensed = false
        let ai = s.connection()
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        #expect(ai.status == .needsLicense && ai.endpoint == nil)
        s.licensed = true
        await ai.refresh()
        guard case .running = ai.status else { Issue.record("\(ai.status)"); return }
        s.licensed = false  // the trial ends while it runs
        await ai.refresh()
        #expect(ai.status == .needsLicense)
        ai.stop()
    }

    @Test func aTakenPortIsNoReasonNotToStart() async throws {
        let s = Setup(); defer { s.cleanUp() }
        let blocker = MCPHTTPServer(handler: MCPHTTPHandler(server: AITools.makeServer(service: s.connection().serviceForTests, version: "x"),
                                                            token: { "t" }, port: { 0 }))
        let taken = try await blocker.start(port: 0)
        defer { blocker.stop() }
        s.defaults.set(Int(taken), forKey: AIConnection.portKey)
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        let ai = s.connection()
        await ai.refresh()
        defer { ai.stop() }
        guard case .running(let port) = ai.status else { Issue.record("\(ai.status)"); return }
        #expect(port != taken)
        #expect(s.defaults.integer(forKey: AIConnection.portKey) == Int(port), "the new port is remembered")
    }

    @Test func theSameServerKeepsItsPortWhenRestarted() async throws {
        let s = Setup(); defer { s.cleanUp() }
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        let first = s.connection()
        await first.refresh()
        let port = try #require(first.port)
        first.stop()
        let second = s.connection()
        await second.refresh()
        defer { second.stop() }
        #expect(second.port == port)
    }

    // MARK: over the wire

    @Test func aClientCanConnectListToolsAndReadADocument() async throws {
        let s = Setup(); defer { s.cleanUp() }
        let (docID, _) = await s.rig.open(.demo())
        let ai = s.connection(version: "1.2.3")
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        defer { ai.stop() }
        let endpoint = try #require(ai.endpoint), token = ai.token

        let hello = try await post(endpoint, token: token, rpc(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                                                  "clientInfo": ["name": "test", "version": "1"]]))
        #expect(hello.status == 200 && hello.json?["result"]?["serverInfo"]?["version"] == "1.2.3")
        #expect(hello.json?["result"]?["instructions"]?.string?.contains("millimetres") == true)
        let note = try await post(endpoint, token: token, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        #expect(note.status == 202)

        let list = try await post(endpoint, token: token, rpc(2, "tools/list"))
        let tools = try #require(list.json?["result"]?["tools"]?.array)
        let names = tools.compactMap { $0["name"]?.string }
        #expect(names == ["list_documents", "get_document", "get_feature", "get_selection", "list_parameters",
                          "create_box", "modify_feature", "set_parameter", "create_sketch", "edit_sketch", "create_extrude", "create_fillet", "create_chamfer", "create_hole", "create_shell", "create_mirror", "create_pattern", "create_combine", "create_revolve", "create_sweep", "create_loft", "create_thread", "create_draft", "create_plane", "create_move", "create_scale",
                          "import_file", "export_file", "delete_feature", "batch",
                          "get_body", "measure", "undo", "redo"])
        #expect(tools.allSatisfy { ($0["description"]?.string?.count ?? 0) > 200 && $0["inputSchema"]?["type"] == "object" })
        let reads = Set(["list_documents", "get_document", "get_feature", "get_selection", "list_parameters", "get_body", "measure"])
        for tool in tools {
            let name = tool["name"]?.string ?? ""
            #expect((tool["annotations"]?["readOnlyHint"] == true) == reads.contains(name), "\(name)")
        }

        let docs = try await post(endpoint, token: token, rpc(3, "tools/call", ["name": "list_documents"]))
        #expect(docs.json?["result"]?["structuredContent"]?["documents"]?.array?.first?["id"] == .string(docID))

        let doc = try await post(endpoint, token: token, rpc(4, "tools/call", ["name": "get_document", "arguments": ["document_id": .string(docID)]]))
        let result = try #require(doc.json?["result"])
        #expect(result["isError"] == nil)
        let content = try #require(result["structuredContent"])
        #expect(content["units"] == "mm" && content["features"]?.array?.count == 6 && content["bodies"]?.array?.count == 1)
        #expect(content["features"]?.array?[1]["parameters"]?["distance"]?["expression"] == "thickness")
        let text = try #require(result["content"]?.array?.first?["text"]?.string)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == content, "the text is the same answer")

        let feature = try await post(endpoint, token: token, rpc(5, "tools/call", ["name": "get_feature", "arguments": ["feature_id": "base", "document_id": .string(docID)]]))
        #expect(feature.json?["result"]?["structuredContent"]?["sketch"]?["degrees_of_freedom"] == 0)

        let params = try await post(endpoint, token: token, rpc(6, "tools/call", ["name": "list_parameters"]))
        #expect(params.json?["result"]?["structuredContent"]?["parameters"]?.array?.count == 7)

        let selection = try await post(endpoint, token: token, rpc(7, "tools/call", ["name": "get_selection"]))
        #expect(selection.json?["result"]?["structuredContent"]?["entities"] == [])
    }

    @Test func aClientCanBuildChangeAndUndoAPartThroughTheTools() async throws {
        let s = Setup(); defer { s.cleanUp() }
        let (docID, model) = await s.rig.open(CADDocument())
        let undo = UndoManager()
        model.undoManager = undo
        let ai = s.connection()
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        defer { ai.stop() }
        let endpoint = try #require(ai.endpoint), token = ai.token
        func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
            let answer = try await post(endpoint, token: token, rpc(1, "tools/call", ["name": .string(name), "arguments": arguments]))
            return try #require(answer.json?["result"])
        }

        // "Create a box that is 100 wide, 50 deep and 20 high."
        let created = try await call("create_box", ["document_id": .string(docID), "width": 100, "length": 50, "height": 20])
        #expect(created["isError"] == nil, "\(created.text())")
        let content = try #require(created["structuredContent"])
        let featureID = try #require(content["feature"]?["id"]?.string)
        #expect(content["success"] == true && content["bodies"]?.array?.first?["volume"]?.number.map { abs($0 - 100_000) < 1e-3 } == true)
        #expect(model.document.features.count == 1 && undo.undoActionName == "AI: Create Box")
        let revision = try #require(content["revision"]?.number).rounded()

        // "Make it 120 wide."
        let changed = try await call("modify_feature", ["document_id": .string(docID), "feature_id": .string(featureID),
                                                       "parameters": ["width": 120], "expected_revision": .int(Int(revision))])
        #expect(changed["isError"] == nil, "\(changed.text())")
        #expect(changed["structuredContent"]?["changes"]?.array?.first?["after"]?["value"] == 120)
        #expect(model.document.features.count == 1, "the same feature was changed")

        // The same call with the old revision is refused: the part has moved on.
        let stale = try await call("modify_feature", ["document_id": .string(docID), "feature_id": .string(featureID),
                                                     "parameters": ["width": 130], "expected_revision": .int(Int(revision))])
        #expect(stale["isError"] == true && stale["structuredContent"]?["error"]?["code"] == "STALE_REVISION")

        // A part the call doesn't name is never guessed.
        let unnamed = try await call("create_box", ["width": 1, "length": 1, "height": 1])
        #expect(unnamed["structuredContent"]?["error"]?["code"] == "INVALID_ARGUMENTS")
        #expect(model.document.features.count == 1)

        // "Undo that."
        let undone = try await call("undo", ["document_id": .string(docID)])
        #expect(undone["structuredContent"]?["step"] == "AI: Change Box1")
        let read = try await call("get_feature", ["document_id": .string(docID), "feature_id": .string(featureID)])
        #expect(read["structuredContent"]?["feature"]?["parameters"]?["width"]?["value"] == 100)
        #expect(read["structuredContent"]?["editable"]?.array?.count == 5)
    }

    @Test func aFailedToolCallTellsTheAIWhatToDo() async throws {
        let s = Setup(); defer { s.cleanUp() }
        _ = await s.rig.open(.demo())
        let ai = s.connection()
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        defer { ai.stop() }
        let endpoint = try #require(ai.endpoint), token = ai.token

        let missing = try await post(endpoint, token: token, rpc(1, "tools/call", ["name": "get_feature", "arguments": ["feature_id": "nope"]]))
        let r = try #require(missing.json?["result"])
        #expect(r["isError"] == true && r["structuredContent"]?["success"] == false)
        #expect(r["structuredContent"]?["error"]?["code"] == "FEATURE_NOT_FOUND" && r["structuredContent"]?["error"]?["recoverable"] == true)
        #expect(r["structuredContent"]?["error"]?["reason"]?.string?.contains("get_document") == true)

        let noID = try await post(endpoint, token: token, rpc(2, "tools/call", ["name": "get_feature", "arguments": [:]]))
        #expect(noID.json?["result"]?["structuredContent"]?["error"]?["code"] == "INVALID_ARGUMENTS")
        let wrongType = try await post(endpoint, token: token, rpc(3, "tools/call", ["name": "get_document", "arguments": ["document_id": 5]]))
        #expect(wrongType.json?["result"]?["structuredContent"]?["error"]?["code"] == "INVALID_ARGUMENTS")
        let noDoc = try await post(endpoint, token: token, rpc(4, "tools/call", ["name": "get_document", "arguments": ["document_id": "doc_999"]]))
        #expect(noDoc.json?["result"]?["structuredContent"]?["error"]?["code"] == "DOCUMENT_NOT_FOUND")
    }

    @Test func theLicenseIsCheckedOnEveryToolCall() async throws {
        let s = Setup(); defer { s.cleanUp() }
        _ = await s.rig.open(.demo())
        let ai = s.connection()
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        defer { ai.stop() }
        let endpoint = try #require(ai.endpoint), token = ai.token
        let ok = try await post(endpoint, token: token, rpc(1, "tools/call", ["name": "list_documents"]))
        #expect(ok.json?["result"]?["isError"] == nil)
        s.licensed = false  // the trial ends; the server hasn't been told yet
        let refused = try await post(endpoint, token: token, rpc(2, "tools/call", ["name": "list_documents"]))
        #expect(refused.json?["result"]?["isError"] == true)
        #expect(refused.json?["result"]?["structuredContent"]?["error"]?["code"] == "LICENSE_REQUIRED")
        #expect(refused.json?["result"]?["structuredContent"]?["error"]?["recoverable"] == false)
    }

    @Test func aWrongOrOldTokenIsRefusedOverTheWire() async throws {
        let s = Setup(); defer { s.cleanUp() }
        let ai = s.connection()
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        defer { ai.stop() }
        let endpoint = try #require(ai.endpoint)
        let old = ai.token
        #expect(try await post(endpoint, token: nil, rpc(1, "ping")).status == 401)
        #expect(try await post(endpoint, token: "guess", rpc(1, "ping")).status == 401)
        #expect(try await post(endpoint, token: old, rpc(1, "ping")).status == 200)
        ai.regenerateToken()
        #expect(ai.token != old)
        #expect(try await post(endpoint, token: old, rpc(1, "ping")).status == 401, "the old secret is dead at once")
        #expect(try await post(endpoint, token: ai.token, rpc(1, "ping")).status == 200)
        #expect(s.file.read()?.token == ai.token, "and the file a relay reads has the new one")
    }

    @Test func aGetRequestAndAFileFromAPageAreRefused() async throws {
        let s = Setup(); defer { s.cleanUp() }
        let ai = s.connection()
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        defer { ai.stop() }
        var get = URLRequest(url: URL(string: ai.endpoint!)!)
        get.setValue("Bearer \(ai.token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: get)
        #expect((response as! HTTPURLResponse).statusCode == 405)
        var page = URLRequest(url: URL(string: ai.endpoint!)!)
        page.httpMethod = "POST"
        page.setValue("application/json", forHTTPHeaderField: "Content-Type")
        page.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        page.setValue("Bearer \(ai.token)", forHTTPHeaderField: "Authorization")
        page.httpBody = Data(rpc(1, "ping").text().utf8)
        let (_, answer) = try await URLSession.shared.data(for: page)
        #expect((answer as! HTTPURLResponse).statusCode == 403, "even with the token")
    }

    // MARK: the relay program

    /// The relay as the build put it, next to the test bundle (`swift test` names the bundle on its command line;
    /// under Xcode it is a loaded bundle).
    private func relayProgram() throws -> URL {
        var bundlePath: String?
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--test-bundle-path"), i + 1 < arguments.count { bundlePath = arguments[i + 1] }
        bundlePath = bundlePath ?? Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }?.bundlePath
        var directory = URL(fileURLWithPath: try #require(bundlePath, "where the test bundle is"))
        while directory.pathExtension != "xctest", directory.path != "/" { directory.deleteLastPathComponent() }
        let url = directory.deletingLastPathComponent().appendingPathComponent("simplmaker-mcp")
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "the relay program was not built at \(url.path)")
        return url
    }

    /// Runs the relay with these lines on its standard input (then end of input); what it wrote, one answer per line.
    private func runRelay(file: URL, lines: [String]) async throws -> [JSONValue] {
        let process = Process()
        process.executableURL = try relayProgram()
        process.environment = ["SIMPLMAKER_MCP_CONNECTION_FILE": file.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        // The service answers on the main actor, so waiting here must not block it.
        let data = await Task.detached { () -> Data in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
        return try String(decoding: data, as: UTF8.self).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    @Test func theRelayProgramCarriesAClientsMessagesToTheRunningApp() async throws {
        let s = Setup(); defer { s.cleanUp() }
        let (docID, _) = await s.rig.open(.demo())
        let ai = s.connection()
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        defer { ai.stop() }
        let answers = try await runRelay(file: s.file.url, lines: [
            rpc(1, "initialize", ["protocolVersion": "2025-06-18"]).text(),
            JSONValue.object(["jsonrpc": "2.0", "method": "notifications/initialized"]).text(),
            rpc(2, "tools/list").text(),
            rpc(3, "tools/call", ["name": "get_document", "arguments": ["document_id": .string(docID)]]).text(),
        ])
        #expect(answers.count == 3, "no answer to the notification: \(answers.count)")
        #expect(answers[0]["result"]?["serverInfo"]?["name"] == "SimplMaker")
        #expect(answers[1]["result"]?["tools"]?.array?.count == 34)
        #expect(answers[2]["result"]?["structuredContent"]?["features"]?.array?.count == 6)
    }

    @Test func theRelayProgramSaysSoWhenTheAppIsNotRunning() async throws {
        let s = Setup(); defer { s.cleanUp() }
        let ai = s.connection()
        s.defaults.set(true, forKey: AIConnection.enabledKey)
        await ai.refresh()
        ai.stop()  // the file now says running: false, with the token kept
        let answers = try await runRelay(file: s.file.url, lines: [
            rpc(1, "tools/call", ["name": "get_document"]).text(),
        ])
        #expect(answers.count == 1)
        #expect(answers[0]["result"]?["structuredContent"]?["error"]?["code"] == "SIMPLMAKER_NOT_RUNNING")
    }
}
