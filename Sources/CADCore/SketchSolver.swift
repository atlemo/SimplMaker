// Geometric constraint solver: Levenberg–Marquardt on constraint residuals.
//
// Unknowns are the coordinates of non-fixed points and circle radii (an arc's radius is
// implied by its center and start point). Every constraint and dimension contributes one
// or two residuals that are zero when satisfied. Starting from the current geometry, the
// damped Gauss–Newton steps move the geometry as little as possible, which is what makes
// an under-constrained sketch "stay where it is" while dimensions change.
//
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct SolveResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case solved, failed }
    public var status: Status
    /// Remaining degrees of freedom (0 = fully constrained).
    public var degreesOfFreedom: Int
    public var maxResidual: Double
    public var iterations: Int
}

public enum SketchSolver {
    public static let tolerance = 1e-9

    /// Solves `sketch` in place. `dimensionValues` maps dimension id -> value in base units (mm / rad).
    public static func solve(_ sketch: inout Sketch, dimensionValues: [EntityID: Double]) -> SolveResult {
        var system = System(sketch)
        system.addConstraints(sketch, dimensionValues: dimensionValues)
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
                    if sumSquares(fn) < err {
                        x = xn; f = fn
                        lambda = max(lambda * 0.3, 1e-12)
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
        return SolveResult(status: residual <= tolerance * 100 ? .solved : .failed,
                           degreesOfFreedom: x.count - rank, maxResidual: residual, iterations: iterations)
    }

    // MARK: - system assembly

    struct System {
        var initial: [Double] = []
        var pointSlot: [EntityID: Int] = [:]          // index of x-coordinate in the unknown vector
        var fixedPoints: [EntityID: SIMD2<Double>] = [:]
        var radiusSlot: [EntityID: Int] = [:]          // circles
        var arcs: [EntityID: (center: EntityID, start: EntityID)] = [:]
        var lines: [EntityID: (EntityID, EntityID)] = [:]
        var circleCenters: [EntityID: EntityID] = [:]  // circles and arcs
        var terms: [([Double]) -> Double] = []

        init(_ s: Sketch) {
            for p in s.points {
                if p.fixed { fixedPoints[p.id] = p.position } else {
                    pointSlot[p.id] = initial.count; initial += [p.x, p.y]
                }
            }
            for c in s.curves {
                switch c.geometry {
                case .line(let a, let b): lines[c.id] = (a, b)
                case .circle(let center, let r):
                    radiusSlot[c.id] = initial.count; initial.append(r); circleCenters[c.id] = center
                case .arc(let center, let start, _):
                    arcs[c.id] = (center, start); circleCenters[c.id] = center
                }
            }
        }

        func p(_ id: EntityID, _ x: [Double]) -> SIMD2<Double> {
            if let i = pointSlot[id] { return SIMD2(x[i], x[i + 1]) }
            return fixedPoints[id] ?? .zero
        }
        func radius(_ id: EntityID, _ x: [Double]) -> Double {
            if let i = radiusSlot[id] { return x[i] }
            if let a = arcs[id] { return vlen(p(a.start, x) - p(a.center, x)) }
            return 0
        }
        func dir(_ line: EntityID, _ x: [Double]) -> SIMD2<Double> {
            guard case let (a, b)? = lines[line] else { return .zero }
            return p(b, x) - p(a, x)
        }

        mutating func add(_ t: @escaping ([Double]) -> Double) { terms.append(t) }

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
                if let line = me.lines[a] != nil ? a : (me.lines[b] != nil ? b : nil) {
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
                }
            case .midpoint(let pt, let l):
                guard case let (a, b)? = me.lines[l] else { return }
                add { me.p(pt, $0).x - (me.p(a, $0).x + me.p(b, $0).x) / 2 }
                add { me.p(pt, $0).y - (me.p(a, $0).y + me.p(b, $0).y) / 2 }
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
