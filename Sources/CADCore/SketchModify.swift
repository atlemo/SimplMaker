// Sketch modify tools: trim, extend, offset and corner fillet.
// Geometry is computed from the current (solved) positions; new points that land on other
// curves get point-on-curve constraints so the result stays parametric.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

/// A curve's current geometry.
public enum CurveGeometry: Sendable, Equatable {
    case line(SIMD2<Double>, SIMD2<Double>)
    /// Full circle.
    case circle(center: SIMD2<Double>, radius: Double)
    /// Counter-clockwise from `start` angle over `sweep` radians.
    case arc(center: SIMD2<Double>, radius: Double, start: Double, sweep: Double)
    /// Cubic Bézier through its four control points, t 0…1.
    case bezier([SIMD2<Double>])
    /// Ellipse: center + major·cos t + minor·sin t (its axes' ends are center + major and center + minor).
    case ellipse(center: SIMD2<Double>, major: SIMD2<Double>, minor: SIMD2<Double>)

    /// Point at parameter t: lines 0…1 start→end, arcs 0…1 start→end, circles t = angle.
    public func point(_ t: Double) -> SIMD2<Double> {
        switch self {
        case .line(let a, let b): return a + (b - a) * t
        case .circle(let c, let r): return c + r * SIMD2(cos(t), sin(t))
        case .arc(let c, let r, let a0, let sw): let a = a0 + sw * t; return c + r * SIMD2(cos(a), sin(a))
        case .bezier(let p): return Bezier.point(p, t)
        case .ellipse(let c, let u, let v): return c + u * cos(t) + v * sin(t)
        }
    }

    /// Parameter of the point on the underlying infinite line / full circle closest to p.
    /// Lines are unclamped; arcs give values outside 0…1 beyond their ends (0…2π/sweep).
    public func parameter(of p: SIMD2<Double>) -> Double {
        switch self {
        case .line(let a, let b):
            let d = b - a
            return vdot(p - a, d) / max(vdot(d, d), 1e-300)
        case .circle(let c, _):
            let t = atan2(p.y - c.y, p.x - c.x)
            return t < 0 ? t + 2 * .pi : t
        case .arc(let c, _, let a0, let sw):
            var t = atan2(p.y - c.y, p.x - c.x) - a0
            while t < 0 { t += 2 * .pi }
            while t >= 2 * .pi { t -= 2 * .pi }
            return t / sw
        case .bezier(let ctrl):
            return Bezier.closest(p, ctrl)
        case .ellipse(let c, let u, let v):
            // Angle in the ellipse's own (affine) frame, where it is a circle.
            let w = p - c, det = vcross(u, v)
            let x = (v.y * w.x - v.x * w.y) / det, y = (u.x * w.y - u.y * w.x) / det
            let t = atan2(y, x)
            return t < 0 ? t + 2 * .pi : t
        }
    }

    public var isClosed: Bool { switch self { case .circle, .ellipse: return true; default: return false } }

    /// Whether parameter t lies on the curve itself (not its extension).
    func contains(_ t: Double, eps: Double = 1e-9) -> Bool {
        switch self {
        case .circle: return true
        case .line, .arc, .bezier: return t >= -eps && t <= 1 + eps
        case .ellipse: return true
        }
    }
}

/// Intersections of the underlying infinite line / full circle of two curves (a Bézier has no
/// extension: only its own crossings count).
func intersect(_ g: CurveGeometry, _ h: CurveGeometry) -> [SIMD2<Double>] {
    func circle(_ x: CurveGeometry) -> (SIMD2<Double>, Double)? {
        switch x {
        case .circle(let c, let r), .arc(let c, let r, _, _): return (c, r)
        case .line, .bezier, .ellipse: return nil
        }
    }
    if case .bezier(let p) = g {
        // Cross each piece of the flattened curve, then pull the hits back onto the curve.
        let line = Bezier.flatten(p, steps: 96)
        var hits: [SIMD2<Double>] = []
        for i in 0..<(line.count - 1) {
            let a = line[i], b = line[i + 1], d = b - a
            for x in intersect(.line(a, b), h) {
                let s = vdot(x - a, d) / max(vdot(d, d), 1e-300)
                guard s >= -1e-9, s < 1 - 1e-9 || i == line.count - 2 else { continue }
                let onCurve = Bezier.point(p, Bezier.closest(x, p))
                if !hits.contains(where: { vlen($0 - onCurve) < 1e-7 }) { hits.append(onCurve) }
            }
        }
        return hits
    }
    if case .bezier = h { return intersect(h, g) }
    switch (g, h) {
    case (.line(let a1, let b1), .line(let a2, let b2)):
        let d1 = b1 - a1, d2 = b2 - a2
        let den = vcross(d1, d2)
        guard abs(den) > 1e-12 * max(vdot(d1, d1) * vdot(d2, d2), 1e-300).squareRoot() else { return [] }
        let t = vcross(a2 - a1, d2) / den
        return [a1 + d1 * t]
    case (.line(let a, let b), _):
        guard case let (c, r)? = circle(h) else { return [] }
        let d = b - a, f = a - c
        let A = vdot(d, d), B = 2 * vdot(f, d), C = vdot(f, f) - r * r
        let disc = B * B - 4 * A * C
        guard A > 1e-300, disc >= -1e-12 * max(B * B, 1) else { return [] }
        let sq = max(disc, 0).squareRoot()
        let t1 = (-B - sq) / (2 * A), t2 = (-B + sq) / (2 * A)
        return sq < 1e-12 ? [a + d * t1] : [a + d * t1, a + d * t2]
    case (_, .line):
        return intersect(h, g)
    default:
        guard case let (c1, r1)? = circle(g), case let (c2, r2)? = circle(h) else { return [] }
        let d = vlen(c2 - c1)
        guard d > 1e-12, d <= r1 + r2 + 1e-9, d >= abs(r1 - r2) - 1e-9 else { return [] }
        let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let h2 = max(r1 * r1 - a * a, 0).squareRoot()
        let u = (c2 - c1) / d
        let m = c1 + u * a
        let n = SIMD2(-u.y, u.x)
        return h2 < 1e-12 ? [m] : [m + n * h2, m - n * h2]
    }
}

extension Sketch {
    public func geometry(of id: EntityID) -> CurveGeometry? {
        guard let c = curve(id) else { return nil }
        return geometry(of: c) { position($0) }
    }

    /// The same for a curve in hand, with the point positions from a `positionTable()`: loops over many curves
    /// look neither the curve nor its points up by scanning.
    public func geometry(of c: SketchCurve, _ positions: [EntityID: SIMD2<Double>]) -> CurveGeometry? {
        geometry(of: c) { positions[$0] }
    }

    private func geometry(of c: SketchCurve, _ position: (EntityID) -> SIMD2<Double>?) -> CurveGeometry? {
        switch c.geometry {
        case .line(let a, let b):
            guard let pa = position(a), let pb = position(b) else { return nil }
            return .line(pa, pb)
        case .circle(let center, let r):
            guard let pc = position(center) else { return nil }
            return .circle(center: pc, radius: r)
        case .arc(let center, let s, let e):
            guard let pc = position(center), let ps = position(s), let pe = position(e) else { return nil }
            let a0 = atan2(ps.y - pc.y, ps.x - pc.x)
            var a1 = atan2(pe.y - pc.y, pe.x - pc.x)
            while a1 <= a0 { a1 += 2 * .pi }
            return .arc(center: pc, radius: vlen(ps - pc), start: a0, sweep: a1 - a0)
        case .bezier:
            let p = pointIDs(of: c).compactMap { position($0) }
            return p.count == 4 ? .bezier(p) : nil
        case .ellipse(let center, let major, let minor):
            guard let pc = position(center), let pu = position(major), let pv = position(minor) else { return nil }
            return .ellipse(center: pc, major: pu - pc, minor: pv - pc)
        }
    }

    /// A place where a curve is cut: at parameter t, at an existing point or on another curve.
    struct Cut {
        var t: Double
        var position: SIMD2<Double>
        var point: EntityID?
        var curve: EntityID?
    }

    /// Where other curves and points cross curve `id` (sorted by parameter, interior only for open curves).
    func cuts(on id: EntityID) -> [Cut] {
        guard let g = geometry(of: id), let me = curve(id) else { return [] }
        let myPoints = Set(pointIDs(of: me))
        var out: [Cut] = []
        func existingPoint(at p: SIMD2<Double>) -> EntityID? {
            points.first { !myPoints.contains($0.id) && vlen($0.position - p) < 1e-6 }?.id
        }
        for other in curves where other.id != id {
            guard let h = geometry(of: other.id) else { continue }
            for p in intersect(g, h) {
                let th = h.parameter(of: p)
                guard h.contains(th, eps: 1e-7) else { continue }
                let t = g.parameter(of: p)
                if !g.isClosed { guard t > 1e-7, t < 1 - 1e-7 else { continue } }
                out.append(Cut(t: t, position: p, point: existingPoint(at: p), curve: other.id))
            }
        }
        // Points constrained onto this curve also cut it.
        for c in constraints {
            if case .pointOnCurve(let p, let cid) = c.kind, cid == id, let pos = position(p) {
                let t = g.parameter(of: pos)
                if g.isClosed || (t > 1e-7 && t < 1 - 1e-7) { out.append(Cut(t: t, position: pos, point: p, curve: nil)) }
            }
        }
        out.sort { $0.t < $1.t }
        var unique: [Cut] = []
        for c in out where unique.last.map({ abs($0.t - c.t) > 1e-7 }) ?? true { unique.append(c) }
        return unique
    }

    /// A point for a cut: the existing point there, or a new one tied to the crossing curve.
    mutating func point(for cut: Cut) -> EntityID {
        if let p = cut.point { return p }
        let id = addPoint(cut.position.x, cut.position.y)
        if let c = cut.curve { constrain(.pointOnCurve(point: id, curve: c)) }
        return id
    }

    /// Replaces one of a curve's endpoints; the old point is removed if nothing uses it any more.
    mutating func replaceEndpoint(of id: EntityID, start: Bool, with p: EntityID) {
        guard let i = curves.firstIndex(where: { $0.id == id }) else { return }
        var old: EntityID?
        switch curves[i].geometry {
        case .line(let a, let b):
            old = start ? a : b
            curves[i].geometry = start ? .line(start: p, end: b) : .line(start: a, end: p)
        case .arc(let c, let a, let b):
            old = start ? a : b
            curves[i].geometry = start ? .arc(center: c, start: p, end: b) : .arc(center: c, start: a, end: p)
        case .bezier(let a, let c1, let c2, let b):
            old = start ? a : b
            curves[i].geometry = start ? .bezier(start: p, control1: c1, control2: c2, end: b)
                                       : .bezier(start: a, control1: c1, control2: c2, end: p)
        case .circle, .ellipse: return
        }
        // Length dimensions no longer describe the modified curve.
        dimensions.removeAll { if case .length(let l) = $0.kind { return l == id }; return false }
        if let old { removeIfUnused(old) }
    }

    mutating func removeIfUnused(_ p: EntityID) {
        guard p != "origin", !curves.contains(where: { pointIDs(of: $0).contains(p) }) else { return }
        delete([p])
    }

    // MARK: trim

    /// Removes the piece of curve `id` around `click` between its neighbouring intersections.
    /// A curve with nothing crossing it is deleted. Returns false if nothing changed.
    @discardableResult
    public mutating func trim(_ id: EntityID, at click: SIMD2<Double>) -> Bool {
        guard let g = geometry(of: id), let original = curve(id) else { return false }
        let crossings = cuts(on: id)
        var t = g.parameter(of: click)
        switch g {
        case .ellipse: return false  // not cut yet: an ellipse's trim is not supported
        case .circle:
            guard crossings.count >= 2 else { delete([id]); return true }
            // Neighbours around the click, cyclically.
            let after = crossings.first(where: { $0.t > t }) ?? crossings[0]
            let before = crossings.last(where: { $0.t < t }) ?? crossings[crossings.count - 1]
            guard case .circle(let center, _) = original.geometry else { return false }
            let s = point(for: after), e = point(for: before)
            if let i = curves.firstIndex(where: { $0.id == id }) {
                curves[i].geometry = .arc(center: center, start: s, end: e)  // keeps the rest of the circle
            }
            return true
        case .line, .arc, .bezier:
            t = min(max(t, 0), 1)
            let before = crossings.last(where: { $0.t < t })
            let after = crossings.first(where: { $0.t > t })
            // A Bézier keeps its shape: the piece that stays gets new handles.
            var ctrl: [SIMD2<Double>]?
            if case .bezier(let p) = g { ctrl = p }
            switch (before, after) {
            case (nil, nil):
                delete([id])
            case (nil, let a?):
                replaceEndpoint(of: id, start: true, with: point(for: a))
                if let ctrl { moveHandles(of: id, to: Bezier.piece(ctrl, from: a.t, to: 1)) }
            case (let b?, nil):
                replaceEndpoint(of: id, start: false, with: point(for: b))
                if let ctrl { moveHandles(of: id, to: Bezier.piece(ctrl, from: 0, to: b.t)) }
            case (let b?, let a?):
                // Split: this curve keeps start…b, a new one takes a…end.
                let pb = point(for: b), pa = point(for: a)
                let second = IDs.make()
                switch original.geometry {
                case .line(_, let end):
                    curves.append(SketchCurve(id: second, .line(start: pa, end: end), construction: original.construction))
                    constrain(.parallel(id, second))
                    constrain(.pointOnCurve(point: pa, curve: id))  // stays collinear
                case .arc(let center, _, let end):
                    curves.append(SketchCurve(id: second, .arc(center: center, start: pa, end: end), construction: original.construction))
                    constrain(.equal(id, second))
                case .ellipse: return false
                case .bezier(_, _, _, let end):
                    guard let ctrl else { return false }
                    let tail = Bezier.piece(ctrl, from: a.t, to: 1)
                    let k1 = addPoint(tail[1].x, tail[1].y), k2 = addPoint(tail[2].x, tail[2].y)
                    curves.append(SketchCurve(id: second, .bezier(start: pa, control1: k1, control2: k2, end: end),
                                              construction: original.construction))
                    moveHandles(of: id, to: Bezier.piece(ctrl, from: 0, to: b.t))
                case .circle:
                    return false
                }
                replaceEndpoint(of: id, start: false, with: pb)
            }
            return true
        }
    }

    /// Moves a Bézier's two handle points to the middle control points of `ctrl`.
    mutating func moveHandles(of id: EntityID, to ctrl: [SIMD2<Double>]) {
        guard case .bezier(_, let c1, let c2, _)? = curve(id)?.geometry else { return }
        for (p, q) in [(c1, ctrl[1]), (c2, ctrl[2])] {
            if let i = points.firstIndex(where: { $0.id == p }) { points[i].x = q.x; points[i].y = q.y }
        }
    }

    // MARK: extend

    /// Extends the end of line/arc `id` nearest to `click` to the next curve it would meet.
    @discardableResult
    public mutating func extend(_ id: EntityID, near click: SIMD2<Double>) -> Bool {
        guard let g = geometry(of: id), !g.isClosed else { return false }
        if case .bezier = g { return false }  // a Bézier has no natural continuation
        let atStart = vlen(g.point(0) - click) < vlen(g.point(1) - click)
        var best: (distance: Double, cut: Cut)?
        for other in curves where other.id != id {
            guard let h = geometry(of: other.id) else { continue }
            for p in intersect(g, h) {
                guard h.contains(h.parameter(of: p), eps: 1e-7) else { continue }
                let t = g.parameter(of: p)
                let beyond: Double
                switch g {
                case .line: beyond = atStart ? -t : t - 1
                case .arc(_, _, _, let sw):
                    // Arc parameters run 0…2π/sweep around the circle; past the end is t > 1,
                    // and "before the start" wraps round to just under 2π/sweep.
                    guard t > 1 else { continue }
                    beyond = atStart ? 2 * .pi / sw - t : t - 1
                case .circle, .bezier, .ellipse: continue
                }
                guard beyond > 1e-7 else { continue }
                if best == nil || beyond < best!.distance {
                    let existing = points.first { vlen($0.position - p) < 1e-6 }?.id
                    best = (beyond, Cut(t: t, position: p, point: existing, curve: other.id))
                }
            }
        }
        guard let target = best?.cut else { return false }
        let old = pointIDs(of: curve(id)!)
        let endpoint = atStart ? old[old.count == 2 ? 0 : 1] : old[old.count == 2 ? 1 : 2]
        let shared = curves.contains { $0.id != id && pointIDs(of: $0).contains(endpoint) }
        if !shared, target.point == nil, let i = points.firstIndex(where: { $0.id == endpoint }) {
            // Move the free end and tie it to the curve it now reaches.
            points[i].x = target.position.x
            points[i].y = target.position.y
            constraints.removeAll { if case .fix(let p, _, _) = $0.kind { return p == endpoint }; return false }
            dimensions.removeAll { if case .length(let l) = $0.kind { return l == id }; return false }
            constrain(.pointOnCurve(point: endpoint, curve: target.curve!))
        } else {
            replaceEndpoint(of: id, start: atStart, with: point(for: target))
        }
        return true
    }

    // MARK: offset

    /// Offsets the given curves by `distance` (positive = outward for closed chains, to the left
    /// of the chain otherwise). Connected curves stay connected. New lines are parallel to the
    /// originals with a distance dimension, arcs/circles are concentric with a radial-offset
    /// dimension, all driven by `expression`. A Bézier is followed by a run of Béziers fitted to its
    /// offset (an approximation, so they carry no dimension). Returns the new curve ids.
    @discardableResult
    public mutating func offset(_ ids: [EntityID], distance: Double, expression: String) -> [EntityID] {
        var created: [EntityID] = []
        let chainable = ids.filter { id in
            switch curve(id)?.geometry {
            case .line?, .arc?, .bezier?: return true
            default: return false  // circles are offset on their own
            }
        }
        // Circles: concentric copies.
        for id in ids {
            guard let c = curve(id), case .circle(let center, let r) = c.geometry else { continue }
            let nr = r + distance
            guard nr > 1e-6 else { continue }
            if Sketch.isGenerated(id) {  // an image or a copy is made again at every change: its offset is a plain circle
                let at = position(center) ?? .zero
                created.append(addCircle(center: addPoint(at.x, at.y), radius: nr))
                continue
            }
            let nid = addCircle(center: center, radius: nr)
            dimension(.radialOffset(from: id, to: nid), expression)
            created.append(nid)
        }
        var madeFrom: [EntityID: [EntityID]] = [:]
        for chain in chains(chainable) {
            created += offsetChain(chain, distance: distance, expression: expression, madeFrom: &madeFrom)
        }
        adoptImageOffsets(madeFrom, created: &created)
        return created
    }

    /// A mirror's image offset together with its original is not a copy of its own: the copy would be made once and
    /// never follow the original's offset when that changes. The copies are dropped instead, the original's offset
    /// joins what the mirror copies (so its image is the offset of the image), and a corner that lies on the mirror
    /// line, where the two offsets meet, is kept on it. Only for a mirror across a line of the sketch.
    private mutating func adoptImageOffsets(_ madeFrom: [EntityID: [EntityID]], created: inout [EntityID]) {
        for mi in mirrors.indices {
            let def = mirrors[mi]
            guard !SketchMirrorDef.isAxis(def.line), mirrorAxis(def.line) != nil else { continue }
            var own: [EntityID] = [], copies = Set<EntityID>()
            for source in def.sources where !Sketch.isGenerated(source) {
                guard let mine = madeFrom[source], let image = madeFrom["\(def.id)~\(source)"], !mine.isEmpty, !image.isEmpty else { continue }
                own += mine
                copies.formUnion(image)
            }
            guard !copies.isEmpty else { continue }
            delete(copies)
            created.removeAll { copies.contains($0) }
            guard let k = mirrors.firstIndex(where: { $0.id == def.id }) else { continue }
            mirrors[k].sources += own.filter { !mirrors[k].sources.contains($0) }
            holdPointsOnMirrorLine(mirrors[k])  // a corner on the line is shared with its image: it has to stay there
        }
    }

    /// Orders curves into connected chains; each entry is (curve id, reversed?) in travel order.
    /// Linear in the number of curves: the ends are looked up in tables made once (a sketch can hold hundreds of
    /// curves, and this runs on every cursor move of the drawing tools).
    func chains(_ ids: [EntityID]) -> [(items: [(id: EntityID, reversed: Bool)], closed: Bool)] {
        let byID = Dictionary(curves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The curves that have two ends, in the order given.
        var order: [EntityID] = []
        var ends: [(EntityID, EntityID)] = []
        for id in ids {
            guard let c = byID[id] else { continue }
            switch c.geometry {
            case .line(let a, let b), .arc(_, let a, let b), .bezier(let a, _, _, let b): order.append(id); ends.append((a, b))
            case .circle, .ellipse: continue
            }
        }
        // The curves at each point, in order (a curve once, even when both its ends are the point), and how many
        // are still free there.
        var at: [EntityID: [Int]] = [:]
        for (i, e) in ends.enumerated() {
            at[e.0, default: []].append(i)
            if e.1 != e.0 { at[e.1, default: []].append(i) }
        }
        var degree = at.mapValues(\.count)
        var alive = [Bool](repeating: true, count: order.count)
        /// Takes a curve out of play, and notes the curves that now have an open end.
        var openEnds = IndexHeap()
        for i in order.indices where degree[ends[i].0] == 1 || degree[ends[i].1] == 1 { openEnds.push(i) }
        func take(_ i: Int) {
            alive[i] = false
            for p in ends[i].0 == ends[i].1 ? [ends[i].0] : [ends[i].0, ends[i].1] {
                degree[p, default: 0] -= 1
                if degree[p] == 1, let left = at[p]?.first(where: { alive[$0] }) { openEnds.push(left) }
            }
        }
        var result: [(items: [(id: EntityID, reversed: Bool)], closed: Bool)] = []
        var scan = 0  // everything before this is taken
        while true {
            while scan < order.count, !alive[scan] { scan += 1 }
            guard scan < order.count else { break }
            // Start at an open end if there is one (the first such curve in the order given), else at the first curve.
            var start = scan
            while let i = openEnds.pop() {
                if alive[i] { start = i; break }
            }
            let e0 = ends[start]
            var chain: [(id: EntityID, reversed: Bool)] = [(order[start], degree[e0.0] != 1 && degree[e0.1] == 1)]
            take(start)
            var tip = chain[0].reversed ? e0.0 : e0.1
            let first = chain[0].reversed ? e0.1 : e0.0
            while let n = at[tip]?.first(where: { alive[$0] }) {
                let e = ends[n]
                let rev = e.1 == tip
                chain.append((order[n], rev))
                tip = rev ? e.0 : e.1
                take(n)
            }
            result.append((chain, tip == first && chain.count > 1))
        }
        return result
    }

    /// The unit direction a curve travels at parameter t (in its own orientation); nil for a circle.
    static func tangent(of g: CurveGeometry, at t: Double) -> SIMD2<Double>? {
        switch g {
        case .line(let a, let b):
            let d = b - a, l = vlen(d)
            return l > 1e-12 ? d / l : nil
        case .arc(_, _, let a0, let sw):
            let a = a0 + sw * t
            return SIMD2(-sin(a), cos(a))
        case .bezier(let p): return Bezier.tangent(p, t)
        case .circle, .ellipse: return nil
        }
    }

    /// Which way a positive offset distance goes from the left of a chain's travel direction: +1 (left),
    /// or −1 for a closed chain that runs counter-clockwise, where positive means outward.
    private func offsetSide(_ chain: (items: [(id: EntityID, reversed: Bool)], closed: Bool)) -> Double {
        guard chain.closed else {
            // A mirror image runs the same way as its original but is the other way round, so its left is the
            // original's right: flipped, the two offset to the same side of the shape. (A chain that joins the
            // original and its image is one curve, offset to its left all along.)
            let images = chain.items.allSatisfy { item in
                Sketch.isGenerated(item.id) && Sketch.pattern(ofGenerated: item.id).map { id in mirrors.contains { $0.id == id } } == true
            }
            return images ? -1 : 1
        }
        // Signed area of the chain walked along its curves, so two arcs or Béziers (whose ends alone
        // enclose nothing) still have a direction.
        var area = 0.0
        for item in chain.items {
            guard let g = geometry(of: item.id) else { continue }
            let steps: Int
            switch g {
            case .line: steps = 1
            case .arc: steps = 24
            default: steps = 16
            }
            var last = g.point(item.reversed ? 1 : 0)
            for k in 1...steps {
                let t = Double(k) / Double(steps)
                let next = g.point(item.reversed ? 1 - t : t)
                area += vcross(last, next)
                last = next
            }
        }
        return area > 0 ? -1 : 1
    }

    /// Where an offset's arrow stands and which way it points: a point in the middle of the first chain
    /// (or circle) of `ids`, and the unit direction a positive distance goes there (outward for a closed
    /// chain, to the left of the travel direction for an open one).
    public func offsetHandle(_ ids: [EntityID]) -> (origin: SIMD2<Double>, direction: SIMD2<Double>)? {
        let chainable = ids.filter { id in
            switch curve(id)?.geometry {
            case .line?, .arc?, .bezier?: return true
            default: return false
            }
        }
        if let chain = chains(chainable).first, !chain.items.isEmpty {
            let item = chain.items[chain.items.count / 2]
            guard let g = geometry(of: item.id), var t = Self.tangent(of: g, at: 0.5) else { return nil }
            if item.reversed { t = -t }
            let side = offsetSide(chain)
            return (g.point(0.5), SIMD2(-t.y, t.x) * side)
        }
        for id in ids {
            if case .circle(let c, let r)? = geometry(of: id) { return (c + SIMD2(r, 0), SIMD2(1, 0)) }
        }
        return nil
    }

    /// Where two lines meet, one through `p` along `u` and the other through `q` along `v`.
    private static func meeting(_ p: SIMD2<Double>, _ u: SIMD2<Double>, _ q: SIMD2<Double>, _ v: SIMD2<Double>) -> SIMD2<Double>? {
        let den = vcross(u, v)
        guard abs(den) > 1e-9 else { return nil }
        return p + u * (vcross(q - p, v) / den)
    }

    private mutating func offsetChain(_ chain: (items: [(id: EntityID, reversed: Bool)], closed: Bool),
                                      distance: Double, expression: String, madeFrom: inout [EntityID: [EntityID]]) -> [EntityID] {
        // Offset geometry of each piece, to the left of the travel direction.
        let left = distance * offsetSide(chain)
        var pieces: [CurveGeometry] = []
        /// A Bézier's offset as a run of cubics (in the curve's own direction); `pieces` then holds a
        /// stand-in with the run's ends and end handles, which is all the joints look at.
        var runs: [Int: [[SIMD2<Double>]]] = [:]
        for (i, item) in chain.items.enumerated() {
            guard let g = geometry(of: item.id) else { return [] }
            switch g {
            case .line(let a, let b):
                let d = (item.reversed ? a - b : b - a) / max(vlen(b - a), 1e-300)
                let n = SIMD2(-d.y, d.x) * left
                pieces.append(.line(a + n, b + n))
            case .arc(let c, let r, let a0, let sw):
                // Travelling counter-clockwise, left is toward the center.
                let nr = item.reversed ? r + left : r - left
                guard nr > 1e-6 else { return [] }
                pieces.append(.arc(center: c, radius: nr, start: a0, sweep: sw))
            case .bezier(let p):
                guard var run = Bezier.offset(item.reversed ? Array(p.reversed()) : p, by: left) else { return [] }
                if item.reversed { run = run.reversed().map { Array($0.reversed()) } }
                runs[i] = run
                pieces.append(.bezier([run[0][0], run[0][1], run[run.count - 1][2], run[run.count - 1][3]]))
            case .circle, .ellipse:
                return []
            }
        }
        // Joints: where consecutive offset pieces meet (nearest intersection to the moved joint).
        let n = chain.items.count
        func endPoint(_ i: Int, atEnd: Bool) -> SIMD2<Double> {
            let rev = chain.items[i].reversed
            return pieces[i].point(atEnd != rev ? 1 : 0)
        }
        /// The curve's travel direction where it starts or ends (as its original, which the offset shares).
        func travel(_ i: Int, atEnd: Bool) -> SIMD2<Double>? {
            let rev = chain.items[i].reversed
            guard let g = geometry(of: chain.items[i].id), let t = Self.tangent(of: g, at: atEnd != rev ? 1 : 0) else { return nil }
            return rev ? -t : t
        }
        var joints: [SIMD2<Double>] = []  // joints[i] = start of piece i in travel order
        for i in 0..<n {
            let prev = i - 1 >= 0 ? i - 1 : (chain.closed ? n - 1 : -1)
            let own = endPoint(i, atEnd: false)
            guard prev >= 0 else { joints.append(own); continue }
            let before = endPoint(prev, atEnd: true), guess = (own + before) / 2
            if runs[i] != nil || runs[prev] != nil {
                // A Bézier is in the corner. Smooth ones meet already; a sharp one meets where the offset
                // curves' tangent lines cross (kept near, or the two ends meet half way).
                if vlen(own - before) < 1e-4 * max(1, abs(distance)) { joints.append(guess); continue }
                if let u = travel(prev, atEnd: true), let v = travel(i, atEnd: false),
                   let m = Self.meeting(before, u, own, v), vlen(m - guess) <= 4 * max(abs(distance), 1e-3) {
                    joints.append(m)
                } else {
                    joints.append(guess)
                }
                continue
            }
            let candidates = intersect(pieces[prev], pieces[i])
            joints.append(candidates.min { vlen($0 - guess) < vlen($1 - guess) } ?? own)
        }
        var jointIDs = joints.map { addPoint($0.x, $0.y) }
        let lastEnd: EntityID
        var lastPosition = SIMD2<Double>.zero
        if chain.closed { lastEnd = jointIDs[0]; lastPosition = joints[0] } else {
            let p = endPoint(n - 1, atEnd: true)
            lastEnd = addPoint(p.x, p.y)
            lastPosition = p
            jointIDs.append(lastEnd)
        }
        var created: [EntityID] = []
        for (i, item) in chain.items.enumerated() {
            let s = jointIDs[i], e = i + 1 < jointIDs.count ? jointIDs[i + 1] : lastEnd
            let (a, b) = item.reversed ? (e, s) : (s, e)  // keep the original's orientation
            guard let original = curve(item.id) else { continue }
            switch original.geometry {
            case .circle, .ellipse: continue
            case .line:
                let nid = addLine(a, b)
                madeFrom[item.id, default: []].append(nid)
                if Sketch.isGenerated(item.id) { created.append(nid); continue }  // no ties to what is made again at every change
                constrain(.parallel(item.id, nid))
                dimension(.pointLineDistance(point: a, line: item.id), expression)
                // The dimension is drawn from the new line's start, which is a corner: its label would sit on the
                // corner, over the very place where the next shape is started. Slide it to the middle of the edge.
                if let ends = lineEnds(item.id) { dimensions[dimensions.count - 1].offset = vlen(ends.1 - ends.0) / 2 }
                created.append(nid)
            case .arc(let center, _, _):
                if Sketch.isGenerated(item.id) {
                    let at = position(center) ?? .zero
                    let nid = addArc(center: addPoint(at.x, at.y), start: a, end: b)
                    madeFrom[item.id, default: []].append(nid)
                    created.append(nid)
                    continue
                }
                let nid = addArc(center: center, start: a, end: b)
                madeFrom[item.id, default: []].append(nid)
                dimension(.radialOffset(from: item.id, to: nid), expression)
                created.append(nid)
            case .bezier:
                guard var run = runs[i] else { continue }
                // The ends go where the joints are (moved with their handles, so the directions stay).
                let startAt = joints[i], endAt = i + 1 < joints.count ? joints[i + 1] : lastPosition
                let (first, last) = item.reversed ? (endAt, startAt) : (startAt, endAt)
                let k = run.count - 1
                run[0][1] += first - run[0][0]; run[0][0] = first
                run[k][2] += last - run[k][3]; run[k][3] = last
                var from = a
                for (j, c) in run.enumerated() {
                    let to = j == k ? b : addPoint(c[3].x, c[3].y)
                    let c1 = addPoint(c[1].x, c[1].y), c2 = addPoint(c[2].x, c[2].y)
                    let nid = addBezier(start: from, control1: c1, control2: c2, end: to)
                    madeFrom[item.id, default: []].append(nid)
                    created.append(nid)
                    from = to
                }
            }
        }
        return created
    }

    // MARK: corner fillet

    /// Rounds the corner at point `p` where exactly two lines meet, with a tangent arc of `radius`
    /// (driven by `expression`). The corner point stays as a construction "virtual sharp" at the
    /// lines' intersection so dimensions to it still work. Returns the radius dimension id.
    public mutating func filletCorner(_ p: EntityID, radius: Double, expression: String) -> EntityID? {
        guard let pp = position(p) else { return nil }
        let lines = curves.filter { c in
            if case .line(let a, let b) = c.geometry { return a == p || b == p }
            return false
        }
        guard lines.count == 2, curves.filter({ pointIDs(of: $0).contains(p) }).count == 2 else { return nil }
        func farEnd(_ c: SketchCurve) -> SIMD2<Double>? {
            guard case .line(let a, let b) = c.geometry else { return nil }
            return position(a == p ? b : a)
        }
        guard let f1 = farEnd(lines[0]), let f2 = farEnd(lines[1]) else { return nil }
        // The lines' own ends, before they're shortened: their sizes stay measured between these.
        let originalEnds = lines.map { line -> (EntityID, EntityID)? in
            if case .line(let a, let b) = line.geometry { return (a, b) }
            return nil
        }
        let l1 = vlen(f1 - pp), l2 = vlen(f2 - pp)
        guard l1 > 1e-9, l2 > 1e-9 else { return nil }
        let u1 = (f1 - pp) / l1, u2 = (f2 - pp) / l2
        let theta = acos(min(max(vdot(u1, u2), -1), 1))
        guard theta > 0.5 * .pi / 180, theta < .pi - 0.5 * .pi / 180 else { return nil }
        let t = radius / tan(theta / 2)
        guard t < min(l1, l2) - 1e-9 else { return nil }
        let t1 = pp + u1 * t, t2 = pp + u2 * t
        let bis = (u1 + u2) / vlen(u1 + u2)
        let c = pp + bis * (radius / sin(theta / 2))

        let a = addPoint(t1.x, t1.y), b = addPoint(t2.x, t2.y), center = addPoint(c.x, c.y)
        for (line, tangentPoint) in [(lines[0], a), (lines[1], b)] {
            guard let i = curves.firstIndex(where: { $0.id == line.id }), case .line(let s, let e) = curves[i].geometry else { continue }
            curves[i].geometry = s == p ? .line(start: tangentPoint, end: e) : .line(start: s, end: tangentPoint)
        }
        // Counter-clockwise from whichever tangent point makes the short way round.
        let ang = { (q: SIMD2<Double>) in atan2(q.y - c.y, q.x - c.x) }
        var sweep = ang(t2) - ang(t1)
        while sweep < 0 { sweep += 2 * .pi }
        let arc = sweep <= .pi ? addArc(center: center, start: a, end: b) : addArc(center: center, start: b, end: a)
        constrain(.tangent(lines[0].id, arc))
        constrain(.tangent(lines[1].id, arc))
        // Keep the old corner as a virtual sharp on both (infinite) lines.
        constrain(.pointOnCurve(point: p, curve: lines[0].id))
        constrain(.pointOnCurve(point: p, curve: lines[1].id))
        // A side's length stays what it was: measured from corner to corner (the old corner is now a
        // virtual sharp on both lines), not along the shorter straight part.
        for (line, ends) in zip(lines, originalEnds) {
            guard let ends else { continue }
            for i in dimensions.indices {
                if case .length(let l) = dimensions[i].kind, l == line.id { dimensions[i].kind = .distance(ends.0, ends.1) }
            }
        }
        let dimID = IDs.make()
        dimension(.radius(arc), expression, id: dimID)
        return dimID
    }

    /// Cuts the corner at point `p` where exactly two lines meet with a straight chamfer: each line is shortened
    /// to `distance` from the corner, and the two new ends are joined by a line. The corner stays as a virtual
    /// sharp on both lines; two construction legs from it to the new ends are equal, and the leg's length is the
    /// dimension (driven by `expression`). Returns that dimension's id.
    public mutating func chamferCorner(_ p: EntityID, distance d: Double, expression: String) -> EntityID? {
        guard let pp = position(p) else { return nil }
        let lines = curves.filter { c in
            if case .line(let a, let b) = c.geometry { return a == p || b == p }
            return false
        }
        guard lines.count == 2, curves.filter({ pointIDs(of: $0).contains(p) }).count == 2 else { return nil }
        func farEnd(_ c: SketchCurve) -> SIMD2<Double>? {
            guard case .line(let a, let b) = c.geometry else { return nil }
            return position(a == p ? b : a)
        }
        guard let f1 = farEnd(lines[0]), let f2 = farEnd(lines[1]) else { return nil }
        let originalEnds = lines.map { line -> (EntityID, EntityID)? in
            if case .line(let a, let b) = line.geometry { return (a, b) }
            return nil
        }
        let l1 = vlen(f1 - pp), l2 = vlen(f2 - pp)
        guard l1 > 1e-9, l2 > 1e-9 else { return nil }
        let u1 = (f1 - pp) / l1, u2 = (f2 - pp) / l2
        let theta = acos(min(max(vdot(u1, u2), -1), 1))
        guard theta > 0.5 * .pi / 180, theta < .pi - 0.5 * .pi / 180 else { return nil }
        guard d > 1e-9, d < min(l1, l2) - 1e-9 else { return nil }
        let t1 = pp + u1 * d, t2 = pp + u2 * d
        let a = addPoint(t1.x, t1.y), b = addPoint(t2.x, t2.y)
        for (line, end) in [(lines[0], a), (lines[1], b)] {
            guard let i = curves.firstIndex(where: { $0.id == line.id }), case .line(let s, let e) = curves[i].geometry else { continue }
            curves[i].geometry = s == p ? .line(start: end, end: e) : .line(start: s, end: end)
        }
        let legA = addLine(p, a, construction: true), legB = addLine(p, b, construction: true)
        addLine(a, b)
        constrain(.pointOnCurve(point: p, curve: lines[0].id))
        constrain(.pointOnCurve(point: p, curve: lines[1].id))
        constrain(.equal(legA, legB))
        // Sides keep the length they had, measured corner to corner (as for a fillet).
        for (line, ends) in zip(lines, originalEnds) {
            guard let ends else { continue }
            for i in dimensions.indices {
                if case .length(let l) = dimensions[i].kind, l == line.id { dimensions[i].kind = .distance(ends.0, ends.1) }
            }
        }
        let dimID = IDs.make()
        dimension(.length(legA), expression, id: dimID)
        return dimID
    }
}

extension Sketch {
    /// The sketch grown by `factor` about its origin: every point and circle radius, and the height of
    /// its texts. Constraints stay as they are, and dimensions are left alone, so the result is for
    /// drawing and profiles, not for solving again.
    public func scaled(by factor: Double, parameters: ParameterValues) -> Sketch {
        var s = self
        for i in s.points.indices { s.points[i].x *= factor; s.points[i].y *= factor }
        for i in s.curves.indices {
            if case .circle(let c, let r) = s.curves[i].geometry { s.curves[i].geometry = .circle(center: c, radius: r * factor) }
        }
        for i in s.texts.indices {
            if let h = try? parameters.value(of: s.texts[i].height, kind: .length) {
                s.texts[i].height = formatDimension(h * factor, kind: .length)
            }
        }
        return s
    }
}

/// A set of curve indices that gives the smallest back first (a binary heap); an index pushed twice comes out twice.
struct IndexHeap {
    private var items: [Int] = []

    mutating func push(_ x: Int) {
        items.append(x)
        var i = items.count - 1
        while i > 0, items[(i - 1) / 2] > items[i] {
            items.swapAt(i, (i - 1) / 2)
            i = (i - 1) / 2
        }
    }

    mutating func pop() -> Int? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count, items[l] < items[m] { m = l }
                if r < items.count, items[r] < items[m] { m = r }
                if m == i { break }
                items.swapAt(i, m)
                i = m
            }
        }
        return top
    }
}
