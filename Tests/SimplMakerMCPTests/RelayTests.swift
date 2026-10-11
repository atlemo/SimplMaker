// The stdio relay: what it sends to the app, and what it says when the app isn't there.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Testing
@testable import SimplMakerMCP

@Suite struct RelayTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        func add(_ r: URLRequest) { lock.withLock { stored.append(r) } }
        var requests: [URLRequest] { lock.withLock { stored } }
    }

    private func connectionFile(running: Bool = true, port: Int = 4242, token: String = "tok") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-test-\(UUID().uuidString).json")
        let json: [String: Any] = ["port": port, "token": token, "pid": 1, "running": running, "version": "t"]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    private func relay(_ file: URL, status: Int = 200, body: String = #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
                       record: Recorder = Recorder()) -> Relay {
        Relay(connectionFile: file, post: { request in
            record.add(request)
            return Relay.Reply(status: status, body: Data(body.utf8))
        })
    }

    private func object(_ line: String?) throws -> [String: Any] {
        let line = try #require(line)
        return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    @Test func aMessageIsPostedWithTheSecretAndTheAnswerComesBackAsOneLine() async throws {
        let file = try connectionFile(port: 5151, token: "s3cret"); defer { try? FileManager.default.removeItem(at: file) }
        let record = Recorder()
        let r = relay(file, body: "{\n  \"jsonrpc\": \"2.0\",\n  \"id\": 1,\n  \"result\": {}\n}", record: record)
        let answer = try #require(await r.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#))
        #expect(!answer.contains("\n"), "one line, as the stdio transport needs")
        #expect(try object(answer)["id"] as? Int == 1)
        let sent = try #require(record.requests.first)
        #expect(sent.url?.absoluteString == "http://127.0.0.1:5151/mcp" && sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(data: sent.httpBody ?? Data(), encoding: .utf8) == #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, "forwarded as it came")
    }

    @Test func aNotificationGetsNoAnswer() async throws {
        let file = try connectionFile(); defer { try? FileManager.default.removeItem(at: file) }
        let r = relay(file, status: 202, body: "")
        #expect(await r.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test func theFileIsReadForEachMessageSoANewSecretIsUsedAtOnce() async throws {
        let file = try connectionFile(token: "old"); defer { try? FileManager.default.removeItem(at: file) }
        let record = Recorder()
        let r = relay(file, record: record)
        _ = await r.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        try JSONSerialization.data(withJSONObject: ["port": 4242, "token": "new", "pid": 1, "running": true, "version": "t"]).write(to: file)
        _ = await r.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        #expect(record.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer old", "Bearer new"])
    }

    @Test func whenTheAppIsNotRunningAToolCallGetsAResultTheAICanReadAndActOn() async throws {
        let file = try connectionFile(running: false); defer { try? FileManager.default.removeItem(at: file) }
        let record = Recorder()
        let r = relay(file, record: record)
        let answer = try object(await r.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_document"}}"#))
        #expect(record.requests.isEmpty, "nothing is sent to an app that says it is not running")
        let result = try #require(answer["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true && answer["id"] as? Int == 9)
        let error = try #require((result["structuredContent"] as? [String: Any])?["error"] as? [String: Any])
        #expect(error["code"] as? String == "SIMPLMAKER_NOT_RUNNING" && error["recoverable"] as? Bool == true)
        #expect((error["reason"] as? String)?.contains("Settings") == true)
        #expect(result["content"] != nil)
    }

    @Test func otherRequestsToAnAppThatIsNotThereAreProtocolErrors() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).json")
        let r = relay(missing)
        for method in ["initialize", "tools/list", "ping"] {
            let answer = try object(await r.handle(line: #"{"jsonrpc":"2.0","id":"a","method":"\#(method)"}"#))
            let error = try #require(answer["error"] as? [String: Any], "\(method)")
            #expect((error["message"] as? String)?.contains("SIMPLMAKER_NOT_RUNNING") == true && answer["id"] as? String == "a")
        }
        #expect(await r.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil, "a notification needs no answer")
    }

    @Test func anAppThatQuitWithoutTellingIsNoticedWhenTheConnectionFails() async throws {
        let file = try connectionFile(running: true); defer { try? FileManager.default.removeItem(at: file) }
        let r = Relay(connectionFile: file, post: { _ in throw URLError(.cannotConnectToHost) })
        let answer = try object(await r.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#))
        let error = ((answer["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["error"] as? [String: Any]
        #expect(error?["code"] as? String == "SIMPLMAKER_NOT_RUNNING")
    }

    @Test func aBatchGetsABatchOfAnswers() async throws {
        let file = try connectionFile(running: false); defer { try? FileManager.default.removeItem(at: file) }
        let r = relay(file)
        let line = try #require(await r.handle(line: #"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/x"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#))
        let list = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]])
        #expect(list.compactMap { $0["id"] as? Int } == [1, 2])
    }

    @Test func theAppRefusingTheSecretOrTheRequestIsExplained() async throws {
        let file = try connectionFile(); defer { try? FileManager.default.removeItem(at: file) }
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#
        for (status, code) in [(401, "SIMPLMAKER_AUTH_FAILED"), (403, "SIMPLMAKER_REFUSED"), (500, "SIMPLMAKER_ERROR")] {
            let answer = try object(await relay(file, status: status, body: "no").handle(line: call))
            let error = ((answer["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["error"] as? [String: Any]
            #expect(error?["code"] as? String == code, "HTTP \(status)")
        }
    }

    @Test func aMessageThatIsNotJSONIsAParseError() async throws {
        let file = try connectionFile(); defer { try? FileManager.default.removeItem(at: file) }
        let answer = try object(await relay(file).handle(line: "{nope"))
        #expect((answer["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    @Test func aStaleOrBrokenFileMeansNotRunning() throws {
        func connection(_ json: String) throws -> RelayConnection? {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("relay-bad-\(UUID().uuidString).json")
            try Data(json.utf8).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
            return Relay(connectionFile: url).connection()
        }
        #expect(try connection(#"{"port":1,"token":"t","pid":1,"running":true,"version":"x"}"#) == RelayConnection(port: 1, token: "t"))
        #expect(try connection(#"{"port":1,"token":"t","pid":1,"running":false,"version":"x"}"#) == nil)
        #expect(try connection(#"{"port":0,"token":"t","running":true}"#) == nil)
        #expect(try connection(#"{"port":1,"token":"","running":true}"#) == nil)
        #expect(try connection("garbage") == nil)
    }
}
