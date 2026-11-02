// simplmaker-mcp: lets a client that starts MCP servers as programs (Claude Desktop) talk to the running SimplMaker.
// Reads one JSON-RPC message per line on standard input and writes one answer per line on standard output; anything
// meant for a human goes to standard error. See Relay.swift.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let relay = Relay(connectionFile: Relay.standardConnectionFile)
while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    if let answer = await relay.handle(line: trimmed) {
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
    }
}
