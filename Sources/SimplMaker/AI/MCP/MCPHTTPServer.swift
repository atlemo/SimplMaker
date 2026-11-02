// Carries MCPHTTPHandler over a TCP listener that is bound to the loopback address, so nothing off this Mac can
// even connect. One task per connection; a connection is dropped after a minute without a byte.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import os

final class MCPHTTPServer: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case couldNotStart(String)
        var description: String { if case .couldNotStart(let why) = self { return why } else { return "" } }
    }

    private let handler: MCPHTTPHandler
    private let queue = DispatchQueue(label: "com.simplmaker.mcp-http")
    private let state = OSAllocatedUnfairLock(initialState: (listener: NWListener?.none, active: [ObjectIdentifier: NWConnection]()))
    static let maxConnections = 32
    static let idleSeconds = 60.0

    init(handler: MCPHTTPHandler) { self.handler = handler }

    /// Starts listening on `port` (0: any free one) and returns the port it got. Throws if the port is taken.
    func start(port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        guard let endpointPort = NWEndpoint.Port(rawValue: port) ?? Optional(NWEndpoint.Port.any) else {
            throw Failure.couldNotStart("bad port")
        }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { throw Failure.couldNotStart("\(error)") }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        state.withLock { $0.listener = listener }  // before it starts, so no early connection is turned away
        let bound: UInt16
        do { bound = try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first() { continuation.resume(returning: listener.port?.rawValue ?? port) }
                case .failed(let error):
                    if once.first() { continuation.resume(throwing: Failure.couldNotStart("\(error)")) }
                    listener.cancel()
                case .cancelled:
                    if once.first() { continuation.resume(throwing: Failure.couldNotStart("cancelled")) }
                default: break
                }
            }
            listener.start(queue: queue)
        } } catch {
            state.withLock { $0.listener = nil }
            throw error
        }
        return bound
    }

    /// Stops listening and drops every connection that is open: a client that connected earlier must not go on being
    /// served after the user has turned the interface off.
    func stop() {
        let (listener, open) = state.withLock { s -> (NWListener?, [NWConnection]) in
            defer { s.listener = nil; s.active = [:] }
            return (s.listener, Array(s.active.values))
        }
        listener?.cancel()
        for connection in open { connection.cancel() }
    }

    private final class Once: Sendable {
        private let done = OSAllocatedUnfairLock(initialState: false)
        func first() -> Bool { done.withLock { d in if d { return false }; d = true; return true } }
    }

    // MARK: connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let tooMany = state.withLock { s -> Bool in
            if s.active.count >= Self.maxConnections || s.listener == nil { return true }
            s.active[id] = connection
            return false
        }
        guard !tooMany else { connection.cancel(); return }
        Task.detached { [self] in
            await serve(connection)
            state.withLock { _ = $0.active.removeValue(forKey: id) }
        }
    }

    private func serve(_ connection: NWConnection) async {
        connection.start(queue: queue)
        defer { connection.cancel() }
        var buffer = Data()
        var sentContinue = false
        while true {
            switch HTTPRequestParser.parse(buffer) {
            case .request(let request, let consumed):
                buffer.removeFirst(consumed)
                sentContinue = false
                let response = await handler.respond(to: request)
                guard await send(response.serialized(), on: connection), !response.closes else { return }
            case .invalid(let response):
                _ = await send(response.serialized(), on: connection)
                return
            case .incomplete(let expectContinue):
                if expectContinue, !sentContinue {
                    sentContinue = true
                    guard await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), on: connection) else { return }
                }
                guard let more = await receive(on: connection) else { return }
                buffer.append(more)
            }
        }
    }

    private func receive(on connection: NWConnection) async -> Data? {
        let idle = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.idleSeconds, execute: idle)
        defer { idle.cancel() }
        return await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { _ = (isComplete, error); continuation.resume(returning: nil) }
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in continuation.resume(returning: error == nil) })
        }
    }
}
