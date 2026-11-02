// Moving, rotating and scaling the geometry of a sketch (a selection of it, or all of it).
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum SketchTransform: Sendable, Equatable {
    case move(dx: Double, dy: Double)
    /// Counter-clockwise, in radians.
    case rotate(angle: Double, about: SIMD2<Double>)
    case scale(factor: Double, about: SIMD2<Double>)
}

extension Sketch {
    /// The curves a transform of `selection` works on: the selected ones, or every one when nothing is selected.
    func transformCurves(_ selection: [EntityID]) -> [SketchCurve] {
        (selection.isEmpty ? curves : curves.filter { selection.contains($0.id) }).filter { !Sketch.isGenerated($0.id) }
    }

    /// The points a transform of `selection` moves: those of the selected curves, the selected points,
    /// and the anchors of selected texts. With nothing selected, every point. Fixed points stay put.
    public func transformPoints(_ selection: [EntityID]) -> Set<EntityID> {
        var out = Set<EntityID>()
        if selection.isEmpty {
            out = Set(points.map(\.id))
        } else {
            for c in transformCurves(selection) { out.formUnion(pointIDs(of: c)) }
            for id in selection where point(id) != nil { out.insert(id) }
        }
        return out.filter { point($0)?.fixed == false }
    }

    /// The middle of the box around what a transform of `selection` works on; nil if there's nothing.
    public func transformCenter(_ selection: [EntityID]) -> SIMD2<Double>? {
        var lo = SIMD2(Double.infinity, Double.infinity), hi = -lo
        func grow(_ p: SIMD2<Double>) { lo.replace(with: p, where: p .< lo); hi.replace(with: p, where: p .> hi) }
        let ids = selection.isEmpty ? Set(points.map(\.id).filter { !Sketch.isGenerated($0) }) : Set(transformPoints(selection))
        for id in ids { if let p = point(id), id != "origin" { grow(p.position) } }
        for c in transformCurves(selection) {
            if case .circle(let m, let r) = c.geometry, let p = point(m) { grow(p.position - SIMD2(r, r)); grow(p.position + SIMD2(r, r)) }
        }
        return lo.x <= hi.x ? (lo + hi) / 2 : nil
    }

    /// Moves, turns or scales the selection (see `transformPoints`). Scaling also grows circle radii,
    /// text heights and the dimensions that lie wholly inside what grows. Fixed-position constraints
    /// go along, and a quarter turn swaps horizontal and vertical constraints. Returns false if there's nothing to work on.
    @discardableResult
    public mutating func apply(_ t: SketchTransform, to selection: [EntityID], parameters: ParameterValues) -> Bool {
        let moving = transformPoints(selection)
        let involved = transformCurves(selection).map(\.id)
        guard !moving.isEmpty || !involved.isEmpty else { return false }

        func map(_ p: SIMD2<Double>) -> SIMD2<Double> {
            switch t {
            case .move(let dx, let dy): return p + SIMD2(dx, dy)
            case .rotate(let a, let c):
                let d = p - c, s = sin(a), k = cos(a)
                return c + SIMD2(k * d.x - s * d.y, s * d.x + k * d.y)
            case .scale(let f, let c): return c + (p - c) * f
            }
        }
        for i in points.indices where moving.contains(points[i].id) {
            let q = map(points[i].position)
            points[i].x = q.x; points[i].y = q.y
        }
        // A text turns with its anchor: its baseline turns about the anchor as well.
        if case .rotate(let a, _) = t {
            for i in texts.indices where moving.contains(texts[i].position) { texts[i].angle += a }
        }
        for i in constraints.indices {
            if case .fix(let p, _, _) = constraints[i].kind, moving.contains(p), let now = point(p) {
                constraints[i].kind = .fix(p, x: now.x, y: now.y)
            }
        }
        // A quarter turn (or three) makes horizontal lines vertical and the other way round.
        if case .rotate(let a, _) = t {
            let quarters = a / (.pi / 2)
            if abs(quarters - quarters.rounded()) < 1e-9, Int(quarters.rounded()) % 2 != 0 {
                for i in constraints.indices {
                    switch constraints[i].kind {
                    case .horizontal(let l) where involved.contains(l): constraints[i].kind = .vertical(l)
                    case .vertical(let l) where involved.contains(l): constraints[i].kind = .horizontal(l)
                    default: break
                    }
                }
            }
        }
        guard case .scale(let f, let center) = t else { return true }

        for i in curves.indices where involved.contains(curves[i].id) {
            if case .circle(let m, let r) = curves[i].geometry { curves[i].geometry = .circle(center: m, radius: r * f) }
        }
        for i in texts.indices where moving.contains(texts[i].position) {
            if let h = try? parameters.value(of: texts[i].height, kind: .length) {
                texts[i].height = formatDimension(h * f, kind: .length)
            }
        }
        // A length dimension grows with the geometry it measures. The sketch origin counts as inside
        // when the scaling is about it: it doesn't move, so its distances grow all the same.
        let originStays = vlen(center) < 1e-9
        func inside(_ id: EntityID) -> Bool {
            if point(id) != nil { return moving.contains(id) || (originStays && id == "origin") }
            return involved.contains(id)
        }
        let factor = String(format: "%.12g", f)
        for i in dimensions.indices where dimensions[i].unitKind == .length {
            let refs = Sketch.references(dimensions[i].kind)
            if !refs.isEmpty, refs.allSatisfy(inside) { dimensions[i].expression = "(\(dimensions[i].expression)) * \(factor)" }
        }
        return true
    }
}
