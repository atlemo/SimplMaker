// Mirror images of sketch geometry across a line (the sketch Mirror tool).
//
// Like a pattern, a mirror is stored as a definition (what it copies, and the line it copies across) and its
// images are generated: `refreshMirrors` makes them again from the originals, so they follow whatever changes
// the originals or the line. The images are fixed points and curves whose ids are "<mirror>~<original>".
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A mirror of a sketch: what it copies, and the line it copies across.
public struct SketchMirrorDef: Codable, Hashable, Sendable, Identifiable {
    /// The sketch's own x axis (the line y = 0) and y axis (x = 0), for a mirror across an axis.
    public static let xAxis: EntityID = "axis:x", yAxis: EntityID = "axis:y"

    public var id: EntityID
    /// What is copied: curves, and points on their own.
    public var sources: [EntityID]
    /// The line the images are on the far side of: a line of the sketch (a drawn one, a construction line or a
    /// projected model edge), or `xAxis` / `yAxis`. Empty until one is chosen.
    public var line: EntityID

    public init(id: EntityID = IDs.make(), sources: [EntityID], line: EntityID = "") {
        self.id = id; self.sources = sources; self.line = line
    }
}

extension Sketch {
    /// A point on the line a mirror goes across and its unit direction; nil if the line is gone, isn't straight or has no length.
    public func mirrorAxis(_ line: EntityID) -> (origin: SIMD2<Double>, direction: SIMD2<Double>)? {
        if line == SketchMirrorDef.xAxis { return (.zero, SIMD2(1, 0)) }
        if line == SketchMirrorDef.yAxis { return (.zero, SIMD2(0, 1)) }
        guard !Sketch.isGenerated(line), let c = curve(line), case .line(let a, let b) = c.geometry,
              let p = position(a), let q = position(b) else { return nil }
        let d = q - p, length = (d.x * d.x + d.y * d.y).squareRoot()
        return length > 1e-9 ? (p, d / length) : nil
    }

    /// What the line is called to the user.
    public func mirrorLineName(_ line: EntityID) -> String {
        switch line {
        case SketchMirrorDef.xAxis: return "the X axis"
        case SketchMirrorDef.yAxis: return "the Y axis"
        default: return curve(line)?.construction == true ? "the construction line" : "the line"
        }
    }

    /// `p` on the other side of the line through `origin` along the unit vector `direction`.
    public static func reflected(_ p: SIMD2<Double>, origin: SIMD2<Double>, direction d: SIMD2<Double>) -> SIMD2<Double> {
        let v = p - origin
        let along = v.x * d.x + v.y * d.y
        return origin + d * (2 * along) - v
    }

    /// Whether `line` can be mirrored across.
    public func canMirror(across line: EntityID) -> Bool { mirrorAxis(line) != nil }

    /// What a mirror of `selection` copies (nothing selected: the whole sketch): curves and the points on their own.
    /// Unlike a pattern, a mirror also copies what other mirrors, patterns and gears made, so mirroring a shape
    /// again takes its image along. The projected model edges are never copied.
    func mirrorParts(_ selection: [EntityID]) -> (curves: [SketchCurve], points: Set<EntityID>) {
        let projected = Set(projections.map(\.line))
        // A circle or arc's centre dot sits on top of it, so picking the dot means the shape.
        var selection = selection
        for id in selection where point(id) != nil {
            for c in curves { if let m = center(of: c.id), m == id { selection.append(c.id) } }
        }
        let chosen = (selection.isEmpty ? curves : curves.filter { selection.contains($0.id) }).filter { !projected.contains($0.id) }
        var points = Set<EntityID>()
        for c in chosen { points.formUnion(pointIDs(of: c)) }
        if selection.isEmpty {
            // Whole sketch: loose points come along, but not the origin or the projected edges' ends.
            let ends = Set(projections.flatMap { [$0.start, $0.end] + ($0.center.map { [$0] } ?? []) })
            for p in self.points where p.id != "origin" && !ends.contains(p.id) { points.insert(p.id) }
        } else {
            for id in selection where point(id) != nil { points.insert(id) }
        }
        return (chosen, points)
    }

    /// What a new mirror of `selection` stores as its sources: the curves, and the points that belong to no curve of them.
    public func mirrorSources(_ selection: [EntityID]) -> [EntityID] {
        let parts = mirrorParts(selection)
        var own = Set<EntityID>()
        for c in parts.curves { own.formUnion(pointIDs(of: c)) }
        return parts.curves.map(\.id) + points.map(\.id).filter { parts.points.contains($0) && !own.contains($0) }
    }

    /// Whether a mirror of `selection` has anything to copy.
    public func canMirror(_ selection: [EntityID]) -> Bool {
        let parts = mirrorParts(selection)
        return !parts.curves.isEmpty || !parts.points.isEmpty
    }

    /// A shape and its image are one outline where the shape meets the line, but only while its points stay exactly on
    /// the line (they are shared with the image only then). So every point of the mirror's sources that lies on a line of
    /// the sketch is held on it: otherwise the first thing that nudges the line, or the point, opens the outline by a
    /// hair and the profile is lost. A point that only comes within `snap` of the line (an end drawn a pixel or two
    /// short of it) is taken to be meant to touch it: it is moved onto the line first, as a snap would have put it.
    /// (Not for the axes, which have no curve to hold a point on.)
    public mutating func holdPointsOnMirrorLine(_ def: SketchMirrorDef, snap: Double = 0) {
        guard !SketchMirrorDef.isAxis(def.line), let axis = mirrorAxis(def.line),
              case .line(let a, let b)? = curve(def.line)?.geometry else { return }
        let present = def.sources.filter { $0 != def.line && (point($0) != nil || curve($0) != nil) }
        guard !present.isEmpty else { return }
        let normal = SIMD2(-axis.direction.y, axis.direction.x)
        for id in mirrorParts(present).points where id != a && id != b && !Sketch.isGenerated(id) {
            guard let k = points.firstIndex(where: { $0.id == id }) else { continue }
            let p = points[k].position
            let away = vdot(p - axis.origin, normal)  // signed distance from the line
            guard abs(away) <= max(1e-7 * max(1, vlen(p)), snap) else { continue }
            if abs(away) > 1e-9, !points[k].fixed {
                points[k].x -= normal.x * away
                points[k].y -= normal.y * away
            }
            let held = constraints.contains { c in
                if case .pointOnCurve(let q, let l) = c.kind { return q == id && l == def.line }
                return false
            }
            if !held { constrain(.pointOnCurve(point: id, curve: def.line)) }
        }
    }

    /// Makes the images of every mirror again, from the originals as they are now. Mirrors go in the order they were
    /// made, so one can copy the image of an earlier one. A mirror whose originals or line are gone is dropped.
    /// Returns what is wrong with a mirror that can't be made, by id; a mirror that has no line yet makes nothing
    /// and is no problem.
    @discardableResult
    mutating func refreshMirrors() -> [EntityID: String] {
        guard !mirrors.isEmpty else { return [:] }
        // Sources that were drawn and are gone; what another mirror made (an id with a "~") is looked for when its turn comes.
        for i in mirrors.indices { mirrors[i].sources = mirrors[i].sources.filter { Sketch.isGenerated($0) || point($0) != nil || curve($0) != nil } }
        let lines = Set(curves.map(\.id))
        mirrors.removeAll { $0.sources.isEmpty || ($0.line != "" && !SketchMirrorDef.isAxis($0.line) && !lines.contains($0.line)) }
        var problems: [EntityID: String] = [:]
        var dead = Set<EntityID>()
        for def in mirrors {
            // What there is to copy now. A mirror that copied only what is gone has nothing left to keep.
            let present = def.sources.filter { $0 != def.line && (point($0) != nil || curve($0) != nil) }
            if def.sources.allSatisfy({ Sketch.isGenerated($0) }), present.isEmpty { dead.insert(def.id); continue }
            guard def.line != "" else { continue }
            guard let axis = mirrorAxis(def.line) else {
                problems[def.id] = "mirror: the line it goes across has no length or isn't straight"
                continue
            }
            // The line itself is not copied: its image would lie on top of it.
            guard !present.isEmpty else { continue }  // (an empty selection would mean the whole sketch)
            var parts = mirrorParts(present)
            let anchors = Set(texts.map(\.position))
            let own = Set(parts.curves.flatMap { pointIDs(of: $0) })
            parts.points = parts.points.filter { own.contains($0) || !anchors.contains($0) }  // a text isn't mirrored, so neither is its anchor
            guard !parts.curves.isEmpty || !parts.points.isEmpty else { continue }
            // A point on the line is its own mirror image: the image shares it, so the shape and its image join into
            // one outline (and one profile) instead of two that only touch.
            let onLine = Set(parts.points.filter { id in
                guard let p = position(id) else { return false }
                let v = p - axis.origin
                return abs(v.x * axis.direction.y - v.y * axis.direction.x) <= 1e-7 * max(1, vlen(p))
            })
            copyGeometry(parts, prefix: "\(def.id)~", map: { Sketch.reflected($0, origin: axis.origin, direction: axis.direction) },
                         reversed: true, textTurn: nil, shared: onLine)
        }
        if !dead.isEmpty { mirrors.removeAll { dead.contains($0.id) } }
        return problems
    }
}

extension SketchMirrorDef {
    /// Whether `line` is one of the two axes.
    public static func isAxis(_ line: EntityID) -> Bool { line == xAxis || line == yAxis }
}
