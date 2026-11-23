// How the workspaces are shown to the person: a glyph, a colour, what each is for. Shared by the Mac's ribbon and the iPad's workspace menu.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

// MARK: Workspaces, as the switcher shows them

extension Workspace {
    /// The glyph that stands for the workspace.
    var symbol: String {
        switch self {
        case .start: "house"
        case .design: "pen-tool"
        case .split: "puzzle"
        case .mold: "split-body"
        case .render: "camera"
        }
    }

    /// What it is for, in a line.
    var summary: String {
        switch self {
        case .start: "New and recent parts, and the ways to begin"
        case .design: "Sketch, model and change the part, step by step"
        case .split: "Cut a big part into pieces that fit your printer, with connectors"
        case .mold: "Make a printable mold of a body, to cast copies of it"
        case .render: "Show the part on a floor with a light you set"
        }
    }

    /// What is in it.
    var contents: String {
        switch self {
        case .start: "New Part · Open · Tutorial · Recent parts"
        case .design: "Sketch · Create · Shapes · Modify · Construct · Inspect"
        case .split: "Printer · Cuts · Connectors · Fit · Export"
        case .mold: "Parting · Gate and vents · Keys · Export"
        case .render: "Floor · Light · Materials · Export image"
        }
    }

    /// The colour of its tile.
    var tint: Color {
        switch self {
        case .start: DS.brand
        case .design: Color(red: 0.22, green: 0.47, blue: 0.93)
        case .split: Color(red: 0.88, green: 0.52, blue: 0.10)
        case .mold: Color(red: 0.09, green: 0.60, blue: 0.55)
        case .render: Color(red: 0.80, green: 0.27, blue: 0.55)
        }
    }
}


/// A thin line between the workspace button and the tools, and between tool groups.
struct RibbonDivider: View {
    @Environment(\.toolsOnTint) private var onTint
    @Environment(\.toolsInk) private var ink

    var body: some View {
        Rectangle()
            .fill((onTint ? ink : Color.primary).opacity(onTint ? 0.35 : 0.14))
            .frame(width: 1, height: 44)
    }
}


extension Workspace {
    /// The same glyph as an SF Symbol, for the iPad's menu (the Mac draws `symbol` with its own icon set).
    var systemImage: String {
        switch self {
        case .start: "house"
        case .design: "pencil.and.ruler"
        case .split: "puzzlepiece"
        case .mold: "square.split.2x1"
        case .render: "camera"
        }
    }
}

extension View {
    /// A menu drawn as a plain tool in a workspace's tool row (the printer, the piece counts): no button chrome and no arrow of its own.
    @ViewBuilder func ribbonMenuStyle() -> some View {
        #if os(macOS)
        menuStyle(.borderlessButton).menuIndicator(.hidden)
        #else
        menuIndicator(.hidden).buttonStyle(.plain)
        #endif
    }
}

extension View {
    /// The Mac's ribbon gives a workspace's tool row 44 pt; on the iPad the row takes the height it needs (the groups' names sit under their buttons).
    @ViewBuilder func workspaceRowHeight() -> some View {
        #if os(macOS)
        frame(height: 44)
        #else
        self
        #endif
    }
}
