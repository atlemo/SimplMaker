// The Model Context Protocol layer: JSON, the JSON-RPC server, HTTP parsing and the rules about who is let in.
// None of it knows about CAD; the tools here are made up.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SimplMaker

@Suite struct MCPProtocolTests {
    private struct Boom: Error {}

    private func server() -> MCPServer {
        MCPServer(
            name: "Test", version: "9.9", instructions: "How to use it.",
            tools: [
                MCPTool(name: "echo", title: "Echo", description: "Echoes.", inputSchema: ["type": "object"], readOnly: true,
                        handler: { args in ["said": args["text"] ?? .null] }),
                MCPTool(name: "fails", title: "Fails", description: "Always fails.", inputSchema: ["type": "object"], readOnly: false,
                        handler: { _ in throw Boom() }),
            ],
            describeFailure: { _ in ["success": false, "error": ["code": "BOOM"]] })
    }

    /// Sends one message; the answer as JSON (nil when there is none).
    private func send(_ server: MCPServer, _ message: JSONValue) async throws -> JSONValue? {
        guard let data = await server.handle(Data(message.text().utf8)) else { return nil }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func call(_ id: JSONValue = 1, _ method: String, _ params: JSONValue = [:]) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params]
    }

    // MARK: JSON

    @Test func jsonRoundTripsAndKeepsIntegersApart() throws {
        let text = #"{"a":1,"b":1.5,"c":"x","d":[true,null],"e":{"f":2}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(value["a"] == .int(1) && value["b"] == .double(1.5) && value["c"]?.string == "x")
        #expect(value["d"] == [true, .null] && value["e"]?["f"] == 2)
        #expect(value.text() == text, "keys sorted, compact")
    }

    @Test func encodingAValueUsesSnakeCaseKeys() throws {
        struct Sample: Encodable { var documentId: String; var featureCount: Int }
        let v = try JSONValue(encoding: Sample(documentId: "doc_1", featureCount: 3))
        #expect(v == ["document_id": "doc_1", "feature_count": 3])
    }

    // MARK: JSON-RPC

    @Test func initializeAgreesAVersionAndSaysWhatItOffers() async throws {
        let s = server()
        let r = try #require(try await send(s, call("a", "initialize", ["protocolVersion": "2025-03-26"])))
        #expect(r["id"] == "a" && r["jsonrpc"] == "2.0")
        let result = try #require(r["result"])
        #expect(result["protocolVersion"] == "2025-03-26", "a version it knows is kept")
        #expect(result["serverInfo"]?["name"] == "Test" && result["serverInfo"]?["version"] == "9.9")
        #expect(result["capabilities"]?["tools"] != nil && result["instructions"] == "How to use it.")
        let other = try #require(try await send(s, call(2, "initialize", ["protocolVersion": "1999-01-01"])))
        #expect(other["result"]?["protocolVersion"] == "2025-06-18", "an unknown one gets the newest")
    }

    @Test func notificationsAreNotAnswered() async throws {
        let s = server()
        let note: JSONValue = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        #expect(try await send(s, note) == nil)
        #expect(try await send(s, ["jsonrpc": "2.0", "method": "notifications/anything-else"]) == nil)
        #expect(try await send(s, ["jsonrpc": "2.0", "id": 4, "result": [:]]) == nil, "a client's answer needs none")
    }

    @Test func pingAnswersEmpty() async throws {
        let r = try #require(try await send(server(), call(7, "ping")))
        #expect(r["result"] == [:] && r["id"] == 7)
    }

    @Test func toolsAreListedWithTheirSchemaAndAnnotations() async throws {
        let r = try #require(try await send(server(), call("l", "tools/list")))
        let tools = try #require(r["result"]?["tools"]?.array)
        #expect(tools.compactMap { $0["name"]?.string } == ["echo", "fails"])
        let echo = tools[0]
        #expect(echo["description"] == "Echoes." && echo["inputSchema"]?["type"] == "object")
        #expect(echo["annotations"]?["readOnlyHint"] == true && tools[1]["annotations"]?["readOnlyHint"] == false)
        #expect(echo["annotations"]?["destructiveHint"] == nil, "a read-only tool says nothing about destruction")
        #expect(tools[1]["annotations"]?["destructiveHint"] == false && tools[1]["annotations"]?["idempotentHint"] == false)
    }

    @Test func aToolCallReturnsStructuredAndTextContent() async throws {
        let r = try #require(try await send(server(), call(3, "tools/call", ["name": "echo", "arguments": ["text": "hi"]])))
        let result = try #require(r["result"])
        #expect(result["structuredContent"] == ["said": "hi"])
        #expect(result["content"]?.array?.first?["type"] == "text")
        #expect(result["content"]?.array?.first?["text"]?.string == #"{"said":"hi"}"#)
        #expect(result["isError"] == nil)
    }

    @Test func aFailingToolIsAnErrorResultTheAICanRead() async throws {
        let r = try #require(try await send(server(), call(3, "tools/call", ["name": "fails"])))
        #expect(r["error"] == nil, "not a protocol error")
        let result = try #require(r["result"])
        #expect(result["isError"] == true)
        #expect(result["structuredContent"]?["error"]?["code"] == "BOOM")
    }

    @Test func badCallsAreProtocolErrors() async throws {
        let s = server()
        let unknownTool = try #require(try await send(s, call(1, "tools/call", ["name": "nope"])))
        #expect(unknownTool["error"]?["code"] == .int(MCPError.invalidParams))
        let noName = try #require(try await send(s, call(1, "tools/call", [:])))
        #expect(noName["error"]?["code"] == .int(MCPError.invalidParams))
        let badArgs = try #require(try await send(s, call(1, "tools/call", ["name": "echo", "arguments": [1, 2]])))
        #expect(badArgs["error"]?["code"] == .int(MCPError.invalidParams))
        let unknownMethod = try #require(try await send(s, call(1, "resources/list")))
        #expect(unknownMethod["error"]?["code"] == .int(MCPError.methodNotFound))
        let notRPC = try #require(try await send(s, ["id": 1, "method": "ping"]))
        #expect(notRPC["error"]?["code"] == .int(MCPError.invalidRequest))
        let garbage = try #require(await s.handle(Data("{not json".utf8)))
        let parsed = try JSONDecoder().decode(JSONValue.self, from: garbage)
        #expect(parsed["error"]?["code"] == .int(MCPError.parseError) && parsed["id"] == .null)
    }

    @Test func aBatchGetsABatchBackWithoutTheNotifications() async throws {
        let batch: JSONValue = [call(1, "ping"), ["jsonrpc": "2.0", "method": "notifications/initialized"], call(2, "ping")]
        let r = try #require(try await send(server(), batch))
        #expect(r.array?.compactMap { $0["id"] } == [1, 2])
    }

    // MARK: HTTP parsing

    private func raw(_ lines: [String], body: String = "") -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    @Test func aWholeRequestIsParsed() {
        let body = #"{"a":1}"#
        let data = raw(["POST /mcp?x=1 HTTP/1.1", "Host: 127.0.0.1:1", "Content-Type: application/json", "Content-Length: \(body.utf8.count)"], body: body)
        guard case .request(let r, let consumed) = HTTPRequestParser.parse(data) else { Issue.record("not parsed"); return }
        #expect(r.method == "POST" && r.path == "/mcp" && r.headers["host"] == "127.0.0.1:1" && r.headers["content-type"] == "application/json")
        #expect(String(data: r.body, encoding: .utf8) == body && consumed == data.count)
    }

    @Test func aRequestArrivingInPiecesWaits() {
        let full = raw(["POST /mcp HTTP/1.1", "Content-Length: 5"], body: "hello")
        #expect(HTTPRequestParser.parse(full.prefix(10)) == .incomplete(expectContinue: false))
        #expect(HTTPRequestParser.parse(full.dropLast(2)) == .incomplete(expectContinue: false))
        guard case .request(let r, _) = HTTPRequestParser.parse(full) else { Issue.record("not parsed"); return }
        #expect(String(data: r.body, encoding: .utf8) == "hello")
    }

    @Test func expectContinueIsNoticed() {
        let headers = raw(["POST /mcp HTTP/1.1", "Content-Length: 5000", "Expect: 100-continue"])
        #expect(HTTPRequestParser.parse(headers) == .incomplete(expectContinue: true))
    }

    @Test func twoRequestsInOneBufferAreTakenOneByOne() {
        let one = raw(["POST /mcp HTTP/1.1", "Content-Length: 2"], body: "{}")
        let two = raw(["POST /mcp HTTP/1.1", "Content-Length: 3"], body: "[1]")
        var buffer = one + two
        guard case .request(_, let first) = HTTPRequestParser.parse(buffer) else { Issue.record("first"); return }
        #expect(first == one.count)
        buffer.removeFirst(first)
        guard case .request(let r, let second) = HTTPRequestParser.parse(buffer) else { Issue.record("second"); return }
        #expect(String(data: r.body, encoding: .utf8) == "[1]" && second == two.count)
    }

    @Test func badAndOversizedRequestsAreRefused() {
        func status(_ data: Data) -> Int? { if case .invalid(let r) = HTTPRequestParser.parse(data) { return r.status } else { return nil } }
        #expect(status(raw(["GARBAGE"])) == 400)
        #expect(status(raw(["POST /mcp HTTP/1.1", "NoColonHere"])) == 400)
        #expect(status(raw(["POST /mcp HTTP/1.1", "Content-Length: x"])) == 400)
        #expect(status(raw(["POST /mcp HTTP/1.1", "Content-Length: 1", "Content-Length: 2"])) == 400)
        #expect(status(raw(["POST /mcp HTTP/1.1", "Transfer-Encoding: chunked"])) == 400)
        #expect(status(raw(["POST /mcp HTTP/1.1", "Content-Length: \(HTTPRequestParser.maxBodyBytes + 1)"])) == 413)
        #expect(status(Data(repeating: 65, count: HTTPRequestParser.maxHeaderBytes + 10)) == 431)
    }

    @Test func aResponseSerializesWithItsLengthAndConnection() {
        let text = String(data: HTTPResponse.json(Data("{}".utf8)).serialized(), encoding: .utf8) ?? ""
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n") && text.contains("Content-Length: 2\r\n") && text.contains("Connection: keep-alive\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}") && text.contains("Content-Type: application/json\r\n"))
        let closing = String(data: HTTPResponse.text(403, "no", closes: true).serialized(), encoding: .utf8) ?? ""
        #expect(closing.hasPrefix("HTTP/1.1 403 Forbidden") && closing.contains("Connection: close"))
    }

    // MARK: who is let in

    private func handler(token: String = "secret", port: UInt16 = 4000) -> MCPHTTPHandler {
        MCPHTTPHandler(server: server(), token: { token }, port: { port })
    }

    private func request(method: String = "POST", path: String = "/mcp", host: String? = "127.0.0.1:4000", origin: String? = nil,
                         auth: String? = "Bearer secret", type: String? = "application/json", body: JSONValue? = nil) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let host { headers["host"] = host }
        if let origin { headers["origin"] = origin }
        if let auth { headers["authorization"] = auth }
        if let type { headers["content-type"] = type }
        return HTTPRequest(method: method, path: path, headers: headers, body: Data((body ?? call("p", "ping")).text().utf8))
    }

    @Test func aGoodRequestIsAnswered() async throws {
        let r = await handler().respond(to: request())
        #expect(r.status == 200 && r.headers["Content-Type"] == "application/json")
        #expect(try JSONDecoder().decode(JSONValue.self, from: r.body)["id"] == "p")
        for host in ["127.0.0.1:4000", "localhost:4000", "LOCALHOST:4000"] {
            #expect(await handler().respond(to: request(host: host)).status == 200, "\(host)")
        }
    }

    @Test func aNotificationGetsAcceptedWithNoBody() async {
        let r = await handler().respond(to: request(body: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        #expect(r.status == 202 && r.body.isEmpty)
    }

    @Test func aForeignHostIsRefusedWhateverTheToken() async {
        // What a DNS-rebinding page looks like: the browser sends the attacker's name as Host.
        for host in [nil, "evil.example", "evil.example:4000", "127.0.0.1", "127.0.0.1:4001", "192.168.0.5:4000", "127.0.0.1.evil.example:4000"] as [String?] {
            let r = await handler().respond(to: request(host: host))
            #expect(r.status == 403 && r.closes, "\(host ?? "no host")")
        }
    }

    @Test func aWebPageOriginIsRefused() async {
        for origin in ["https://evil.example", "http://evil.example:4000", "null", "http://127.0.0.1.evil.example", "file://"] {
            #expect(await handler().respond(to: request(origin: origin)).status == 403, "\(origin)")
        }
        for origin in ["http://127.0.0.1:3000", "http://localhost", "http://localhost:5173"] {
            #expect(await handler().respond(to: request(origin: origin)).status == 200, "\(origin)")
        }
    }

    @Test func theTokenIsRequired() async {
        let h = handler()
        for auth in [nil, "", "Bearer", "Bearer wrong", "Bearer secret2", "Bearer secre", "Basic secret", "secret"] as [String?] {
            let r = await h.respond(to: request(auth: auth))
            #expect(r.status == 401 && r.headers["WWW-Authenticate"]?.hasPrefix("Bearer") == true, "\(auth ?? "none")")
        }
        #expect(await h.respond(to: request(auth: "bearer secret")).status == 200, "the scheme isn't case sensitive")
    }

    @Test func aNewTokenTakesEffectAtOnce() async {
        let box = TokenBox("one")
        let h = MCPHTTPHandler(server: server(), token: { box.value }, port: { 4000 })
        #expect(await h.respond(to: request(auth: "Bearer one")).status == 200)
        box.value = "two"
        #expect(await h.respond(to: request(auth: "Bearer one")).status == 401)
        #expect(await h.respond(to: request(auth: "Bearer two")).status == 200)
    }

    private final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String
        init(_ v: String) { stored = v }
        var value: String { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    }

    @Test func otherPathsMethodsAndTypesAreRefused() async {
        let h = handler()
        #expect(await h.respond(to: request(path: "/")).status == 404)
        #expect(await h.respond(to: request(path: "/mcp/extra")).status == 404)
        for method in ["GET", "DELETE", "PUT", "OPTIONS"] {
            let r = await h.respond(to: request(method: method))
            #expect(r.status == 405 && r.headers["Allow"] == "POST", "\(method)")
        }
        #expect(await h.respond(to: request(type: "text/plain")).status == 415)
        #expect(await h.respond(to: request(type: nil)).status == 415)
        #expect(await h.respond(to: request(type: "application/json; charset=utf-8")).status == 200)
    }

    @Test func withoutTheTokenEveryRequestGetsTheSameAnswer() async {
        // No token, no information: a wrong path, method or type is not told apart from a right one.
        let h = handler()
        var seen = Set<HTTPResponse>()
        for r in [request(auth: nil), request(method: "GET", auth: nil), request(path: "/secret", auth: nil),
                  request(auth: nil, type: "text/plain"), request(auth: "Bearer nope", body: call("x", "tools/list"))] {
            seen.insert(await h.respond(to: r))
        }
        #expect(seen.count == 1 && seen.first?.status == 401, "\(seen.map(\.status))")
        #expect((seen.first?.body.count ?? 999) < 200, "nothing about the server in it")
    }

    @Test func comparingTokensDoesNotStopAtTheFirstDifference() {
        #expect(MCPHTTPHandler.constantTimeEqual("abc", "abc"))
        #expect(!MCPHTTPHandler.constantTimeEqual("abc", "abd"))
        #expect(!MCPHTTPHandler.constantTimeEqual("abc", "abcd"))
        #expect(!MCPHTTPHandler.constantTimeEqual("", "a"))
        #expect(MCPHTTPHandler.constantTimeEqual("", ""))
    }
}
