// More ways to draw the common sketch shapes: a line from its middle, a rectangle on a slanted edge, a
// rounded rectangle from its center, a circle through three points or tangent to curves, polygons round
// or on an edge, slots from their middle or along an arc, and a spline pulled by control points.
// Copyright © 2026 Atle Mo
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension Sketch {
    // MARK: lines

    /// A line drawn from its middle: `center` is the midpoint and `end` one end, the other end mirrors it. A midpoint
    /// constraint keeps the center in the middle. Nil when the two clicks coincide.
    @discardableResult
    public mutating func addMidpointLine(center: SketchSnap, end: SketchSnap) -> (line: EntityID, middle: EntityID, start: EntityID, end: EntityID)? {
        let c = concrete(center)
        var e = concrete(end)
        let pc = c.point.flatMap { position($0) } ?? c.position
        let pe0 = e.point.flatMap { position($0) } ?? e.position
        guard vlen(pe0 - pc) > 1e-9 else { return nil }
        let alignment = Sketch.inferredAlignment(from: pc, to: pe0)
        if e.point == nil, e.curve == nil, let alignment {  // make it exactly aligned
            if alignment == .horizontal { e.position.y = pc.y } else { e.position.x = pc.x }
        }
        let pe = e.point.flatMap { position($0) } ?? e.position
        let middle = resolve(c)
        let b = resolve(e)
        let other = 2 * pc - pe
        let a = addPoint(other.x, other.y)
        let line = addLine(a, b)
        constrain(.midpoint(point: middle, line: line))
        if let alignment { constrain(alignment == .horizontal ? .horizontal(line) : .vertical(line)) }
        return (line, middle, a, b)
    }

    // MARK: rectangles

    /// A rectangle on any slant: one side from `s` to `e`, and its depth from where `third` lies off that side. The
    /// sides are kept square to each other. Returns the sides (the first from `s` to `e`, then round), or nil when
    /// the first two clicks coincide or the third lies on the first side.
    @discardableResult
    public mutating func addThreePointRectangle(from s: SketchSnap, to e: SketchSnap, depth third: SketchSnap) -> [EntityID]? {
        let s = concrete(s)
        var e = concrete(e)
        let pa = s.point.flatMap { position($0) } ?? s.position
        let pb0 = e.point.flatMap { position($0) } ?? e.position
        guard vlen(pb0 - pa) > 1e-9 else { return nil }
        let alignment = Sketch.inferredAlignment(from: pa, to: pb0)
        if e.point == nil, e.curve == nil, let alignment {
            if alignment == .horizontal { e.position.y = pa.y } else { e.position.x = pa.x }
        }
        let pb = e.point.flatMap { position($0) } ?? e.position
        let len = vlen(pb - pa)
        let u = (pb - pa) / len, n = SIMD2(-u.y, u.x)
        let h = vdot(third.position - pa, n)
        guard abs(h) > 1e-9 else { return nil }
        let a = resolve(s), b = resolve(e)
        let c = addPoint((pb + n * h).x, (pb + n * h).y), d = addPoint((pa + n * h).x, (pa + n * h).y)
        let l = [addLine(a, b), addLine(b, c), addLine(c, d), addLine(d, a)]
        constrain(.perpendicular(l[0], l[1])); constrain(.perpendicular(l[1], l[2])); constrain(.perpendicular(l[2], l[3]))
        if let alignment { constrain(alignment == .horizontal ? .horizontal(l[0]) : .vertical(l[0])) }
        return l
    }

    /// A rounded rectangle drawn from its center to a corner (see `addRoundedRectangle`). A construction diagonal keeps
    /// the center in the middle as it is resized. Nil in the cases the rounded rectangle is.
    @discardableResult
    public mutating func addCenterRoundedRectangle(center: SketchSnap, corner: SketchSnap, radius: Double, expression: String)
        -> (lines: [EntityID], corners: [EntityID], arcs: [EntityID])? {
        let c = concrete(center), k = concrete(corner)
        let pc = c.point.flatMap { position($0) } ?? c.position
        guard let made = addRoundedRectangle(from: SketchSnap(2 * pc - k.position), to: k, radius: radius, expression: expression) else { return nil }
        let middle = resolve(c)
        let diagonal = addLine(made.corners[0], made.corners[2], construction: true)
        constrain(.midpoint(point: middle, line: diagonal))
        return made
    }

    // MARK: circles

    /// The circle through three points, or nil when they lie on a line.
    public static func circumcircle(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> (center: SIMD2<Double>, radius: Double)? {
        let d = 2 * vcross(b - a, c - a)
        guard abs(d) > 1e-9 * max(vdot(b - a, b - a), vdot(c - a, c - a), 1e-12) else { return nil }
        let ab = vdot(b - a, b - a), ac = vdot(c - a, c - a)
        let off = SIMD2((c - a).y * ab - (b - a).y * ac, (b - a).x * ac - (c - a).x * ab) / d
        return (a + off, vlen(off))
    }

    /// A circle through three clicked points. Points that snapped to geometry are kept on it. Nil when they lie on a line.
    @discardableResult
    public mutating func addCircle(through a: SketchSnap, _ b: SketchSnap, _ c: SketchSnap) -> EntityID? {
        let a = concrete(a), b = concrete(b), c = concrete(c)
        func at(_ s: SketchSnap) -> SIMD2<Double> { s.point.flatMap { position($0) } ?? s.position }
        guard let made = Sketch.circumcircle(at(a), at(b), at(c)), made.radius > 1e-9 else { return nil }
        let id = addCircle(center: addPoint(made.center.x, made.center.y), radius: made.radius)
        for s in [a, b, c] where s.point != nil || s.curve != nil {
            constrain(.pointOnCurve(point: resolve(s), curve: id))
        }
        return id
    }

    /// A circle of `result`'s size, kept tangent to each of `curves`.
    @discardableResult
    public mutating func addTangentCircle(_ result: TangentCircle.Result, tangentTo curves: [EntityID]) -> EntityID {
        let id = addCircle(center: addPoint(result.center.x, result.center.y), radius: max(result.radius, 1e-3))
        for curve in curves { constrain(.tangent(curve, id)) }
        return id
    }

    // MARK: polygons

    /// A regular polygon round a circle: the clicks are its center and the middle of one side, so the circle touches every
    /// side. A construction circle is kept tangent to the sides, which are all equal. Returns the sides and the circle.
    @discardableResult
    public mutating func addCircumscribedPolygon(center: SketchSnap, sideMiddle: SketchSnap, sides: Int) -> (lines: [EntityID], circle: EntityID) {
        let n = min(max(sides, Sketch.polygonSides.lowerBound), Sketch.polygonSides.upperBound)
        let center = concrete(center), sideMiddle = concrete(sideMiddle)
        let c = center.point.flatMap { position($0) } ?? center.position
        let d = sideMiddle.position - c
        let apothem = max(vlen(d), 1e-3)
        let toSide = atan2(d.y, d.x)
        let corner = apothem / cos(.pi / Double(n))
        let middle = resolve(center)
        let circle = addCircle(center: middle, radius: apothem)
        if let i = curves.firstIndex(where: { $0.id == circle }) { curves[i].construction = true }
        let corners = (0..<n).map { k -> EntityID in
            let a = toSide - .pi / Double(n) + 2 * .pi * Double(k) / Double(n)
            return addPoint(c.x + corner * cos(a), c.y + corner * sin(a))
        }
        let lines = (0..<n).map { addLine(corners[$0], corners[($0 + 1) % n]) }
        for l in lines { constrain(.tangent(l, circle)) }
        for l in lines.dropFirst() { constrain(.equal(lines[0], l)) }
        return (lines, circle)
    }

    /// A regular polygon on one side: the clicks are that side's two ends, and the polygon lies to the left of the way
    /// from the first to the second. Nil when the ends coincide.
    @discardableResult
    public mutating func addEdgePolygon(from a: SketchSnap, to b: SketchSnap, sides: Int) -> (lines: [EntityID], circle: EntityID)? {
        let n = min(max(sides, Sketch.polygonSides.lowerBound), Sketch.polygonSides.upperBound)
        let a = concrete(a), b = concrete(b)
        let pa = a.point.flatMap { position($0) } ?? a.position, pb = b.point.flatMap { position($0) } ?? b.position
        let side = vlen(pb - pa)
        guard side > 1e-9 else { return nil }
        let u = (pb - pa) / side, left = SIMD2(-u.y, u.x)
        let c = (pa + pb) / 2 + left * (side / (2 * tan(.pi / Double(n))))
        let made = addPolygon(center: SketchSnap(c), corner: SketchSnap(pa, point: a.point, curve: a.curve), sides: n)
        let corners = made.lines.compactMap { line -> EntityID? in pointIDs(of: curve(line)!).first }
        if corners.count > 1 { attach(corners[1], to: b) }
        return made
    }

    // MARK: slots

    /// A slot drawn from its middle: `center` is the middle of the slot and `end` the center of one round end; the other
    /// end mirrors it. See `addSlot`.
    @discardableResult
    public mutating func addCenterPointSlot(center: SketchSnap, end: SketchSnap, width: Double)
        -> (sides: [EntityID], ends: [EntityID], centers: [EntityID])? {
        let c = concrete(center), e = concrete(end)
        let pc = c.point.flatMap { position($0) } ?? c.position
        let pe = e.point.flatMap { position($0) } ?? e.position
        guard vlen(pe - pc) > 1e-9 else { return nil }
        let slot = addSlot(from: SketchSnap(2 * pc - pe), to: e, width: width)
        let middle = resolve(c)
        let axis = addLine(slot.centers[0], slot.centers[1], construction: true)
        constrain(.midpoint(point: middle, line: axis))
        return slot
    }

    /// A slot that follows an arc: the arc is centered on `center` and runs counter-clockwise from the round end at
    /// `start` to the round end at `end` (which is brought onto the arc's circle). The two long sides are arcs round the
    /// same center, tangent to both round ends. Nil when the arc is no wider than the slot, or has no length.
    @discardableResult
    public mutating func addArcSlot(center: SketchSnap, start: SketchSnap, end: SketchSnap, width: Double)
        -> (sides: [EntityID], ends: [EntityID], centers: [EntityID])? {
        let c = concrete(center), s = concrete(start)
        let pc = c.point.flatMap { position($0) } ?? c.position
        let ps = s.point.flatMap { position($0) } ?? s.position
        let radius = vlen(ps - pc), h = width / 2
        guard radius > h + 1e-6, width > 1e-9 else { return nil }
        var e = concrete(end)
        if e.point == nil {
            let d = e.position - pc
            guard vlen(d) > 1e-9 else { return nil }
            e.position = pc + d * (radius / vlen(d))
        }
        let pe = e.point.flatMap { position($0) } ?? e.position
        guard vlen(pe - pc) > 1e-9, vlen(pe - ps) > 1e-6 else { return nil }
        let dirA = (ps - pc) / vlen(ps - pc), dirB = (pe - pc) / vlen(pe - pc)
        let middle = resolve(c), a = resolve(s), b = resolve(e)
        func point(_ dir: SIMD2<Double>, _ r: Double) -> EntityID { addPoint((pc + dir * r).x, (pc + dir * r).y) }
        let aOut = point(dirA, radius + h), aIn = point(dirA, radius - h)
        let bOut = point(dirB, radius + h), bIn = point(dirB, radius - h)
        let outer = addArc(center: middle, start: aOut, end: bOut)
        let inner = addArc(center: middle, start: aIn, end: bIn)
        let capA = addArc(center: a, start: aIn, end: aOut)  // round the start, through the way back
        let capB = addArc(center: b, start: bOut, end: bIn)  // and round the end, through the way on
        let centerline = addArc(center: middle, start: a, end: b)
        if let i = curves.firstIndex(where: { $0.id == centerline }) { curves[i].construction = true }
        for side in [outer, inner] { for cap in [capA, capB] { constrain(.tangent(cap, side)) } }
        constrain(.equal(capA, capB))
        return ([outer, inner], [capA, capB], [a, b])
    }

    // MARK: splines

    /// The cubic Béziers (four points each) of the spline that starts at the first control point, ends at the last, and is
    /// pulled toward those between, like a B-spline of the control points. Three points give one curve, four or more a chain
    /// whose pieces meet with the same slope and bend. Nil with fewer than three points.
    public static func controlPointSpline(_ controls: [SIMD2<Double>]) -> [[SIMD2<Double>]]? {
        let m = controls.count
        guard m >= 3 else { return nil }
        if m == 3 {  // a quadratic curve, raised to a cubic
            let p = controls
            return [[p[0], p[0] + (p[1] - p[0]) * (2.0 / 3), p[2] + (p[1] - p[2]) * (2.0 / 3), p[2]]]
        }
        // Clamped uniform knots; every inner knot is repeated until the curve breaks into Bézier pieces.
        var knots: [Double] = [0, 0, 0, 0] + (1..<(m - 3)).map(Double.init) + Array(repeating: Double(m - 3), count: 4)
        var points = controls
        for inner in 1..<(m - 3) {
            for _ in 0..<2 {
                let u = Double(inner)
                guard let k = (0..<(knots.count - 1)).last(where: { knots[$0] <= u && u < knots[$0 + 1] }) else { break }
                var next: [SIMD2<Double>] = []
                for i in 0...points.count {
                    if i <= k - 3 { next.append(points[i]) }
                    else if i > k { next.append(points[i - 1]) }
                    else {
                        let alpha = (u - knots[i]) / (knots[i + 3] - knots[i])
                        next.append(points[i - 1] * (1 - alpha) + points[i] * alpha)
                    }
                }
                points = next
                knots.insert(u, at: k + 1)
            }
        }
        return stride(from: 0, to: points.count - 1, by: 3).map { Array(points[$0...($0 + 3)]) }
    }

    /// Draws the spline of `controls` (see `controlPointSpline`) as a chain of Bézier curves between points that are
    /// handed out; the first and last control points take their snaps. Returns the curves, or nil with fewer than three
    /// distinct control points.
    @discardableResult
    public mutating func addControlPointSpline(_ controls: [SketchSnap]) -> [EntityID]? {
        let snaps = controls.map { concrete($0) }
        let positions = snaps.map { $0.point.flatMap { position($0) } ?? $0.position }
        guard let pieces = Sketch.controlPointSpline(positions) else { return nil }
        let first = resolve(snaps[0]), last = resolve(snaps[snaps.count - 1])
        var anchor = first
        var made: [EntityID] = []
        for (i, p) in pieces.enumerated() {
            let end = i == pieces.count - 1 ? last : addPoint(p[3].x, p[3].y)
            let c1 = addPoint(p[1].x, p[1].y), c2 = addPoint(p[2].x, p[2].y)
            made.append(addBezier(start: anchor, control1: c1, control2: c2, end: end))
            anchor = end
        }
        return made
    }
}

/// Circles that touch given curves: the geometry behind the two- and three-tangent circle tools.
public enum TangentCircle {
    public struct Result: Sendable, Equatable {
        public var center: SIMD2<Double>
        public var radius: Double
    }

    /// What a curve is to a tangent circle: the infinite line, or the full circle, it lies on.
    private enum Carrier {
        case line(origin: SIMD2<Double>, normal: SIMD2<Double>)
        case circle(center: SIMD2<Double>, radius: Double)
    }

    private static func carrier(_ g: CurveGeometry) -> Carrier? {
        switch g {
        case .line(let a, let b):
            let d = b - a, l = vlen(d)
            return l > 1e-12 ? .line(origin: a, normal: SIMD2(-d.y, d.x) / l) : nil
        case .circle(let c, let r), .arc(let c, let r, _, _):
            return .circle(center: c, radius: r)
        case .bezier, .ellipse:
            return nil
        }
    }

    /// Whether a curve can have a tangent circle drawn to it: a line, a circle or an arc.
    public static func supports(_ g: CurveGeometry?) -> Bool { g.flatMap(carrier) != nil }

    /// Signed distance from `p` to the carrier, and which way it grows.
    private static func signed(_ k: Carrier, _ p: SIMD2<Double>) -> (distance: Double, gradient: SIMD2<Double>) {
        switch k {
        case .line(let o, let n): return (vdot(n, p - o), n)
        case .circle(let c, let r):
            let d = p - c, l = max(vlen(d), 1e-12)
            return (l - r, d / l)
        }
    }

    /// Where the centers of circles of radius `r` touching the carrier lie: one or two curves parallel to it.
    private static func offsets(_ k: Carrier, _ r: Double) -> [CurveGeometry] {
        switch k {
        case .line(let o, let n):
            let t = SIMD2(-n.y, n.x)
            return [-1.0, 1.0].map { s in .line(o + n * (s * r), o + n * (s * r) + t) }
        case .circle(let c, let radius):
            var out: [CurveGeometry] = [.circle(center: c, radius: radius + r)]
            if abs(radius - r) > 1e-9 { out.append(.circle(center: c, radius: abs(radius - r))) }
            return out
        }
    }

    private static func centers(_ a: Carrier, _ b: Carrier, radius r: Double) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        for u in offsets(a, r) { for v in offsets(b, r) { out += intersect(u, v) } }
        return out
    }

    /// The circle tangent to both curves whose center is nearest `p` (with `radius` when given). So with two lines the
    /// circle slides along the line halfway between them as `p` moves. Nil when the curves can't be touched that way.
    public static func solve(_ a: CurveGeometry, _ b: CurveGeometry, near p: SIMD2<Double>, radius: Double? = nil) -> Result? {
        guard let ka = carrier(a), let kb = carrier(b) else { return nil }
        // Two parallel lines: only the circle that fills the gap touches both, and it can sit anywhere along the way between.
        if case .line(let o1, let n1) = ka, case .line(let o2, let n2) = kb, abs(n1.x * n2.y - n1.y * n2.x) < 1e-9 {
            let gap = vdot(n1, o2 - o1), half = abs(gap) / 2
            guard half > 1e-9, radius.map({ abs($0 - half) < 1e-6 }) ?? true else { return nil }
            let mid = o1 + n1 * (gap / 2), t = SIMD2(-n1.y, n1.x)
            return Result(center: mid + t * vdot(t, p - mid), radius: half)
        }
        func nearest(_ r: Double) -> (center: SIMD2<Double>, distance: Double)? {
            centers(ka, kb, radius: r).map { ($0, vlen($0 - p)) }.min { $0.1 < $1.1 }
        }
        if let radius {
            guard radius > 1e-9, let best = nearest(radius) else { return nil }
            return Result(center: best.center, radius: radius)
        }
        let reach = abs(signed(ka, p).distance) + abs(signed(kb, p).distance)
        let top = max(reach * 4, 1)
        let steps = 400, low = top * 1e-4
        var best: (index: Int, distance: Double)?
        for i in 0...steps {
            let r = low * pow(top / low, Double(i) / Double(steps))
            if let n = nearest(r), n.distance < (best?.distance ?? .infinity) { best = (i, n.distance) }
        }
        guard let best else { return nil }
        func radiusAt(_ i: Double) -> Double { low * pow(top / low, min(max(i, 0), Double(steps)) / Double(steps)) }
        var lo = Double(best.index) - 1, hi = Double(best.index) + 1
        func cost(_ i: Double) -> Double { nearest(radiusAt(i))?.distance ?? .infinity }
        for _ in 0..<40 {
            let m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3
            if cost(m1) < cost(m2) { hi = m2 } else { lo = m1 }
        }
        let r = radiusAt((lo + hi) / 2)
        guard let n = nearest(r) else { return nil }
        return Result(center: n.center, radius: r)
    }

    /// The circle tangent to all three curves whose center is nearest `p`. Nil when there is none.
    public static func solve(_ a: CurveGeometry, _ b: CurveGeometry, _ c: CurveGeometry, near p: SIMD2<Double>) -> Result? {
        guard let ka = carrier(a), let kb = carrier(b), let kc = carrier(c) else { return nil }
        let ks = [ka, kb, kc]
        let reach = ks.map { abs(signed($0, p).distance) }.max() ?? 1
        let scale = max(reach, 1)
        var found: [Result] = []
        var starts: [(SIMD2<Double>, Double)] = []
        for s in [0.0, 0.5, 2, 8] {
            let ring = s == 0 ? 1 : 8
            for k in 0..<ring {
                let t = Double(k) * 2 * .pi / Double(ring)
                for r in [0.3, 1, 4] { starts.append((p + SIMD2(cos(t), sin(t)) * (s * scale), r * scale)) }
            }
        }
        for (c0, r0) in starts {
            var x = SIMD3(c0.x, c0.y, r0)
            var converged = false
            for _ in 0..<80 {
                var f = SIMD3<Double>(), jac = [SIMD3<Double>](repeating: .zero, count: 3)
                for (i, k) in ks.enumerated() {
                    let s = signed(k, SIMD2(x.x, x.y))
                    f[i] = s.distance * s.distance - x.z * x.z
                    jac[i] = SIMD3(2 * s.distance * s.gradient.x, 2 * s.distance * s.gradient.y, -2 * x.z)
                }
                if max(abs(f.x), abs(f.y), abs(f.z)) < 1e-10 * scale * scale { converged = true; break }
                let det = jac[0].x * (jac[1].y * jac[2].z - jac[1].z * jac[2].y)
                    - jac[0].y * (jac[1].x * jac[2].z - jac[1].z * jac[2].x)
                    + jac[0].z * (jac[1].x * jac[2].y - jac[1].y * jac[2].x)
                guard abs(det) > 1e-14 else { break }
                func solved(_ col: Int) -> Double {  // Cramer's rule
                    var m = jac
                    for row in 0..<3 { m[row][col] = -f[row] }
                    return (m[0].x * (m[1].y * m[2].z - m[1].z * m[2].y)
                        - m[0].y * (m[1].x * m[2].z - m[1].z * m[2].x)
                        + m[0].z * (m[1].x * m[2].y - m[1].y * m[2].x)) / det
                }
                var step = SIMD3(solved(0), solved(1), solved(2))
                let limit = 4 * scale
                let size = max(abs(step.x), abs(step.y), abs(step.z))
                if size > limit { step *= limit / size }
                x += step
            }
            guard converged else { continue }
            let r = abs(x.z)
            guard r > 1e-6 * scale, r.isFinite else { continue }
            let result = Result(center: SIMD2(x.x, x.y), radius: r)
            if !found.contains(where: { vlen($0.center - result.center) < 1e-6 * scale && abs($0.radius - r) < 1e-6 * scale }) {
                found.append(result)
            }
        }
        return found.min { vlen($0.center - p) < vlen($1.center - p) }
    }
}
