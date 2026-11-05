// The tools, in a strip at the bottom of the viewport. What it shows follows what the model is waiting for: the tools to
// start with, a plane to sketch on, the sketch tools, or a picked feature's confirm and cancel.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import SwiftUI

struct PadToolStrip: View {
    let model: DocumentModel

    var body: some View {
        VStack(spacing: 8) {
            if let prompt { Text(prompt).font(.footnote).multilineTextAlignment(.center).lineLimit(3)
                .padding(.horizontal, 12).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
                .accessibilityIdentifier("prompt") }
            HStack(spacing: 4) { tools }
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
        .frame(maxWidth: 640)
        .padding(.bottom, 8)
    }

    /// What to tell the finger: the sketch tool's hint, or what the waiting tool wants.
    private var prompt: String? {
        if let session = model.sketchSession { return session.statusText }
        if model.isPickingSketchPlane { return "Tap a plane or a flat face to sketch on" }
        return model.toolPrompt
    }

    @ViewBuilder private var tools: some View {
        if let session = model.sketchSession {
            ForEach(Self.sketchTools, id: \.tool) { item in
                ToolButton(title: item.tool.shortTitle, symbol: item.symbol, active: session.tool == item.tool) {
                    model.setSketchTool(item.tool)
                }
            }
            Divider().frame(height: 36)
            ToolButton(title: "Delete", symbol: "trash", active: false) { model.sketchCommand { $0.deleteSelection() } }
            ToolButton(title: "Done", symbol: "checkmark.circle.fill", active: false, tint: .green) { model.finishSketch() }
        } else if model.isPickingSketchPlane {
            ToolButton(title: "Cancel", symbol: "xmark.circle", active: false) { model.cancelSketchPlanePick() }
        } else if let tool = model.pendingTool {
            ToolButton(title: "Cancel", symbol: "xmark.circle", active: false) { model.cancelTool() }
            ToolButton(title: tool.rawValue, symbol: Self.symbol(for: tool), active: true) { model.confirmTool() }
            ToolButton(title: "Done", symbol: "checkmark.circle.fill", active: false, tint: .green) { model.confirmTool() }
        } else {
            ToolButton(title: "Sketch", symbol: "pencil.and.ruler", active: false) { model.startSketch() }
            Divider().frame(height: 36)
            ForEach(Self.designTools, id: \.self) { tool in
                ToolButton(title: tool.rawValue, symbol: Self.symbol(for: tool), active: false) { model.run(tool) }
            }
        }
    }

    static let sketchTools: [(tool: SketchTool, symbol: String)] = [
        (.select, "cursorarrow"), (.line, "line.diagonal"), (.rectangle, "rectangle"), (.circle, "circle"),
        (.arc3Point, "point.topleft.down.to.point.bottomright.curvepath"), (.polygon, "hexagon"),
    ]

    static let designTools: [DesignTool] = [.extrude, .box, .cylinder, .fillet, .chamfer]

    static func symbol(for tool: DesignTool) -> String {
        switch tool {
        case .extrude: return "arrow.up.to.line"
        case .box: return "cube"
        case .cylinder: return "cylinder"
        case .fillet: return "square.on.square.dashed"
        case .chamfer: return "triangle"
        default: return "wrench.and.screwdriver"
        }
    }
}

private struct ToolButton: View {
    let title: String
    let symbol: String
    let active: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 20)).frame(height: 24)
                Text(title).font(.caption2).lineLimit(1)
            }
            .frame(minWidth: 56, minHeight: 48)
            .foregroundStyle(active ? Color.white : tint)
            .background(active ? tint : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tool-\(title)")
    }
}
