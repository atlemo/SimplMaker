// The drawn form of a distance dimension: the line with arrows between two extension lines.
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
            guard case let (a, b)? = lineEnds(l), vlen(b - a) > 1e-12 else { return nil }
            return (b - a) / vlen(b - a)
        }
        switch d.kind {
        case .distance(let a, let b): return line(position(a), position(b), normal: nil)
        case .horizontalDistance(let a, let b): return line(position(a), position(b), normal: SIMD2(0, 1))
        case .verticalDistance(let a, let b): return line(position(a), position(b), normal: SIMD2(1, 0))
        case .pointLineDistance(let p, let l):
            guard let pp = position(p), case let (a, _)? = lineEnds(l), let u = direction(l) else { return nil }
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
        case .length, .angle, .radialOffset: return nil
        }
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
        case .length, .radius, .diameter, .angle, .radialOffset: return []
        }
    }
}
