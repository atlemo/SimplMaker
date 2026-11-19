// The window's workspaces: the part of the app the tools and panels belong to. Design is the modelling the app
// began with (sketches, features, the timeline); Mold is the studio for making a printable mold of a body. A
// workspace is a way of working with the same document, not a feature: it is not saved and has no undo step. Split sits between them: it cuts a
// body that is too big for the printer into pieces with connectors, and the pieces can then go on to be a mold or be printed.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import Foundation

extension Preferences {
    /// Shows the Mold workspace in the window's mode selector while it is being built (Settings has no switch for it yet).
}

enum Workspace: String, CaseIterable, Identifiable, Sendable {
    case start = "Start"
    case design = "Design"
    case split = "Split"
    case mold = "Mold"
    case render = "Render"

    var id: String { rawValue }

    /// The workspaces the mode selector offers.
    static var available: [Workspace] { allCases }

    /// Whether the workspace has a row of tool islands under the toolbar. Start is a page of its own, and Render is for looking.
    var hasTools: Bool { self == .design || self == .split || self == .mold }

    var help: String {
        switch self {
        case .start: "The start page: new and recent parts, and the ways to begin"
        case .design: "Model the part: sketches, features and the timeline"
        case .split: "Cut a part that is too big into pieces that fit your printer, with connectors to put them back together"
        case .mold: "Make a printable mold of a body, to cast copies of it"
        case .render: "Show the part on a floor with a light you set, for presentation"
        }
    }
}

extension DocumentModel {
    /// The workspace a part opens in: the start page while it is empty, otherwise Design.
    static func openingWorkspace(for document: CADDocument) -> Workspace {
        document.features.isEmpty ? .start : .design
    }

    /// Moves the window to a workspace. A sketch being edited is finished and a tool waiting for picks is dropped first,
    /// since the tools they belong to are not there any more; leaving Render turns its view off, entering it turns it on.
    func setWorkspace(_ next: Workspace) {
        guard next != workspace else {
            if next == .render { showRenderOptions = true }  // the Render segment pressed again brings its panel back
            return
        }
        guard Workspace.available.contains(next) else { return }
        if sketchSession != nil { finishSketch() }
        if isPickingSketchPlane { cancelSketchPlanePick() }
        if pendingTool != nil { cancelTool() }
        // Read before the Render view is switched: turning it on or off moves `workspace` itself, and the workspace
        // being left (Mold, Split) must still be told it was left, or its scene and bounds linger (a floor under a body that floats).
        let previous = workspace
        if renderView, next != .render { applyRenderView(false) }
        if next == .render { applyRenderView(true) }
        workspace = next
        if next == .mold || previous == .mold { moldWorkspaceChanged(entering: next == .mold) }
        if next == .split || previous == .split { splitWorkspaceChanged(entering: next == .split) }
    }

    /// A design tool is about to run (from a key, a menu or a button of the start page): the window goes to Design first.
    /// (The iPad has no workspaces: its Render view and tools work side by side as they did.)
    func ensureDesignWorkspace() {
        #if os(macOS)
        if workspace != .design { setWorkspace(.design) }
        #endif
    }
}
