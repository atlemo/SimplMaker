// Starts and stops the AI interface: the MCP server on a loopback port, the secret that guards it, and the file
// that tells a relay where it is. Off until the user turns it on in Settings ▸ AI; it also stays off without a valid
// license or running trial. What it serves is CADService's: this class decides only whether there is a server.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Observation
import os

@MainActor
@Observable
final class AIConnection {
    enum Status: Equatable {
        case off
        case running(port: UInt16)
        /// Turned on, but the trial has ended or the license isn't valid.
        case needsLicense
        case failed(String)
    }

    static let shared = AIConnection()
    static let enabledKey = "aiEnabled"
    static let portKey = "aiPort"
    /// Where it listens unless that is taken: a fixed number, so a connection a user set up survives restarts.
    static let defaultPort: UInt16 = 47821

    private(set) var status = Status.off
    private(set) var token: String

    /// What the server reads for each request, from any thread.
    private let secrets: OSAllocatedUnfairLock<(token: String, port: UInt16)>
    private let defaults: UserDefaults
    private let file: MCPConnectionFile
    private let service: CADService
    private let licensed: @MainActor () -> Bool
    private let version: String
    /// Whether this build has the AI mode at all (see AIFeature). Without it nothing here ever starts.
    let isAvailable: Bool
    @ObservationIgnored private var http: MCPHTTPServer?

    init(defaults: UserDefaults = .standard, file: MCPConnectionFile = .standard, service: CADService = CADService(),
         licensed: @escaping @MainActor () -> Bool = { LicenseManager.shared.allowsEditing },
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
         available: Bool = AIFeature.isAvailable) {
        self.defaults = defaults; self.file = file; self.service = service; self.licensed = licensed; self.version = version
        isAvailable = available
        isEnabled = available && defaults.bool(forKey: Self.enabledKey)
        let initial = file.read()?.token ?? MCPConnectionFile.makeToken()
        token = initial
        secrets = OSAllocatedUnfairLock(initialState: (token: initial, port: 0))
    }

    /// Whether the user turned it on (kept in the preferences; Settings ▸ AI).
    private(set) var isEnabled: Bool

    /// The port the server has, when it is running.
    var port: UInt16? { if case .running(let p) = status { return p } else { return nil } }

    /// The address a client connects to.
    var endpoint: String? { port.map { "http://127.0.0.1:\($0)/mcp" } }

    // MARK: switching

    func setEnabled(_ on: Bool) {
        guard isAvailable else { return }
        defaults.set(on, forKey: Self.enabledKey)
        isEnabled = on
        Task { await refresh() }
    }

    /// At launch: brings the server up if the user turned it on.
    func startIfEnabled() {
        Task { await refresh() }
    }

    /// Makes the server match what is wanted: running when it is turned on and the license allows it, stopped otherwise.
    func refresh() async {
        guard isAvailable else { isEnabled = false; status = .off; return }  // not in this build: no server, no file
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        guard isEnabled else { stop(); status = .off; return }
        guard licensed() else { stop(); status = .needsLicense; return }
        if case .running = status { return }
        let preferred = UInt16(exactly: defaults.integer(forKey: Self.portKey)).flatMap { $0 == 0 ? nil : $0 } ?? Self.defaultPort
        let handler = MCPHTTPHandler(
            server: AITools.makeServer(service: service, version: version),
            token: { [secrets] in secrets.withLock { $0.token } },
            port: { [secrets] in secrets.withLock { $0.port } })
        // A taken port is no reason not to start: any free one will do, and it is remembered.
        for candidate in [preferred, 0] as [UInt16] {
            let server = MCPHTTPServer(handler: handler)
            do {
                let bound = try await server.start(port: candidate)
                secrets.withLock { $0.port = bound }
                http = server
                defaults.set(Int(bound), forKey: Self.portKey)
                status = .running(port: bound)
                writeFile(running: true, port: bound)
                return
            } catch {
                if candidate == 0 { status = .failed("\(error)") }
            }
        }
    }

    func stop() {
        guard isAvailable else { return }
        http?.stop()
        http = nil
        file.markStopped()
        secrets.withLock { $0.port = 0 }
    }

    /// A new secret: whoever has the old one is locked out, and the connection details a user pasted somewhere stop working.
    func regenerateToken() {
        let fresh = MCPConnectionFile.makeToken()
        token = fresh
        secrets.withLock { $0.token = fresh }
        if let port { writeFile(running: true, port: port) }
    }

    private func writeFile(running: Bool, port: UInt16) {
        try? file.write(MCPConnectionInfo(port: Int(port), token: token, pid: ProcessInfo.processInfo.processIdentifier,
                                          running: running, version: version))
    }

    // MARK: what a user pastes into a client

    /// The service the tools call; the tests build their own server around it.
    var serviceForTests: CADService { service }

    /// For Claude Code. `--scope user` makes it available in every folder; without it Claude Code ties the server to the
    /// folder the command is run in (a "project").
    var claudeCodeCommand: String? {
        endpoint.map { "claude mcp add --scope user --transport http simplmaker \($0) --header \"Authorization: Bearer \(token)\"" }
    }
}
