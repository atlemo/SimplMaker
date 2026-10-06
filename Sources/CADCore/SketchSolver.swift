// Geometric constraint solver: Levenberg–Marquardt on constraint residuals.
//
// Unknowns are the coordinates of non-fixed points and circle radii (an arc's radius is
// implied by its center and start point). Every constraint and dimension contributes one
// or two residuals that are zero when satisfied. Starting from the current geometry, the
// damped Gauss–Newton steps move the geometry as little as possible, which is what makes
// an under-constrained sketch "stay where it is" while dimensions change.
//
// Copyright © 2026 Atle Mo. All rights reserved.
import Foundation

public struct SolveResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case solved, failed }
    public var status: Status
    /// Remaining degrees of freedom (0 = fully constrained).
    public var degreesOfFreedom: Int
    public var maxResidual: Double
    public var iterations: Int
}

/// A weak pull used while dragging: satisfied as well as the real constraints allow.
public enum SoftTarget: Sendable, Equatable {
    case point(EntityID, SIMD2<Double>)
    case radius(EntityID, Double)
}

public enum SketchSolver {
    public static let tolerance = 1e-9

    /// Solves `sketch` in place. `dimensionValues` maps dimension id -> value in base units (mm / rad).
    /// `soft` targets are weighted down so constraints win; with soft targets the result is a
    /// least-squares compromise (re-solve without them to satisfy the constraints exactly).
    public static func solve(_ sketch: inout Sketch, dimensionValues: [EntityID: Double],
                             soft: [SoftTarget] = [], softWeight: Double = 0.05) -> SolveResult {
        // Pattern copies take no part: they are made again from the originals afterwards.
        if sketch.points.contains(where: { Sketch.isGenerated($0.id) }) {
            let generated = sketch.takeGenerated()
            defer { sketch.restoreGenerated(generated) }
            return solve(&sketch, dimensionValues: dimensionValues, soft: soft, softWeight: softWeight)
        }
        // The solver is dense, so a big sketch (an imported drawing, say) is solved in independent groups.
        guard sketch.points.count > splitThreshold else {
            return solveTogether(&sketch, dimensionValues: dimensionValues, soft: soft, softWeight: softWeight)
        }
        return solveInGroups(&sketch, dimensionValues: dimensionValues, soft: soft, softWeight: softWeight)
    }

    /// Sketches with more points than this are split into groups that don't constrain each other.
    static let splitThreshold = 150

    /// Solves the groups of a sketch one by one. Arcs, constraints, dimensions and soft targets tie
    /// together the movable points (and circle radii) they mention; things tied together are one
    /// group. Fixed points are constants and tie nothing. Points and circles that nothing mentions
    /// are free, and cost nothing.
    static func solveInGroups(_ sketch: inout Sketch, dimensionValues: [EntityID: Double],
                              soft: [SoftTarget], softWeight: Double) -> SolveResult {
        struct Item {
            var refs: [EntityID]
            var constraint: SketchConstraint?
            var dimension: SketchDimension?
            var soft: SoftTarget?
        }
        var items: [Item] = []
        for c in sketch.curves { if case .arc = c.geometry { items.append(Item(refs: [c.id])) } }
        for c in sketch.constraints { items.append(Item(refs: Sketch.references(c.kind), constraint: c)) }
        for d in sketch.dimensions { items.append(Item(refs: Sketch.references(d.kind), dimension: d)) }
        for t in soft {
            switch t {
            case .point(let id, _), .radius(let id, _): items.append(Item(refs: [id], soft: t))
            }
        }

        let fixed = Set(sketch.points.filter(\.fixed).map(\.id))
        let pointIDs = Set(sketch.points.map(\.id))
        let curveByID = Dictionary(sketch.curves.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        /// The points of some entities: points themselves, and the points curves are built from.
        func pointsOf(_ refs: [EntityID]) -> Set<EntityID> {
            var out = Set<EntityID>()
            for id in refs {
                if pointIDs.contains(id) { out.insert(id) } else if let c = curveByID[id] { out.formUnion(sketch.pointIDs(of: c)) }
            }
            return out
        }
        let circles = Set(sketch.curves.compactMap { c -> EntityID? in if case .circle = c.geometry { return c.id } else { return nil } })
        var parent: [EntityID: EntityID] = [:]
        func find(_ id: EntityID) -> EntityID {
            var root = id
            while let p = parent[root], p != root { root = p }
            var walk = id
            while let p = parent[walk], p != root { parent[walk] = root; walk = p }
            return root
        }
        var nodes: [[EntityID]] = [], points: [Set<EntityID>] = []
        for item in items {
            let pts = pointsOf(item.refs)
            var n = pts.subtracting(fixed)
            for r in item.refs where circles.contains(r) { n.insert(r) }
            let list = Array(n)
            for id in list where parent[id] == nil { parent[id] = id }
            if let first = list.first { let root = find(first); for id in list { parent[find(id)] = root } }
            nodes.append(list); points.append(pts)
        }

        struct Group {
            var points = Set<EntityID>()
            var curves = Set<EntityID>()
            var constraints: [SketchConstraint] = []
            var dimensions: [SketchDimension] = []
            var soft: [SoftTarget] = []
        }
        var groups: [EntityID: Group] = [:]
        var touched = Set<EntityID>(), used = Set<EntityID>()
        for (i, item) in items.enumerated() {
            let key = nodes[i].first.map(find) ?? "~"  // only fixed things: one group for all of those
            groups[key, default: Group()].points.formUnion(points[i])
            groups[key]!.curves.formUnion(item.refs)
            touched.formUnion(points[i]); used.formUnion(item.refs)
            if let c = item.constraint { groups[key]!.constraints.append(c) }
            if let d = item.dimension { groups[key]!.dimensions.append(d) }
            if let t = item.soft { groups[key]!.soft.append(t) }
        }

        var total = SolveResult(status: .solved, degreesOfFreedom: 0, maxResidual: 0, iterations: 0)
        for p in sketch.points where !p.fixed && !touched.contains(p.id) { total.degreesOfFreedom += 2 }
        for c in circles where !used.contains(c) { total.degreesOfFreedom += 1 }

        let index = Dictionary(uniqueKeysWithValues: sketch.points.indices.map { (sketch.points[$0].id, $0) })
        let curveIndex = Dictionary(uniqueKeysWithValues: sketch.curves.indices.map { (sketch.curves[$0].id, $0) })
        for g in groups.values {
            var part = Sketch()
            part.points = g.points.compactMap { index[$0] }.sorted().map { sketch.points[$0] }
            part.curves = g.curves.compactMap { curveIndex[$0] }.sorted().map { sketch.curves[$0] }
            part.constraints = g.constraints
            part.dimensions = g.dimensions
            let r = solveTogether(&part, dimensionValues: dimensionValues, soft: g.soft, softWeight: softWeight)
            for p in part.points { if let i = index[p.id], !p.fixed { sketch.points[i] = p } }
            for c in part.curves { if let i = curveIndex[c.id] { sketch.curves[i] = c } }
            if r.status == .failed { total.status = .failed }
            total.degreesOfFreedom += r.degreesOfFreedom
            total.maxResidual = max(total.maxResidual, r.maxResidual)
            total.iterations += r.iterations
        }
        return total
    }

    /// Solves with circle radii held first: where the constraints leave a choice, a circle moves
    /// rather than growing (a hole put 4 mm from an edge keeps its size). Only when that can't satisfy
    /// them are the radii solved for too.
    static func solveTogether(_ sketch: inout Sketch, dimensionValues: [EntityID: Double],
                              soft: [SoftTarget], softWeight: Double) -> SolveResult {
        let hasCircles = sketch.curves.contains { if case .circle = $0.geometry { return true } else { return false } }
        let pullsRadius = soft.contains { if case .radius = $0 { return true } else { return false } }
        if hasCircles, !pullsRadius {
            var trial = sketch
            let held = solveSystem(&trial, dimensionValues: dimensionValues, soft: soft, softWeight: softWeight, holdRadii: true)
            if held.hardResidual <= tolerance * 100 {
                sketch = trial
                var result = held.result
                var full = System(sketch)
                full.addConstraints(sketch, dimensionValues: dimensionValues)
                full.addSoft(soft, weight: softWeight)
                let x = full.initial
                result.degreesOfFreedom = x.count - (x.isEmpty ? 0 : matrixRank(full.jacobian(x), rows: full.terms.count, cols: x.count))
                return result
            }
        }
        return solveSystem(&sketch, dimensionValues: dimensionValues, soft: soft, softWeight: softWeight, holdRadii: false).result
    }

    private static func solveSystem(_ sketch: inout Sketch, dimensionValues: [EntityID: Double], soft: [SoftTarget],
                                    softWeight: Double, holdRadii: Bool) -> (result: SolveResult, hardResidual: Double) {
        var system = System(sketch, holdRadii: holdRadii)
        system.addConstraints(sketch, dimensionValues: dimensionValues)
        let hardTerms = system.terms.count
        system.addSoft(soft, weight: softWeight)
        var x = system.initial

        var f = system.residuals(x)
        var iterations = 0
        var lambda = 1e-3
        solving: while iterations < 200, maxAbs(f) > tolerance, !x.isEmpty {
            iterations += 1
            let J = system.jacobian(x)
            let n = x.count, m = f.count
            // Normal equations: (JᵀJ + λI) step = -Jᵀf
            var A = [Double](repeating: 0, count: n * n)
            var g = [Double](repeating: 0, count: n)
            for r in 0..<m {
                let row = r * n
                for i in 0..<n where J[row + i] != 0 {
                    g[i] += J[row + i] * f[r]
                    for j in 0..<n where J[row + j] != 0 { A[i * n + j] += J[row + i] * J[row + j] }
                }
            }
            let err = sumSquares(f)
            while true {
                var M = A
                for i in 0..<n { M[i * n + i] += lambda }
                if let step = choleskySolve(M, g.map { -$0 }, n) {
                    let xn = zip(x, step).map { $0 + $1 }
                    let fn = system.residuals(xn)
                    let errNew = sumSquares(fn)
                    if errNew < err {
                        x = xn; f = fn
                        lambda = max(lambda * 0.3, 1e-12)
                        // Converged to a least-squares minimum that isn't zero (soft targets, conflicts).
                        if err - errNew <= 1e-14 * max(err, 1e-30) + 1e-30 { break solving }
                        break
                    }
                }
                lambda *= 10
                if lambda > 1e12 { break solving }
            }
        }

        system.write(x, into: &sketch)
        let residual = maxAbs(f)
        let rank = x.isEmpty ? 0 : matrixRank(system.jacobian(x), rows: f.count, cols: x.count)
        let result = SolveResult(status: residual <= tolerance * 100 ? .solved : .failed,
                                 degreesOfFreedom: x.count - rank, maxResidual: residual, iterations: iterations)
        return (result, maxAbs(Array(f[0..<hardTerms])))
    }

    // MARK: - system assembly

    struct System {
        var initial: [Double] = []
        var pointSlot: [EntityID: Int] = [:]          // index of x-coordinate in the unknown vector
        var fixedPoints: [EntityID: SIMD2<Double>] = [:]
        var radiusSlot: [EntityID: Int] = [:]          // circles
        var heldRadius: [EntityID: Double] = [:]       // circles whose radius is held constant this pass
        var arcs: [EntityID: (center: EntityID, start: EntityID)] = [:]
        var lines: [EntityID: (EntityID, EntityID)] = [:]
        var circleCenters: [EntityID: EntityID] = [:]  // circles and arcs
        var beziers: [EntityID: [EntityID]] = [:]      // start, control 1, control 2, end
        var terms: [([Double]) -> Double] = []

        /// With `holdRadii`, circles keep the radius they have: nothing is solved for it.
        init(_ s: Sketch, holdRadii: Bool = false) {
            for p in s.points {
                if p.fixed { fixedPoints[p.id] = p.position } else {
                    pointSlot[p.id] = initial.count; initial += [p.x, p.y]
                }
            }
            for c in s.curves {
                switch c.geometry {
                case .line(let a, let b): lines[c.id] = (a, b)
                case .circle(let center, let r):
                    if holdRadii { heldRadius[c.id] = r } else { radiusSlot[c.id] = initial.count; initial.append(r) }
                    circleCenters[c.id] = center
                case .arc(let center, let start, _):
                    arcs[c.id] = (center, start); circleCenters[c.id] = center
                case .bezier(let a, let c1, let c2, let b):
                    beziers[c.id] = [a, c1, c2, b]
                }
            }
        }

        func p(_ id: EntityID, _ x: [Double]) -> SIMD2<Double> {
            if let i = pointSlot[id] { return SIMD2(x[i], x[i + 1]) }
            return fixedPoints[id] ?? .zero
        }
        func radius(_ id: EntityID, _ x: [Double]) -> Double {
            if let i = radiusSlot[id] { return x[i] }
            if let r = heldRadius[id] { return r }
            if let a = arcs[id] { return vlen(p(a.start, x) - p(a.center, x)) }
            return 0
        }
        /// A circle or arc's rim against a point, line, or another circle or arc (see RimGap).
        func rimGap(_ circle: EntityID, _ other: EntityID, _ x: [Double]) -> RimGap? {
            guard let c = circleCenters[circle] else { return nil }
            let target: RimGap.Other
            if let (a, b) = lines[other] { target = .line(p(a, x), p(b, x)) }
            else if let oc = circleCenters[other] { target = .circle(p(oc, x), radius(other, x)) }
            else { target = .point(p(other, x)) }
            return RimGap(center: p(c, x), radius: radius(circle, x), other: target)
        }
        func dir(_ line: EntityID, _ x: [Double]) -> SIMD2<Double> {
            guard case let (a, b)? = lines[line] else { return .zero }
            return p(b, x) - p(a, x)
        }

        mutating func add(_ t: @escaping ([Double]) -> Double) { terms.append(t) }

        mutating func addSoft(_ targets: [SoftTarget], weight w: Double) {
            let me = self
            for t in targets {
                switch t {
                case .point(let id, let target):
                    add { w * (me.p(id, $0).x - target.x) }
                    add { w * (me.p(id, $0).y - target.y) }
                case .radius(let id, let r):
                    add { w * (me.radius(id, $0) - r) }
                }
            }
        }

        mutating func addConstraints(_ s: Sketch, dimensionValues: [EntityID: Double]) {
            let me = self  // closures capture an immutable snapshot of the slot tables
            // Arcs keep both endpoints on the same circle.
            for c in s.curves {
                if case .arc(let center, let start, let end) = c.geometry {
                    add { vlen(me.p(end, $0) - me.p(center, $0)) - vlen(me.p(start, $0) - me.p(center, $0)) }
                }
            }
            for c in s.constraints { addConstraint(c.kind, me, s) }
            for d in s.dimensions {
                guard let v = dimensionValues[d.id] else { continue }
                addDimension(d.kind, v, me, s)
            }
        }

        mutating func addConstraint(_ k: SketchConstraint.Kind, _ me: System, _ s: Sketch) {
            func norm(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { max(vlen(a) * vlen(b), 1e-12) }
            switch k {
            case .coincident(let a, let b):
                add { me.p(a, $0).x - me.p(b, $0).x }
                add { me.p(a, $0).y - me.p(b, $0).y }
            case .horizontal(let l): add { me.dir(l, $0).y }
            case .vertical(let l): add { me.dir(l, $0).x }
            case .parallel(let a, let b):
                add { let u = me.dir(a, $0), v = me.dir(b, $0); return vcross(u, v) / norm(u, v) }
            case .perpendicular(let a, let b):
                add { let u = me.dir(a, $0), v = me.dir(b, $0); return vdot(u, v) / norm(u, v) }
            case .equal(let a, let b):
                if me.lines[a] != nil, me.lines[b] != nil {
                    add { vlen(me.dir(a, $0)) - vlen(me.dir(b, $0)) }
                } else {
                    add { me.radius(a, $0) - me.radius(b, $0) }
                }
            case .tangent(let a, let b):
                if let bz = me.beziers[a] ?? me.beziers[b], let line = me.lines[a] != nil ? a : (me.lines[b] != nil ? b : nil),
                   let ends = me.lines[line] {
                    // At the Bézier end the line shares a point with (its start, unless only the end is shared).
                    let atEnd = [ends.0, ends.1].contains(bz[3]) && ![ends.0, ends.1].contains(bz[0])
                    add {
                        let d = me.dir(line, $0)
                        let h = atEnd ? me.p(bz[3], $0) - me.p(bz[2], $0) : me.p(bz[1], $0) - me.p(bz[0], $0)
                        return vcross(d, h) / norm(d, h)
                    }
                } else if let line = me.lines[a] != nil ? a : (me.lines[b] != nil ? b : nil) {
                    let circle = line == a ? b : a
                    guard let center = me.circleCenters[circle], let ends = me.lines[line] else { return }
                    add {
                        let d = me.dir(line, $0)
                        return abs(vcross(d, me.p(center, $0) - me.p(ends.0, $0))) / max(vlen(d), 1e-12) - me.radius(circle, $0)
                    }
                } else if let ca = me.circleCenters[a], let cb = me.circleCenters[b] {
                    // External or internal tangency, whichever the current geometry is closer to.
                    let x0 = me.initial
                    let d0 = vlen(me.p(ca, x0) - me.p(cb, x0))
                    let external = abs(d0 - (me.radius(a, x0) + me.radius(b, x0))) <= abs(d0 - abs(me.radius(a, x0) - me.radius(b, x0)))
                    add {
                        let d = vlen(me.p(ca, $0) - me.p(cb, $0))
                        return external ? d - (me.radius(a, $0) + me.radius(b, $0)) : d - abs(me.radius(a, $0) - me.radius(b, $0))
                    }
                }
            case .pointOnCurve(let pt, let c):
                if let ends = me.lines[c] {
                    add { let d = me.dir(c, $0); return vcross(d, me.p(pt, $0) - me.p(ends.0, $0)) / max(vlen(d), 1e-12) }
                } else if let center = me.circleCenters[c] {
                    add { vlen(me.p(pt, $0) - me.p(center, $0)) - me.radius(c, $0) }
                } else if let bz = me.beziers[c] {
                    add { x in
                        // Signed distance from the point to the curve, along the curve's normal.
                        let ctrl = bz.map { me.p($0, x) }, q = me.p(pt, x)
                        let t = Bezier.closest(q, ctrl)
                        let b = Bezier.point(ctrl, t), d = Bezier.derivative(ctrl, t)
                        let len = vlen(d)
                        return len > 1e-12 ? vcross(d, q - b) / len : vlen(q - b)
                    }
                }
            case .midpoint(let pt, let l):
                guard case let (a, b)? = me.lines[l] else { return }
                add { me.p(pt, $0).x - (me.p(a, $0).x + me.p(b, $0).x) / 2 }
                add { me.p(pt, $0).y - (me.p(a, $0).y + me.p(b, $0).y) / 2 }
            case .symmetric(let a, let b, let l):
                // The middle of a–b on the line, and a–b square to it.
                guard case let (l0, _)? = me.lines[l] else { return }
                add {
                    let d = me.dir(l, $0), m = (me.p(a, $0) + me.p(b, $0)) / 2
                    return vcross(d, m - me.p(l0, $0)) / max(vlen(d), 1e-12)
                }
                add {
                    let d = me.dir(l, $0)
                    return vdot(d, me.p(b, $0) - me.p(a, $0)) / max(vlen(d), 1e-12)
                }
            case .fix(let pt, let fx, let fy):
                add { me.p(pt, $0).x - fx }
                add { me.p(pt, $0).y - fy }
            }
        }

        mutating func addDimension(_ k: SketchDimension.Kind, _ v: Double, _ me: System, _ s: Sketch) {
            let x0 = me.initial
            switch k {
            case .distance(let a, let b): add { vlen(me.p(b, $0) - me.p(a, $0)) - v }
            case .horizontalDistance(let a, let b):
                let sign: Double = me.p(b, x0).x >= me.p(a, x0).x ? 1 : -1  // keep the current side
                add { (me.p(b, $0).x - me.p(a, $0).x) - sign * v }
            case .verticalDistance(let a, let b):
                let sign: Double = me.p(b, x0).y >= me.p(a, x0).y ? 1 : -1
                add { (me.p(b, $0).y - me.p(a, $0).y) - sign * v }
            case .pointLineDistance(let pt, let l):
                guard case let (a, _)? = me.lines[l] else { return }
                let d0 = me.dir(l, x0)
                let sign: Double = vcross(d0, me.p(pt, x0) - me.p(a, x0)) >= 0 ? 1 : -1
                add { let d = me.dir(l, $0); return vcross(d, me.p(pt, $0) - me.p(a, $0)) / max(vlen(d), 1e-12) - sign * v }
            case .length(let l): add { vlen(me.dir(l, $0)) - v }
            case .radius(let c): add { me.radius(c, $0) - v }
            case .diameter(let c): add { 2 * me.radius(c, $0) - v }
            case .radialOffset(let a, let b):
                let sign: Double = me.radius(b, x0) >= me.radius(a, x0) ? 1 : -1  // keep the current side
                add { (me.radius(b, $0) - me.radius(a, $0)) - sign * v }
            case .gap(let a, let b):
                guard let g0 = me.rimGap(a, b, x0) else { return }
                let side = g0.side, sign: Double = g0.gap(side) >= 0 ? 1 : -1  // keep the current side
                add { me.rimGap(a, b, $0).map { sign * $0.gap(side) - v } ?? 0 }
            case .lineAngle(let l):
                // The line's direction from the x-axis, less the value on the side it is on (above or below),
                // wrapped to ±π: no second solution, and a long turn runs straight to the target.
                let side: Double = me.dir(l, x0).y < 0 ? -1 : 1, target = side * Sketch.foldedAngle(v)
                add {
                    let u = me.dir(l, $0), d = atan2(u.y, u.x) - target
                    return atan2(sin(d), cos(d))
                }
            case .angle(let a, let b):
                // sin(θ - v) where θ is the ccw angle from a to b; zero at θ = v.
                add {
                    let u = me.dir(a, $0), w = me.dir(b, $0)
                    return (vcross(u, w) * cos(v) - vdot(u, w) * sin(v)) / max(vlen(u) * vlen(w), 1e-12)
                }
                // Reject the θ = v + π branch.
                add {
                    let u = me.dir(a, $0), w = me.dir(b, $0)
                    let c = (vdot(u, w) * cos(v) + vcross(u, w) * sin(v)) / max(vlen(u) * vlen(w), 1e-12)
                    return c >= 0 ? 0 : c
                }
            }
        }

        func residuals(_ x: [Double]) -> [Double] { terms.map { $0(x) } }

        /// Dense row-major Jacobian by central differences.
        func jacobian(_ x: [Double]) -> [Double] {
            let n = x.count, m = terms.count
            var J = [Double](repeating: 0, count: m * n)
            var xp = x
            for j in 0..<n {
                let h = 1e-7 * max(1, abs(x[j]))
                xp[j] = x[j] + h; let fp = residuals(xp)
                xp[j] = x[j] - h; let fm = residuals(xp)
                xp[j] = x[j]
                for r in 0..<m { J[r * n + j] = (fp[r] - fm[r]) / (2 * h) }
            }
            return J
        }

        func write(_ x: [Double], into s: inout Sketch) {
            for i in s.points.indices {
                if let k = pointSlot[s.points[i].id] { s.points[i].x = x[k]; s.points[i].y = x[k + 1] }
            }
            for i in s.curves.indices {
                if case .circle(let c, _) = s.curves[i].geometry, let k = radiusSlot[s.curves[i].id] {
                    s.curves[i].geometry = .circle(center: c, radius: x[k])
                }
            }
        }
    }

    // MARK: - small dense linear algebra (sketches have at most a few hundred unknowns)

    static func maxAbs(_ v: [Double]) -> Double { v.reduce(0) { max($0, abs($1)) } }
    static func sumSquares(_ v: [Double]) -> Double { v.reduce(0) { $0 + $1 * $1 } }

    /// Solves the symmetric positive definite system M x = b. Nil if M is not SPD.
    static func choleskySolve(_ M: [Double], _ b: [Double], _ n: Int) -> [Double]? {
        var L = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = M[i * n + j]
                for k in 0..<j { sum -= L[i * n + k] * L[j * n + k] }
                if i == j {
                    guard sum > 1e-300 else { return nil }
                    L[i * n + i] = sum.squareRoot()
                } else {
                    L[i * n + j] = sum / L[j * n + j]
                }
            }
        }
        var y = b
        for i in 0..<n {
            for k in 0..<i { y[i] -= L[i * n + k] * y[k] }
            y[i] /= L[i * n + i]
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            for k in (i + 1)..<n { y[i] -= L[k * n + i] * y[k] }
            y[i] /= L[i * n + i]
        }
        return y.allSatisfy(\.isFinite) ? y : nil
    }

    /// Numerical rank by Gaussian elimination with partial pivoting.
    static func matrixRank(_ J: [Double], rows m: Int, cols n: Int) -> Int {
        var A = J
        let scale = max(maxAbs(J), 1)
        var rank = 0
        for col in 0..<n where rank < m {
            var pivot = rank
            for r in rank..<m where abs(A[r * n + col]) > abs(A[pivot * n + col]) { pivot = r }
            guard abs(A[pivot * n + col]) > 1e-7 * scale else { continue }
            if pivot != rank { for c in 0..<n { A.swapAt(pivot * n + c, rank * n + c) } }
            for r in (rank + 1)..<m {
                let f = A[r * n + col] / A[rank * n + col]
                if f != 0 { for c in col..<n { A[r * n + c] -= f * A[rank * n + c] } }
            }
            rank += 1
        }
        return rank
    }
}

extension SketchSolver {
    /// Solves after dimensions changed, moving only what they're about when that's enough: first
    /// with everything else held still, then letting the geometry next to it move too, ring by
    /// ring, and only then everything. So typing a rounded corner's radius moves the arc and its
    /// two touch points, not the whole rectangle a little. Nothing changed: a plain solve.
    public static func solveLocally(_ sketch: inout Sketch, dimensionValues: [EntityID: Double]) -> SolveResult {
        if sketch.points.contains(where: { Sketch.isGenerated($0.id) }) {
            let generated = sketch.takeGenerated()
            defer { sketch.restoreGenerated(generated) }
            return solveLocally(&sketch, dimensionValues: dimensionValues)
        }
        var moving = Set<EntityID>(), anchored = Set<EntityID>()
        for d in sketch.dimensions {
            guard let target = dimensionValues[d.id], let now = sketch.measure(d.kind), abs(now - target) > 1e-9 else { continue }
            let anchors = sketch.anchorPoints(of: d.kind)
            moving.formUnion(sketch.points(of: Sketch.references(d.kind)).subtracting(anchors))
            anchored.formUnion(anchors)
        }
        anchored.subtract(moving)  // held, unless another dimension has to move it
        guard !moving.isEmpty else { return solve(&sketch, dimensionValues: dimensionValues) }
        for _ in 0..<4 {
            var trial = sketch
            for i in trial.points.indices where !moving.contains(trial.points[i].id) { trial.points[i].fixed = true }
            if solve(&trial, dimensionValues: dimensionValues).status == .solved {
                for i in trial.points.indices { trial.points[i].fixed = sketch.points[i].fixed }  // held only for this solve
                sketch = trial
                return solve(&sketch, dimensionValues: dimensionValues)  // already solved: reports the real freedom
            }
            let wider = moving.union(sketch.neighbours(of: moving)).subtracting(anchored)
            if wider == moving { break }
            moving = wider
        }
        return solve(&sketch, dimensionValues: dimensionValues)
    }
}

extension Sketch {
    /// The points that stay put when a dimension's value is changed (see anchors(of:)); a line's angle turns it about its start.
    func anchorPoints(of kind: SketchDimension.Kind) -> Set<EntityID> {
        var out = points(of: Sketch.anchors(of: kind))
        if case .lineAngle(let l) = kind, case .line(let start, _)? = curve(l)?.geometry { out.insert(start) }
        return out
    }

    /// The points of some entities: points themselves, and the points curves are built from.
    func points(of ids: [EntityID]) -> Set<EntityID> {
        var out = Set<EntityID>()
        for id in ids {
            if point(id) != nil { out.insert(id) } else if let c = curve(id) { out.formUnion(pointIDs(of: c)) }
        }
        return out
    }

    /// Points one step away from `points`: on the same curves, or tied to them by a constraint.
    func neighbours(of points: Set<EntityID>) -> Set<EntityID> {
        var out = Set<EntityID>()
        for c in curves where !points.isDisjoint(with: pointIDs(of: c)) { out.formUnion(pointIDs(of: c)) }
        for c in constraints {
            let tied = self.points(of: Sketch.references(c.kind))
            if !points.isDisjoint(with: tied) { out.formUnion(tied) }
        }
        return out
    }
}
