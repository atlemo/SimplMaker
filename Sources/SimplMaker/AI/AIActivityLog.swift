// What the assistants did: one line for each tool call, newest first, kept while the app runs. It is for the person to see what
// happened (Settings ▸ AI), and to paste into a message when something went wrong. It holds no part data beyond a short sentence the
// tool itself gave, and nothing is written to disk.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import Observation

struct AIActivityEntry: Identifiable, Equatable {
    let id = UUID()
    var date: Date
    var tool: String
    var title: String
    /// What happened, in a sentence: the tool's own message, or why it failed.
    var summary: String
    /// For a failure: the error code (REBUILD_FAILED…).
    var code: String?
    var isError: Bool
    /// It only looked; nothing was changed.
    var readOnly: Bool
    var seconds: Double
    var document: String?

    init(_ call: MCPToolCall) {
        date = call.date; tool = call.name; title = call.title; isError = call.isError; readOnly = call.readOnly; seconds = call.seconds
        document = call.arguments["document_id"]?.string
        if call.isError {
            code = call.result["error"]?["code"]?.string
            summary = call.result["error"]?["message"]?.string ?? "It failed."
        } else {
            var text = call.result["message"]?.string ?? call.title
            // A batch says how many steps; naming them says what they were.
            if call.name == "batch", let steps = call.arguments["operations"]?.array {
                let names = steps.compactMap { $0["tool"]?.string }.map { $0.replacingOccurrences(of: "create_", with: "") }
                text += " (" + names.joined(separator: ", ") + ")"
            }
            summary = text
        }
    }

    /// One line of plain text, for pasting.
    var line: String {
        let time = date.formatted(date: .omitted, time: .standard)
        let seconds = self.seconds >= 0.05 ? String(format: " %.1f s", self.seconds) : ""
        return "\(time) \(tool)\(seconds)\(isError ? " FAILED" + (code.map { " (\($0))" } ?? "") : ""): \(summary)"
    }
}

@MainActor
@Observable
final class AIActivityLog {
    /// Newest first.
    private(set) var entries: [AIActivityEntry] = []
    let limit: Int

    init(limit: Int = 300) { self.limit = limit }

    func record(_ call: MCPToolCall) {
        entries.insert(AIActivityEntry(call), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    func clear() { entries = [] }

    /// What to show: everything, or only what changed something or went wrong.
    func shown(includingLooks: Bool) -> [AIActivityEntry] {
        includingLooks ? entries : entries.filter { !$0.readOnly || $0.isError }
    }

    /// The entries as text, oldest first, to paste into a message.
    func text(includingLooks: Bool) -> String {
        shown(includingLooks: includingLooks).reversed().map(\.line).joined(separator: "\n")
    }
}
