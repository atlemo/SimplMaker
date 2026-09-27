// Cubic Bézier math for sketch curves: evaluation, the closest point, splitting and flattening.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum Bezier {
    /// Point at t (0…1) of the cubic with control points p.
    public static func point(_ p: [SIMD2<Double>], _ t: Double) -> SIMD2<Double> {
        let u = 1 - t
        // Weights first, as plain numbers: one long mixed expression is too slow to type-check.
        let w0: Double = u * u * u, w1: Double = 3 * u * u * t, w2: Double = 3 * u * t * t, w3: Double = t * t * t
        let a: SIMD2<Double> = w0 * p[0] + w1 * p[1]
        return a + w2 * p[2] + w3 * p[3]
    }

    /// First derivative at t.
    public static func derivative(_ p: [SIMD2<Double>], _ t: Double) -> SIMD2<Double> {
        let u = 1 - t
        let w0: Double = 3 * u * u, w1: Double = 6 * u * t, w2: Double = 3 * t * t
        let a: SIMD2<Double> = w0 * (p[1] - p[0]) + w1 * (p[2] - p[1])
        return a + w2 * (p[3] - p[2])
    }

    /// Parameter (0…1) of the curve point closest to q: the best of a coarse sampling, refined by Newton steps.
    public static func closest(_ q: SIMD2<Double>, _ p: [SIMD2<Double>]) -> Double {
        let n = 32
        var best = 0.0, bestD = Double.infinity
        for i in 0...n {
            let t = Double(i) / Double(n), d = vlen(point(p, t) - q)
            if d < bestD { bestD = d; best = t }
        }
        var t = best
        for _ in 0..<8 {
            // Minimise |B(t) − q|²: Newton on f(t) = B′(t)·(B(t) − q).
            let b = point(p, t), d1 = derivative(p, t)
            let u = 1 - t
            let bend0: SIMD2<Double> = p[2] - 2 * p[1] + p[0], bend1: SIMD2<Double> = p[3] - 2 * p[2] + p[1]
            let d2: SIMD2<Double> = (6 * u) * bend0 + (6 * t) * bend1
            let f = vdot(d1, b - q), df = vdot(d2, b - q) + vdot(d1, d1)
            guard abs(df) > 1e-300 else { break }
            let next = min(max(t - f / df, 0), 1)
            if abs(next - t) < 1e-12 { t = next; break }
            t = next
        }
        return t
    }

    /// The control points of the piece of the curve between t0 and t1 (de Casteljau).
    public static func piece(_ p: [SIMD2<Double>], from t0: Double, to t1: Double) -> [SIMD2<Double>] {
        func split(_ p: [SIMD2<Double>], _ t: Double) -> (left: [SIMD2<Double>], right: [SIMD2<Double>]) {
            let a = p[0] + (p[1] - p[0]) * t, b = p[1] + (p[2] - p[1]) * t, c = p[2] + (p[3] - p[2]) * t
            let d = a + (b - a) * t, e = b + (c - b) * t
            let f = d + (e - d) * t
            return ([p[0], a, d, f], [f, e, c, p[3]])
        }
        let tail = split(p, t0).right
        guard t1 < 1 else { return tail }
        return split(tail, t0 < 1 ? (t1 - t0) / (1 - t0) : 0).left
    }

    /// The curve as a polyline of `steps` segments.
    public static func flatten(_ p: [SIMD2<Double>], steps: Int = 48) -> [SIMD2<Double>] {
        (0...steps).map { point(p, Double($0) / Double(steps)) }
    }
}
