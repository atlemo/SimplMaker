// The timeline: every feature in build order, as a horizontal bar along the bottom of the window,
// with a marker that rolls the model back to any point (like the timeline in other CAD tools).
// SPDX-License-Identifier: GPL-3.0-or-later
import CADCore
import SwiftUI

extension Feature {
    /// The glyph for a feature, the same as the tool that makes it.
    var iconName: String {
        switch kind {
        case .sketch: return "pen-tool"
        case .extrude: return DesignTool.extrude.symbol
        case .fillet: return DesignTool.fillet.symbol
        case .chamfer: return DesignTool.chamfer.symbol
        case .revolve: return DesignTool.revolve.symbol
        case .sweep: return DesignTool.sweep.symbol
        case .loft: return DesignTool.loft.symbol
        case .rib: return DesignTool.rib.symbol
        case .hole: return DesignTool.hole.symbol
        case .thread: return DesignTool.thread.symbol
        case .pipe: return DesignTool.pipe.symbol
        case .move(let m): return m.rotating ? DesignTool.rotate.symbol : DesignTool.move.symbol
        case .rotate: return DesignTool.rotate.symbol
        case .scale: return DesignTool.scale.symbol
        case .combine: return DesignTool.combine.symbol
        case .plane: return DesignTool.plane.symbol
        case .mirror: return DesignTool.mirror.symbol
        case .pattern: return DesignTool.pattern.symbol
        case .shell: return DesignTool.shell.symbol
        case .importBody: return "file-box"
        case .image: return DesignTool.canvas.symbol
        case .primitive(let p):
            switch p.kind {
            case .box: return DesignTool.box.symbol
            case .cylinder: return DesignTool.cylinder.symbol
            case .sphere: return DesignTool.sphere.symbol
            case .torus: return DesignTool.torus.symbol
            case .coil: return DesignTool.coil.symbol
            }
        }
    }
}

struct TimelineBar: View {
    let model: DocumentModel
    /// Where the marker is while it's being dragged.
    @State private var dragPosition: Int?
    /// A feature being dragged to another place in the timeline, and how far it has moved.
    @State private var moving: (id: FeatureID, dx: CGFloat)?

    nonisolated static let height: CGFloat = 44
    private static let item: CGFloat = 30
    private static let spacing: CGFloat = 4
    private static var step: CGFloat { item + spacing }

    private var marker: Int { dragPosition ?? model.markerPosition }

    var body: some View {
        HStack(spacing: DS.Spacing.space4) {
            playback
            Divider().frame(height: 22)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Self.spacing) {
                        ForEach(Array(model.document.features.enumerated()), id: \.element.id) { i, f in
                            if i == marker { markerView }
                            item(f, index: i)
                        }
                        if marker >= model.document.features.count { markerView }
                    }
                    .padding(.horizontal, DS.Spacing.space2)
                    .frame(height: Self.height)
                }
                .onChange(of: model.document.features.count) {
                    if let last = model.document.features.last?.id { withAnimation { proxy.scrollTo(last) } }
                }
            }
            if model.document.features.isEmpty {
                Text("Features you add appear here, in the order they're built.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, DS.Spacing.space4)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.Radius.xl3))
    }

    /// Start · back one · forward one · end, for the marker. (Named here: the symbols' own names
    /// have start and end the wrong way round for a timeline.)
    private var playback: some View {
        let count = model.document.features.count, at = model.markerPosition
        return HStack(spacing: DS.Spacing.space3) {
            Button { model.setMarker(0) } label: { Image(systemName: "backward.end.fill") }
                .help("Roll back to the start").accessibilityLabel("Start").disabled(at == 0)
            Button { model.setMarker(at - 1) } label: { Image(systemName: "backward.frame.fill") }
                .help("Step back one feature").accessibilityLabel("Back one").disabled(at == 0)
            Button { model.setMarker(at + 1) } label: { Image(systemName: "forward.frame.fill") }
                .help("Step forward one feature").accessibilityLabel("Forward one").disabled(at >= count)
            Button { model.setMarker(count) } label: { Image(systemName: "forward.end.fill") }
                .help("Roll forward to the end").accessibilityLabel("End").disabled(at >= count)
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .frame(height: Self.item)
    }

    private func item(_ f: Feature, index: Int) -> some View {
        let selected = model.selectedFeature == f.id
        let error = model.result?.errors[f.id]
        let rolledBack = index >= marker
        let dx = moving?.id == f.id ? moving?.dx ?? 0 : 0
        return Icon(f.iconName, size: 17)
            .frame(width: Self.item, height: Self.item)
            .background(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if error != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .offset(x: 2, y: 2)
                }
            }
            .opacity(rolledBack ? 0.35 : f.suppressed ? 0.5 : 1)
            .contentShape(Rectangle())
            .offset(x: dx)
            .zIndex(dx == 0 ? 0 : 1)
            .shadow(color: .black.opacity(dx == 0 ? 0 : 0.25), radius: 4, y: 2)
            .help(error.map { "\(f.name): \($0)" } ?? "\(f.name)\(f.suppressed ? " (suppressed)" : "") · double-click to edit · drag to reorder")
            .onTapGesture(count: 2) { model.editFeature(f.id) }
            .onTapGesture { model.selection = []; model.bringIntoModel(f.id); model.selectedFeature = f.id }
            // Drag sideways to move it earlier or later in the timeline.
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { g in moving = (f.id, g.translation.width) }
                .onEnded { g in
                    moving = nil
                    let steps = Int((g.translation.width / Self.step).rounded())
                    if steps != 0 { model.moveFeature(f.id, to: index + steps) }
                })
            .contextMenu {
                Button("Edit \(f.name)") { model.editFeature(f.id) }
                if model.profileSource(f.id) != nil {
                    Button("Reselect Profiles…") { model.reselectProfiles(f.id) }
                }
                Button(f.suppressed ? "Unsuppress" : "Suppress") {
                    model.updateFeature(f.id, f.suppressed ? "Unsuppress" : "Suppress") { $0.suppressed.toggle() }
                }
                Button("Roll Back to Here") { model.setMarker(index) }
                Divider()
                Button("Move Earlier") { model.moveFeature(f.id, to: index - 1) }
                    .disabled(index == 0 || model.document.reorderProblem(f.id, to: index - 1) != nil)
                Button("Move Later") { model.moveFeature(f.id, to: index + 1) }
                    .disabled(index + 1 >= model.document.features.count || model.document.reorderProblem(f.id, to: index + 1) != nil)
                Divider()
                Button("Delete \(f.name)", role: .destructive) { model.deleteFeature(f.id) }
            }
            .id(f.id)
            .accessibilityLabel(f.name)
    }

    /// The marker: drag it left or right to roll the model back or forward.
    private var markerView: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 4, height: Self.item + 6)
            .padding(.horizontal, 2)
            .contentShape(Rectangle().inset(by: -6))
            .help("Drag to roll the model back to an earlier point")
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { g in
                        let start = model.markerPosition
                        let p = min(max(start + Int((g.translation.width / Self.step).rounded()), 0), model.document.features.count)
                        if p != dragPosition {
                            dragPosition = p
                            model.previewMarker(p)
                        }
                    }
                    .onEnded { _ in
                        if let p = dragPosition { model.setMarker(p) }
                        dragPosition = nil
                    }
            )
            .accessibilityLabel("Timeline marker")
    }
}
