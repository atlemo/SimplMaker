// One step of the guided first part: what it says, how it knows the step is done, and what it can
// do for a user who'd rather watch.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What a step tells the user to do next, shown under its text and kept up to date as the part changes.
struct TutorialHint: Equatable {
    var text: String
    /// Something is off (a wrong plane, a number typed where a parameter belongs), not just the next move.
    var isProblem = false

    static func next(_ text: String) -> TutorialHint { TutorialHint(text: text) }
    static func problem(_ text: String) -> TutorialHint { TutorialHint(text: text, isProblem: true) }
}

/// A step in the tutorial. Steps are not a counter: the one on show is the first whose `kind` isn't
/// satisfied by the part as it is now, so undoing a step brings the card back to it, and a user who
/// jumps ahead is never told to do what is already done.
@MainActor
struct TutorialStep: Identifiable {
    enum Chapter: Int, CaseIterable {
        case start, floor, walls, change
        /// The name tag's chapters (the iPad's tutorial).
        case tagShape, tagName, tagRing, tagChange

        var title: String {
            switch self {
            case .start: return "Get started"
            case .floor: return "The floor"
            case .walls: return "The walls and sections"
            case .change, .tagChange: return "Make it yours"
            case .tagShape: return "The tag"
            case .tagName: return "Your name"
            case .tagRing: return "The ring hole"
            }
        }
    }

    enum Kind {
        /// Something to read; the button (its title) moves on.
        case read(button: String)
        /// Something to do; the step is over when the part says so.
        case task(done: @MainActor (DocumentModel) -> Bool)
    }

    let id: String
    let chapter: Chapter
    let title: String
    /// Inline Markdown: `code` for what to type, **bold** for what to click (or tap).
    let text: String
    let kind: Kind
    /// The next move, from the state of the part and the sketch.
    var hint: @MainActor (DocumentModel) -> TutorialHint? = { _ in nil }
    /// What pulses in the window (see `View.tutorialSpot`): toolbar tools by title, and "browser", "parameters", "inspector".
    var spotlight: @MainActor (DocumentModel) -> Set<String> = { _ in [] }
    /// Runs when the step comes up: opening a panel, turning the view, readying a tool.
    var enter: (@MainActor (DocumentModel) -> Void)?
    /// Does the step for the user ("Do it for me"), the way the interface would.
    var assist: (@MainActor (DocumentModel) async -> Void)?
    /// Takes the step back, when undoing isn't how (leaving sketch mode makes nothing to undo: the sketch is opened again).
    var rewind: (@MainActor (DocumentModel) async -> Void)?

    var isTask: Bool { if case .task = kind { true } else { false } }
}
