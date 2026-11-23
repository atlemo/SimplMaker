// The Render workspace's tool row (Mac): the controls you reach for all the time, kept out of the options panel.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The Render view's tool row: the quality segments · View (turntable, options panel) · Export. What is tuned value by value (floor, light,
/// shadows, the Advanced tab) stays in `RenderPanel`.
struct RenderToolbar: View {
    @Bindable var model: DocumentModel

    var body: some View {
        HStack(spacing: DS.Spacing.space3) {
            // No title and no group: the names of the segments say what it is, and it centres in the bar's whole height
            // (the tools' groups carry a label under them, which lifts their icons).
            SegmentedRow(items: RenderSettings.Quality.allCases.map { q in
                SegmentedRow.Item(title: q.title, selected: model.renderSettings.matchingQuality == q) { model.renderSettings.apply(q) }
            } + [SegmentedRow.Item(title: "Custom", selected: model.renderSettings.matchingQuality == nil, action: nil)],
                         compact: true)
                .padding(.horizontal, DS.Spacing.space2)
                .help(model.renderSettings.matchingQuality?.detail ?? "Your own mix of the Advanced settings")
            RibbonDivider()
            MoldGroup(title: "View") {
                ToolButton(title: "Turntable", icon: model.renderSpinning ? "pause" : "play", active: model.renderSpinning,
                           help: model.renderSpinning ? "Pause the turntable" : "Slowly turn the part around so every side comes into view") {
                    model.renderSpinning.toggle()
                }
                ToolButton(title: "Options", icon: "sliders-horizontal", active: model.showRenderOptions,
                           help: model.showRenderOptions ? "Hide the render options" : "Show the render options: floor, light, shadows and the rest") {
                    model.showRenderOptions.toggle()
                }
            }
            RibbonDivider()
            MoldGroup(title: "Export") {
                ToolButton(title: "Export", icon: "download", help: "Save what the view shows as a picture, with or without the background") {
                    model.exportImageWithDialog()
                }
            }
        }
        .workspaceRowHeight()
        .fixedSize()
    }
}
