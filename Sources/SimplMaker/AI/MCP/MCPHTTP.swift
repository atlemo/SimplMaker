// HTTP for the MCP server (the "Streamable HTTP" transport, in its simplest form: every POST is answered with one
// JSON body, and there is no event stream or session). This file is only text handling and rules, with no sockets,
// so it can be tested directly; MCPHTTPServer.swift carries it over a loopback connection.
//
// Who may talk to the server:
//  - only a program on this Mac (the listener is bound to 127.0.0.1);
//  - not a web page: a request whose Host isn't the loopback address, or that names a foreign Origin, is refused
//    (that is what a DNS-rebinding attack looks like), and a browser can't send the secret anyway;
//  - only with the secret: the token the Settings window shows, as "Authorization: Bearer <token>".
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

struct HTTPRequest: Equatable, Sendable {
    var method: String
    var path: String
    /// Header names in lower case.
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse: Hashable, Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    /// The connection is closed after this response.
    var closes = false

    static func text(_ status: Int, _ message: String, headers: [String: String] = [:], closes: Bool = false) -> HTTPResponse {
        var h = headers
        h["Content-Type"] = "text/plain; charset=utf-8"
        return HTTPResponse(status: status, headers: h, body: Data((message + "\n").utf8), closes: closes)
    }

    static func json(_ body: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    private static let reasons = [100: "Continue", 200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                                  404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large",
                                  415: "Unsupported Media Type", 431: "Request Header Fields Too Large", 500: "Internal Server Error"]

    /// The bytes to send.
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = closes ? "close" : "keep-alive"
        all["Cache-Control"] = "no-store"
        for key in all.keys.sorted() { head += "\(key): \(all[key]!)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

enum HTTPParse: Equatable {
    /// More bytes are needed. `expectContinue`: the client waits for "100 Continue" before it sends the body.
    case incomplete(expectContinue: Bool)
    /// A whole request, and how many bytes of the buffer it used.
    case request(HTTPRequest, consumed: Int)
    /// Not something to answer normally: send this and close.
    case invalid(HTTPResponse)
}

enum HTTPRequestParser {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 4 * 1024 * 1024

    static func parse(_ buffer: Data) -> HTTPParse {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: terminator) else {
            return buffer.count > maxHeaderBytes ? .invalid(.text(431, "The headers are too long.", closes: true)) : .incomplete(expectContinue: false)
        }
        guard end.lowerBound <= maxHeaderBytes else { return .invalid(.text(431, "The headers are too long.", closes: true)) }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(.text(400, "The headers are not text.", closes: true))
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid(.text(400, "Not an HTTP/1.1 request.", closes: true))
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(.text(400, "A header has no colon.", closes: true)) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil, name == "content-length" || name == "host" { return .invalid(.text(400, "Repeated \(name).", closes: true)) }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(.text(400, "Chunked bodies are not supported; send a Content-Length.", closes: true))
        }
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .invalid(.text(400, "Bad Content-Length.", closes: true)) }
            guard n <= maxBodyBytes else { return .invalid(.text(413, "The body is too large.", closes: true)) }
            length = n
        }
        let bodyStart = end.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= length else {
            return .incomplete(expectContinue: headers["expect"]?.lowercased() == "100-continue")
        }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)])
        let consumed = buffer.distance(from: buffer.startIndex, to: bodyStart) + length
        var path = requestLine[1]
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        return .request(HTTPRequest(method: requestLine[0].uppercased(), path: path, headers: headers, body: body), consumed: consumed)
    }
}

/// The rules: who is let in, and what a request gets.
struct MCPHTTPHandler: Sendable {
    let server: MCPServer
    /// The secret a client has to send. Read for each request, so a new token takes effect at once.
    let token: @Sendable () -> String
    /// The port the listener is on; the only `Host` values accepted name it.
    let port: @Sendable () -> UInt16
    var path = "/mcp"

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        let port = port()
        let hosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.headers["host"]?.lowercased(), hosts.contains(host) else {
            return .text(403, "Forbidden: this server answers only to its loopback address.", closes: true)
        }
        if let origin = request.headers["origin"], !Self.isLoopbackOrigin(origin) {
            return .text(403, "Forbidden: requests from web pages are not accepted.", closes: true)
        }
        // The token comes before anything is said about paths or methods: without it every request gets the same answer.
        guard Self.bearer(request.headers["authorization"]).map({ Self.constantTimeEqual($0, token()) }) == true else {
            return .text(401, "Unauthorized: send the token from SimplMaker ▸ Settings ▸ AI as \"Authorization: Bearer <token>\".",
                         headers: ["WWW-Authenticate": "Bearer realm=\"SimplMaker\""])
        }
        guard request.path == path else { return .text(404, "Not found. The MCP endpoint is \(path).") }
        guard request.method == "POST" else { return .text(405, "Use POST.", headers: ["Allow": "POST"]) }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return .text(415, "The body must be application/json.")
        }
        guard let answer = await server.handle(request.body) else { return HTTPResponse(status: 202) }
        return .json(answer)
    }

    static func bearer(_ header: String?) -> String? {
        guard let header, header.lowercased().hasPrefix("bearer ") else { return nil }
        return String(header.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }

    /// "http://127.0.0.1:8080", "http://localhost", "http://[::1]:3000": a page served from this Mac itself.
    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let scheme = url.scheme, scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Compares without stopping at the first difference, so how long it takes says nothing about the token.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var difference = x.count ^ y.count
        for i in 0..<max(x.count, y.count) { difference |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0) }
        return difference == 0
    }
}
