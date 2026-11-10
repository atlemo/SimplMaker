// The drawn form of a distance dimension: the line with arrows between two extension lines.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Where a distance dimension is drawn. It measures between `p1` and `p2`; the dimension line is
/// those points shifted along `normal` by `offset`, joined to them by extension lines.
public struct DimensionLine: Sendable, Equatable {
    public var p1: SIMD2<Double>
    public var p2: SIMD2<Double>
    /// Unit direction the line can be moved along.
    public var normal: SIMD2<Double>
    public var offset: Double
    /// For a circle's diameter or radius: the center it turns about. Its line is dragged around the
    /// circle (its angle is the stored value), not sideways.
    public var center: SIMD2<Double>?
    /// Radius lines have an arrowhead only at the rim.
    public var arrowAtStart = true

    /// The ends of the dimension line (its arrows' tips).
    public var q1: SIMD2<Double> { p1 + normal * offset }
    public var q2: SIMD2<Double> { p2 + normal * (offset + vdot(p1 - p2, normal)) }

    /// The value to store (see SketchDimension.offset) that puts the line through `point`: how far
    /// sideways, or for a circle the angle about its center.
    public func value(through point: SIMD2<Double>) -> Double {
        if let center { return atan2(point.y - center.y, point.x - center.x) }
        return vdot(point - p1, normal)
    }
}

extension Sketch {
    /// The drawn line of a dimension that measures a distance (straight, sideways, up and down, to a
    /// line, or from a circle's edge); nil for sizes, angles and degenerate (zero) distances.
    public func dimensionLine(of d: SketchDimension) -> DimensionLine? {
        func line(_ p1: SIMD2<Double>?, _ p2: SIMD2<Double>?, normal: SIMD2<Double>?) -> DimensionLine? {
            guard let p1, let p2, vlen(p2 - p1) > 1e-9 else { return nil }
            let n = normal ?? SIMD2(-(p2 - p1).y, (p2 - p1).x) / vlen(p2 - p1)
            return DimensionLine(p1: p1, p2: p2, normal: n, offset: d.offset ?? 0)
        }
        func direction(_ l: EntityID) -> SIMD2<Double>? {
            guard case let (a, b)? = chordEnds(l), vlen(b - a) > 1e-12 else { return nil }
            return (b - a) / vlen(b - a)
        }
        switch d.kind {
        case .distance(let a, let b): return line(position(a), position(b), normal: nil)
        case .horizontalDistance(let a, let b): return line(position(a), position(b), normal: SIMD2(0, 1))
        case .verticalDistance(let a, let b): return line(position(a), position(b), normal: SIMD2(1, 0))
        case .pointLineDistance(let p, let l):
            guard let pp = position(p), case let (a, _)? = chordEnds(l), let u = direction(l) else { return nil }
            return line(pp, a + u * vdot(pp - a, u), normal: u)
        case .gap(let c, let o):
            guard let ends = gapEnds(c, o) else { return nil }
            return line(ends.0, ends.1, normal: kind(of: o) == .line ? direction(o) : nil)
        case .radius(let c), .diameter(let c):
            guard let g = curve(c), let r = radius(of: g), r > 1e-9, let cp = center(of: c).flatMap({ position($0) }) else { return nil }
            let angle = d.offset ?? defaultAngle(of: g)
            let u = SIMD2(cos(angle), sin(angle))
            var out = DimensionLine(p1: d.kind == .radius(c) ? cp : cp - u * r, p2: cp + u * r,
                                    normal: SIMD2(-u.y, u.x), offset: 0)
            out.center = cp
            out.arrowAtStart = d.kind != .radius(c)
            return out
        case .length, .angle, .supplementAngle, .lineAngle, .arcAngle, .radialOffset: return nil
        }
    }

    /// The drawn arc of an angle dimension: about `center`, from direction `start` sweeping `sweep` (counter-clockwise
    /// positive). A line's angle is drawn from the sketch's x-axis (`axis`) round to the line; two lines' angle
    /// between them, at the point where they meet. `size` (a few pixels, in mm) keeps it clear on short lines.
    public struct AngleArc: Sendable {
        public var center: SIMD2<Double>
        public var radius: Double
        public var start: Double
        public var sweep: Double
        public var axis: Bool
        /// The direction the label stands in: through the middle of the arc.
        public var middle: Double { start + sweep / 2 }
    }

    public func angleArc(of d: SketchDimension, size: Double) -> AngleArc? {
        func radius(_ length: Double) -> Double { min(max(length * 0.45, size * 5), size * 14) }
        switch d.kind {
        case .lineAngle(let l):
            guard case let (a, b)? = lineEnds(l), vlen(b - a) > 1e-9, let direction = lineDirection(l) else { return nil }
            return AngleArc(center: a, radius: radius(vlen(b - a)), start: 0, sweep: direction, axis: true)
        case .arcAngle(let c):
            // Drawn inside the arc, from its start round to its end.
            guard case .arc(let center, let start, _)? = curve(c)?.geometry, let cp = position(center), let sp = position(start),
                  let sweep = measure(d.kind), vlen(sp - cp) > 1e-9 else { return nil }
            return AngleArc(center: cp, radius: min(max(vlen(sp - cp) * 0.6, size * 3), vlen(sp - cp)),
                            start: atan2(sp.y - cp.y, sp.x - cp.x), sweep: sweep, axis: false)
        case .angle(let l1, let l2), .supplementAngle(let l1, let l2):
            guard case let (a1, b1)? = lineEnds(l1), case let (a2, b2)? = lineEnds(l2),
                  case .line(let s1, let e1)? = curve(l1)?.geometry, case .line(let s2, let e2)? = curve(l2)?.geometry,
                  let t = measure(d.kind) else { return nil }
            let u = b1 - a1, w = b2 - a2
            guard vlen(u) > 1e-9, vlen(w) > 1e-9 else { return nil }
            // Where the lines meet: the point they share, or where they cross.
            var vertex: SIMD2<Double>
            if let shared = [s1, e1].first(where: { $0 == s2 || $0 == e2 }), let p = position(shared) {
                vertex = p
            } else {
                let denom = vcross(u, w)
                guard abs(denom) > 1e-12 else { return nil }
                vertex = a1 + u * (vcross(a2 - a1, w) / denom)
            }
            // The rays run from there along the lines' bodies; the arc between them is the one whose size is the value.
            func ray(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
                let far = vlen(a - vertex) > vlen(b - vertex) ? a : b
                let mid = (a + b) / 2
                let toward = vlen(far - vertex) > 1e-9 ? far : mid
                return atan2(toward.y - vertex.y, toward.x - vertex.x)
            }
            let r1 = ray(a1, b1), r2 = ray(a2, b2)
            func ccw(_ from: Double, _ to: Double) -> Double {
                var x = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
                if x < 0 { x += 2 * .pi }
                return x
            }
            var start = atan2(u.y, u.x)  // the lines' own directions, when the value is neither of the angles between the bodies
            if abs(ccw(r1, r2) - t) < 1e-6 { start = r1 } else if abs(ccw(r2, r1) - t) < 1e-6 { start = r2 }
            else {
                // The value is the other way of reading the same two lines (105° where the bodies make 75°): draw it
                // between one line's body and the other's extension, with the most body in it, and above the lines
                // where either would do.
                let first = [(r1, true), (r1 + .pi, false)], second = [(r2, true), (r2 + .pi, false)]
                var best: (start: Double, score: Double)?
                for (from, to) in first.flatMap({ f in second.map { (f, $0) } }) + second.flatMap({ f in first.map { (f, $0) } })
                where abs(ccw(from.0, to.0) - t) < 1e-6 {
                    let score = (from.1 ? 10.0 : 0) + (to.1 ? 10.0 : 0) + (sin(from.0 + t / 2) >= -1e-9 ? 1 : 0)
                    if best == nil || score > best!.score { best = (from.0, score) }
                }
                if let best { start = best.start }
            }
            // A placed angle keeps its wedge: of the arcs of this size between the two lines, the one nearest where it was placed.
            if let wedge = d.wedge {
                let rays = [r1, r2, r1 + .pi, r2 + .pi]
                var nearest: (start: Double, miss: Double)?
                for from in rays where rays.contains(where: { abs(ccw(from, $0) - t) < 1e-4 }) {
                    let miss = abs(atan2(sin(from + t / 2 - wedge), cos(from + t / 2 - wedge)))
                    if nearest == nil || miss < nearest!.miss { nearest = (from, miss) }
                }
                if let nearest { start = nearest.start }
            }
            // A placed angle keeps the radius it was placed at (its offset); until then the arc is drawn at the default size.
            return AngleArc(center: vertex, radius: d.offset ?? radius(min(vlen(u), vlen(w))), start: start, sweep: t, axis: false)
        default: return nil
        }
    }

    /// The angle between two lines as the wedge the cursor points into: the two ways of reading the pair
    /// (first to second, and second to first) each draw an arc, and the one whose middle is nearest the cursor wins.
    /// The radius is the cursor's distance from the vertex, so the arc passes under the cursor.
    public func angleChoice(_ l1: EntityID, _ l2: EntityID, toward p: SIMD2<Double>, size: Double)
        -> (kind: SketchDimension.Kind, value: Double, radius: Double, middle: Double)? {
        var best: (kind: SketchDimension.Kind, value: Double, radius: Double, middle: Double, miss: Double)?
        // Four readings: each pair of lines both ways round, as the turn and as its supplement (the other wedge).
        for kind in [SketchDimension.Kind.angle(l1, l2), .angle(l2, l1), .supplementAngle(l1, l2), .supplementAngle(l2, l1)] {
            guard let arc = angleArc(of: SketchDimension(kind, ""), size: size), let value = measure(kind) else { continue }
            let toCursor = atan2(p.y - arc.center.y, p.x - arc.center.x)
            let miss = abs(atan2(sin(toCursor - arc.middle), cos(toCursor - arc.middle)))
            let radius = max(vlen(p - arc.center), size * 5)
            if best == nil || miss < best!.miss { best = (kind, value, radius, arc.middle, miss) }
        }
        return best.map { ($0.kind, $0.value, $0.radius, $0.middle) }
    }

    /// Which way a circle's diameter or radius is drawn until it is moved: up and to the right, or for an arc, through its middle.
    func defaultAngle(of curve: SketchCurve) -> Double {
        guard case .arc(let c, let s, let e) = curve.geometry, let pc = position(c), let ps = position(s), let pe = position(e)
        else { return .pi / 4 }
        let a0 = atan2(ps.y - pc.y, ps.x - pc.x)
        var a1 = atan2(pe.y - pc.y, pe.x - pc.x)
        while a1 <= a0 { a1 += 2 * .pi }
        return (a0 + a1) / 2
    }

    /// Where a new distance dimension's line stands: clear of the circle it measures from, and of the
    /// edge it measures to, by a share of the distance.
    public func defaultOffset(for kind: SketchDimension.Kind, value: Double) -> Double? {
        switch kind {
        case .distance, .horizontalDistance, .verticalDistance, .pointLineDistance, .gap:
            let clear = max(value * 0.4, 2)
            if case .gap(let c, _) = kind, let r = curve(c).flatMap({ radius(of: $0) }) { return r + clear }
            return clear
        default: return nil
        }
    }

    /// What stays where it is when a dimension's value is changed, so that the thing being placed moves
    /// and not the thing it is placed from: the edge a circle or point is measured to, the first of two points.
    public static func anchors(of kind: SketchDimension.Kind) -> [EntityID] {
        switch kind {
        case .gap(_, let other): return [other]
        case .pointLineDistance(_, let line): return [line]
        case .distance(let a, _), .horizontalDistance(let a, _), .verticalDistance(let a, _): return [a]
        case .length, .radius, .diameter, .angle, .supplementAngle, .lineAngle, .arcAngle, .radialOffset: return []
        }
    }
}
