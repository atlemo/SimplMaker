// The Model Context Protocol, server side: JSON-RPC 2.0 messages in, answers out. It offers tools and nothing else
// (no resources, prompts or sampling). It is stateless: a connection needs no session, so a restart of the app
// loses nothing a client could depend on. Transports (HTTP, in MCPHTTPServer.swift) only carry the bytes.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

/// One tool an AI can call. `description` is written for a language model: the tool descriptions are part of the product.
struct MCPTool: Sendable {
    var name: String
    var title: String
    var description: String
    /// A JSON Schema for the arguments (an object).
    var inputSchema: JSONValue
    /// The tool only reads: it changes nothing in any document.
    var readOnly: Bool
    /// It may overwrite or remove what is there (a change to an existing thing, an undo), as opposed to only adding.
    var destructive = false
    /// Making the same call again leaves things as they are after the first.
    var idempotent = false
    var handler: @Sendable (JSONValue) async throws -> JSONValue
}

enum MCPError {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

final class MCPServer: Sendable {
    /// Newest first. A client asking for a version in this list gets it; any other gets the newest.
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let name: String
    let version: String
    /// Shown to the AI when it connects: how to use the tools well.
    let instructions: String
    private let tools: [MCPTool]
    /// What a tool's failure reads like to the AI: a JSON object (see `AIError`).
    private let describeFailure: @Sendable (Error) -> JSONValue
    /// Told the name and version a client gives when it connects ("initialize"), so the app can show that something is connected.
    private let onInitialize: (@Sendable (_ clientName: String, _ clientVersion: String) -> Void)?

    init(name: String, version: String, instructions: String, tools: [MCPTool],
         describeFailure: @escaping @Sendable (Error) -> JSONValue,
         onInitialize: (@Sendable (_ clientName: String, _ clientVersion: String) -> Void)? = nil) {
        self.name = name; self.version = version; self.instructions = instructions
        self.tools = tools; self.describeFailure = describeFailure; self.onInitialize = onInitialize
    }

    // MARK: messages

    /// Answers one POSTed body: a message or a batch of them. Nil when there is nothing to send back (notifications).
    func handle(_ body: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return encode(failure(id: .null, MCPError.parseError, "The body is not valid JSON."))
        }
        if case .array(let batch) = message {
            if batch.isEmpty { return encode(failure(id: .null, MCPError.invalidRequest, "An empty batch.")) }
            var answers: [JSONValue] = []
            for item in batch { if let a = await respond(to: item) { answers.append(a) } }
            return answers.isEmpty ? nil : encode(.array(answers))
        }
        return await respond(to: message).flatMap(encode)
    }

    private func encode(_ value: JSONValue) -> Data? { try? JSONEncoder().encode(value) }

    private func respond(to message: JSONValue) async -> JSONValue? {
        guard let object = message.object, object["jsonrpc"]?.string == "2.0" else {
            return failure(id: .null, MCPError.invalidRequest, "Not a JSON-RPC 2.0 message.")
        }
        // A message with a result or an error is a client's answer to something we asked; we ask nothing.
        if object["result"] != nil || object["error"] != nil { return nil }
        guard let method = object["method"]?.string else {
            return failure(id: object["id"] ?? .null, MCPError.invalidRequest, "The message has no method.")
        }
        let id = object["id"]  // nil: a notification, which is never answered
        let params = object["params"] ?? .object([:])
        let outcome: Result<JSONValue, RPCFailure>
        switch method {
        case "initialize": outcome = .success(initialize(params))
        case "ping": outcome = .success([:])
        case "tools/list": outcome = .success(listTools())
        case "tools/call": outcome = await callTool(params)
        default:
            if method.hasPrefix("notifications/") { return nil }
            outcome = .failure(RPCFailure(code: MCPError.methodNotFound, message: "Unknown method \(method)."))
        }
        guard let id else { return nil }
        switch outcome {
        case .success(let result): return ["jsonrpc": "2.0", "id": id, "result": result]
        case .failure(let f): return failure(id: id, f.code, f.message)
        }
    }

    private struct RPCFailure: Error { var code: Int; var message: String }

    private func failure(id: JSONValue, _ code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    // MARK: methods

    private func initialize(_ params: JSONValue) -> JSONValue {
        if let info = params["clientInfo"], let clientName = info["name"]?.string {
            onInitialize?(clientName, info["version"]?.string ?? "")
        }
        let asked = params["protocolVersion"]?.string
        let version = asked.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions[0]
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(name), "version": .string(self.version)],
            "instructions": .string(instructions),
        ]
    }

    private func listTools() -> JSONValue {
        .object(["tools": .array(tools.map { tool in
            [
                "name": .string(tool.name), "title": .string(tool.title), "description": .string(tool.description),
                "inputSchema": tool.inputSchema,
                "annotations": tool.readOnly
                    ? ["readOnlyHint": true, "openWorldHint": false]
                    : ["readOnlyHint": false, "destructiveHint": .bool(tool.destructive), "idempotentHint": .bool(tool.idempotent),
                       "openWorldHint": false],
            ]
        })])
    }

    /// A failing tool is a result with `isError` set, which the AI can read and react to; only a call that isn't one
    /// (no such tool, arguments that aren't an object) is a protocol error.
    private func callTool(_ params: JSONValue) async -> Result<JSONValue, RPCFailure> {
        guard let name = params["name"]?.string else {
            return .failure(RPCFailure(code: MCPError.invalidParams, message: "tools/call needs a tool name."))
        }
        guard let tool = tools.first(where: { $0.name == name }) else {
            return .failure(RPCFailure(code: MCPError.invalidParams, message: "There is no tool called \(name)."))
        }
        let arguments = params["arguments"] ?? .object([:])
        guard arguments.object != nil else {
            return .failure(RPCFailure(code: MCPError.invalidParams, message: "The arguments must be a JSON object."))
        }
        do {
            return .success(toolResult(try await tool.handler(arguments), isError: false))
        } catch {
            return .success(toolResult(describeFailure(error), isError: true))
        }
    }

    /// The structured result, and the same as text for clients that only show text.
    private func toolResult(_ value: JSONValue, isError: Bool) -> JSONValue {
        var result: [String: JSONValue] = ["content": [["type": "text", "text": .string(value.text())]]]
        if value.object != nil { result["structuredContent"] = value }
        if isError { result["isError"] = true }
        return .object(result)
    }
}
