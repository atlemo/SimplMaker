// The Exploded View (View menu): every body slides away from the middle of the part, a little or a lot, to show
// how it is built up. A view setting like the section analysis: it reads the model without changing it, so no
// feature, no undo step, nothing saved. The renderer draws each body shifted by its offset (see Renderer.setScene).
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation
import simd
import SwiftUI

/// Which way the bodies move apart.
enum ExplodeDirection: String, CaseIterable, Identifiable {
    case radial, x, y, z

    var id: String { rawValue }

    var title: String {
        switch self {
        case .radial: return "All"
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        }
    }

    /// The axis a body moves along; nil: away from the middle in every direction.
    var axis: SIMD3<Float>? {
        switch self {
        case .radial: return nil
        case .x: return SIMD3(1, 0, 0)
        case .y: return SIMD3(0, 1, 0)
        case .z: return SIMD3(0, 0, 1)
        }
    }
}

enum ExplodedView {
    /// How far apart the bodies end up with the slider at its end, as a multiple of their distance from the middle.
    static let reach: Float = 2

    /// How far each body moves, given the middle of each one. The part's middle is the middle of the box around all
    /// the bodies; a body moves along the line from there to its own middle, `amount * reach` times as far as it
    /// already lies from it. With an axis, only the part of that line along the axis counts (a stack of layers
    /// opens up like an accordion). A body that lies on the middle stays where it is.
    static func offsets(centers: [SIMD3<Float>], amount: Double, direction: ExplodeDirection) -> [SIMD3<Float>] {
        guard centers.count > 1, amount > 0 else { return centers.map { _ in .zero } }
        var lo = centers[0], hi = centers[0]
        for c in centers { lo = simd_min(lo, c); hi = simd_max(hi, c) }
        let middle = (lo + hi) / 2
        let scale = Float(amount) * reach
        return centers.map { c in
            let away = c - middle
            if let axis = direction.axis { return axis * simd_dot(away, axis) * scale }
            return away * scale
        }
    }
}

extension DocumentModel {
    /// The box around each shown body, in the order of `visibleMeshes`. Kept until the scene or what is shown changes.
    var bodyBoxes: [(min: SIMD3<Float>, max: SIMD3<Float>)] {
        let hidden = document.hidden
        if let cached = bodyBoxesCache, cached.revision == sceneRevision, cached.hidden == hidden { return cached.value }
        let value = visibleMeshes.map { m -> (min: SIMD3<Float>, max: SIMD3<Float>) in
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            let p = m.mesh.positions
            for i in stride(from: 0, to: p.count, by: 3) {
                let v = SIMD3(p[i], p[i + 1], p[i + 2])
                lo = simd_min(lo, v); hi = simd_max(hi, v)
            }
            return p.isEmpty ? (.zero, .zero) : (lo, hi)
        }
        bodyBoxesCache = (sceneRevision, hidden, value)
        return value
    }

    /// Whether there is anything to pull apart.
    var canExplode: Bool { visibleMeshes.count > 1 }

    /// What the viewport shifts each shown body by now. Zero while the view is off, and while a sketch or a tool is
    /// at work: their handles and previews are drawn where the bodies really are.
    var explodeOffsets: [SIMD3<Float>] {
        guard explodeOn, sketchSession == nil, pendingTool == nil else { return [] }
        return ExplodedView.offsets(centers: bodyBoxes.map { ($0.min + $0.max) / 2 }, amount: explodeAmount, direction: explodeDirection)
    }

    /// What the bodies take up as drawn now, shifted apart; nil for an empty scene.
    var explodedSceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        let shifts = explodeOffsets
        guard !shifts.isEmpty else { return sceneBounds }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for (box, shift) in zip(bodyBoxes, shifts) {
            lo = simd_min(lo, box.min + shift); hi = simd_max(hi, box.max + shift)
        }
        return lo.x <= hi.x ? (lo, hi) : nil
    }

    /// Turns the exploded view on or off; on, it opens its panel.
    func setExplodedView(_ on: Bool) {
        explodeOn = on
        if on { showExplodeOptions = true }
    }
}

/// The exploded view's panel: the slider, and which way the bodies go.
struct ExplodePanel: View {
    @Bindable var model: DocumentModel
    static let width: CGFloat = 270

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space5) {
            HStack {
                Text("Exploded View").font(.headline)
                Spacer()
                HeaderIconButton(systemImage: "xmark", help: "Close the exploded view") { model.setExplodedView(false) }
            }
            if model.canExplode {
                HStack(spacing: DS.Spacing.space4) {
                    Slider(value: $model.explodeAmount, in: 0...1)
                        .help("Move the bodies apart")
                    Text("\(Int((model.explodeAmount * 100).rounded())) %")
                        .font(.callout)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Picker("Direction", selection: $model.explodeDirection) {
                    ForEach(ExplodeDirection.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("All: away from the middle in every direction. X, Y or Z: along that axis only")
                Text(model.sketchSession != nil || model.pendingTool != nil
                     ? "The bodies sit back in place while you sketch or use a tool."
                     : "Bodies move away from the middle of the part. Nothing in the part is changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("There is only one body. Make a second one and they can be pulled apart.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.space6)
        .frame(width: Self.width)
        .panelGlass(in: .rect(cornerRadius: DS.Radius.window))
    }
}
