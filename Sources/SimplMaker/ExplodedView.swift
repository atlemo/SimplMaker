// The Exploded View (View menu): the bodies slide apart in equal steps, a little or a lot, to show
// how it is built up. A view setting like the section analysis: it reads the model without changing it, so no
// feature, no undo step, nothing saved. The renderer draws each body shifted by its offset (see Renderer.setScene).
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import simd
import SwiftUI

/// Which way the bodies move apart.
enum ExplodeDirection: String, CaseIterable, Identifiable {
    case all, x, y, z

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .x: return "X"
        case .y: return "Y"
        case .z: return "Z"
        }
    }

    /// The axis a body moves along; nil: away from the middle in every direction.
    var axis: SIMD3<Float>? {
        switch self {
        case .all: return nil
        case .x: return SIMD3(1, 0, 0)
        case .y: return SIMD3(0, 1, 0)
        case .z: return SIMD3(0, 0, 1)
        }
    }
}

enum ExplodedView {
    /// Bodies whose middles lie this close along an axis (as a share of the part's length on it) are one layer.
    static let layerTolerance: Float = 0.02

    /// How far each body moves, given the box around each one. Along an axis the bodies are sorted into layers by
    /// the middle of their boxes (bodies side by side at one level share a layer), and each layer moves one equal
    /// step further from the next: the part grows by `amount` times its own length on that axis, the middle layer
    /// stays, and every gap between layers opens by the same distance. "All" does this on X, Y and Z at once.
    static func offsets(boxes: [(min: SIMD3<Float>, max: SIMD3<Float>)], amount: Double, direction: ExplodeDirection) -> [SIMD3<Float>] {
        guard boxes.count > 1, amount > 0 else { return boxes.map { _ in .zero } }
        let axes: [Int] = direction.axis.map { [$0.x != 0 ? 0 : $0.y != 0 ? 1 : 2] } ?? [0, 1, 2]
        var out = [SIMD3<Float>](repeating: .zero, count: boxes.count)
        for axis in axes {
            let span = boxes.map(\.max[axis]).max()! - boxes.map(\.min[axis]).min()!
            guard span > 1e-6 else { continue }
            let centers = boxes.map { ($0.min[axis] + $0.max[axis]) / 2 }
            let order = centers.indices.sorted { centers[$0] < centers[$1] }
            // Layers, in order: a body joins the last one when its middle is near that layer's first.
            var layerOf = [Int](repeating: 0, count: boxes.count)
            var layers = 0, layerStart = centers[order[0]]
            for (n, i) in order.enumerated() {
                if n > 0, centers[i] - layerStart > layerTolerance * span { layers += 1; layerStart = centers[i] }
                layerOf[i] = layers
            }
            guard layers > 0 else { continue }
            let step = Float(amount) * span / Float(layers)
            for i in boxes.indices { out[i][axis] = (Float(layerOf[i]) - Float(layers) / 2) * step }
        }
        return out
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
        return ExplodedView.offsets(boxes: bodyBoxes, amount: explodeAmount, direction: explodeDirection)
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
                .help("All: along X, Y and Z. X, Y or Z: along that axis only")
                Text(model.sketchSession != nil || model.pendingTool != nil
                     ? "The bodies sit back in place while you sketch or use a tool."
                     : "The bodies move apart in equal steps. Nothing in the part is changed.")
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
