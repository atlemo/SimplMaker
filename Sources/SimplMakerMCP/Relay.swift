// The stdio side of SimplMaker's MCP interface, for clients that start a server as a program (Claude Desktop). It holds
// no CAD knowledge and no state: each message a client writes to standard input is posted to the running SimplMaker
// (whose port and secret it reads from the connection file the app keeps), and the answer is written back as one line.
// When SimplMaker isn't running it says so in words the AI can act on: SIMPLMAKER_NOT_RUNNING.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

struct RelayConnection: Equatable {
    var port: Int
    var token: String
}

struct Relay {
    /// What the post to the app came back with.
    struct Reply { var status: Int; var body: Data }

    var connectionFile: URL
    /// Posts to the app; throws when nothing is listening. Replaceable, for tests.
    var post: (URLRequest) async throws -> Reply = Relay.urlSessionPost

    /// ~/Library/Application Support/SimplMaker/mcp-connection.json, or the file the SIMPLMAKER_MCP_CONNECTION_FILE
    /// environment variable names (for tests; it only redirects this process).
    static var standardConnectionFile: URL {
        if let override = ProcessInfo.processInfo.environment["SIMPLMAKER_MCP_CONNECTION_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SimplMaker/mcp-connection.json")
    }

    static func urlSessionPost(_ request: URLRequest) async throws -> Reply {
        let (data, response) = try await URLSession.shared.data(for: request)
        return Reply(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    // MARK: the connection file

    /// Where the app says it is, if it says it is running.
    func connection() -> RelayConnection? {
        guard let data = try? Data(contentsOf: connectionFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["running"] as? Bool == true, let port = json["port"] as? Int, let token = json["token"] as? String,
              port > 0, !token.isEmpty else { return nil }
        return RelayConnection(port: port, token: token)
    }

    // MARK: one line in, one line out

    /// The line to write back for one line read, or nil when nothing is to be written (a notification).
    func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return Self.line(Self.rpcError(id: NSNull(), code: -32700, "The message is not valid JSON."))
        }
        guard let connection = connection() else { return Self.notRunning(for: message) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(connection.port)/mcp")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300  // a rebuild of a big part can take a while
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        let reply: Reply
        do { reply = try await post(request) } catch { return Self.notRunning(for: message) }
        switch reply.status {
        case 200: return String(data: Self.oneLine(reply.body), encoding: .utf8)
        case 202: return nil
        case 401: return Self.failure(for: message, code: "SIMPLMAKER_AUTH_FAILED",
                                      "SimplMaker did not accept the connection secret.",
                                      "Open SimplMaker ▸ Settings ▸ AI and check that the interface is on; if the secret was renewed, reconnect the client.")
        case 403, 404, 405, 415: return Self.failure(for: message, code: "SIMPLMAKER_REFUSED",
                                                     "SimplMaker refused the request (HTTP \(reply.status)).",
                                                     "This relay and SimplMaker may be different versions. Update both.")
        default: return Self.failure(for: message, code: "SIMPLMAKER_ERROR", "SimplMaker answered with HTTP \(reply.status).", nil)
        }
    }

    // MARK: answers made here

    static let notRunningText = "SimplMaker is not running, or its AI interface is turned off."
    static let notRunningReason = "Ask the user to open SimplMaker and turn on Settings ▸ AI, then try again."

    static func notRunning(for message: Any) -> String? {
        failure(for: message, code: "SIMPLMAKER_NOT_RUNNING", notRunningText, notRunningReason)
    }

    /// An answer for each request in `message` (several, for a batch); nil if it holds only notifications.
    static func failure(for message: Any, code: String, _ text: String, _ reason: String?) -> String? {
        if let batch = message as? [Any] {
            let answers = batch.compactMap { answer(for: $0, code: code, text, reason) }
            return answers.isEmpty ? nil : line(answers)
        }
        return answer(for: message, code: code, text, reason).flatMap(line)
    }

    private static func answer(for message: Any, code: String, _ text: String, _ reason: String?) -> [String: Any]? {
        guard let object = message as? [String: Any], let id = object["id"], object["method"] != nil else { return nil }
        if object["method"] as? String == "tools/call" {
            // Inside a tool call it is a result the AI reads, in the same shape as every other failure.
            var error: [String: Any] = ["code": code, "message": text, "recoverable": true]
            if let reason { error["reason"] = reason }
            let structured: [String: Any] = ["success": false, "error": error]
            let json = (try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return ["jsonrpc": "2.0", "id": id,
                    "result": ["isError": true, "structuredContent": structured, "content": [["type": "text", "text": json]]]]
        }
        // Anything else (initialize, listing the tools) is a protocol error, which tells the client the server is not there.
        return rpcError(id: id, code: -32000, "\(code): \(text)" + (reason.map { " \($0)" } ?? ""))
    }

    static func rpcError(id: Any, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    // MARK: lines

    /// One line of JSON, as the stdio transport wants it (no newline inside).
    static func line(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The body with any line breaks outside strings taken out (the app sends compact JSON, so this is a safety net).
    static func oneLine(_ body: Data) -> Data {
        guard body.contains(UInt8(ascii: "\n")),
              let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
              let compact = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]) else { return body }
        return compact
    }
}
