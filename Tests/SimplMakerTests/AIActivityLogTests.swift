// The record of what the assistants did: one line for each tool call, from the server's own hook, for Settings ▸ AI.
// Copyright © 2026 Atle Mo. All rights reserved.
import CADCore
import Foundation
import Testing
import os
@testable import SimplMaker

@Suite @MainActor struct AIActivityLogTests {
    private func call(_ name: String, readOnly: Bool = false, arguments: JSONValue = [:], result: JSONValue, isError: Bool = false, at: Date = Date()) -> MCPToolCall {
        MCPToolCall(name: name, title: name.replacingOccurrences(of: "_", with: " ").capitalized, readOnly: readOnly, arguments: arguments, result: result,
                    isError: isError, seconds: 0.2, date: at)
    }

    @Test func aChangeIsOneLineWithTheToolsOwnSentence() {
        let e = AIActivityEntry(call("create_box", arguments: ["document_id": "d1"], result: ["success": true, "message": "Created Box1: 60 × 40 × 20 mm."]))
        #expect(e.summary == "Created Box1: 60 × 40 × 20 mm." && !e.isError && !e.readOnly && e.document == "d1")
    }

    @Test func aFailureCarriesItsCodeAndWhy() {
        let e = AIActivityEntry(call("create_fillet", result: ["success": false, "error": ["code": "REBUILD_FAILED", "message": "The change was not applied: Fillet1 could not be built."]], isError: true))
        #expect(e.isError && e.code == "REBUILD_FAILED" && e.summary.contains("Fillet1"))
        #expect(e.line.contains("FAILED (REBUILD_FAILED)") && e.line.contains("create_fillet"))
    }

    @Test func aBatchNamesItsSteps() {
        let steps: JSONValue = [["tool": "create_sketch", "arguments": [:]], ["tool": "create_extrude", "arguments": [:]]]
        let e = AIActivityEntry(call("batch", arguments: ["operations": steps], result: ["message": "Made 2 changes as one undo step."]))
        #expect(e.summary == "Made 2 changes as one undo step. (sketch, extrude)")
    }

    @Test func aLookWithoutAMessageIsNamedByItsTool() {
        let e = AIActivityEntry(call("get_document", readOnly: true, result: ["document_id": "d1"]))
        #expect(e.readOnly && e.summary == "Get Document")
    }

    @Test func lookingIsHiddenUnlessAskedForButFailuresAlwaysShow() {
        let log = AIActivityLog()
        log.record(call("get_document", readOnly: true, result: [:]))
        log.record(call("create_box", result: ["message": "Created Box1."]))
        log.record(call("get_body", readOnly: true, result: ["error": ["code": "FEATURE_NOT_FOUND", "message": "No such body."]], isError: true))
        #expect(log.shown(includingLooks: false).map(\.tool) == ["get_body", "create_box"], "newest first, the failed look included")
        #expect(log.shown(includingLooks: true).count == 3)
        #expect(log.text(includingLooks: false).split(separator: "\n").count == 2)
        #expect(log.text(includingLooks: true).hasPrefix(log.entries.last!.line), "pasted text runs oldest first")
        log.clear()
        #expect(log.entries.isEmpty)
    }

    @Test func theLogKeepsOnlyTheNewestEntries() {
        let log = AIActivityLog(limit: 5)
        for n in 0..<8 { log.record(call("create_box", result: ["message": .string("Box \(n)")])) }
        #expect(log.entries.count == 5 && log.entries.first?.summary == "Box 7" && log.entries.last?.summary == "Box 3")
    }

    @Test func theServerTellsTheLogAboutEveryCallThatRan() async throws {
        let rig = AIServiceTests.Rig()
        let (id, _) = await rig.open(CADDocument())
        let seen = OSAllocatedUnfairLock<[MCPToolCall]>(initialState: [])
        let server = AITools.makeServer(service: rig.service, version: "t", onToolCall: { call in seen.withLock { $0.append(call) } })
        func send(_ tool: String, _ arguments: JSONValue) async {
            let message: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": arguments]]
            _ = await server.handle(Data(message.text().utf8))
        }
        await send("create_box", ["document_id": .string(id), "width": 10, "length": 10, "height": 5])
        await send("create_box", ["document_id": .string(id), "width": 10])  // missing sizes
        await send("get_document", ["document_id": .string(id)])
        let calls = seen.withLock { $0 }
        #expect(calls.map(\.name) == ["create_box", "create_box", "get_document"])
        #expect(calls.map(\.isError) == [false, true, false])
        #expect(calls[0].result["message"]?.string?.contains("Created") == true)
        let log = AIActivityLog()
        calls.forEach { log.record($0) }
        #expect(log.entries.first?.readOnly == true && log.entries[1].code == "INVALID_ARGUMENTS", "\(log.entries.map(\.line))")
    }
}
