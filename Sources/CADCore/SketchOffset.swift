// Offsets of splines and ellipses that follow their originals (the sketch Offset tool).
//
// A line or an arc is offset with a parallel constraint and a dimension, so the offset follows the original by
// itself. A spline's offset is only an approximation (a run of Béziers fitted to it), so nothing can tie it to the
// original that way. It is stored as a definition instead (what it offsets, and how far) and its curves are
// generated: `refreshOffsets` makes them again from the originals at every change, like the copies of a pattern.
// The generated points are fixed and, with the curves, have ids "<offset>~p<n>" and "<offset>~c<n>".
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// An offset of a sketch that follows its originals: the curves it offsets, and how far.
public struct SketchOffsetDef: Codable, Hashable, Sendable, Identifiable {
    public var id: EntityID
    /// The curves offset: the splines and the lines and arcs joined to them (an outline is offset as one), or ellipses.
    public var sources: [EntityID]
    /// The distance as the user wrote it. Positive goes outward from a closed outline, to the left of an open one;
    /// negative the other way.
    public var expression: String

    public init(id: EntityID = IDs.make(), sources: [EntityID], expression: String) {
        self.id = id; self.sources = sources; self.expression = expression
    }
}

extension Sketch {
    /// Of the curves to offset, the ones whose offset is kept alive (a chain that holds a spline, with everything
    /// joined to it, and the ellipses) and the ones that are not (their offset follows by constraints, or is made
    /// once). What a pattern, mirror or gear made is always offset once: it is made again at every change.
    func liveOffsetSources(_ ids: [EntityID]) -> (live: [EntityID], rest: [EntityID]) {
        let chainable = ids.filter { id in
            switch curve(id)?.geometry {
            case .line?, .arc?, .bezier?: return true
            default: return false
            }
        }
        var live: [EntityID] = []
        for chain in chains(chainable) {
            let members = chain.items.map(\.id)
            let hasSpline = members.contains { if case .bezier? = curve($0)?.geometry { return true }; return false }
            if hasSpline, !members.contains(where: Sketch.isGenerated) { live += members }
        }
        for id in ids where !Sketch.isGenerated(id) {
            if case .ellipse? = curve(id)?.geometry { live.append(id) }
        }
        let chosen = Set(live)
        return (live, ids.filter { !chosen.contains($0) })
    }

    /// Adds the curves of an offset `distance` away (see `offset`) as generated points and curves, and returns the
    /// curves. Nothing is added where the offset folds over itself.
    mutating func appendLiveOffset(_ def: SketchOffsetDef, distance: Double) -> [EntityID] {
        // The offset is made on a copy, with the tools the other offsets use, and what it adds is taken over.
        var scratch = self
        let knownPoints = Set(points.map(\.id)), knownCurves = Set(curves.map(\.id))
        _ = scratch.offsetFixed(def.sources, distance: distance, expression: "1")
        let newPoints = scratch.points.filter { !knownPoints.contains($0.id) }
        let newCurves = scratch.curves.filter { !knownCurves.contains($0.id) }
        guard !newCurves.isEmpty else { return [] }
        var renamed: [EntityID: EntityID] = [:]
        for (k, p) in newPoints.enumerated() { renamed[p.id] = "\(def.id)~p\(k + 1)" }
        for (k, c) in newCurves.enumerated() { renamed[c.id] = "\(def.id)~c\(k + 1)" }
        func name(_ id: EntityID) -> EntityID { renamed[id] ?? id }
        for p in newPoints { points.append(SketchPoint(id: name(p.id), x: p.x, y: p.y, fixed: true)) }
        for c in newCurves {
            let geometry: SketchCurve.Geometry
            switch c.geometry {
            case .line(let a, let b): geometry = .line(start: name(a), end: name(b))
            case .arc(let m, let a, let b): geometry = .arc(center: name(m), start: name(a), end: name(b))
            case .bezier(let a, let c1, let c2, let b): geometry = .bezier(start: name(a), control1: name(c1), control2: name(c2), end: name(b))
            case .circle(let m, let r): geometry = .circle(center: name(m), radius: r)
            case .ellipse(let m, let a, let b): geometry = .ellipse(center: name(m), major: name(a), minor: name(b))
            }
            curves.append(SketchCurve(id: name(c.id), geometry, construction: c.construction))
        }
        return newCurves.map { name($0.id) }
    }

    /// Makes the curves of every live offset again, from the originals as they are now (the generated curves are
    /// taken out first: see `refreshGenerated`). An offset whose originals are all gone is dropped. Returns what is
    /// wrong with an offset that can't be made, by id.
    @discardableResult
    mutating func refreshOffsets(_ parameters: ParameterValues) -> [EntityID: String] {
        guard !offsets.isEmpty else { return [:] }
        for i in offsets.indices { offsets[i].sources = offsets[i].sources.filter { !Sketch.isGenerated($0) && curve($0) != nil } }
        offsets.removeAll { $0.sources.isEmpty }
        var problems: [EntityID: String] = [:]
        for def in offsets {
            let distance: Double
            do { distance = try parameters.value(of: def.expression, kind: .length) } catch {
                problems[def.id] = "offset: \(error)"
                continue
            }
            guard abs(distance) > 1e-9 else { problems[def.id] = "offset: the distance can't be zero"; continue }
            if appendLiveOffset(def, distance: distance).isEmpty {
                problems[def.id] = "offset: that far from the curve, the offset folds over itself"
            }
        }
        return problems
    }
}
