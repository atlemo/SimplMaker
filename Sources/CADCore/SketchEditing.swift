// Editing operations on a sketch used by the interactive tools: snapping, deleting with
// cascade, measuring, suggesting dimensions, constraint tools and drag-solving.
// Kept UI-free so it can be unit-tested.
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

public enum SketchEntityKind: Sendable, Equatable {
    case point, line, circle, arc, bezier
    public var isCircular: Bool { self == .circle || self == .arc }
}

/// Where a tool click landed: a free position, an existing point, or on an existing curve.
/// A straight model edge the cursor snapped to (its ends in sketch coordinates), or one of its ends.
public struct ModelSnap: Sendable, Equatable {
    public var edge: EdgeRef
    public var start: SIMD2<Double>
    public var end: SIMD2<Double>
    /// 0 = the start, 1 = the end; nil = somewhere along the edge.
    public var endIndex: Int?
    public init(edge: EdgeRef, start: SIMD2<Double>, end: SIMD2<Double>, endIndex: Int? = nil) {
        self.edge = edge; self.start = start; self.end = end; self.endIndex = endIndex
    }
}

public struct SketchSnap: Sendable, Equatable {
    public var position: SIMD2<Double>
    public var point: EntityID?
    public var curve: EntityID?
    /// A model edge or corner: it becomes a projection of that edge when the snap is used (see concrete).
    public var model: ModelSnap?
    /// Two opposite corners of the four-sided shape whose center this is: a point placed here
    /// is kept at the middle of the diagonal between them.
    public var centerOf: [EntityID]?
    public init(_ position: SIMD2<Double>, point: EntityID? = nil, curve: EntityID? = nil, centerOf: [EntityID]? = nil,
                model: ModelSnap? = nil) {
        self.position = position; self.point = point; self.curve = curve; self.centerOf = centerOf; self.model = model
    }
}

/// The center of a closed shape in a sketch: the middle of its bounding box.
public struct ShapeCenter: Sendable, Equatable {
    public var position: SIMD2<Double>
    /// For a four-sided shape, two opposite corners (the center stays on their diagonal's middle).
    public var corners: [EntityID]?
    /// The points the shape is built from.
    public var points: Set<EntityID>
}

/// Constraint commands offered for a selection ("select, then constrain").
public enum ConstraintTool: String, CaseIterable, Sendable {
    case coincident = "Coincident"
    case horizontal = "Horizontal"
    case vertical = "Vertical"
    case parallel = "Parallel"
    case perpendicular = "Perpendicular"
    case tangent = "Tangent"
    case equal = "Equal"
    case midpoint = "Midpoint"
    case concentric = "Concentric"
    case symmetric = "Symmetric"
    case fix = "Fix"
}

extension Sketch {
    // MARK: queries

    public func kind(of id: EntityID) -> SketchEntityKind? {
        if point(id) != nil { return .point }
        guard let c = curve(id) else { return nil }
        switch c.geometry {
        case .line: return .line
        case .circle: return .circle
        case .arc: return .arc
        case .bezier: return .bezier
        }
    }

    /// Points a curve is built from (endpoints, center).
    public func pointIDs(of c: SketchCurve) -> [EntityID] {
        switch c.geometry {
        case .line(let a, let b): return [a, b]
        case .circle(let center, _): return [center]
        case .arc(let center, let s, let e): return [center, s, e]
        case .bezier(let a, let c1, let c2, let b): return [a, c1, c2, b]
        }
    }

    public func position(_ id: EntityID) -> SIMD2<Double>? { point(id)?.position }

    /// Every point's position by id, for loops over many curves: `position` scans the points, which adds up when
    /// a gear or a pattern has made hundreds of them.
    public func positionTable() -> [EntityID: SIMD2<Double>] {
        Dictionary(points.map { ($0.id, $0.position) }, uniquingKeysWith: { first, _ in first })
    }

    public func lineEnds(_ id: EntityID) -> (SIMD2<Double>, SIMD2<Double>)? {
        guard let c = curve(id), case .line(let a, let b) = c.geometry, let pa = position(a), let pb = position(b) else { return nil }
        return (pa, pb)
    }

    public func center(of id: EntityID) -> EntityID? {
        guard let c = curve(id) else { return nil }
        switch c.geometry {
        case .circle(let center, _), .arc(let center, _, _): return center
        case .line, .bezier: return nil
        }
    }

    public static func references(_ k: SketchConstraint.Kind) -> [EntityID] {
        switch k {
        case .coincident(let a, let b), .parallel(let a, let b), .perpendicular(let a, let b),
             .equal(let a, let b), .tangent(let a, let b): return [a, b]
        case .horizontal(let a), .vertical(let a): return [a]
        case .pointOnCurve(let p, let c): return [p, c]
        case .midpoint(let p, let l): return [p, l]
        case .fix(let p, _, _): return [p]
        case .symmetric(let a, let b, let l): return [a, b, l]
        }
    }

    public static func references(_ k: SketchDimension.Kind) -> [EntityID] {
        switch k {
        case .distance(let a, let b), .horizontalDistance(let a, let b), .verticalDistance(let a, let b),
             .angle(let a, let b), .radialOffset(let a, let b), .gap(let a, let b): return [a, b]
        case .pointLineDistance(let p, let l): return [p, l]
        case .length(let a), .radius(let a), .diameter(let a), .lineAngle(let a): return [a]
        }
    }

    // MARK: creating geometry from tool clicks

    /// Returns a point for the snap: the snapped point itself, or a new point
    /// (constrained onto the snapped curve, if any).
    public mutating func resolve(_ snap: SketchSnap) -> EntityID {
        let snap = concrete(snap)
        if let p = snap.point, point(p) != nil { return p }
        let id = addPoint(snap.position.x, snap.position.y)
        if let c = snap.curve, curve(c) != nil { constrain(.pointOnCurve(point: id, curve: c)) }
        if let corners = snap.centerOf, corners.count == 2, corners.allSatisfy({ point($0) != nil }) {
            // Centred for good: the middle of a construction diagonal across the shape.
            let diagonal = addLine(corners[0], corners[1], construction: true)
            constrain(.midpoint(point: id, line: diagonal))
        }
        return id
    }

    // MARK: projected model edges

    /// The projection of a model edge, made if the sketch doesn't have it yet.
    @discardableResult
    public mutating func project(_ m: ModelSnap) -> SketchProjection {
        if let have = projections.first(where: { $0.edge == m.edge }), point(have.start) != nil, point(have.end) != nil,
           curve(have.line) != nil {
            return have
        }
        projections.removeAll { $0.edge == m.edge }
        let a = addPoint(m.start.x, m.start.y), b = addPoint(m.end.x, m.end.y)
        for id in [a, b] { if let i = points.firstIndex(where: { $0.id == id }) { points[i].fixed = true } }
        let line = addLine(a, b, construction: true)
        let p = SketchProjection(edge: m.edge, start: a, end: b, line: line)
        projections.append(p)
        return p
    }

    /// A snap that names a model edge, turned into one that names sketch geometry: the edge's end
    /// point, or its line. Any other snap is returned as it is.
    public mutating func concrete(_ snap: SketchSnap) -> SketchSnap {
        guard let m = snap.model else { return snap }
        let p = project(m)
        var out = snap
        out.model = nil
        if let end = m.endIndex { out.point = end == 0 ? p.start : p.end } else { out.curve = p.line }
        return out
    }

    /// Drops projections whose points or line are gone.
    mutating func dropBrokenProjections() {
        let kept = projections.filter { p in point(p.start) != nil && point(p.end) != nil && curve(p.line) != nil }
        projections = kept
    }

    /// Every curve joined to `id` end to end, directly or through others (points that are shared
    /// or constrained coincident count as joined), `id` first. Construction curves join only a
    /// construction curve, and the others only each other.
    public func connectedCurves(_ id: EntityID) -> [EntityID] {
        guard let seed = curve(id) else { return [] }
        // Points tied by coincident constraints are one place.
        var group: [EntityID: EntityID] = [:]
        func root(_ p: EntityID) -> EntityID {
            var r = p
            while let next = group[r], next != r { r = next }
            return r
        }
        for c in constraints {
            if case .coincident(let a, let b) = c.kind { let ra = root(a), rb = root(b); if ra != rb { group[ra] = rb } }
        }
        func ends(_ c: SketchCurve) -> [EntityID] {
            switch c.geometry {
            case .line(let a, let b), .arc(_, let a, let b), .bezier(let a, _, _, let b): return [a, b]
            case .circle: return []
            }
        }
        let candidates = curves.filter { $0.construction == seed.construction }
        var found = [id], frontier = ends(seed).map(root)
        var seen = Set(frontier)
        while let p = frontier.popLast() {
            for c in candidates where !found.contains(c.id) && ends(c).map(root).contains(p) {
                found.append(c.id)
                for q in ends(c).map(root) where seen.insert(q).inserted { frontier.append(q) }
            }
        }
        return found
    }

    /// Centers of the closed shapes made of lines, arcs and curves joined end to end
    /// (construction geometry left out).
    public func shapeCenters() -> [ShapeCenter] {
        let ids = curves.filter { c in
            if case .circle = c.geometry { return false }
            return !c.construction && !Sketch.isGenerated(c.id)  // copies and gears: the callers never wanted their centres, and chaining hundreds of curves is slow
        }.map(\.id)
        let byID = Dictionary(curves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let positions = positionTable()
        return chains(ids).compactMap { chain -> ShapeCenter? in
            guard chain.closed else { return nil }
            var lo = SIMD2(Double.infinity, .infinity), hi = -lo
            var corners: [EntityID] = [], points = Set<EntityID>()
            var allLines = true
            for item in chain.items {
                guard let c = byID[item.id], let g = geometry(of: c, positions) else { return nil }
                for t in stride(from: 0.0, through: 1, by: 1.0 / 16) {
                    let p = g.point(t)
                    lo = pointwiseMin(lo, p); hi = pointwiseMax(hi, p)
                }
                let ends = pointIDs(of: c)
                points.formUnion(ends)
                if case .line = c.geometry {} else { allLines = false }
                corners.append(item.reversed ? ends[ends.count - 1] : ends[0])
            }
            let fourSided = allLines && corners.count == 4
            return ShapeCenter(position: (lo + hi) / 2, corners: fourSided ? [corners[0], corners[2]] : nil, points: points)
        }
    }

    public enum Alignment: Sendable { case horizontal, vertical }

    /// Horizontal/vertical inference for a new line (within ~2.5°).
    public static func inferredAlignment(from a: SIMD2<Double>, to b: SIMD2<Double>) -> Alignment? {
        let d = b - a
        let len = vlen(d)
        guard len > 1e-9 else { return nil }
        let tol = sin(2.5 * .pi / 180)
        if abs(d.y) / len < tol { return .horizontal }
        if abs(d.x) / len < tol { return .vertical }
        return nil
    }

    /// Adds a line between two snaps, with inferred horizontal/vertical constraint. Returns (line, end point).
    @discardableResult
    public mutating func addLine(from s: SketchSnap, to e: SketchSnap, startPoint: EntityID? = nil) -> (line: EntityID, end: EntityID) {
        let a = startPoint ?? resolve(s)
        var endSnap = concrete(e)
        let aPos = position(a) ?? s.position
        let alignment = Sketch.inferredAlignment(from: aPos, to: e.position)
        if endSnap.point == nil, endSnap.curve == nil, let alignment {  // make it exactly aligned
            if alignment == .horizontal { endSnap.position.y = aPos.y } else { endSnap.position.x = aPos.x }
        }
        let b = resolve(endSnap)
        let line = addLine(a, b)
        if let alignment {
            constrain(alignment == .horizontal ? .horizontal(line) : .vertical(line))
        }
        return (line, b)
    }

    /// Rectangle from two corner snaps; snapped corners are tied to what they snapped to.
    @discardableResult
    public mutating func addRectangle(from s: SketchSnap, to e: SketchSnap) -> [EntityID] {
        let s = concrete(s), e = concrete(e)
        let r = addRectangle(s.position.x, s.position.y, e.position.x, e.position.y)
        attach(r.corners[0], to: s)
        attach(r.corners[2], to: e)
        return r.lines
    }

    /// Rectangle centred on `center` with a corner at `corner`. A construction diagonal keeps the
    /// center point in its middle, so it stays centred as it's resized. Returns the lines
    /// (bottom, right, top, left).
    @discardableResult
    public mutating func addCenterRectangle(center: SketchSnap, corner: SketchSnap) -> [EntityID] {
        let center = concrete(center), corner = concrete(corner)
        let c = center.point.flatMap { position($0) } ?? center.position
        let r = addRectangle(2 * c.x - corner.position.x, 2 * c.y - corner.position.y, corner.position.x, corner.position.y)
        attach(r.corners[2], to: corner)
        let middle = resolve(center)
        let diagonal = addLine(r.corners[0], r.corners[2], construction: true)
        constrain(.midpoint(point: middle, line: diagonal))
        return r.lines
    }

    /// The fewest and most corners a polygon can have.
    public static let polygonSides = 3...64

    /// Regular polygon of `sides` corners around `center`, with its first corner at `corner`. The
    /// corners sit on a construction circle and the sides are all equal, so it stays regular as it is
    /// resized or dragged. Returns the sides (counter-clockwise from the first corner) and the circle.
    @discardableResult
    public mutating func addPolygon(center: SketchSnap, corner: SketchSnap, sides: Int) -> (lines: [EntityID], circle: EntityID) {
        let n = min(max(sides, Sketch.polygonSides.lowerBound), Sketch.polygonSides.upperBound)
        let center = concrete(center), corner = concrete(corner)
        let c = center.point.flatMap { position($0) } ?? center.position
        let d = corner.position - c
        let r = max(vlen(d), 1e-3)
        let first = atan2(d.y, d.x)
        let middle = resolve(center)
        let circle = addCircle(center: middle, radius: r)
        if let i = curves.firstIndex(where: { $0.id == circle }) { curves[i].construction = true }
        let corners = (0..<n).map { k -> EntityID in
            let a = first + 2 * .pi * Double(k) / Double(n)
            return addPoint(c.x + r * cos(a), c.y + r * sin(a))
        }
        let lines = (0..<n).map { addLine(corners[$0], corners[($0 + 1) % n]) }
        for p in corners { constrain(.pointOnCurve(point: p, curve: circle)) }
        for l in lines.dropFirst() { constrain(.equal(lines[0], l)) }
        attach(corners[0], to: corner)
        return (lines, circle)
    }

    /// Arc from `start` to `end` through `through`, with a new center point; nil if the three are
    /// in a line.
    @discardableResult
    public mutating func addArc(from start: SketchSnap, to end: SketchSnap, through mid: SketchSnap) -> EntityID? {
        let a = start.point.flatMap { position($0) } ?? start.position
        let b = end.point.flatMap { position($0) } ?? end.position
        let m = mid.position
        // The circle through three points: where the perpendicular bisectors cross.
        let d = 2 * vcross(b - a, m - a)
        guard abs(d) > 1e-9 * max(vdot(b - a, b - a), 1e-12) else { return nil }
        let ab = vdot(b - a, b - a), am = vdot(m - a, m - a)
        let off = SIMD2((m - a).y * ab - (b - a).y * am, (b - a).x * am - (m - a).x * ab) / d
        let center = a + off
        // Arcs run counter-clockwise from start to end: swap them if the middle point is on the other side.
        func angle(_ p: SIMD2<Double>) -> Double { atan2(p.y - center.y, p.x - center.x) }
        func ccw(_ from: Double, _ to: Double) -> Double { var t = to - from; while t < 0 { t += 2 * .pi }; return t }
        let throughFirst = ccw(angle(a), angle(m)) < ccw(angle(a), angle(b))
        let c = addPoint(center.x, center.y)
        return throughFirst ? addArc(center: SketchSnap(center, point: c), start: start, end: end)
                            : addArc(center: SketchSnap(center, point: c), start: end, end: start)
    }

    @discardableResult
    public mutating func addCircle(center s: SketchSnap, through e: SketchSnap) -> EntityID {
        let c = resolve(s)
        let r = max(vlen(e.position - (position(c) ?? s.position)), 1e-3)
        return addCircle(center: c, radius: r)
    }

    /// Circle through two points on opposite sides (they span its diameter), with a new center point
    /// midway. Clicked points that snapped to geometry are kept on the circle.
    @discardableResult
    public mutating func addCircle(diameterFrom a: SketchSnap, to b: SketchSnap) -> EntityID {
        let a = concrete(a), b = concrete(b)
        let pa = a.point.flatMap { position($0) } ?? a.position, pb = b.point.flatMap { position($0) } ?? b.position
        let mid = (pa + pb) / 2
        let id = addCircle(center: addPoint(mid.x, mid.y), radius: max(vlen(pb - pa) / 2, 1e-3))
        for s in [a, b] where s.point != nil || s.curve != nil {
            constrain(.pointOnCurve(point: resolve(s), curve: id))
        }
        return id
    }

    /// Center-point arc, counter-clockwise from `start` to `end` (end is projected onto the circle).
    @discardableResult
    public mutating func addArc(center s: SketchSnap, start: SketchSnap, end: SketchSnap) -> EntityID {
        let c = resolve(s)
        let cp = position(c) ?? s.position
        let a = resolve(start)
        let r = vlen((position(a) ?? start.position) - cp)
        var endSnap = concrete(end)
        if endSnap.point == nil {
            let d = end.position - cp
            let len = vlen(d)
            endSnap.position = len > 1e-9 ? cp + d * (r / len) : cp + SIMD2(r, 0)
        }
        let b = resolve(endSnap)
        return addArc(center: c, start: a, end: b)
    }

    /// Cubic Bézier from `a` to `b` that bends through `bend`: its handles start a third of the way
    /// along, pushed sideways together so the curve's middle lands on `bend`.
    @discardableResult
    public mutating func addBezier(from a: SketchSnap, to b: SketchSnap, through bend: SIMD2<Double>) -> EntityID {
        let s = resolve(a), e = resolve(b)
        let ps = position(s) ?? a.position, pe = position(e) ?? b.position
        let push = (bend - (ps + pe) / 2) / 0.75  // B(½) = midpoint + ¾ · push
        let c1 = ps + (pe - ps) / 3 + push, c2 = ps + (pe - ps) * 2 / 3 + push
        return addBezier(start: s, control1: addPoint(c1.x, c1.y), control2: addPoint(c2.x, c2.y), end: e)
    }

    public mutating func attach(_ p: EntityID, to snap: SketchSnap) {
        let snap = concrete(snap)
        if let q = snap.point, point(q) != nil { constrain(.coincident(p, q)) }
        else if let c = snap.curve, curve(c) != nil { constrain(.pointOnCurve(point: p, curve: c)) }
    }

    // MARK: deleting

    /// Deletes points, curves, constraints or dimensions by id. Curves using deleted points go too,
    /// as do constraints/dimensions referencing anything deleted and points left unused.
    public mutating func delete(_ ids: Set<EntityID>) {
        var gone = ids
        gone.remove("origin")
        let removedCurves = curves.filter { c in gone.contains(c.id) || pointIDs(of: c).contains(where: gone.contains) }
        for c in removedCurves { gone.insert(c.id) }
        curves.removeAll { gone.contains($0.id) }
        // Points that only belonged to removed curves.
        texts.removeAll { gone.contains($0.id) || gone.contains($0.position) }  // a text goes with its anchor
        let stillUsed = Set(curves.flatMap { pointIDs(of: $0) } + texts.map(\.position))
        for c in removedCurves {
            for p in pointIDs(of: c) where p != "origin" && !stillUsed.contains(p) { gone.insert(p) }
        }
        points.removeAll { gone.contains($0.id) }
        dropBrokenProjections()
        for i in patterns.indices { patterns[i].sources.removeAll { gone.contains($0) } }
        patterns.removeAll { $0.sources.isEmpty }
        constraints.removeAll { gone.contains($0.id) || Sketch.references($0.kind).contains(where: gone.contains) }
        dimensions.removeAll { gone.contains($0.id) || Sketch.references($0.kind).contains(where: gone.contains) }
    }

    public mutating func toggleConstruction(_ ids: [EntityID]) {
        let targets = Set(ids)
        let makeConstruction = curves.contains { targets.contains($0.id) && !$0.construction }
        for i in curves.indices where targets.contains(curves[i].id) { curves[i].construction = makeConstruction }
    }

    // MARK: measuring and dimensions

    /// Current value of a dimension in base units (mm / rad), as the geometry is now.
    public func measure(_ k: SketchDimension.Kind) -> Double? {
        switch k {
        case .distance(let a, let b):
            guard let pa = position(a), let pb = position(b) else { return nil }
            return vlen(pb - pa)
        case .horizontalDistance(let a, let b):
            guard let pa = position(a), let pb = position(b) else { return nil }
            return abs(pb.x - pa.x)
        case .verticalDistance(let a, let b):
            guard let pa = position(a), let pb = position(b) else { return nil }
            return abs(pb.y - pa.y)
        case .pointLineDistance(let p, let l):
            guard let pp = position(p), case let (a, b)? = lineEnds(l) else { return nil }
            return abs(vcross(b - a, pp - a)) / max(vlen(b - a), 1e-12)
        case .length(let l):
            guard case let (a, b)? = lineEnds(l) else { return nil }
            return vlen(b - a)
        case .radius(let c):
            return curve(c).flatMap { radius(of: $0) }
        case .diameter(let c):
            return curve(c).flatMap { radius(of: $0) }.map { $0 * 2 }
        case .radialOffset(let a, let b):
            guard let ca = curve(a), let cb = curve(b), let ra = radius(of: ca), let rb = radius(of: cb) else { return nil }
            return abs(rb - ra)
        case .gap(let a, let b):
            return rimGap(a, b).map { abs($0.gap($0.side)) }
        case .angle(let l1, let l2):
            guard case let (a1, b1)? = lineEnds(l1), case let (a2, b2)? = lineEnds(l2) else { return nil }
            let u = b1 - a1, w = b2 - a2
            var t = atan2(vcross(u, w), vdot(u, w))
            if t < 0 { t += 2 * .pi }
            return t
        case .lineAngle(let l):
            guard case let (a, b)? = lineEnds(l) else { return nil }
            return abs(atan2(b.y - a.y, b.x - a.x))
        }
    }

    /// A line's direction from the sketch's x-axis, counter-clockwise, -180° to 180°: which side of it the line is on.
    public func lineDirection(_ l: EntityID) -> Double? {
        guard case let (a, b)? = lineEnds(l) else { return nil }
        return atan2(b.y - a.y, b.x - a.x)
    }

    /// A line-angle value as measured: 0° to 180°, whatever turn was typed (325° and -35° are both 35°).
    public static func foldedAngle(_ v: Double) -> Double { abs(atan2(sin(v), cos(v))) }

    /// A line's full extent when corners were rounded off it: the outermost of its ends and the
    /// points kept on it (a rounded corner's "virtual sharp"). Nil when that's just its own ends.
    public func lineSpan(_ id: EntityID) -> (EntityID, EntityID)? {
        var onLine: [EntityID] = []
        for c in constraints {
            if case .pointOnCurve(let p, let line) = c.kind, line == id { onLine.append(p) }
        }
        return lineSpan(id, onLine: onLine, positionTable())
    }

    /// The span of a line, given the points constrained onto it (in constraint order) and every point's position.
    private func lineSpan(_ id: EntityID, onLine: [EntityID], _ positions: [EntityID: SIMD2<Double>]) -> (EntityID, EntityID)? {
        guard case .line(let a, let b)? = curve(id)?.geometry, let pa = positions[a], let pb = positions[b] else { return nil }
        let d = pb - pa, len2 = vdot(d, d)
        guard len2 > 1e-18 else { return nil }
        var candidates = [a, b]
        for p in onLine where !candidates.contains(p) { candidates.append(p) }
        let along = candidates.compactMap { p in positions[p].map { (p, vdot($0 - pa, d) / len2) } }
        guard let lo = along.min(by: { $0.1 < $1.1 }), let hi = along.max(by: { $0.1 < $1.1 }),
              lo.0 != a || hi.0 != b else { return nil }
        return (lo.0, hi.0)
    }

    /// `suggestDimension(for: [id])` for every line, circle and arc at once: what the sketch shows as the light
    /// measured size of each. The same answers, from tables made once, for a sketch of hundreds of curves.
    public func sizeSuggestions() -> [EntityID: (kind: SketchDimension.Kind, value: Double)] {
        let positions = positionTable()
        var byLine: [EntityID: [EntityID]] = [:]
        for c in constraints {
            if case .pointOnCurve(let p, let line) = c.kind { byLine[line, default: []].append(p) }
        }
        var out: [EntityID: (kind: SketchDimension.Kind, value: Double)] = [:]
        for c in curves {
            switch c.geometry {
            case .line(let a, let b):
                if let span = lineSpan(c.id, onLine: byLine[c.id] ?? [], positions) {
                    guard let pa = positions[span.0], let pb = positions[span.1] else { continue }
                    out[c.id] = (.distance(span.0, span.1), vlen(pb - pa))
                } else if let pa = positions[a], let pb = positions[b] {
                    out[c.id] = (.length(c.id), vlen(pb - pa))
                }
            case .circle(_, let r): out[c.id] = (.diameter(c.id), r * 2)
            case .arc(let center, let s, _):
                if let pc = positions[center], let ps = positions[s] { out[c.id] = (.radius(c.id), vlen(ps - pc)) }
            case .bezier: continue
            }
        }
        return out
    }

    /// A circle or arc's rim and what it is measured to, as they are now.
    func rimGap(_ circle: EntityID, _ other: EntityID) -> RimGap? {
        guard let c = curve(circle), let r = radius(of: c), let cp = center(of: circle).flatMap({ position($0) }) else { return nil }
        switch kind(of: other) {
        case .point?: return position(other).map { RimGap(center: cp, radius: r, other: .point($0)) }
        case .line?: return lineEnds(other).map { RimGap(center: cp, radius: r, other: .line($0.0, $0.1)) }
        case .circle?, .arc?:
            guard let oc = curve(other), let orad = radius(of: oc), let op = center(of: other).flatMap({ position($0) })
            else { return nil }
            return RimGap(center: cp, radius: r, other: .circle(op, orad))
        case .bezier?, nil: return nil
        }
    }

    /// The distance the Distance tool sets between two picked items: points and lines as usual, a
    /// circle or arc by its rim (to measure from its middle, pick its center point instead).
    /// Nil for a pair with no single distance: two lines that aren't parallel, or a spline.
    public func suggestDistance(for ids: [EntityID]) -> (kind: SketchDimension.Kind, value: Double)? {
        guard ids.count == 2, ids[0] != ids[1], let k0 = kind(of: ids[0]), let k1 = kind(of: ids[1]) else { return nil }
        func gap(_ circle: EntityID, _ other: EntityID) -> (kind: SketchDimension.Kind, value: Double)? {
            if center(of: circle) == other { return nil }  // a circle to its own center
            let k = SketchDimension.Kind.gap(circle, other)
            return measure(k).map { (kind: k, value: $0) }
        }
        switch (k0, k1) {
        case (.bezier, _), (_, .bezier): return nil
        case (.circle, _), (.arc, _): return gap(ids[0], ids[1])
        case (_, .circle), (_, .arc): return gap(ids[1], ids[0])
        case (.line, .line):
            guard case let (a1, b1)? = lineEnds(ids[0]), case let (a2, b2)? = lineEnds(ids[1]),
                  abs(vcross(b1 - a1, b2 - a2)) / max(vlen(b1 - a1) * vlen(b2 - a2), 1e-12) < 1e-6 else { return nil }
            return suggestDimension(for: ids)
        default: return suggestDimension(for: ids)
        }
    }

    /// The dimension that fits a picked set of entities, with its current value.
    /// One line → length; circle → diameter; arc → radius; two points → distance;
    /// point + line → distance to line; two lines → angle (or distance if parallel).
    public func suggestDimension(for ids: [EntityID]) -> (kind: SketchDimension.Kind, value: Double)? {
        let kinds = ids.map { kind(of: $0) }
        func result(_ k: SketchDimension.Kind) -> (kind: SketchDimension.Kind, value: Double)? { measure(k).map { (kind: k, value: $0) } }
        switch (ids.count, kinds.first ?? nil, kinds.count > 1 ? kinds[1] : nil) {
        case (1, .line?, _):
            // A side with rounded corners is measured corner to corner.
            if let span = lineSpan(ids[0]) { return result(.distance(span.0, span.1)) }
            return result(.length(ids[0]))
        case (1, .circle?, _): return result(.diameter(ids[0]))
        case (1, .arc?, _): return result(.radius(ids[0]))
        case (2, .point?, .point?): return result(.distance(ids[0], ids[1]))
        case (2, .point?, .line?): return result(.pointLineDistance(point: ids[0], line: ids[1]))
        case (2, .line?, .point?): return result(.pointLineDistance(point: ids[1], line: ids[0]))
        case (2, .line?, .line?):
            guard case let (a1, b1)? = lineEnds(ids[0]), case let (a2, b2)? = lineEnds(ids[1]) else { return nil }
            let u = b1 - a1, w = b2 - a2
            if abs(vcross(u, w)) / max(vlen(u) * vlen(w), 1e-12) < 1e-6,
               case .line(let s, _)? = curve(ids[1])?.geometry {
                return result(.pointLineDistance(point: s, line: ids[0]))
            }
            // Measure the angle the "short way" (< 180°) by ordering the lines.
            let k: SketchDimension.Kind = (measure(.angle(ids[0], ids[1])) ?? 0) <= .pi
                ? .angle(ids[0], ids[1]) : .angle(ids[1], ids[0])
            return result(k)
        case (2, .point?, .circle?), (2, .point?, .arc?):
            guard let c = center(of: ids[1]) else { return nil }
            return result(.distance(ids[0], c))
        case (2, .circle?, .point?), (2, .arc?, .point?):
            guard let c = center(of: ids[0]) else { return nil }
            return result(.distance(c, ids[1]))
        default: return nil
        }
    }

    /// Whether picking stops being ambiguous: circles/arcs and pairs are complete; a single
    /// line or point waits for a second pick (or a click in empty space for a line).
    public func dimensionPickIsComplete(_ ids: [EntityID]) -> Bool {
        if ids.count >= 2 { return true }
        guard let id = ids.first, let k = kind(of: id) else { return false }
        return k.isCircular
    }

    // MARK: constraint tools

    /// The constraints a tool would add for the selection, or nil if it doesn't apply.
    public func constraints(_ tool: ConstraintTool, for ids: [EntityID]) -> [SketchConstraint.Kind]? {
        let kinds = ids.compactMap { kind(of: $0) }
        guard kinds.count == ids.count, !ids.isEmpty else { return nil }
        let lines = zip(ids, kinds).filter { $0.1 == .line }.map(\.0)
        let circular = zip(ids, kinds).filter { $0.1.isCircular }.map(\.0)
        let pts = zip(ids, kinds).filter { $0.1 == .point }.map(\.0)
        switch tool {
        case .horizontal, .vertical:
            guard lines.count == ids.count else { return nil }
            return lines.map { tool == .horizontal ? .horizontal($0) : .vertical($0) }
        case .parallel, .perpendicular:
            guard ids.count == 2, lines.count == 2 else { return nil }
            return [tool == .parallel ? .parallel(lines[0], lines[1]) : .perpendicular(lines[0], lines[1])]
        case .equal:
            guard ids.count == 2, lines.count == 2 || circular.count == 2 else { return nil }
            return [.equal(ids[0], ids[1])]
        case .tangent:
            let beziers = kinds.filter { $0 == .bezier }.count
            guard ids.count == 2, (circular.count >= 1 && lines.count + circular.count == 2) || (lines.count == 1 && beziers == 1)
            else { return nil }
            return [.tangent(ids[0], ids[1])]
        case .coincident:
            guard ids.count == 2 else { return nil }
            if pts.count == 2 { return [.coincident(pts[0], pts[1])] }
            if pts.count == 1 {
                let c = ids.first { $0 != pts[0] }!
                return [.pointOnCurve(point: pts[0], curve: c)]
            }
            return nil
        case .midpoint:
            guard ids.count == 2, pts.count == 1, lines.count == 1 else { return nil }
            return [.midpoint(point: pts[0], line: lines[0])]
        case .concentric:
            guard ids.count == 2, circular.count == 2, let a = center(of: circular[0]), let b = center(of: circular[1]) else {
                return nil
            }
            return [.coincident(a, b)]
        case .symmetric:
            // Two points (or the centres of two circles or arcs) mirrored across a line: the line
            // picked last when there are two.
            guard ids.count == 3, lines.count >= 1 else { return nil }
            let axis = lines[lines.count - 1]
            let others = ids.filter { $0 != axis }
            let points = others.compactMap { id -> EntityID? in kind(of: id) == .point ? id : center(of: id) }
            guard others.count == 2, points.count == 2, points[0] != points[1] else { return nil }
            return [.symmetric(points[0], points[1], line: axis)]
        case .fix:
            guard pts.count == ids.count else { return nil }
            return pts.compactMap { p in position(p).map { .fix(p, x: $0.x, y: $0.y) } }
        }
    }

    // MARK: solving

    /// Dimension values for solving, evaluated against the parameter table. Failing expressions are skipped.
    public func dimensionValues(_ params: ParameterValues) -> [EntityID: Double] {
        var out: [EntityID: Double] = [:]
        for d in dimensions {
            if let v = try? params.value(of: d.expression, kind: d.unitKind) { out[d.id] = v }
        }
        return out
    }

    /// Adds constraints and re-solves; leaves the sketch untouched and returns false if that over-constrains it.
    public mutating func applyConstraints(_ kinds: [SketchConstraint.Kind], values: [EntityID: Double]) -> Bool {
        var trial = self
        for k in kinds { trial.constrain(k) }
        guard SketchSolver.solve(&trial, dimensionValues: values).status == .solved else { return false }
        self = trial
        return true
    }

    /// Adds a dimension (value in base units, shown as `expression`); false if it over-constrains.
    public mutating func applyDimension(_ kind: SketchDimension.Kind, expression: String, value: Double,
                                        values: [EntityID: Double], id: EntityID = IDs.make()) -> Bool {
        var trial = self
        trial.dimension(kind, expression, id: id)
        var v = values
        v[id] = value
        guard SketchSolver.solve(&trial, dimensionValues: v).status == .solved else { return false }
        self = trial
        return true
    }

    /// Drags a point (or a whole line, or a circle's rim) toward `target`, keeping all constraints.
    /// Geometry follows as far as the constraints allow. Returns false (sketch unchanged) if the
    /// entity can't be dragged or the sketch can't be solved.
    public mutating func drag(_ id: EntityID, to target: SIMD2<Double>, grabOffset: SIMD2<Double> = .zero,
                              values: [EntityID: Double]) -> Bool {
        var soft: [SoftTarget] = []
        switch kind(of: id) {
        case .point?:
            guard point(id)?.fixed == false else { return false }
            soft = [.point(id, target)]
        case .line?:
            guard case let (a, b)? = lineEnds(id), case .line(let pa, let pb)? = curve(id)?.geometry else { return false }
            let delta = target - grabOffset - a
            soft = [.point(pa, a + delta), .point(pb, b + delta)]
        case .circle?, .arc?:
            guard let c = center(of: id), let cp = position(c) else { return false }
            soft = [.radius(id, max(vlen(target - cp), 1e-3))]
        case .bezier?:
            // The whole curve, handles and all, slides with the cursor.
            guard let c = curve(id), let start = pointIDs(of: c).first.flatMap({ position($0) }) else { return false }
            let delta = target - grabOffset - start
            soft = pointIDs(of: c).compactMap { p in position(p).map { .point(p, $0 + delta) } }
        case nil: return false
        }
        var trial = self
        _ = SketchSolver.solve(&trial, dimensionValues: values, soft: soft)      // pull toward the cursor
        guard SketchSolver.solve(&trial, dimensionValues: values).status == .solved else { return false }  // then exact
        self = trial
        return true
    }
}

/// A plain number in a field (`68`, `12.5 mm`, `-3 deg`) moved by `delta`, keeping what follows the number
/// (its unit) as typed. Nil when the text is anything else (an expression, a parameter's name), which an
/// arrow key leaves alone.
public func nudgedExpression(_ text: String, by delta: Double) -> String? {
    let t = text.trimmingCharacters(in: .whitespaces)
    guard let m = t.wholeMatch(of: /(-?(?:\d+\.?\d*|\.\d+))(\s*[a-zA-Z°"']*)/), let v = Double(m.1) else { return nil }
    var s = String(format: "%.6f", ((v + delta) * 1e6).rounded() / 1e6)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    if s == "-0" { s = "0" }
    return s + m.2
}

/// Formats a measured value as an expression, e.g. "23.45 mm" or "30 deg".
public func formatDimension(_ value: Double, kind: UnitKind) -> String {
    let v = kind == .angle ? value * 180 / .pi : value
    var s = String(format: "%.3f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    if s == "-0" { s = "0" }
    switch kind {
    case .length: return s + " mm"
    case .angle: return s + " deg"
    case .none: return s
    }
}
