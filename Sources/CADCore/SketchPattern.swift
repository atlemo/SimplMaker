// Linked copies of sketch geometry, in a grid or around a point (the sketch Pattern tool).
//
// A pattern is stored as a definition: which curves it copies, and counts and spacings as
// expressions. The copies themselves are generated: `refreshGenerated` throws away every generated
// point, curve and text and makes them again from the originals, so they follow whatever changes
// the originals or the parameters. Generated entities carry "~" in their ids, made from the
// pattern, the copy and the original ("<pattern>~<copy>~<original>"), so the same copy always has
// the same id and profiles built on it stay valid. They are fixed points that no constraint refers to.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// How copies of sketch geometry are laid out. Counts include the original.
public enum SketchPattern: Equatable, Sendable {
    /// A grid: `countX` columns `spacingX` apart along the sketch's x, `countY` rows `spacingY` apart along y.
    case rectangular(countX: Int, spacingX: Double, countY: Int, spacingY: Double)
    /// `count` copies turned about a point, spread over `angle` (radians; a whole turn spreads them all the way round).
    case circular(count: Int, angle: Double, about: SIMD2<Double>)

    /// The most copies one pattern may make, so a typo can't freeze the sketch.
    public static let maxCopies = 400

    /// How many copies it makes, not counting the original.
    public var copyCount: Int {
        switch self {
        case .rectangular(let nx, _, let ny, _): return max(nx, 1) * max(ny, 1) - 1
        case .circular(let n, _, _): return max(n, 1) - 1
        }
    }

    /// The step between circular copies: all the way round is `count` equal steps, less puts the last copy at the end of the angle.
    static func step(count: Int, angle: Double) -> Double {
        abs(abs(angle) - 2 * .pi) < 1e-9 ? angle / Double(max(count, 1)) : angle / Double(max(count - 1, 1))
    }

    /// Where each copy goes: a move for a grid, a turn about a point for a circle.
    var placements: [SketchTransform] {
        var out: [SketchTransform] = []
        switch self {
        case .rectangular(let nx, let sx, let ny, let sy):
            for j in 0..<max(ny, 1) {
                for i in 0..<max(nx, 1) where i > 0 || j > 0 { out.append(.move(dx: Double(i) * sx, dy: Double(j) * sy)) }
            }
        case .circular(let n, let angle, let c):
            let step = Self.step(count: n, angle: angle)
            for k in 1..<max(n, 1) { out.append(.rotate(angle: step * Double(k), about: c)) }
        }
        return out
    }
}

/// A pattern of a sketch: what it copies and how, as expressions so parameters can drive it.
public struct SketchPatternDef: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
        case rectangular, circular
        public var id: String { rawValue }
    }
    public var id: EntityID
    public var kind: Kind
    /// What is copied: curves, and points on their own (a text's anchor, a loose point).
    public var sources: [EntityID]
    public var countX: String, spacingX: String, countY: String, spacingY: String
    public var count: String, angle: String
    /// The point a circular pattern goes round.
    public var center: EntityID

    public init(id: EntityID = IDs.make(), kind: Kind = .rectangular, sources: [EntityID], countX: String = "3", spacingX: String = "20 mm",
                countY: String = "2", spacingY: String = "20 mm", count: String = "6", angle: String = "360 deg", center: EntityID = "origin") {
        self.id = id; self.kind = kind; self.sources = sources
        self.countX = countX; self.spacingX = spacingX; self.countY = countY; self.spacingY = spacingY
        self.count = count; self.angle = angle; self.center = center
    }

    /// The layout the expressions come to, or what is wrong with them.
    public func layout(_ sketch: Sketch, _ p: ParameterValues) throws -> SketchPattern {
        func whole(_ text: String) throws -> Int {
            let v = try p.value(of: text, kind: .none)
            guard abs(v - v.rounded()) < 1e-9, v >= 1 else { throw PatternError("a count must be a whole number, 1 or more (not \(text))") }
            return Int(v.rounded())
        }
        func length(_ text: String) throws -> Double { try p.value(of: text, kind: .length) }
        let pattern: SketchPattern
        switch kind {
        case .rectangular:
            pattern = .rectangular(countX: try whole(countX), spacingX: try length(spacingX), countY: try whole(countY), spacingY: try length(spacingY))
        case .circular:
            pattern = .circular(count: try whole(count), angle: try p.value(of: angle, kind: .angle), about: sketch.position(center) ?? .zero)
        }
        guard pattern.copyCount <= SketchPattern.maxCopies else {
            throw PatternError("that makes \(pattern.copyCount) copies; the most is \(SketchPattern.maxCopies)")
        }
        return pattern
    }
}

public struct PatternError: Error, CustomStringConvertible {
    public var description: String
    init(_ text: String) { description = text }
}

extension Sketch {
    /// Whether an entity was made by a pattern rather than drawn.
    public static func isGenerated(_ id: EntityID) -> Bool { id.contains("~") }

    /// The pattern that made a generated entity.
    public static func pattern(ofGenerated id: EntityID) -> EntityID? {
        id.contains("~") ? String(id.split(separator: "~", maxSplits: 1, omittingEmptySubsequences: false)[0]) : nil
    }

    /// What a pattern of `selection` copies: its curves (every curve but the projected model edges when
    /// nothing is selected), their points, the loose points selected, and the texts anchored on them.
    /// Copies made by other patterns are never included.
    func patternParts(_ selection: [EntityID]) -> (curves: [SketchCurve], points: Set<EntityID>) {
        let projected = Set(projections.flatMap(\.curveIDs))
        // A circle or arc's centre dot sits on top of it, so picking the dot means the shape.
        var selection = selection
        for id in selection where point(id) != nil {
            for c in self.curves { if let m = center(of: c.id), m == id { selection.append(c.id) } }
        }
        let curves = transformCurves(selection).filter { !projected.contains($0.id) }
        var points = Set<EntityID>()
        for c in curves { points.formUnion(pointIDs(of: c)) }
        if selection.isEmpty {
            // Whole sketch: loose points and text anchors come along, but not the origin or the projected edges' ends.
            let ends = Set(projections.flatMap(\.pointIDs))
            for p in self.points where p.id != "origin" && !ends.contains(p.id) && !Sketch.isGenerated(p.id) { points.insert(p.id) }
        } else {
            for id in selection where point(id) != nil && !Sketch.isGenerated(id) { points.insert(id) }
        }
        return (curves, points)
    }

    /// What a new pattern of `selection` would store as its sources: the curves, and the points that
    /// belong to no curve of them.
    public func patternSources(_ selection: [EntityID]) -> [EntityID] {
        let parts = patternParts(selection)
        var own = Set<EntityID>()
        for c in parts.curves { own.formUnion(pointIDs(of: c)) }
        return parts.curves.map(\.id) + points.map(\.id).filter { parts.points.contains($0) && !own.contains($0) }
    }

    /// The box around what a pattern of `selection` copies (circles count with their radius).
    public func patternBox(_ selection: [EntityID]) -> (min: SIMD2<Double>, max: SIMD2<Double>)? {
        let parts = patternParts(selection)
        var lo = SIMD2(Double.infinity, Double.infinity), hi = -lo
        func grow(_ p: SIMD2<Double>) { lo.replace(with: p, where: p .< lo); hi.replace(with: p, where: p .> hi) }
        for id in parts.points { if let p = position(id) { grow(p) } }
        for c in parts.curves {
            if case .circle(let m, let r) = c.geometry, let p = position(m) { grow(p - SIMD2(r, r)); grow(p + SIMD2(r, r)) }
        }
        return lo.x <= hi.x ? (lo, hi) : nil
    }

    /// Whether a pattern of `selection` has anything to copy.
    public func canPattern(_ selection: [EntityID]) -> Bool {
        let parts = patternParts(selection)
        return !parts.curves.isEmpty || !parts.points.isEmpty
    }

    // MARK: generated copies

    /// Takes the pattern copies out of the sketch, for solving without them.
    public mutating func takeGenerated() -> (points: [SketchPoint], curves: [SketchCurve], texts: [SketchText]) {
        let out = (points.filter { Sketch.isGenerated($0.id) }, curves.filter { Sketch.isGenerated($0.id) }, texts.filter { Sketch.isGenerated($0.id) })
        if !out.0.isEmpty { points.removeAll { Sketch.isGenerated($0.id) } }
        if !out.1.isEmpty { curves.removeAll { Sketch.isGenerated($0.id) } }
        if !out.2.isEmpty { texts.removeAll { Sketch.isGenerated($0.id) } }
        return out
    }

    public mutating func restoreGenerated(_ g: (points: [SketchPoint], curves: [SketchCurve], texts: [SketchText])) {
        points += g.points; curves += g.curves; texts += g.texts
    }

    /// Makes the copies of every pattern and the outline of every gear again, from the originals as they are
    /// now. A pattern whose originals are all gone is dropped, and so is a gear whose centre is. Returns what is
    /// wrong with the patterns and gears that can't be made (a count that isn't a number), by id; those make nothing.
    @discardableResult
    public mutating func refreshGenerated(_ parameters: ParameterValues) -> [EntityID: String] {
        _ = takeGenerated()
        guard !patterns.isEmpty || !gears.isEmpty || !mirrors.isEmpty else { return [:] }
        for i in patterns.indices { patterns[i].sources = patterns[i].sources.filter { point($0) != nil || curve($0) != nil } }
        patterns.removeAll { $0.sources.isEmpty }
        var problems: [EntityID: String] = [:]
        for def in patterns {
            do {
                let layout = try def.layout(self, parameters)
                let parts = patternParts(def.sources)
                for (k, placement) in layout.placements.enumerated() { copy(parts, placement, prefix: "\(def.id)~\(k + 1)~") }
            } catch {
                problems[def.id] = "pattern: \(error)"
            }
        }
        for (id, problem) in refreshGears(parameters) { problems[id] = problem }
        for (id, problem) in refreshMirrors() { problems[id] = problem }
        return problems
    }

    private mutating func copy(_ parts: (curves: [SketchCurve], points: Set<EntityID>), _ t: SketchTransform, prefix: String) {
        func map(_ p: SIMD2<Double>) -> SIMD2<Double> {
            switch t {
            case .move(let dx, let dy): return p + SIMD2(dx, dy)
            case .rotate(let a, let c):
                let d = p - c, s = sin(a), k = cos(a)
                return c + SIMD2(k * d.x - s * d.y, s * d.x + k * d.y)
            case .scale(let f, let c): return c + (p - c) * f
            }
        }
        var turn = 0.0
        if case .rotate(let a, _) = t { turn = a }
        copyGeometry(parts, prefix: prefix, map: map, reversed: false, textTurn: turn)
    }

    /// Adds a copy of `parts` with every position sent through `map`, as fixed points and curves whose ids
    /// are the originals' behind `prefix`. `reversed` is for a map that flips left and right (a reflection),
    /// which swaps an arc's ends so it still runs counter-clockwise. Texts come along turned by `textTurn`;
    /// nil leaves them out.
    /// `shared` are points the copy uses as they are instead of making its own (the ones a mirror leaves in place,
    /// on its line): copies of curves that end there join the originals. A line or circle that would then lie
    /// exactly on its original is left out.
    mutating func copyGeometry(_ parts: (curves: [SketchCurve], points: Set<EntityID>), prefix: String,
                               map: (SIMD2<Double>) -> SIMD2<Double>, reversed: Bool, textTurn: Double?,
                               shared: Set<EntityID> = []) {
        func id(_ source: EntityID) -> EntityID { shared.contains(source) ? source : prefix + source }
        for p in points where parts.points.contains(p.id) && !shared.contains(p.id) {
            let q = map(p.position)
            points.append(SketchPoint(id: id(p.id), x: q.x, y: q.y, fixed: true))
        }
        for c in parts.curves {
            let geometry: SketchCurve.Geometry
            switch c.geometry {
            case .line(let a, let b):
                if shared.contains(a), shared.contains(b) { continue }  // on the line itself: its own image
                geometry = .line(start: id(a), end: id(b))
            case .circle(let m, let r):
                if shared.contains(m) { continue }
                geometry = .circle(center: id(m), radius: r)
            case .arc(let m, let a, let b): geometry = reversed ? .arc(center: id(m), start: id(b), end: id(a)) : .arc(center: id(m), start: id(a), end: id(b))
            case .bezier(let a, let c1, let c2, let b): geometry = .bezier(start: id(a), control1: id(c1), control2: id(c2), end: id(b))
            case .ellipse(let m, let a, let b): geometry = .ellipse(center: id(m), major: id(a), minor: id(b))
            }
            curves.append(SketchCurve(id: id(c.id), geometry, construction: c.construction))
        }
        guard let turn = textTurn else { return }
        for text in texts where parts.points.contains(text.position) && !Sketch.isGenerated(text.id) {
            var copy = SketchText(id: id(text.id), text: text.text, position: id(text.position), height: text.height, font: text.font, angle: text.angle)
            copy.angle += turn
            texts.append(copy)
        }
    }
}
